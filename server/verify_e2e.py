"""End-to-end verification against the live server, with cleanup.

    export TIMELOG_URL=https://your-server.example.ts.net
    export TIMELOG_TOKEN_SECRET=...          # from /etc/timelog.env on the server
    .venv/bin/python verify_e2e.py            # uses domain 6 (Waste)
    .venv/bin/python verify_e2e.py 2          # or any domain index

Exercises the whole path the watch will use -- public HTTPS, auth, replay,
Google Calendar write -- and then deletes the event it created, so running it
leaves no trace in your real calendars.

Requires token.json locally (for the cleanup step only); the writes themselves go
through the public API exactly as the watch's would.
"""

import json
import os
import sys
import time
import urllib.request

import yaml

from calendar_client import CalendarClient

HERE = os.path.dirname(os.path.abspath(__file__))
URL = os.environ.get("TIMELOG_URL", "").rstrip("/")
TOKEN = os.environ.get("TIMELOG_TOKEN_SECRET", "")

# The test window sits two hours in the past so it cannot collide with a real
# session you might be logging right now.
START_AGO = 7200
STOP_AGO = 5400

PASS, FAIL = "  \033[32mPASS\033[0m", "  \033[31mFAIL\033[0m"
failures = 0


def check(ok: bool, msg: str) -> bool:
    global failures
    print(f"{PASS if ok else FAIL}  {msg}")
    if not ok:
        failures += 1
    return ok


def post_events(presses):
    req = urllib.request.Request(
        f"{URL}/v1/events",
        data=json.dumps({"presses": presses}).encode(),
        method="POST",
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {TOKEN}",
        },
    )
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read())


def main() -> int:
    if not URL or not TOKEN:
        print("Set TIMELOG_URL and TIMELOG_TOKEN_SECRET", file=sys.stderr)
        return 2

    idx = int(sys.argv[1]) if len(sys.argv) > 1 else 6

    with open(os.path.join(HERE, "config.yaml")) as fh:
        cfg = yaml.safe_load(fh)
    domain = cfg["domains"][idx]
    cal_id = domain["calendar_id"]

    print(f"\nTarget: [{idx}] {domain['name']}")
    print(f"Server: {URL}\n")

    now = int(time.time())
    base_id = now  # same seeding rule the watch uses
    batch = [
        {"id": base_id, "a": "start", "d": idx, "t": now - START_AGO},
        {"id": base_id + 1, "a": "stop", "t": now - STOP_AGO},
    ]

    # -- 1. write ---------------------------------------------------------
    print("1. Writing a start/stop pair through the public API")
    r1 = post_events(batch)
    check(r1.get("ok") is True, "server accepted the batch")
    check(sorted(r1.get("acked", [])) == [base_id, base_id + 1], "both presses acked")
    check(r1.get("cur") is None, "no event left open after stop")

    # -- 2. confirm in Google --------------------------------------------
    print("\n2. Confirming the event exists in Google Calendar")
    client = CalendarClient(os.path.join(HERE, "token.json"), cfg["timezone"])
    svc = client._get_service()

    def find_events():
        lo = client._rfc3339(now - START_AGO - 300)
        hi = client._rfc3339(now - STOP_AGO + 300)
        resp = svc.events().list(
            calendarId=cal_id, timeMin=lo, timeMax=hi, singleEvents=True
        ).execute()
        return [e for e in resp.get("items", []) if e.get("summary") == domain["name"]]

    found = find_events()
    check(len(found) == 1, f"exactly one event created (found {len(found)})")
    if found:
        ev = found[0]
        start = ev["start"].get("dateTime", "")
        end = ev["end"].get("dateTime", "")
        dur = (START_AGO - STOP_AGO) // 60
        print(f"       {ev['summary']!r}")
        print(f"       {start}  ->  {end}")
        check("T" in start and "T" in end, "event has real start and end times")
        print(f"       expected duration ~{dur} min")

    # -- 3. the guarantee -------------------------------------------------
    print("\n3. Replaying the identical batch (the duplicate-prevention guarantee)")
    r2 = post_events(batch)
    check(sorted(r2.get("acked", [])) == [base_id, base_id + 1],
          "replayed presses still acked, so the watch stops retrying")
    after = find_events()
    check(len(after) == len(found), f"no duplicate created (still {len(after)})")

    # -- 4. cleanup -------------------------------------------------------
    print("\n4. Cleaning up")
    for ev in after:
        svc.events().delete(calendarId=cal_id, eventId=ev["id"]).execute()
        print(f"       deleted {ev['id']}")
    check(len(find_events()) == 0, "calendar left clean")

    print()
    if failures:
        print(f"\033[31m{failures} check(s) FAILED\033[0m\n")
        return 1
    print("\033[32mAll checks passed. The watch path is verified end to end.\033[0m\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
