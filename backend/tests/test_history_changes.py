"""PR 5A (5-U03): GET /history/changes?after=&limit= paging.

Contract (Phase 5 §4): `after` >= 0, `limit` 1..1000 (default 200). Read
`revision > after ORDER BY revision LIMIT limit+1` and latestRevision in ONE
snapshot; return the first `limit` rows; nextCursor = last RETURNED revision
only when another row exists, else null; latestRevision = max committed
history revision (0 if none), informational only. Revisions are sparse
because track mutations share the counter; the cursor never comes from the
global MAX.
"""

import importlib
from contextlib import contextmanager
import json
import sys
import uuid

import pytest
from fastapi.testclient import TestClient


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


def _event(**overrides):
    e = {
        "event_uuid": str(uuid.uuid4()),
        "kind": "clicked",
        "entity_type": "track",
        "entity_ref": "t-1",
        "occurred_at": 1_800_000_000_000,
        "seconds_played": None,
        "track_length": None,
    }
    e.update(overrides)
    return e


def _post(client, events):
    res = client.post("/history", content=json.dumps({"events": events}))
    assert res.status_code == 200
    return events


def _track_mutation(client):
    """Consume a revision the way a catalog write does (shared counter)."""
    db = client.app.state.database
    with db._connection(commit=True, immediate=True) as conn:
        db._next_revision(conn)


def _changes(client, **params):
    res = client.get("/history/changes", params=params)
    assert res.status_code == 200, res.text
    return res.json()


def test_empty_history(client):
    _track_mutation(client)
    page = _changes(client, after=0)
    assert page == {"events": [], "nextCursor": None, "latestRevision": 0}


def test_one_event_round_trips_every_field(client):
    (e,) = _post(client, [_event(kind="play", seconds_played=12.5, track_length=200.0)])
    page = _changes(client, after=0)
    (row,) = page["events"]
    for key, value in e.items():
        assert row[key] == value
    assert row["revision"] > 0 and row["received_at"] > 0
    assert page["nextCursor"] is None
    assert page["latestRevision"] == row["revision"]


def test_paging_with_sparse_revisions_and_track_mutations(client):
    uuids = []
    for _ in range(5):
        _track_mutation(client)
        uuids += [e["event_uuid"] for e in _post(client, [_event()])]
        _track_mutation(client)
    first = _changes(client, after=0, limit=2)
    revs = [e["revision"] for e in first["events"]]
    assert [e["event_uuid"] for e in first["events"]] == uuids[:2]
    assert revs == sorted(revs) and len(set(revs)) == 2
    assert first["nextCursor"] == revs[-1], "last RETURNED revision"
    latest = first["latestRevision"]

    second = _changes(client, after=first["nextCursor"], limit=2)
    assert [e["event_uuid"] for e in second["events"]] == uuids[2:4]
    third = _changes(client, after=second["nextCursor"], limit=2)
    assert [e["event_uuid"] for e in third["events"]] == uuids[4:]
    assert third["nextCursor"] is None, "final partial page"
    assert third["events"][-1]["revision"] == latest
    # The global counter moved past the last history revision (a trailing
    # track mutation): the cursor never comes from that MAX.
    counter = client.app.state.database
    with counter._connection() as conn:
        global_max = conn.execute("SELECT value FROM revision_counter").fetchone()[0]
    assert global_max > latest
    assert _changes(client, after=latest) == {
        "events": [], "nextCursor": None, "latestRevision": latest,
    }


def test_exactly_limit_rows_has_no_next_cursor(client):
    _post(client, [_event(), _event()])
    page = _changes(client, after=0, limit=2)
    assert len(page["events"]) == 2
    assert page["nextCursor"] is None


def test_limit_plus_one_rows_has_a_next_cursor(client):
    _post(client, [_event(), _event(), _event()])
    page = _changes(client, after=0, limit=2)
    assert len(page["events"]) == 2
    assert page["nextCursor"] == page["events"][-1]["revision"]


def test_default_limit_is_200(client):
    for _ in range(2):
        _post(client, [_event() for _ in range(150)])
    page = _changes(client, after=0)
    assert len(page["events"]) == 200
    assert page["nextCursor"] == page["events"][-1]["revision"]


@pytest.mark.parametrize(
    "params",
    [{"after": -1}, {"after": 0, "limit": 0}, {"after": 0, "limit": 1001},
     {"after": 2**63}, {"after": 2**64},  # audit 5A(a) #6: 422, not a 500
     {"after": "x"}, {"after": 0, "limit": "many"}],
)
def test_invalid_cursor_or_limit_is_422(client, params):
    assert client.get("/history/changes", params=params).status_code == 422


def test_limit_1000_is_allowed(client):
    assert client.get("/history/changes", params={"after": 0, "limit": 1000}).status_code == 200


def test_page_and_latest_share_snapshot_during_a_concurrent_commit(client, monkeypatch):
    from app.models.history import HistoryEvent

    first, late = _event(), _event()
    _post(client, [first])
    db = client.app.state.database
    connect = db._connection
    inserted = False

    class Reader:
        def __init__(self, conn):
            self.conn = conn

        def execute(self, sql, parameters=()):
            nonlocal inserted
            if "SELECT COALESCE(MAX(revision), 0) FROM history_events" in sql and not inserted:
                inserted = True
                # The writer uses another real WAL connection. It commits
                # between the reader's page fetch and latest-revision read.
                db.insert_history_events([HistoryEvent.model_validate(late)])
            return self.conn.execute(sql, parameters)

    @contextmanager
    def controlled_connection(*args, **kwargs):
        with connect(*args, **kwargs) as conn:
            yield Reader(conn)

    monkeypatch.setattr(db, "_connection", controlled_connection)
    page = _changes(client)
    assert inserted
    assert [e["event_uuid"] for e in page["events"]] == [first["event_uuid"]]
    assert page["latestRevision"] == page["events"][0]["revision"]
    following = _changes(client, after=page["latestRevision"])
    assert [e["event_uuid"] for e in following["events"]] == [late["event_uuid"]]
