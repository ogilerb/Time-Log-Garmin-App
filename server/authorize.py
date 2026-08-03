"""One-time Google consent flow. Run this ONCE, on a machine with a browser.

    python authorize.py

Produces token.json containing a long-lived refresh token. Copy that single file
to the server:

    scp token.json you@your-oracle-box:/opt/timelog/

The server never runs this. It only refreshes silently, which is why it does not
need a browser and why the machine you run this on plays no further part.

The refresh token does not expire on a schedule. It stops working only if you
revoke access, leave it unused for six months, or -- the one people actually hit
-- leave the OAuth consent screen in "Testing" status, where Google force-expires
refresh tokens after 7 days. Set it to "In production" first.
"""

import os
import sys

from google_auth_oauthlib.flow import InstalledAppFlow

from calendar_client import SCOPES

HERE = os.path.dirname(os.path.abspath(__file__))
CREDENTIALS = os.path.join(HERE, "credentials.json")
TOKEN = os.path.join(HERE, "token.json")


def main() -> int:
    if not os.path.exists(CREDENTIALS):
        print(
            f"Missing {CREDENTIALS}.\n\n"
            "In the Google Cloud console pick (or reuse) a project, enable the\n"
            "Google Calendar API, and download an OAuth client of type 'Desktop\n"
            "app' as credentials.json.\n\n"
            "An existing Desktop client from another project works too -- enabling\n"
            "the Calendar API on that project is enough; no new client is required.",
            file=sys.stderr,
        )
        return 1

    if os.path.exists(TOKEN):
        print(f"{TOKEN} already exists. Delete it to re-authorize.", file=sys.stderr)
        return 1

    flow = InstalledAppFlow.from_client_secrets_file(CREDENTIALS, SCOPES)
    # access_type=offline + prompt=consent is what actually returns a refresh
    # token. Without prompt=consent Google omits it on repeat authorisations,
    # which produces credentials that work for an hour and then die.
    creds = flow.run_local_server(
        port=0, access_type="offline", prompt="consent"
    )

    if not creds.refresh_token:
        print(
            "No refresh token returned. Revoke this app's access at\n"
            "https://myaccount.google.com/permissions and run again.",
            file=sys.stderr,
        )
        return 1

    with open(TOKEN, "w") as fh:
        fh.write(creds.to_json())
    os.chmod(TOKEN, 0o600)

    print(f"Wrote {TOKEN}")
    print("Now: scp token.json to the server, then run list_calendars.py there.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
