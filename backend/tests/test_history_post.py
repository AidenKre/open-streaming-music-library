"""PR 5A (5-U02, 5-T13, 5-T16 server side, SC-23, SC-24, SC-03): POST /history.

Contract (Phase 5 §4): body {"events": [...]} of 1–200 immutable payloads,
<= 256 KiB (413 past it, enforced while streaming); field errors / bad count
-> 422 (no input echo); unknown fields rejected, open VALUES accepted. Under
one BEGIN IMMEDIATE transaction: collapse exact in-batch duplicates (same UUID
with different values -> 409, no writes); an existing UUID with a different
normalized payload -> 409 SC-22 `history_event_conflict` with
`conflicting_event_uuids`, rolling back the whole batch; each new UUID gets
`_next_revision` and a server `received_at`; hooks see only new rows, each in
its own SAVEPOINT; commit before ACK. ACK = unique UUIDs of every batch event
now present (retries included). A database error is a retriable server error.
"""

import importlib
import json
import sqlite3
import sys
import uuid

import pytest
from fastapi.testclient import TestClient

from app.database.database import Database
from app.services.history_hooks import register_history_hook, unregister_history_hook


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("APP_DATA_DIR", str(tmp_path / "data"))
    monkeypatch.setenv("MUSIC_LIBRARY_DIR", str(tmp_path / "music"))
    monkeypatch.setenv("IMPORT_DIR", str(tmp_path / "import"))
    monkeypatch.setenv("ENABLE_FILE_WATCHER", "false")
    sys.modules.pop("app.main", None)
    sys.modules.pop("app.config", None)
    import app.main

    importlib.reload(app.main)
    with TestClient(app.main.app) as c:
        yield c


def _db_path(client):
    return client.app.state.database.context.database_path


def _q(client, sql, args=()):
    conn = sqlite3.connect(_db_path(client))
    try:
        return conn.execute(sql, args).fetchall()
    finally:
        conn.close()


def _counter(client):
    return _q(client, "SELECT value FROM revision_counter WHERE id = 0")[0][0]


def _event(**overrides):
    event = {
        "event_uuid": str(uuid.uuid4()),
        "kind": "play",
        "entity_type": "track",
        "entity_ref": "track-uuid-1",
        "occurred_at": 1_800_000_000_000,
        "seconds_played": 30.5,
        "track_length": 200.0,
    }
    event.update(overrides)
    return event


def _post(client, events, **extra):
    return client.post("/history", content=json.dumps({"events": events, **extra}))


def test_app_info_advertises_the_history_block(client):
    assert client.get("/app/info").json()["history"] == {"version": 1}


def test_new_events_are_stored_with_revisions_and_acknowledged(client):
    before = _counter(client)
    events = [_event(), _event(kind="clicked", seconds_played=None, track_length=None)]
    res = _post(client, events)
    assert res.status_code == 200
    ack = res.json()["acknowledged"]
    assert sorted(ack) == sorted(e["event_uuid"] for e in events)
    assert len(ack) == len(set(ack))
    rows = _q(client, "SELECT event_uuid, revision, received_at, owner_id FROM history_events ORDER BY revision")
    assert [r[1] for r in rows] == [before + 1, before + 2]
    assert all(r[2] > 0 and r[3] is None for r in rows)
    assert _counter(client) == before + 2


def test_exact_retry_acknowledges_without_new_rows_or_revisions(client):
    events = [_event(), _event()]
    assert _post(client, events).status_code == 200
    counter = _counter(client)
    res = _post(client, events)
    assert res.status_code == 200
    assert sorted(res.json()["acknowledged"]) == sorted(e["event_uuid"] for e in events)
    assert _counter(client) == counter
    assert _q(client, "SELECT count(*) FROM history_events")[0][0] == 2


def test_numbers_compare_normalized(client):
    """30 and 30.0 are the same payload value (typed comparison)."""
    e = _event(seconds_played=30.0, track_length=200.0)
    assert _post(client, [e]).status_code == 200
    again = dict(e, seconds_played=30, track_length=200)
    res = _post(client, [again])
    assert res.status_code == 200
    assert res.json()["acknowledged"] == [e["event_uuid"]]


def test_existing_uuid_with_a_different_payload_rolls_back_the_batch(client):
    first = _event()
    assert _post(client, [first]).status_code == 200
    counter = _counter(client)
    fresh = _event()
    conflicting = dict(first, seconds_played=99.0)
    res = _post(client, [fresh, conflicting])
    assert res.status_code == 409
    detail = res.json()["detail"]
    assert detail["error"] == "history_event_conflict"
    assert detail["conflicting_event_uuids"] == [first["event_uuid"]]
    assert detail["retryable"] is False
    assert _counter(client) == counter
    assert _q(client, "SELECT event_uuid FROM history_events") == [(first["event_uuid"],)]


def test_exact_duplicates_within_a_batch_collapse(client):
    e = _event()
    res = _post(client, [e, dict(e)])
    assert res.status_code == 200
    assert res.json()["acknowledged"] == [e["event_uuid"]]
    assert _q(client, "SELECT count(*) FROM history_events")[0][0] == 1


def test_same_uuid_with_different_values_within_a_batch_is_409_without_writes(client):
    e = _event()
    res = _post(client, [e, dict(e, kind="clicked")])
    assert res.status_code == 409
    assert _q(client, "SELECT count(*) FROM history_events")[0][0] == 0


def test_200_events_are_accepted_201_are_not(client):
    assert _post(client, [_event() for _ in range(200)]).status_code == 200
    counter = _counter(client)
    res = _post(client, [_event() for _ in range(201)])
    assert res.status_code == 422
    assert _counter(client) == counter


def test_an_empty_batch_is_invalid(client):
    assert _post(client, []).status_code == 422


INVALID_EVENTS = [
    {"event_uuid": "not-a-uuid"},
    {"event_uuid": str(uuid.uuid1())},  # not v4
    {"event_uuid": str(uuid.uuid4()).upper()},  # not canonical
    {"kind": ""},
    {"kind": "k" * 65},
    {"entity_type": ""},
    {"entity_type": "e" * 65},
    {"entity_ref": ""},
    {"entity_ref": "r" * 257},
    {"occurred_at": -1},
    {"occurred_at": 253402300800000},
    {"occurred_at": 1.5},
    {"seconds_played": -0.1},
    {"track_length": 0},
    {"track_length": -3.0},
    {"unexpected_field": 1},
]


@pytest.mark.parametrize("overrides", INVALID_EVENTS)
def test_invalid_events_are_422_with_no_writes(client, overrides):
    good = _event()
    res = _post(client, [good, _event(**overrides)])
    assert res.status_code == 422, overrides
    assert _q(client, "SELECT count(*) FROM history_events")[0][0] == 0
    body = res.text
    assert "SECRET" not in body


# Audit 5A(a) #4: control characters (NUL first of all) are not valid in
# the identifier fields; SQLite's length() stops at NUL, so they must be a
# 422 here, never a retryable storage error that blocks later uploads.
@pytest.mark.parametrize("field", ["kind", "entity_type", "entity_ref"])
@pytest.mark.parametrize("value", ["\x00abc", "ab\x07c", "a\nb", "x\x7f"])
def test_control_characters_are_422(client, field, value):
    res = _post(client, [_event(**{field: value})])
    assert res.status_code == 422
    assert _q(client, "SELECT count(*) FROM history_events")[0][0] == 0


@pytest.mark.parametrize("token", ["NaN", "Infinity", "-Infinity"])
def test_non_finite_measures_are_rejected(client, token):
    body = json.dumps({"events": [_event()]}).replace("30.5", token)
    res = client.post("/history", content=body)
    assert res.status_code == 422
    assert _q(client, "SELECT count(*) FROM history_events")[0][0] == 0


def test_unknown_top_level_fields_are_rejected(client):
    assert _post(client, [_event()], unexpected=True).status_code == 422


def test_open_values_pass_through(client):
    e = _event(kind="future_kind", entity_type="playlist", entity_ref="x:1",
               seconds_played=None, track_length=None)
    assert _post(client, [e]).status_code == 200
    row = _q(client, "SELECT kind, entity_type, entity_ref FROM history_events")
    assert row == [("future_kind", "playlist", "x:1")]


def test_422_does_not_echo_input(client):
    res = _post(client, [_event(kind="SECRET" * 20)])
    assert res.status_code == 422
    assert "SECRET" not in res.text


def test_body_over_256_kib_is_413(client):
    big = _event(entity_ref="r" * 200)
    body = json.dumps({"events": [big] * 2000})
    assert len(body.encode()) > 256 * 1024
    res = client.post("/history", content=body)
    assert res.status_code == 413
    assert _q(client, "SELECT count(*) FROM history_events")[0][0] == 0


def test_a_database_error_is_a_retriable_server_error(client, monkeypatch):
    def boom(conn):
        raise sqlite3.OperationalError("database is locked")

    monkeypatch.setattr(Database, "_next_revision", staticmethod(boom))
    res = _post(client, [_event()])
    assert res.status_code >= 500
    assert res.json()["detail"]["retryable"] is True
    assert _q(client, "SELECT count(*) FROM history_events")[0][0] == 0


class TestHooks:
    """SC-23: hooks see only new rows; a failing hook is isolated."""

    @pytest.fixture(autouse=True)
    def _cleanup(self):
        yield
        for name in ("recorder", "writer", "broken"):
            try:
                unregister_history_hook(name)
            except KeyError:
                pass

    def test_hooks_receive_only_newly_inserted_events(self, client):
        seen = []
        register_history_hook("recorder", lambda conn, new: seen.append(
            sorted(e["event_uuid"] for e in new)))
        a, b = _event(), _event()
        _post(client, [a])
        _post(client, [a, b])  # a is an exact duplicate now
        assert seen == [[a["event_uuid"]], [b["event_uuid"]]]

    def test_a_raising_hook_is_isolated_and_recorded(self, client):
        def writer(conn, new):
            conn.execute("INSERT INTO app_settings (key, value) VALUES ('hook.writer', 'ok')")

        def broken(conn, new):
            conn.execute("INSERT INTO app_settings (key, value) VALUES ('hook.broken', 'x')")
            raise RuntimeError("subscriber bug")

        register_history_hook("broken", broken)
        register_history_hook("writer", writer)
        e = _event()
        res = _post(client, [e])
        assert res.status_code == 200
        assert res.json()["acknowledged"] == [e["event_uuid"]]
        assert _q(client, "SELECT event_uuid FROM history_events") == [(e["event_uuid"],)]
        keys = {k for (k,) in _q(client, "SELECT key FROM app_settings WHERE key LIKE 'hook.%'")}
        assert keys == {"hook.writer"}, "the broken hook's own write rolled back"
        failures = _q(client, "SELECT subscriber, event_uuid, error FROM history_hook_failures")
        assert len(failures) == 1
        assert failures[0][0] == "broken"
        assert failures[0][1] == e["event_uuid"]
        assert "subscriber bug" in failures[0][2]
