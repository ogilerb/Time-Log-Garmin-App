"""Time logger API.

The watch is deliberately dumb: it emits an append-only log of button presses
and nothing else. All calendar state lives here, which is what makes retries
safe -- the watch can resend a batch as often as it likes.

Two endpoints:
    GET  /v1/domains  -> the domain list, so names live in one place
    POST /v1/events   -> a batch of presses to replay
"""

import logging
import os
import secrets
import time
from typing import Optional

import yaml
from fastapi import Depends, FastAPI, HTTPException, Request
from pydantic import BaseModel, Field

from calendar_client import CalendarClient, EventGone, MIN_EVENT_SECONDS
from state import OpenEvent, Store

logging.basicConfig(
    level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s"
)
log = logging.getLogger("timelog")

HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.environ.get("TIMELOG_CONFIG", os.path.join(HERE, "config.yaml"))
TOKEN_PATH = os.environ.get("TIMELOG_TOKEN", os.path.join(HERE, "token.json"))
DB_PATH = os.environ.get("TIMELOG_DB", os.path.join(HERE, "timelog.db"))

# Presses older than this are ignored. Guards against a watch whose clock was
# wrong, or a queue that somehow survived months of being offline, silently
# rewriting old history.
MAX_PRESS_AGE = 7 * 24 * 3600


def load_config() -> dict:
    with open(CONFIG_PATH) as fh:
        cfg = yaml.safe_load(fh)
    if not cfg.get("domains"):
        raise RuntimeError("config.yaml has no domains")
    for i, d in enumerate(cfg["domains"]):
        if "FILL_ME" in d.get("calendar_id", ""):
            raise RuntimeError(
                f"domain {i} ({d['name']!r}) still has a placeholder calendar_id. "
                "Run list_calendars.py."
            )
    return cfg


CONFIG = load_config()
DOMAINS = CONFIG["domains"]

AUTH_TOKEN = os.environ.get("TIMELOG_TOKEN_SECRET")
if not AUTH_TOKEN:
    raise RuntimeError("TIMELOG_TOKEN_SECRET is not set (see timelog.service)")

store = Store(DB_PATH)
calendar = CalendarClient(TOKEN_PATH, CONFIG["timezone"])
app = FastAPI(title="Garmin time logger", docs_url=None, redoc_url=None)


def require_token(request: Request) -> None:
    header = request.headers.get("authorization", "")
    prefix = "Bearer "
    supplied = header[len(prefix):] if header.startswith(prefix) else ""
    # Constant-time so the token cannot be recovered by timing the comparison.
    if not secrets.compare_digest(supplied, AUTH_TOKEN):
        raise HTTPException(status_code=401, detail="bad token")


# -- schema --------------------------------------------------------------


class Press(BaseModel):
    id: int = Field(..., description="Monotonic id from the watch; dedupe key")
    a: str = Field(..., description="'start' or 'stop'")
    t: int = Field(..., description="UTC epoch seconds when the button was pressed")
    d: Optional[int] = Field(None, description="Domain index, required for 'start'")


class PressBatch(BaseModel):
    presses: list[Press]


# -- replay --------------------------------------------------------------


def _close_open(open_ev: OpenEvent, end_ts: int) -> None:
    """Set the open event's end, clamping so Google never sees end <= start."""
    if end_ts <= open_ev.start_ts:
        end_ts = open_ev.start_ts + MIN_EVENT_SECONDS
    try:
        calendar.set_event_end(open_ev.calendar_id, open_ev.event_id, end_ts)
    except EventGone:
        log.warning("open event %s was deleted in Google; dropping", open_ev.event_id)


def _apply(press: Press) -> None:
    open_ev = store.get_open()

    if press.a == "stop":
        if open_ev is None:
            log.info("stop with nothing open; ignoring")
            return
        _close_open(open_ev, press.t)
        store.clear_open()
        log.info("closed domain %d", open_ev.domain_idx)
        return

    if press.a != "start":
        raise HTTPException(status_code=400, detail=f"unknown action {press.a!r}")

    if press.d is None or not (0 <= press.d < len(DOMAINS)):
        raise HTTPException(status_code=400, detail=f"bad domain index {press.d!r}")

    domain = DOMAINS[press.d]

    # Pressing the domain that is already running is a no-op rather than a
    # zero-length event followed by an identical one.
    if open_ev is not None and open_ev.domain_idx == press.d:
        log.info("domain %d already running; ignoring", press.d)
        return

    if open_ev is not None:
        _close_open(open_ev, press.t)
        store.clear_open()

    event_id = calendar.open_event(domain["calendar_id"], domain["name"], press.t)
    store.set_open(
        OpenEvent(
            domain_idx=press.d,
            calendar_id=domain["calendar_id"],
            event_id=event_id,
            start_ts=press.t,
        )
    )


# -- endpoints -----------------------------------------------------------


@app.get("/v1/domains", dependencies=[Depends(require_token)])
def get_domains():
    # Short keys: this response is parsed inside the watch's background process,
    # which has a much smaller memory ceiling than the foreground app.
    return {
        "v": 1,
        "domains": [
            {"i": i, "n": d["name"], "s": d.get("short", d["name"])}
            for i, d in enumerate(DOMAINS)
        ],
    }


@app.post("/v1/events", dependencies=[Depends(require_token)])
def post_events(batch: PressBatch):
    now = int(time.time())
    acked: list[int] = []

    # Replay in press order regardless of the order they arrived in.
    for press in sorted(batch.presses, key=lambda p: p.id):
        if store.is_applied(press.id):
            # Already done on a previous attempt whose response never made it
            # back. Ack it so the watch stops resending.
            acked.append(press.id)
            continue

        if press.t > now + 300 or press.t < now - MAX_PRESS_AGE:
            log.warning("press %d has implausible timestamp %d; dropping", press.id, press.t)
            with store.transaction():
                store.mark_applied(press.id, now)
            acked.append(press.id)
            continue

        _apply(press)
        with store.transaction():
            store.mark_applied(press.id, now)
        acked.append(press.id)

    # Heartbeat: stretch the running event to now so an in-progress block shows
    # its true length in Google Calendar instead of the 1-minute placeholder.
    open_ev = store.get_open()
    if open_ev is not None and now > open_ev.start_ts:
        try:
            calendar.set_event_end(open_ev.calendar_id, open_ev.event_id, now)
        except EventGone:
            store.clear_open()
            open_ev = None

    with store.transaction():
        store.prune_applied()

    return {
        "ok": True,
        "acked": acked,
        "cur": (
            {"d": open_ev.domain_idx, "since": open_ev.start_ts} if open_ev else None
        ),
    }


@app.get("/v1/health")
def health():
    open_ev = store.get_open()
    return {"ok": True, "open": open_ev.domain_idx if open_ev else None}
