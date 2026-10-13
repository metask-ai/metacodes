#!/usr/bin/env python3
"""Talk to a state root's local TinyKG service (`metacodes kgd`) the way a
session does: the port and key come from `<state root>/kg/daemon.json`, and
requests go to `GET /api/ready` and `POST /api/run` with `x-api-key`
(doc/TINYKG_INTEGRATION.md, "The local service"; the envelope mirrors
src/kg/transport.zig `runWithRequestId`).

  kgd_api.py ready <state root> [--wait SECONDS]   exit 0 once the service is ready
  kgd_api.py run <state root> <command> [args...]  print the command's stdout

Standard library only: the e2e smokes run it on bare hosts.
"""
import itertools
import json
import os
import sys
import time
import urllib.error
import urllib.request

PROTOCOL_VERSION = 2
REQUIRED_CAPABILITIES = ["task-hierarchy-canonical-read-v1"]
_request_ids = itertools.count(1)


def _config(state_root):
    with open(os.path.join(state_root, "kg", "daemon.json"), encoding="utf-8") as handle:
        return json.load(handle)


def _request(config, path, body=None, timeout=10):
    data = None if body is None else json.dumps(body).encode("utf-8")
    request = urllib.request.Request(
        config["url"].rstrip("/") + path,
        data=data,
        method="GET" if body is None else "POST",
        headers={"x-api-key": config["api_key"], "content-type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


def ready(state_root, wait):
    deadline = time.monotonic() + wait
    last = None
    while True:
        try:
            answer = _request(_config(state_root), "/api/ready", timeout=2)
            if answer.get("ok") and answer.get("ready") and not answer.get("degraded"):
                return 0
            last = answer
        except (OSError, ValueError, urllib.error.URLError) as error:
            last = error
        if time.monotonic() >= deadline:
            print(f"kgd_api: the service under {state_root} is not ready: {last}", file=sys.stderr)
            return 1
        time.sleep(0.1)


def run(state_root, command, args):
    answer = _request(
        _config(state_root),
        "/api/run",
        {
            "protocolVersion": PROTOCOL_VERSION,
            "requestId": f"process-smoke-{os.getpid()}-{next(_request_ids)}",
            "command": command,
            "args": args,
            "sessionId": None,
            "timeoutMs": 30000,
            "requiredCapabilities": REQUIRED_CAPABILITIES,
        },
        timeout=40,
    )
    if not answer.get("ok"):
        print(f"kgd_api: {command} failed: {json.dumps(answer)}", file=sys.stderr)
        return 1
    sys.stdout.write(answer.get("stdout") or "")
    return 0


def main(argv):
    if len(argv) >= 2 and argv[0] == "ready":
        wait = float(argv[3]) if len(argv) >= 4 and argv[2] == "--wait" else 30.0
        return ready(argv[1], wait)
    if len(argv) >= 3 and argv[0] == "run":
        return run(argv[1], argv[2], argv[3:])
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
