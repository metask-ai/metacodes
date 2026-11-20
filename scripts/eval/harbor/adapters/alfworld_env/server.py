"""ALFWorld environment sidecar: one TextWorld game behind a small HTTP API.

Runs as the `alfworld-env` compose service of an ALFWorld task (see
../alfworld.py). The game file, the oracle token and this server live only in
this container; the agent's container reaches it over the compose network
through the `alfworld` CLI (alfworld_cli.py) and cannot read or write its
files. The server is therefore the only witness of the episode: it counts
actions, enforces the step budget, and writes the authoritative record to
/var/lib/alfworld/result.json after every action. Harbor's collect hook
freezes it (POST /finalize from inside this container) when the agent phase
ends and collects the file as an artifact for the separate verifier.

API (JSON over HTTP, port 8080):
  GET  /observation  task text, latest observation, steps, budget, done, won
  GET  /actions      admissible commands in the current state
  POST /step         {"action": str} -> observation; one step of the budget
  POST /oracle       {"token": str} -> plays the planner's solution (oracle agent only)
  POST /finalize     loopback only; no further actions are accepted

Python 3.9+. The TextWorld backend needs alfworld==0.4.2 / textworld==1.6.2
(installed in this image); the episode logic is backend-agnostic so it is
unit-tested without them.
"""

from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Dict, List, Optional, Tuple

MAX_ACTION_CHARS = 200
SCHEMA = 1


class EpisodeClosed(Exception):
    """No further actions: the task is complete, the budget is spent, or the episode is frozen."""


class TextWorldGame:
    """The real backend: alfworld's TextWorld wrappers over one game.tw-pddl."""

    def __init__(self, gamefile: Path, max_steps: int) -> None:
        self.gamefile = str(gamefile)
        self.max_steps = max_steps
        self.env = self._make(expert=False)
        self.infos: Dict[str, object] = {}

    def _make(self, expert: bool):  # pragma: no cover - needs textworld
        import textworld
        import textworld.gym
        from alfworld.agents.environment.alfred_tw_env import AlfredDemangler, AlfredInfos

        # As AlfredTWEnv.init_env for evaluation: no domain randomisation. The
        # expert copy asks TextWorld for the PDDL planner's `policy_commands`,
        # which is what AlfredExpert("planner") exposes as expert_plan; the
        # AlfredExpert wrapper itself also needs ALFRED's traj_data.json.
        request_infos = textworld.EnvInfos(
            won=True, admissible_commands=True, policy_commands=expert, extras=["gamefile"]
        )
        wrappers = [AlfredDemangler(shuffle=False), AlfredInfos]
        env_id = textworld.gym.register_game(
            self.gamefile, request_infos, max_episode_steps=self.max_steps + 10, wrappers=wrappers
        )
        return textworld.gym.make(env_id)

    def reset(self) -> str:  # pragma: no cover - needs textworld
        obs, infos = self.env.reset()
        self.infos = infos
        return str(obs)

    def step(self, action: str) -> Tuple[str, bool]:  # pragma: no cover - needs textworld
        obs, _score, _done, infos = self.env.step(action)
        self.infos = infos
        return str(obs), bool(infos.get("won"))

    def admissible(self) -> List[str]:  # pragma: no cover - needs textworld
        return [str(cmd) for cmd in self.infos.get("admissible_commands") or []]

    def expert_plan(self, limit: int) -> List[str]:  # pragma: no cover - needs textworld
        """The PDDL planner's commands from the initial state, played on a private copy."""
        env = self._make(expert=True)
        _obs, infos = env.reset()
        plan: List[str] = []
        while len(plan) < limit and not infos.get("won"):
            options = infos.get("policy_commands") or []
            if not options:
                break
            command = str(options[0])
            plan.append(command)
            _obs, _score, _done, infos = env.step(command)
        return plan


class Episode:
    """The step budget and the authoritative record of one episode."""

    def __init__(self, game, *, task_id: str, game_sha256: str, max_steps: int, result_path: Path) -> None:
        self.game = game
        self.task_id = task_id
        self.game_sha256 = game_sha256
        self.max_steps = max_steps
        self.result_path = result_path
        self.lock = threading.Lock()
        self.initial_observation = game.reset()
        self.last_observation = self.initial_observation
        self.trajectory: List[Dict[str, object]] = []
        self.won = False
        self.finalized = False
        self.oracle_used = False
        self.persist()

    @property
    def steps(self) -> int:
        return len(self.trajectory)

    @property
    def done(self) -> bool:
        return self.won or self.steps >= self.max_steps or self.finalized

    def state(self) -> Dict[str, object]:
        return {
            "task": self.initial_observation,
            "observation": self.last_observation,
            "steps": self.steps,
            "max_steps": self.max_steps,
            "done": self.done,
            "won": self.won,
        }

    def step(self, action: str) -> Dict[str, object]:
        action = " ".join(str(action).split())[:MAX_ACTION_CHARS]
        if not action:
            raise ValueError("empty action")
        if self.done:
            raise EpisodeClosed(self._closed_reason())
        observation, won = self.game.step(action)
        self.last_observation = observation
        self.won = bool(won)
        self.trajectory.append({"action": action, "observation": observation, "won": self.won})
        self.persist()
        return self.state()

    def admissible(self) -> List[str]:
        return [] if self.done else self.game.admissible()

    def run_oracle(self, plan: List[str]) -> Dict[str, object]:
        if self.steps:
            raise EpisodeClosed("the oracle only runs from the initial state")
        self.oracle_used = True
        for action in plan:
            if self.done:
                break
            self.step(action)
        self.persist()
        return self.state()

    def finalize(self) -> Dict[str, object]:
        self.finalized = True
        self.persist()
        return self.record()

    def _closed_reason(self) -> str:
        if self.won:
            return "the task is already complete"
        if self.finalized:
            return "the episode has ended"
        return "the step budget of %d actions is spent" % self.max_steps

    def record(self) -> Dict[str, object]:
        return {
            "schema": SCHEMA,
            "task_id": self.task_id,
            "game_sha256": self.game_sha256,
            "max_steps": self.max_steps,
            "steps": self.steps,
            "won": self.won,
            "done": self.done,
            "finalized": self.finalized,
            "oracle_used": self.oracle_used,
            "initial_observation": self.initial_observation,
            "trajectory": self.trajectory,
        }

    def persist(self) -> None:
        self.result_path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.result_path.with_name(self.result_path.name + ".tmp")
        tmp.write_text(json.dumps(self.record(), indent=1) + "\n", encoding="utf-8")
        os.replace(tmp, self.result_path)


def make_handler(episode: Episode, oracle_token: Optional[str]):
    class Handler(BaseHTTPRequestHandler):
        server_version = "alfworld-env/1"

        def log_message(self, fmt, *args):  # noqa: A003 - keep container logs quiet
            pass

        def _send(self, code: int, payload: object) -> None:
            body = json.dumps(payload).encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _body(self) -> Dict[str, object]:
            length = int(self.headers.get("Content-Length") or 0)
            if length > 1 << 16:
                raise ValueError("request too large")
            data = json.loads(self.rfile.read(length) or b"{}")
            if not isinstance(data, dict):
                raise ValueError("expected a JSON object")
            return data

        def do_GET(self) -> None:  # noqa: N802
            with episode.lock:
                if self.path == "/observation":
                    self._send(200, episode.state())
                elif self.path == "/actions":
                    self._send(200, {"actions": episode.admissible(), **episode.state()})
                elif self.path == "/health":
                    self._send(200, {"ok": True})
                else:
                    self._send(404, {"error": "not found"})

        def do_POST(self) -> None:  # noqa: N802
            try:
                body = self._body()
            except ValueError as error:
                self._send(400, {"error": str(error)})
                return
            with episode.lock:
                try:
                    if self.path == "/step":
                        self._send(200, episode.step(str(body.get("action") or "")))
                    elif self.path == "/oracle":
                        token = str(body.get("token") or "")
                        if not oracle_token or not hmac.compare_digest(token, oracle_token):
                            self._send(403, {"error": "forbidden"})
                            return
                        self._send(200, episode.run_oracle(episode.game.expert_plan(episode.max_steps)))
                    elif self.path == "/finalize":
                        if self.client_address[0] not in ("127.0.0.1", "::1"):
                            self._send(403, {"error": "forbidden"})
                            return
                        self._send(200, episode.finalize())
                    else:
                        self._send(404, {"error": "not found"})
                except EpisodeClosed as error:
                    self._send(409, {"error": str(error), **episode.state()})
                except ValueError as error:
                    self._send(400, {"error": str(error)})

    return Handler


def serve(episode: Episode, oracle_token: Optional[str], host: str, port: int) -> ThreadingHTTPServer:
    return ThreadingHTTPServer((host, port), make_handler(episode, oracle_token))


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--game", type=Path, required=True)
    parser.add_argument("--task", type=Path, required=True, help="task.json: task_id, max_steps")
    parser.add_argument("--oracle-token", type=Path)
    parser.add_argument("--result", type=Path, default=Path("/var/lib/alfworld/result.json"))
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8080)
    args = parser.parse_args(argv)
    task = json.loads(args.task.read_text(encoding="utf-8"))
    game_sha256 = hashlib.sha256(args.game.read_bytes()).hexdigest()
    if game_sha256 != task["game_sha256"]:
        print("game file does not match task.json", file=sys.stderr)
        return 2
    token = args.oracle_token.read_text(encoding="utf-8").strip() if args.oracle_token else None
    max_steps = int(task["max_steps"])
    episode = Episode(
        TextWorldGame(args.game, max_steps),
        task_id=str(task["task_id"]),
        game_sha256=game_sha256,
        max_steps=max_steps,
        result_path=args.result,
    )
    server = serve(episode, token, args.host, args.port)
    print("alfworld-env ready on %s:%d" % (args.host, args.port), flush=True)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
