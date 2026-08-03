"""Print your calendar ids, and try to match them to the configured domains.

    python list_calendars.py

Emits a ready-to-paste `domains:` block with calendar_id filled in wherever a
calendar's name matches a domain name. Anything it cannot match is left as
FILL_ME with the full list printed above for you to pick from.
"""

import os
import sys

import yaml

from calendar_client import CalendarClient

HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG = os.environ.get("TIMELOG_CONFIG", os.path.join(HERE, "config.yaml"))
TOKEN = os.environ.get("TIMELOG_TOKEN", os.path.join(HERE, "token.json"))


def normalise(s: str) -> str:
    return "".join(c for c in s.lower() if c.isalnum())


def main() -> int:
    with open(CONFIG) as fh:
        cfg = yaml.safe_load(fh)

    client = CalendarClient(TOKEN, cfg["timezone"])
    cals = client.list_calendars()

    print("# All calendars visible to this account:")
    for c in cals:
        access = c.get("accessRole", "?")
        print(f"#   {c['summary']!r:45} {c['id']}   ({access})")
    print()

    by_name = {normalise(c["summary"]): c["id"] for c in cals}

    matched = 0
    out_domains = []
    for d in cfg["domains"]:
        cal_id = by_name.get(normalise(d["name"]))
        if cal_id:
            matched += 1
        entry = {
            "name": d["name"],
            "short": d.get("short", d["name"]),
            "calendar_id": cal_id or "FILL_ME@group.calendar.google.com",
        }
        out_domains.append(entry)

    print(f"# Matched {matched}/{len(cfg['domains'])} domains by name.")
    print("# Paste this over the `domains:` block in config.yaml:")
    print()
    print(yaml.safe_dump({"domains": out_domains}, sort_keys=False, allow_unicode=True))

    if matched < len(cfg["domains"]):
        print(
            "# Some domains did not match a calendar name. Either rename the\n"
            "# calendar in Google to match exactly, or paste the right id by hand\n"
            "# from the list above.",
            file=sys.stderr,
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
