#!/usr/bin/env python3
"""`alfworld`: the agent's only handle on the ALFWorld environment sidecar.

Installed as /usr/local/bin/alfworld in the agent's container. Python 3.9+,
stdlib only. Talks to $ALFWORLD_URL (default http://alfworld-env:8080).

  alfworld look              the task and the latest observation
  alfworld act "<command>"   one action (counts against the step budget)
  alfworld actions           commands that are valid right now
  alfworld status            steps used, budget, whether the task is complete
"""

from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.request
from typing import Dict, List, Optional

BASE = os.environ.get("ALFWORLD_URL", "http://alfworld-env:8080").rstrip("/")
# The environment is a sibling service on the task's own Docker network. A
# proxy injected into the container (HTTP_PROXY) cannot resolve its service
# name, so this client never uses one.
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def call(method: str, path: str, payload: Optional[Dict[str, object]] = None, attempts: int = 30) -> Dict[str, object]:
    data = None if payload is None else json.dumps(payload).encode("utf-8")
    last: Optional[BaseException] = None
    for _ in range(attempts):
        request = urllib.request.Request(BASE + path, data=data, method=method, headers={"Content-Type": "application/json"})
        try:
            with OPENER.open(request, timeout=600) as response:
                return json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as error:
            body = json.loads(error.read().decode("utf-8") or "{}")
            body.setdefault("error", "HTTP %d" % error.code)
            body["_status"] = error.code
            return body
        except (urllib.error.URLError, ConnectionError) as error:
            last = error  # the sidecar may still be starting
            time.sleep(2)
    raise SystemExit("alfworld: environment unreachable at %s (%s)" % (BASE, last))


def footer(state: Dict[str, object]) -> str:
    status = "COMPLETE" if state.get("won") else ("OVER" if state.get("done") else "in progress")
    return "[steps %s/%s, task %s]" % (state.get("steps"), state.get("max_steps"), status)


def main(argv: List[str]) -> int:
    if not argv or argv[0] in ("-h", "--help", "help"):
        print(__doc__.split("\n\n", 1)[1].strip())
        return 0
    command, rest = argv[0], argv[1:]
    if command == "look":
        state = call("GET", "/observation")
        print(state.get("task", ""))
        if state.get("steps"):
            print("\nLatest observation:\n" + str(state.get("observation", "")))
        print("\n" + footer(state))
        return 0
    if command == "act":
        action = " ".join(rest).strip()
        if not action:
            print('usage: alfworld act "<command>"', file=sys.stderr)
            return 2
        state = call("POST", "/step", {"action": action})
        if "_status" in state:
            print("alfworld: " + str(state.get("error")), file=sys.stderr)
            print(footer(state))
            return 1
        print(state.get("observation", ""))
        print(footer(state))
        return 0
    if command == "actions":
        state = call("GET", "/actions")
        for item in state.get("actions") or []:  # type: ignore[union-attr]
            print(item)
        print(footer(state))
        return 0
    if command == "status":
        state = call("GET", "/observation")
        print(footer(state))
        return 0
    if command == "oracle":  # used by the task's solution/solve.sh only
        state = call("POST", "/oracle", {"token": rest[0] if rest else ""})
        print(json.dumps(state))
        return 0 if state.get("won") else 1
    print("alfworld: unknown command %r (try: look, act, actions, status)" % command, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
