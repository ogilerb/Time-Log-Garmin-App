"""Durable state for the time logger.

Two things need to survive a restart:

1. Which calendar event is currently open (so the next press can close it).
2. Which press ids have already been applied, so that a watch retrying a batch
   whose response got lost does not duplicate calendar events.

SQLite is used rather than a JSON file because presses arrive as batches that
must be applied atomically -- a crash midway through a batch must not leave the
open-event pointer disagreeing with what is actually in Google Calendar.
"""

import sqlite3
import threading
from contextlib import contextmanager
from dataclasses import dataclass
from typing import Optional

# How many applied press ids to remember. The watch only ever retries the tail
# of its queue, so this is generously large.
APPLIED_HISTORY = 500


@dataclass
class OpenEvent:
    domain_idx: int
    calendar_id: str
    event_id: str
    start_ts: int


class Store:
    def __init__(self, path: str):
        self._path = path
        # FastAPI serves requests from a threadpool; SQLite connections are not
        # shareable across threads, so serialise access behind one lock. Request
        # volume here is a handful per day.
        self._lock = threading.Lock()
        self._conn = sqlite3.connect(path, check_same_thread=False)
        self._conn.execute("PRAGMA journal_mode=WAL")
        self._init_schema()

    def _init_schema(self) -> None:
        with self._conn:
            self._conn.execute(
                """
                CREATE TABLE IF NOT EXISTS open_event (
                    id          INTEGER PRIMARY KEY CHECK (id = 1),
                    domain_idx  INTEGER NOT NULL,
                    calendar_id TEXT    NOT NULL,
                    event_id    TEXT    NOT NULL,
                    start_ts    INTEGER NOT NULL
                )
                """
            )
            self._conn.execute(
                """
                CREATE TABLE IF NOT EXISTS applied (
                    press_id   INTEGER PRIMARY KEY,
                    applied_at INTEGER NOT NULL
                )
                """
            )

    @contextmanager
    def transaction(self):
        """Group a whole batch so a crash cannot half-apply it."""
        with self._lock:
            with self._conn:
                yield

    # -- open event ------------------------------------------------------

    def get_open(self) -> Optional[OpenEvent]:
        row = self._conn.execute(
            "SELECT domain_idx, calendar_id, event_id, start_ts FROM open_event WHERE id = 1"
        ).fetchone()
        return OpenEvent(*row) if row else None

    def set_open(self, ev: OpenEvent) -> None:
        self._conn.execute(
            """
            INSERT INTO open_event (id, domain_idx, calendar_id, event_id, start_ts)
            VALUES (1, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                domain_idx  = excluded.domain_idx,
                calendar_id = excluded.calendar_id,
                event_id    = excluded.event_id,
                start_ts    = excluded.start_ts
            """,
            (ev.domain_idx, ev.calendar_id, ev.event_id, ev.start_ts),
        )

    def clear_open(self) -> None:
        self._conn.execute("DELETE FROM open_event WHERE id = 1")

    # -- idempotency -----------------------------------------------------

    def is_applied(self, press_id: int) -> bool:
        row = self._conn.execute(
            "SELECT 1 FROM applied WHERE press_id = ?", (press_id,)
        ).fetchone()
        return row is not None

    def mark_applied(self, press_id: int, ts: int) -> None:
        self._conn.execute(
            "INSERT OR IGNORE INTO applied (press_id, applied_at) VALUES (?, ?)",
            (press_id, ts),
        )

    def prune_applied(self) -> None:
        self._conn.execute(
            """
            DELETE FROM applied WHERE press_id NOT IN (
                SELECT press_id FROM applied ORDER BY press_id DESC LIMIT ?
            )
            """,
            (APPLIED_HISTORY,),
        )
