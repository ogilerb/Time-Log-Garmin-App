"""Google Calendar wrapper.

Holds the long-lived refresh token and turns press timestamps into calendar
events. The interactive consent flow lives in authorize.py and is run once on a
machine with a browser; this module only ever refreshes silently, which is what
lets it run on a headless server.
"""

import datetime
import logging
import os
import threading
from typing import Optional
from zoneinfo import ZoneInfo

from google.auth.transport.requests import Request
from google.oauth2.credentials import Credentials
from googleapiclient.discovery import build
from googleapiclient.errors import HttpError

log = logging.getLogger(__name__)

SCOPES = ["https://www.googleapis.com/auth/calendar"]

# Google rejects an event whose end is not after its start. A running event
# therefore carries this placeholder duration until the closing press corrects
# it.
MIN_EVENT_SECONDS = 60


class EventGone(Exception):
    """The open event no longer exists in Google Calendar (deleted by hand)."""


class CalendarClient:
    def __init__(self, token_path: str, timezone: str):
        self._token_path = token_path
        self._tz = ZoneInfo(timezone)
        self._tz_name = timezone
        self._lock = threading.Lock()
        self._creds: Optional[Credentials] = None
        self._service = None

    # -- auth ------------------------------------------------------------

    def _get_service(self):
        with self._lock:
            if self._creds is None:
                if not os.path.exists(self._token_path):
                    raise RuntimeError(
                        f"{self._token_path} not found. Run authorize.py on a machine "
                        "with a browser and copy the resulting token here."
                    )
                self._creds = Credentials.from_authorized_user_file(
                    self._token_path, SCOPES
                )

            if not self._creds.valid:
                if not (self._creds.expired and self._creds.refresh_token):
                    raise RuntimeError(
                        "Stored credentials cannot be refreshed. Re-run authorize.py. "
                        "If this happened about a week after setup, the OAuth consent "
                        "screen is still in Testing status -- publish it."
                    )
                log.info("refreshing google access token")
                self._creds.refresh(Request())
                # Persist so a restart does not need another refresh round-trip,
                # and so any rotated refresh token is not lost.
                with open(self._token_path, "w") as fh:
                    fh.write(self._creds.to_json())
                self._service = None

            if self._service is None:
                self._service = build(
                    "calendar", "v3", credentials=self._creds, cache_discovery=False
                )
            return self._service

    def _rfc3339(self, ts: int) -> str:
        return datetime.datetime.fromtimestamp(ts, self._tz).isoformat()

    # -- operations ------------------------------------------------------

    def list_calendars(self) -> list[dict]:
        svc = self._get_service()
        out, page = [], None
        while True:
            resp = svc.calendarList().list(pageToken=page).execute()
            out.extend(resp.get("items", []))
            page = resp.get("nextPageToken")
            if not page:
                return out

    def open_event(self, calendar_id: str, summary: str, start_ts: int) -> str:
        """Create a running event. Returns the Google event id."""
        svc = self._get_service()
        body = {
            "summary": summary,
            "start": {"dateTime": self._rfc3339(start_ts), "timeZone": self._tz_name},
            "end": {
                "dateTime": self._rfc3339(start_ts + MIN_EVENT_SECONDS),
                "timeZone": self._tz_name,
            },
        }
        ev = svc.events().insert(calendarId=calendar_id, body=body).execute()
        log.info("opened %r on %s at %s", summary, calendar_id, self._rfc3339(start_ts))
        return ev["id"]

    def set_event_end(self, calendar_id: str, event_id: str, end_ts: int) -> None:
        """Move an existing event's end. Used both to close and to heartbeat."""
        svc = self._get_service()
        body = {
            "end": {"dateTime": self._rfc3339(end_ts), "timeZone": self._tz_name}
        }
        try:
            svc.events().patch(
                calendarId=calendar_id, eventId=event_id, body=body
            ).execute()
        except HttpError as exc:
            # If the event was deleted in the Google Calendar UI there is nothing
            # to close. Surface it so the caller can drop the stale pointer
            # instead of wedging on every future press.
            if exc.resp.status in (404, 410):
                raise EventGone(event_id) from exc
            raise
