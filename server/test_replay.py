"""Replay/idempotency tests with a fake calendar. No network, no Google.

    python -m pytest test_replay.py -v

These cover the failure that actually costs you data: the watch resending a
batch whose response was lost, and duplicating every event in it.
"""

import importlib
import os
import sys
import tempfile
import time

import pytest
import yaml
from fastapi.testclient import TestClient

TOKEN = "test-token"

CONFIG = {
    "timezone": "Europe/London",
    "domains": [
        {"name": "Compounding", "short": "Compounding", "calendar_id": "cal0"},
        {"name": "Enriching", "short": "Enriching", "calendar_id": "cal1"},
        {"name": "Waste", "short": "Waste", "calendar_id": "cal2"},
    ],
}


class FakeCalendar:
    """Records what would have been sent to Google."""

    def __init__(self):
        self.events = {}
        self.inserts = 0
        self._n = 0

    def open_event(self, calendar_id, summary, start_ts):
        self._n += 1
        self.inserts += 1
        eid = f"ev{self._n}"
        self.events[eid] = {
            "calendar_id": calendar_id,
            "summary": summary,
            "start": start_ts,
            "end": start_ts + 60,
        }
        return eid

    def set_event_end(self, calendar_id, event_id, end_ts):
        self.events[event_id]["end"] = end_ts


@pytest.fixture
def client(monkeypatch):
    tmp = tempfile.mkdtemp()
    cfg_path = os.path.join(tmp, "config.yaml")
    with open(cfg_path, "w") as fh:
        yaml.safe_dump(CONFIG, fh)

    monkeypatch.setenv("TIMELOG_CONFIG", cfg_path)
    monkeypatch.setenv("TIMELOG_DB", os.path.join(tmp, "t.db"))
    monkeypatch.setenv("TIMELOG_TOKEN", os.path.join(tmp, "token.json"))
    monkeypatch.setenv("TIMELOG_TOKEN_SECRET", TOKEN)

    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import app as app_module

    importlib.reload(app_module)

    fake = FakeCalendar()
    app_module.calendar = fake

    c = TestClient(app_module.app)
    c.fake = fake
    return c


def post(client, presses):
    return client.post(
        "/v1/events",
        json={"presses": presses},
        headers={"Authorization": f"Bearer {TOKEN}"},
    )


def test_requires_token(client):
    assert client.post("/v1/events", json={"presses": []}).status_code == 401


def test_start_then_switch_closes_previous(client):
    now = int(time.time())
    post(client, [{"id": 1, "a": "start", "d": 0, "t": now - 3600}])
    post(client, [{"id": 2, "a": "start", "d": 1, "t": now - 1800}])

    evs = client.fake.events
    assert client.fake.inserts == 2
    assert evs["ev1"]["summary"] == "Compounding"
    # First event must have been closed exactly when the second began.
    assert evs["ev1"]["end"] == now - 1800
    assert evs["ev2"]["summary"] == "Enriching"


def test_stop_closes_and_clears(client):
    now = int(time.time())
    post(client, [{"id": 1, "a": "start", "d": 0, "t": now - 600}])
    r = post(client, [{"id": 2, "a": "stop", "t": now - 60}])

    assert client.fake.events["ev1"]["end"] == now - 60
    assert r.json()["cur"] is None


def test_replayed_batch_does_not_duplicate(client):
    """The core guarantee: resending an applied batch changes nothing."""
    now = int(time.time())
    batch = [
        {"id": 1, "a": "start", "d": 0, "t": now - 3600},
        {"id": 2, "a": "start", "d": 2, "t": now - 1800},
    ]
    r1 = post(client, batch)
    inserts_after_first = client.fake.inserts

    r2 = post(client, batch)  # watch never saw r1

    assert client.fake.inserts == inserts_after_first == 2
    # Still acked, so the watch stops retrying.
    assert r2.json()["acked"] == [1, 2]
    assert r1.json()["cur"] == r2.json()["cur"]


def test_out_of_order_batch_is_sorted_by_id(client):
    now = int(time.time())
    post(
        client,
        [
            {"id": 2, "a": "start", "d": 1, "t": now - 1800},
            {"id": 1, "a": "start", "d": 0, "t": now - 3600},
        ],
    )
    assert client.fake.events["ev1"]["summary"] == "Compounding"
    assert client.fake.events["ev2"]["summary"] == "Enriching"


def test_reselecting_running_domain_is_noop(client):
    now = int(time.time())
    post(client, [{"id": 1, "a": "start", "d": 0, "t": now - 600}])
    post(client, [{"id": 2, "a": "start", "d": 0, "t": now - 300}])
    assert client.fake.inserts == 1


def test_backwards_timestamp_is_clamped(client):
    """Never let Google see end <= start."""
    now = int(time.time())
    post(client, [{"id": 1, "a": "start", "d": 0, "t": now - 600}])
    post(client, [{"id": 2, "a": "start", "d": 1, "t": now - 900}])
    ev1 = client.fake.events["ev1"]
    assert ev1["end"] > ev1["start"]


def test_implausible_timestamp_dropped(client):
    """A watch reporting the Garmin epoch instead of UNIX must not rewrite 1989."""
    r = post(client, [{"id": 1, "a": "start", "d": 0, "t": 100000}])
    assert client.fake.inserts == 0
    assert r.json()["acked"] == [1]


def test_stop_with_nothing_open_is_harmless(client):
    now = int(time.time())
    r = post(client, [{"id": 1, "a": "stop", "t": now}])
    assert r.json()["ok"] is True
    assert r.json()["cur"] is None


def test_heartbeat_extends_running_event(client):
    now = int(time.time())
    post(client, [{"id": 1, "a": "start", "d": 0, "t": now - 3600}])
    # The placeholder end is start+60; the heartbeat should have stretched it.
    assert client.fake.events["ev1"]["end"] > now - 120


def test_domains_endpoint(client):
    r = client.get("/v1/domains", headers={"Authorization": f"Bearer {TOKEN}"})
    body = r.json()
    assert [d["n"] for d in body["domains"]] == ["Compounding", "Enriching", "Waste"]
