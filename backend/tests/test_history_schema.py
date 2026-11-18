"""PR 5A (5-U01): backend history tables.

`history_events`: primary key `event_uuid`; unique positive `revision`
(indexed for paging); immutable payload (kind/entity_type max 64, entity_ref
max 256, occurred_at Unix ms 0..253402300799999, seconds_played >= 0,
track_length > 0, both nullable); server-stamped `received_at`; Phase M's
required `owner_id` referencing `users`. `history_hook_failures(subscriber, event_uuid, error,
created_at)` records SC-23 subscriber failures. (Phase M deleted the v11
upgrade cases: pre-M databases are refused, see test_schema_refusal.py.)
"""

import sqlite3

import pytest

from app.database.database import Database
from tests.schema_fixtures import open_database, user_version

PAYLOAD_COLUMNS = {
    "event_uuid": ("TEXT", 1),
    "revision": ("INTEGER", 1),
    "kind": ("TEXT", 1),
    "entity_type": ("TEXT", 1),
    "entity_ref": ("TEXT", 1),
    "occurred_at": ("INTEGER", 1),
    "seconds_played": ("REAL", 0),
    "track_length": ("REAL", 0),
    "received_at": ("INTEGER", 1),
    "owner_id": ("INTEGER", 1),
}


def _columns(path, table):
    conn = sqlite3.connect(path)
    try:
        return {
            row[1]: (row[2].upper(), row[3], row[5])
            for row in conn.execute(f"PRAGMA table_info({table})")
        }
    finally:
        conn.close()


@pytest.fixture
def fresh(tmp_path):
    path = tmp_path / "fresh" / "database.db"
    open_database(path)
    return path


def test_latest_schema_version_is_15():
    assert Database.LATEST_SCHEMA_VERSION == 15


def test_history_events_columns(fresh):
    path = fresh
    cols = _columns(path, "history_events")
    assert {name: (t, nn) for name, (t, nn, _) in cols.items()} == PAYLOAD_COLUMNS
    assert [name for name, (_, _, pk) in cols.items() if pk] == ["event_uuid"]
    assert user_version(path) == 15


def test_history_hook_failures_columns(fresh):
    cols = _columns(fresh, "history_hook_failures")
    for name in ("subscriber", "event_uuid", "error", "created_at"):
        assert name in cols and cols[name][1] == 1, name


def test_revision_is_unique_and_indexed(fresh):
    conn = sqlite3.connect(fresh)
    try:
        uniques = [
            conn.execute(f"PRAGMA index_info({row[1]})").fetchall()
            for row in conn.execute("PRAGMA index_list(history_events)")
            if row[2]  # unique
        ]
    finally:
        conn.close()
    assert any([c[2] for c in cols] == ["revision"] for cols in uniques)


def _insert(conn, **overrides):
    row = {
        "event_uuid": "00000000-0000-4000-8000-000000000001",
        "revision": 1,
        "kind": "play",
        "entity_type": "track",
        "entity_ref": "t-1",
        "occurred_at": 1_800_000_000_000,
        "seconds_played": 12.5,
        "track_length": 200.0,
        "received_at": 1_800_000_000_500,
        "owner_id": conn.execute("SELECT id FROM users LIMIT 1").fetchone()[0],
    }
    row.update(overrides)
    conn.execute(
        "INSERT INTO history_events (%s) VALUES (%s)"
        % (",".join(row), ",".join("?" * len(row))),
        tuple(row.values()),
    )


VALID = [
    {},
    {"seconds_played": None, "track_length": None, "kind": "clicked"},
    {"seconds_played": 0.0},
    {"occurred_at": 0},
    {"occurred_at": 253402300799999},
    {"kind": "k" * 64, "entity_type": "e" * 64, "entity_ref": "r" * 256},
    {"kind": "future_kind", "entity_type": "playlist"},  # open values
]

INVALID = [
    {"revision": 0},
    {"revision": -1},
    {"kind": ""},
    {"kind": "k" * 65},
    {"entity_type": ""},
    {"entity_type": "e" * 65},
    {"entity_ref": ""},
    {"entity_ref": "r" * 257},
    {"occurred_at": -1},
    {"occurred_at": 253402300800000},
    {"seconds_played": -0.5},
    {"track_length": 0.0},
    {"track_length": -1.0},
    {"kind": None},
    {"received_at": None},
    {"owner_id": None},
]


@pytest.mark.parametrize("overrides", VALID)
def test_valid_rows_are_accepted(fresh, overrides):
    conn = sqlite3.connect(fresh)
    try:
        _insert(conn, **overrides)
    finally:
        conn.close()


@pytest.mark.parametrize("overrides", INVALID)
def test_invalid_rows_are_rejected_by_the_schema(fresh, overrides):
    conn = sqlite3.connect(fresh)
    try:
        with pytest.raises(sqlite3.IntegrityError):
            _insert(conn, **overrides)
    finally:
        conn.close()


def test_duplicate_uuid_and_revision_are_rejected(fresh):
    conn = sqlite3.connect(fresh)
    try:
        _insert(conn)
        with pytest.raises(sqlite3.IntegrityError):
            _insert(conn, revision=2)  # same uuid
        with pytest.raises(sqlite3.IntegrityError):
            _insert(conn, event_uuid="00000000-0000-4000-8000-000000000002")  # same revision
    finally:
        conn.close()
