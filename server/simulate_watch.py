"""Pretend to be the watch. Useful for testing the server before sideloading.

    export TIMELOG_URL=https://your.domain/timelog
    export TIMELOG_TOKEN_SECRET=...

    python simulate_watch.py domains          # list what the watch would show
    python simulate_watch.py start 0          # start domain index 0, now
    python simulate_watch.py start 3 -600     # start domain 3, ten minutes ago
    python simulate_watch.py stop
    python simulate_watch.py replay           # resend the last batch (dedupe check)

Press ids are kept in .sim_state.json so replay sends genuinely identical
payloads, which is the only way to actually exercise the idempotency path.
"""

import json
import os
import sys
import time
from typing import Optional
import urllib.error
import urllib.request

STATE = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".sim_state.json")


def load_state() -> dict:
    if os.path.exists(STATE):
        with open(STATE) as fh:
            return json.load(fh)
    # Same seeding rule as the watch: start from the clock so ids never collide
    # with a previous install's.
    return {"next_id": int(time.time()), "last_batch": []}


def save_state(s: dict) -> None:
    with open(STATE, "w") as fh:
        json.dump(s, fh)


def call(path: str, body: Optional[dict]):
    base = os.environ.get("TIMELOG_URL")
    token = os.environ.get("TIMELOG_TOKEN_SECRET")
    if not base or not token:
        print("Set TIMELOG_URL and TIMELOG_TOKEN_SECRET", file=sys.stderr)
        raise SystemExit(1)

    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        base.rstrip("/") + path,
        data=data,
        method="POST" if data else "GET",
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {token}",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as exc:
        print(f"HTTP {exc.code}: {exc.read().decode()}", file=sys.stderr)
        raise SystemExit(1)


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 1

    cmd = sys.argv[1]
    state = load_state()

    if cmd == "domains":
        for d in call("/v1/domains", None)["domains"]:
            print(f"  {d['i']}  {d['s']:<14} -> {d['n']}")
        return 0

    if cmd == "replay":
        if not state["last_batch"]:
            print("nothing to replay", file=sys.stderr)
            return 1
        presses = state["last_batch"]
    elif cmd in ("start", "stop"):
        offset = int(sys.argv[3]) if len(sys.argv) > 3 else (
            int(sys.argv[2]) if cmd == "stop" and len(sys.argv) > 2 else 0
        )
        press = {"id": state["next_id"], "a": cmd, "t": int(time.time()) + offset}
        if cmd == "start":
            press["d"] = int(sys.argv[2])
        state["next_id"] += 1
        presses = [press]
        state["last_batch"] = presses
        save_state(state)
    else:
        print(__doc__)
        return 1

    print(json.dumps(call("/v1/events", {"presses": presses}), indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
