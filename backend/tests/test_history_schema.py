"""PR 5A (5-U01): backend history tables, fresh and migrated.

`history_events`: primary key `event_uuid`; unique positive `revision`
(indexed for paging); immutable payload (kind/entity_type max 64, entity_ref
max 256, occurred_at Unix ms 0..253402300799999, seconds_played >= 0,
track_length > 0, both nullable); server-stamped `received_at`; nullable
reserved `owner_id`. `history_hook_failures(subscriber, event_uuid, error,
created_at)` records SC-23 subscriber failures. Fresh DDL and the migration
agree; the upgrade starts from the real v11 schema PR 5A.0 shipped.
"""

import sqlite3

import pytest

from app.database.database import Database
from tests.schema_fixtures import make_v11_database, open_database, user_version

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
    "owner_id": ("TEXT", 0),
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


def _schema(path, names):
    conn = sqlite3.connect(path)
    try:
        return sorted(
            (row[0], row[1], " ".join((row[2] or "").split()))
            for row in conn.execute(
                "SELECT type, name, sql FROM sqlite_master WHERE tbl_name IN (%s)"
                % ",".join("?" * len(names)),
                names,
            )
        )
    finally:
        conn.close()


@pytest.fixture
def fresh(tmp_path):
    path = tmp_path / "fresh" / "database.db"
    open_database(path)
    return path


@pytest.fixture
def migrated(tmp_path):
    path = tmp_path / "migrated" / "database.db"
    make_v11_database(path)
    open_database(path)
    return path


def test_latest_schema_version_is_12():
    assert Database.LATEST_SCHEMA_VERSION == 12


@pytest.mark.parametrize("db", ["fresh", "migrated"])
def test_history_events_columns(db, request):
    path = request.getfixturevalue(db)
    cols = _columns(path, "history_events")
    assert {name: (t, nn) for name, (t, nn, _) in cols.items()} == PAYLOAD_COLUMNS
    assert [name for name, (_, _, pk) in cols.items() if pk] == ["event_uuid"]
    assert user_version(path) == 12


@pytest.mark.parametrize("db", ["fresh", "migrated"])
def test_history_hook_failures_columns(db, request):
    cols = _columns(request.getfixturevalue(db), "history_hook_failures")
    for name in ("subscriber", "event_uuid", "error", "created_at"):
        assert name in cols and cols[name][1] == 1, name


def test_fresh_and_migrated_history_schema_are_identical(fresh, migrated):
    names = ["history_events", "history_hook_failures"]
    assert _schema(fresh, names) == _schema(migrated, names)
    assert _schema(fresh, names), "tables exist"


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
        "owner_id": None,
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


def test_upgrade_preserves_v11_data_and_reopens_idempotently(tmp_path):
    path = tmp_path / "database.db"
    make_v11_database(path)
    conn = sqlite3.connect(path)
    conn.execute("INSERT INTO artists (id, name) VALUES (3, 'A')")
    conn.commit()
    conn.close()
    open_database(path)
    open_database(path)  # second open: no re-migration failure
    assert user_version(path) == 12
    conn = sqlite3.connect(path)
    try:
        assert conn.execute("SELECT id, name FROM artists").fetchall() == [(3, "A")]
        assert conn.execute(
            "SELECT value FROM app_settings WHERE key='server_instance_id'"
        ).fetchone() == ("inst-v11",)
    finally:
        conn.close()
