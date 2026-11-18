"""The fresh schema's upload, receipt and reservation tables.

Every table holds per-user rows and carries its own required ``owner_id``.
Client-generated ids (batch, item, operation uuids) are unique per owner
only: the same uuid sent by two users gives two independent rows, and no row
of one user can reference a row of another.
"""

import sqlite3

import pytest

from app.services.audio_identity import (
    FINGERPRINT_COLUMNS,
    IDENTITY_COLUMNS,
    AudioIdentity,
    ExactAudioHash,
    ExactUnavailable,
    FingerprintIdentity,
    identity_from_columns,
    identity_to_columns,
)
from tests.schema_fixtures import INIT_SQL

SAM, ALEX = 1, 2
# Every upload, receipt and reservation table, each with its own owner (SC-28 rule 1).
NEW_TABLES = (
    "upload_batches",
    "upload_items",
    "upload_item_audio_identity",
    "operation_receipts",
    "storage_reservations",
    "upload_item_acknowledgements",
    "upload_commit_journal",
)


@pytest.fixture
def conn():
    connection = sqlite3.connect(":memory:")
    connection.executescript(INIT_SQL.read_text())
    connection.execute("PRAGMA foreign_keys=ON")
    connection.executemany(
        "INSERT INTO users (id, username, username_key, password_hash, library_folder, "
        "created_at) VALUES (?, ?, ?, 'h', ?, 0)",
        [(SAM, "Sam", "sam", "sam"), (ALEX, "Alex", "alex", "alex")],
    )
    try:
        yield connection
    finally:
        connection.close()


def _info(conn, table):
    """name -> (notnull, default, pk position) from PRAGMA table_info."""
    return {
        row[1]: (row[3], row[4], row[5])
        for row in conn.execute(f"PRAGMA table_info('{table}')")
    }


def _primary_key(conn, table):
    info = _info(conn, table)
    return [name for name, _ in sorted(
        ((n, pk) for n, (_, _, pk) in info.items() if pk), key=lambda item: item[1]
    )]


def _index_columns(conn, index):
    return [row[2] for row in conn.execute(f"PRAGMA index_info('{index}')")]


def _indexes(conn, table):
    return {
        row[1]: _index_columns(conn, row[1])
        for row in conn.execute(f"PRAGMA index_list('{table}')")
    }


def _plan(conn, sql, args):
    return " ".join(row[3] for row in conn.execute(f"EXPLAIN QUERY PLAN {sql}", args))


# --- every new table is owned (SC-28 rule 1) ----------------------------------------------------


@pytest.mark.parametrize("table", NEW_TABLES)
def test_a_new_table_has_a_required_owner_without_default(conn, table):
    notnull, default, _ = _info(conn, table)["owner_id"]
    assert (notnull, default) == (1, None)
    targets = {(row[3], row[2], row[4]) for row in conn.execute(f"PRAGMA foreign_key_list('{table}')")}
    assert ("owner_id", "users", "id") in targets


@pytest.mark.parametrize("table", NEW_TABLES)
def test_a_new_table_has_an_index_that_leads_with_the_owner(conn, table):
    assert any(cols[:1] == ["owner_id"] for cols in _indexes(conn, table).values())


# --- upload_batches -------------------------------------------------------------------------


def _batch(conn, owner, batch_uuid, *, created_at=100, label="My upload"):
    conn.execute(
        "INSERT INTO upload_batches (owner_id, batch_uuid, label, created_at, updated_at) "
        "VALUES (?, ?, ?, ?, ?)",
        (owner, batch_uuid, label, created_at, created_at),
    )


def test_a_batch_is_keyed_by_owner_and_uuid(conn):
    assert _primary_key(conn, "upload_batches") == ["owner_id", "batch_uuid"]


def test_the_same_batch_uuid_from_two_users_gives_two_independent_batches(conn):
    _batch(conn, SAM, "b-1", label="Sam's")
    _batch(conn, ALEX, "b-1", label="Alex's")

    rows = conn.execute(
        "SELECT owner_id, label FROM upload_batches WHERE batch_uuid = 'b-1' ORDER BY owner_id"
    ).fetchall()
    assert rows == [(SAM, "Sam's"), (ALEX, "Alex's")]
    # One user's lookup by (owner, uuid) never sees the other's.
    assert conn.execute(
        "SELECT label FROM upload_batches WHERE owner_id = ? AND batch_uuid = 'b-1'", (ALEX,)
    ).fetchall() == [("Alex's",)]


def test_one_user_cannot_hold_the_same_batch_uuid_twice(conn):
    _batch(conn, SAM, "b-1")
    with pytest.raises(sqlite3.IntegrityError):
        _batch(conn, SAM, "b-1")


def test_a_batch_of_an_unknown_user_cannot_be_stored(conn):
    with pytest.raises(sqlite3.IntegrityError):
        _batch(conn, 99, "b-1")


@pytest.mark.parametrize("column", ["owner_id", "batch_uuid", "created_at", "updated_at"])
def test_batch_columns_are_required(conn, column):
    values = {"owner_id": SAM, "batch_uuid": "b-1", "label": None, "created_at": 1, "updated_at": 1}
    values[column] = None
    with pytest.raises(sqlite3.IntegrityError):
        conn.execute(
            "INSERT INTO upload_batches (owner_id, batch_uuid, label, created_at, updated_at) "
            "VALUES (:owner_id, :batch_uuid, :label, :created_at, :updated_at)",
            values,
        )


def test_a_batch_label_is_optional(conn):
    _batch(conn, SAM, "b-1", label=None)
    assert conn.execute("SELECT label FROM upload_batches").fetchone() == (None,)


def test_the_batch_keyset_index_is_owner_created_at_uuid(conn):
    assert _indexes(conn, "upload_batches")["idx_upload_batches_list"] == [
        "owner_id", "created_at", "batch_uuid",
    ]


BATCH_PAGE = (
    "SELECT batch_uuid FROM upload_batches WHERE owner_id = ? "
    "AND (created_at, batch_uuid) > (?, ?) ORDER BY created_at, batch_uuid LIMIT ?"
)


def test_the_batch_keyset_page_uses_the_index_without_a_temp_b_tree(conn):
    plan = _plan(conn, BATCH_PAGE, (SAM, 0, "", 25))
    assert "idx_upload_batches_list" in plan
    assert "TEMP B-TREE" not in plan


def test_the_batch_keyset_walks_one_users_batches_once_in_order_with_ties(conn):
    for owner in (SAM, ALEX):
        for created_at, uuid in ((5, "c"), (5, "a"), (3, "z"), (5, "b"), (9, "d")):
            _batch(conn, owner, uuid, created_at=created_at)
    seen, cursor = [], (0, "")
    while True:
        page = conn.execute(
            BATCH_PAGE.replace("SELECT batch_uuid", "SELECT created_at, batch_uuid"),
            (SAM, *cursor, 2),
        ).fetchall()
        if not page:
            break
        seen.extend(page)
        cursor = page[-1]
    assert seen == [(3, "z"), (5, "a"), (5, "b"), (5, "c"), (9, "d")]


# --- upload_items ---------------------------------------------------------------------------

# Spec §3 "States and permitted transitions": every state an item can be in.
ITEM_STATES = (
    "allocated", "receiving", "validating", "review_ready", "committing", "imported",
    "duplicate", "expanded", "failed", "duplicate_conflict", "expired", "cancelled",
)
DIGEST = "0123456789abcdef" * 4

ITEM_COLUMNS = (
    "owner_id", "item_uuid", "batch_uuid", "parent_item_uuid", "kind", "filename",
    "selection_index", "member_order_key", "expected_bytes", "expected_sha256",
    "received_bytes", "received_sha256", "part_path", "source_path", "detected_metadata",
    "review_version", "state", "error_code", "error_message", "error_retryable",
    "cancel_requested", "lease_boot_id", "duplicate_report", "conflict_track_uuids",
    "skipped_members", "reserved_track_uuid", "final_path", "result_track_uuid",
    "result_revision", "duplicate_kind", "created_at", "updated_at", "progress_at",
)
REQUIRED_ITEM_COLUMNS = {
    "owner_id", "item_uuid", "batch_uuid", "filename", "selection_index",
    "member_order_key", "received_bytes", "review_version", "state", "cancel_requested",
    "created_at", "updated_at", "progress_at",
}


def _item(conn, owner, item_uuid, batch_uuid="b-1", **overrides):
    """A direct audio item, valid as ``allocated`` unless overridden."""
    values = {
        "owner_id": owner, "item_uuid": item_uuid, "batch_uuid": batch_uuid,
        "parent_item_uuid": None, "kind": None, "filename": "song.flac",
        "selection_index": 0, "member_order_key": "", "expected_bytes": 10,
        "expected_sha256": DIGEST, "state": "allocated", "created_at": 100,
        "updated_at": 100, "progress_at": 100,
    }
    values.update(overrides)
    columns = ", ".join(values)
    conn.execute(
        f"INSERT INTO upload_items ({columns}) VALUES ({', '.join(':' + c for c in values)})",
        values,
    )


def _state_row(state):
    """Overrides that make an item legal in ``state``."""
    return {
        "imported": {"result_track_uuid": "t-1", "result_revision": 7},
        "duplicate": {"result_track_uuid": "t-1", "duplicate_kind": "exact"},
        "expanded": {"kind": "zip"},
        "failed": {"error_code": "invalid_audio"},
    }.get(state, {})


@pytest.fixture
def batches(conn):
    _batch(conn, SAM, "b-1")
    _batch(conn, ALEX, "b-1")
    return conn


def test_the_item_columns(conn):
    info = _info(conn, "upload_items")
    assert set(info) == set(ITEM_COLUMNS)
    assert {name for name, (notnull, _, _) in info.items() if notnull} == REQUIRED_ITEM_COLUMNS
    assert info["received_bytes"][1] == "0"
    assert info["review_version"][1] == "0"
    assert info["cancel_requested"][1] == "0"
    assert info["state"][1] is None  # writers say which state a new item starts in


def test_an_item_is_keyed_by_owner_and_uuid(conn):
    assert _primary_key(conn, "upload_items") == ["owner_id", "item_uuid"]


def test_the_same_item_uuid_from_two_users_gives_two_independent_items(batches):
    _item(batches, SAM, "i-1", filename="sam.flac")
    _item(batches, ALEX, "i-1", filename="alex.flac")

    assert batches.execute(
        "SELECT owner_id, filename FROM upload_items WHERE item_uuid = 'i-1' ORDER BY owner_id"
    ).fetchall() == [(SAM, "sam.flac"), (ALEX, "alex.flac")]
    with pytest.raises(sqlite3.IntegrityError):
        _item(batches, SAM, "i-1")


def test_an_item_cannot_join_another_users_batch(conn):
    _batch(conn, SAM, "b-sam")
    with pytest.raises(sqlite3.IntegrityError):
        _item(conn, ALEX, "i-1", batch_uuid="b-sam")


def test_a_zip_child_cannot_hang_under_another_users_archive(batches):
    _item(batches, SAM, "zip-1", kind="zip")
    with pytest.raises(sqlite3.IntegrityError):
        _item(batches, ALEX, "child-1", parent_item_uuid="zip-1", member_order_key="a.flac",
              expected_bytes=None, expected_sha256=None)


def test_a_zip_child_of_the_same_user_is_stored(batches):
    _item(batches, SAM, "zip-1", kind="zip")
    _item(batches, SAM, "child-1", parent_item_uuid="zip-1", member_order_key="a/b.flac",
          expected_bytes=None, expected_sha256=None, state="validating")
    assert batches.execute("SELECT count(*) FROM upload_items").fetchone() == (2,)


@pytest.mark.parametrize("state", ITEM_STATES)
def test_every_spec_state_is_storable(batches, state):
    _item(batches, SAM, "i-1", state=state, **_state_row(state))


@pytest.mark.parametrize(
    "overrides",
    [
        {"state": "uploaded"},
        {"state": None},
        {"kind": "tar"},
        {"selection_index": -1},
        {"expected_bytes": -1},
        {"received_bytes": -1},
        {"review_version": -1},
        {"cancel_requested": 2},
        {"error_retryable": 2},
        {"skipped_members": -1},
        {"duplicate_kind": "maybe", "state": "duplicate", "result_track_uuid": "t-1"},
        # A selected file needs its expected length and digest (spec §4 POST).
        {"expected_bytes": None},
        {"expected_sha256": None},
        {"expected_sha256": DIGEST.upper()},
        {"expected_sha256": DIGEST[:-1]},
        {"received_sha256": "not-a-digest"},
        # A direct item has no member name.
        {"member_order_key": "a.flac"},
        # Terminal receipts carry the canonical track (spec §3).
        {"state": "imported"},
        {"state": "imported", "result_track_uuid": "t-1"},  # and its revision (review r1)
        {"state": "duplicate", "result_track_uuid": "t-1"},
        {"state": "review_ready", "duplicate_kind": "exact"},
        # Only a ZIP parent expands, and failures say why.
        {"state": "expanded"},
        {"state": "failed"},
    ],
)
def test_item_constraints_reject_an_impossible_row(batches, overrides):
    with pytest.raises(sqlite3.IntegrityError):
        _item(batches, SAM, "i-1", **overrides)


@pytest.mark.parametrize(
    "overrides",
    [
        # A ZIP child must name its member, and archives do not nest.
        {"member_order_key": ""},
        {"kind": "zip"},
    ],
)
def test_zip_child_constraints(batches, overrides):
    _item(batches, SAM, "zip-1", kind="zip")
    child = {"parent_item_uuid": "zip-1", "member_order_key": "a.flac",
             "expected_bytes": None, "expected_sha256": None}
    child.update(overrides)
    with pytest.raises(sqlite3.IntegrityError):
        _item(batches, SAM, "child-1", **child)


def test_an_item_cannot_be_its_own_archive(batches):
    with pytest.raises(sqlite3.IntegrityError):
        _item(batches, SAM, "i-1", parent_item_uuid="i-1", member_order_key="a.flac")


def test_items_go_with_their_batch_and_children_with_their_archive(batches):
    _item(batches, SAM, "zip-1", kind="zip")
    _item(batches, SAM, "child-1", parent_item_uuid="zip-1", member_order_key="a.flac",
          expected_bytes=None, expected_sha256=None)
    _item(batches, SAM, "i-2", selection_index=1)
    _item(batches, ALEX, "zip-1", kind="zip")

    batches.execute("DELETE FROM upload_items WHERE owner_id = ? AND item_uuid = 'zip-1'", (SAM,))
    assert batches.execute(
        "SELECT owner_id, item_uuid FROM upload_items ORDER BY owner_id, item_uuid"
    ).fetchall() == [(SAM, "i-2"), (ALEX, "zip-1")]

    batches.execute("DELETE FROM upload_batches WHERE owner_id = ?", (SAM,))
    assert batches.execute("SELECT owner_id, item_uuid FROM upload_items").fetchall() == [
        (ALEX, "zip-1"),
    ]


def test_the_item_indexes(conn):
    indexes = _indexes(conn, "upload_items")
    assert indexes["idx_upload_items_list"] == [
        "owner_id", "batch_uuid", "selection_index", "member_order_key", "item_uuid",
    ]
    assert indexes["idx_upload_items_parent"] == ["owner_id", "batch_uuid", "parent_item_uuid"]
    assert indexes["idx_upload_items_state"] == ["state", "updated_at"]
    assert indexes["idx_upload_items_result"] == ["owner_id", "result_track_uuid"]


ITEM_PAGE = (
    "SELECT selection_index, member_order_key, item_uuid FROM upload_items "
    "WHERE owner_id = ? AND batch_uuid = ? "
    "AND (selection_index, member_order_key, item_uuid) > (?, ?, ?) "
    "ORDER BY selection_index, member_order_key, item_uuid LIMIT ?"
)


def test_the_item_keyset_page_uses_the_index_without_a_temp_b_tree(conn):
    plan = _plan(conn, ITEM_PAGE, (SAM, "b-1", -1, "", "", 25))
    assert "idx_upload_items_list" in plan
    assert "TEMP B-TREE" not in plan


def test_the_item_keyset_walks_one_batch_once_in_display_order(batches):
    _item(batches, SAM, "zip-z", kind="zip", selection_index=0)
    for uuid, key in (("c-2", "b.flac"), ("c-1", "a.flac"), ("c-3", "a.flac")):
        _item(batches, SAM, uuid, parent_item_uuid="zip-z", member_order_key=key,
              selection_index=0, expected_bytes=None, expected_sha256=None)
    _item(batches, SAM, "d-1", selection_index=1)
    _item(batches, ALEX, "x-1", selection_index=0)
    seen, cursor = [], (-1, "", "")
    while True:
        page = batches.execute(ITEM_PAGE, (SAM, "b-1", *cursor, 2)).fetchall()
        if not page:
            break
        seen.extend(row[2] for row in page)
        cursor = page[-1]
    assert seen == ["zip-z", "c-1", "c-3", "c-2", "d-1"]


# --- upload_item_audio_identity (plan D11) --------------------------------------------------


def _identity_row(conn, owner, item_uuid, identity, **writer_columns):
    """Store ``identity`` the way validation will: the SC-25 serializer's
    columns plus the writer's own fingerprint state when there is no print."""
    values = {"owner_id": owner, "item_uuid": item_uuid, **identity_to_columns(identity)}
    values.update(writer_columns)
    conn.execute(
        f"INSERT INTO upload_item_audio_identity ({', '.join(values)}) "
        f"VALUES ({', '.join(':' + c for c in values)})",
        values,
    )


def _read_identity(conn, owner, item_uuid):
    conn.row_factory = sqlite3.Row
    try:
        row = conn.execute(
            "SELECT * FROM upload_item_audio_identity WHERE owner_id = ? AND item_uuid = ?",
            (owner, item_uuid),
        ).fetchone()
    finally:
        conn.row_factory = None
    return dict(row)


CURRENT = AudioIdentity(
    exact=ExactAudioHash("pcm_sha256", "ab" * 32, 44100, 2, 16),
    tool_versions="ffmpeg 8.1; fpcalc 1.6.2",
    computed_at=1_700_000_000,
    fingerprint=FingerprintIdentity("current", "fpcalc", "chromaprint-2", 181.5, (1, 2, 3, 4)),
)
NO_PRINT = AudioIdentity(
    exact=ExactUnavailable("unsupported", "codec"),
    tool_versions="ffmpeg 8.1",
    computed_at=1_700_000_001,
    fingerprint=None,
)


@pytest.fixture
def items(batches):
    _item(batches, SAM, "i-1")
    _item(batches, ALEX, "i-1")
    return batches


def test_the_staged_identity_columns_are_the_sc25_serializer_columns(conn):
    """Plan D11: the column set comes from ``audio_identity`` (no hand-copied
    list that can drift); a column added to the serializer must appear here."""
    expected = (
        {"owner_id", "item_uuid", "fp_failure_reason"}
        | set(IDENTITY_COLUMNS)
        | set(FINGERPRINT_COLUMNS)
    )
    assert set(_info(conn, "upload_item_audio_identity")) == expected


def test_a_staged_identity_is_keyed_by_owner_and_item(conn):
    assert _primary_key(conn, "upload_item_audio_identity") == ["owner_id", "item_uuid"]


def test_a_current_identity_round_trips_through_the_serializer(items):
    _identity_row(items, SAM, "i-1", CURRENT)
    assert identity_from_columns(_read_identity(items, SAM, "i-1")) == CURRENT


def test_an_identity_without_a_print_round_trips_with_the_writers_fp_state(items):
    _identity_row(items, SAM, "i-1", NO_PRINT, fp_state="failed", fp_failure_reason="timeout")
    row = _read_identity(items, SAM, "i-1")
    assert identity_from_columns(row) == NO_PRINT
    assert (row["fp_state"], row["fp_failure_reason"]) == ("failed", "timeout")


def test_two_users_staged_identities_for_the_same_item_uuid_are_independent(items):
    _identity_row(items, SAM, "i-1", CURRENT)
    _identity_row(items, ALEX, "i-1", NO_PRINT, fp_state="unavailable")

    assert identity_from_columns(_read_identity(items, SAM, "i-1")) == CURRENT
    assert identity_from_columns(_read_identity(items, ALEX, "i-1")) == NO_PRINT


def test_a_staged_identity_needs_an_item_of_the_same_user(batches):
    _item(batches, SAM, "i-sam")
    with pytest.raises(sqlite3.IntegrityError):
        _identity_row(batches, ALEX, "i-sam", CURRENT)


def test_a_staged_identity_goes_with_its_item(items):
    _identity_row(items, SAM, "i-1", CURRENT)
    _identity_row(items, ALEX, "i-1", CURRENT)

    items.execute("DELETE FROM upload_items WHERE owner_id = ? AND item_uuid = 'i-1'", (SAM,))

    assert items.execute(
        "SELECT owner_id FROM upload_item_audio_identity"
    ).fetchall() == [(ALEX,)]


@pytest.mark.parametrize(
    "overrides",
    [
        {"exact_state": "pending"},  # staged identities are computed, never pending
        {"exact_kind": "md5"},
        {"exact_digest": None},  # a current exact layer has its digest
        {"fp_state": "pending"},
        {"fp_state": None},
        {"fp_data": None},  # a current print has its data
        {"fp_duration_s": 0.0},  # unknown is not zero
        {"computed_at": None},
    ],
)
def test_staged_identity_constraints_reject_an_impossible_row(items, overrides):
    with pytest.raises(sqlite3.IntegrityError):
        _identity_row(items, SAM, "i-1", CURRENT, **overrides)


# --- operation_receipts (SC-16c, decision O2) -----------------------------------------------

HASH = "f" * 64


def _receipt(conn, owner, operation_uuid, *, kind="upload_commit", request_hash=HASH,
             result_ref=None):
    conn.execute(
        "INSERT INTO operation_receipts (owner_id, operation_uuid, kind, request_hash, "
        "created_at, result_ref) VALUES (?, ?, ?, ?, 100, ?)",
        (owner, operation_uuid, kind, request_hash, result_ref),
    )


def test_the_receipt_columns(conn):
    info = _info(conn, "operation_receipts")
    assert set(info) == {
        "owner_id", "operation_uuid", "kind", "request_hash", "created_at", "result_ref",
    }
    assert {n for n, (notnull, _, _) in info.items() if notnull} == {
        "owner_id", "operation_uuid", "kind", "request_hash", "created_at",
    }
    assert _primary_key(conn, "operation_receipts") == ["owner_id", "operation_uuid"]


def test_the_same_operation_uuid_from_two_users_gives_two_independent_receipts(conn):
    _receipt(conn, SAM, "op-1", result_ref="sam-item")
    _receipt(conn, ALEX, "op-1", kind="upload_resolve_duplicate", result_ref="alex-item")

    assert conn.execute(
        "SELECT owner_id, kind, result_ref FROM operation_receipts ORDER BY owner_id"
    ).fetchall() == [
        (SAM, "upload_commit", "sam-item"),
        (ALEX, "upload_resolve_duplicate", "alex-item"),
    ]
    with pytest.raises(sqlite3.IntegrityError):
        _receipt(conn, SAM, "op-1")


def test_receipt_kinds_are_an_open_set_for_later_phases(conn):
    """SC-16c: Phase 8 delete jobs and 9D enable add kinds; a CHECK list would
    need a table rebuild for each."""
    _receipt(conn, SAM, "op-8", kind="library_delete")


@pytest.mark.parametrize(
    "overrides",
    [
        {"kind": ""},
        {"request_hash": HASH[:-1]},
        {"request_hash": HASH.upper()},
        {"request_hash": "g" * 64},
        {"request_hash": None},
    ],
)
def test_receipt_constraints_reject_an_impossible_row(conn, overrides):
    with pytest.raises(sqlite3.IntegrityError):
        _receipt(conn, SAM, "op-1", **overrides)


# --- storage_reservations (SC-16g table only) -----------------------------------------------


def _reservation(conn, owner, *, purpose="upload_receive", subject_ref="i-1", bytes_=10):
    return conn.execute(
        "INSERT INTO storage_reservations (owner_id, purpose, subject_ref, bytes, created_at) "
        "VALUES (?, ?, ?, ?, 100)",
        (owner, purpose, subject_ref, bytes_),
    ).lastrowid


def test_the_reservation_columns(conn):
    info = _info(conn, "storage_reservations")
    assert set(info) == {
        "id", "owner_id", "purpose", "subject_ref", "bytes", "lease_boot_id", "created_at",
    }
    assert {n for n, (notnull, _, _) in info.items() if notnull} == {
        "owner_id", "purpose", "bytes", "created_at",
    }


def test_a_released_reservation_id_is_never_reused(conn):
    """AUTOINCREMENT: a release followed by a new reservation never hands the
    old id to someone else (a late release must not free another's bytes)."""
    _reservation(conn, SAM)
    last = _reservation(conn, ALEX)
    conn.execute("DELETE FROM storage_reservations WHERE id = ?", (last,))

    assert _reservation(conn, SAM) == last + 1


@pytest.mark.parametrize(
    "overrides",
    [{"bytes_": -1}, {"bytes_": None}, {"purpose": ""}, {"purpose": None}],
)
def test_reservation_constraints_reject_an_impossible_row(conn, overrides):
    with pytest.raises(sqlite3.IntegrityError):
        _reservation(conn, SAM, **overrides)


def test_the_reservation_indexes(conn):
    """Review r1 #1: a subject (item uuid) is unique per owner only, so every
    lookup by subject leads with the owner."""
    indexes = _indexes(conn, "storage_reservations")
    assert indexes == {"idx_storage_reservations_owner": ["owner_id", "purpose", "subject_ref"]}


# --- upload_item_acknowledgements (spec §3, §6 step 3) --------------------------------------


def _ack(conn, owner, item_uuid, subject_kind, subject_ref):
    conn.execute(
        "INSERT INTO upload_item_acknowledgements (owner_id, item_uuid, subject_kind, "
        "subject_ref) VALUES (?, ?, ?, ?)",
        (owner, item_uuid, subject_kind, subject_ref),
    )


def test_an_acknowledgement_is_keyed_by_owner_item_and_subject(conn):
    assert _primary_key(conn, "upload_item_acknowledgements") == [
        "owner_id", "item_uuid", "subject_kind", "subject_ref",
    ]


def test_two_users_acknowledgements_under_the_same_item_uuid_are_independent(items):
    _ack(items, SAM, "i-1", "library_track", "t-1")
    _ack(items, SAM, "i-1", "staged_item", "i-2")
    _ack(items, ALEX, "i-1", "library_track", "t-1")
    with pytest.raises(sqlite3.IntegrityError):
        _ack(items, SAM, "i-1", "library_track", "t-1")

    items.execute("DELETE FROM upload_items WHERE owner_id = ? AND item_uuid = 'i-1'", (SAM,))

    assert items.execute(
        "SELECT owner_id, subject_ref FROM upload_item_acknowledgements"
    ).fetchall() == [(ALEX, "t-1")]


def test_an_acknowledgement_needs_an_item_of_the_same_user(batches):
    _item(batches, SAM, "i-sam")
    with pytest.raises(sqlite3.IntegrityError):
        _ack(batches, ALEX, "i-sam", "library_track", "t-1")


@pytest.mark.parametrize("subject_kind", ["track", "", None])
def test_an_acknowledgement_names_a_library_track_or_a_staged_item(items, subject_kind):
    with pytest.raises(sqlite3.IntegrityError):
        _ack(items, SAM, "i-1", subject_kind, "t-1")


def test_the_symmetric_rule_looks_acknowledgements_up_by_subject(conn):
    """§6 step 3: "published by an upload item whose persisted
    acknowledgements list *this* item" is a lookup by (owner, subject)."""
    assert _indexes(conn, "upload_item_acknowledgements")["idx_upload_acks_subject"] == [
        "owner_id", "subject_kind", "subject_ref",
    ]


# --- upload_commit_journal (spec §6) --------------------------------------------------------

JOURNAL_STATES = ("committing", "prepared", "moved", "imported", "duplicate_conflict", "failed")
JOURNAL_OWN_COLUMNS = {
    "owner_id", "operation_uuid", "item_uuid", "state", "base_review_version",
    "reserved_track_uuid", "edits", "write_tags", "acknowledged_duplicates", "source_path",
    "work_path", "final_path", "final_metadata", "cover_art_id", "cover_art_created",
    "error_code", "lease_boot_id", "created_at", "updated_at",
    # 7A.3a: the outcome of the exact-digest re-verification of the work file.
    "digest_check",
}
REQUIRED_JOURNAL_COLUMNS = {
    "owner_id", "operation_uuid", "item_uuid", "state", "base_review_version",
    "reserved_track_uuid", "edits", "write_tags", "acknowledged_duplicates", "source_path",
    "created_at", "updated_at",
}


def _journal(conn, owner, operation_uuid, item_uuid="i-1", **overrides):
    values = {
        "owner_id": owner, "operation_uuid": operation_uuid, "item_uuid": item_uuid,
        "state": "committing", "base_review_version": 3, "reserved_track_uuid": "t-new",
        "edits": "{}", "write_tags": 0,
        "acknowledged_duplicates": '{"library_tracks":[],"staged_items":[]}',
        "source_path": "/music/.uploads/b/i/source", "created_at": 100, "updated_at": 100,
    }
    values.update(overrides)
    conn.execute(
        f"INSERT INTO upload_commit_journal ({', '.join(values)}) "
        f"VALUES ({', '.join(':' + c for c in values)})",
        values,
    )


@pytest.fixture
def receipts(items):
    _receipt(items, SAM, "op-1")
    _receipt(items, ALEX, "op-1")
    return items


def test_the_journal_columns_carry_the_identity_to_insert_through_the_serializer(conn):
    """§6: the journal holds "the audio identity to insert"; it uses the same
    SC-25 columns, so it is read back with ``identity_from_columns``."""
    info = _info(conn, "upload_commit_journal")
    assert set(info) == JOURNAL_OWN_COLUMNS | set(IDENTITY_COLUMNS) | set(FINGERPRINT_COLUMNS)
    assert {n for n, (notnull, _, _) in info.items() if notnull} == REQUIRED_JOURNAL_COLUMNS
    assert _primary_key(conn, "upload_commit_journal") == ["owner_id", "operation_uuid"]


def test_a_journaled_identity_round_trips_through_the_serializer(receipts):
    _journal(receipts, SAM, "op-1", state="prepared", **identity_to_columns(CURRENT))
    receipts.row_factory = sqlite3.Row
    row = dict(receipts.execute("SELECT * FROM upload_commit_journal").fetchone())
    receipts.row_factory = None
    assert identity_from_columns(row) == CURRENT


@pytest.mark.parametrize("state", JOURNAL_STATES)
def test_every_journal_state_is_storable(receipts, state):
    _journal(receipts, SAM, "op-1", state=state)


@pytest.mark.parametrize("outcome", ["verified", "changed", "computed", "unverified", None])
def test_every_digest_check_outcome_is_storable(receipts, outcome):
    """7A.3a: spec §6 step 2 re-verifies the exact digest of the work file."""
    _journal(receipts, SAM, "op-1", state="prepared", digest_check=outcome)


def test_two_users_journals_under_the_same_operation_uuid_are_independent(receipts):
    _journal(receipts, SAM, "op-1", reserved_track_uuid="t-sam")
    _journal(receipts, ALEX, "op-1", reserved_track_uuid="t-alex")
    assert receipts.execute(
        "SELECT owner_id, reserved_track_uuid FROM upload_commit_journal ORDER BY owner_id"
    ).fetchall() == [(SAM, "t-sam"), (ALEX, "t-alex")]


def test_a_journal_row_needs_its_own_receipt_and_item(receipts):
    with pytest.raises(sqlite3.IntegrityError):
        _journal(receipts, SAM, "op-unknown")
    _item(receipts, SAM, "i-sam-only", selection_index=1)
    with pytest.raises(sqlite3.IntegrityError):
        _journal(receipts, ALEX, "op-1", item_uuid="i-sam-only")


def test_an_item_with_a_journal_cannot_vanish_under_it(receipts):
    """Recovery owns the journal: deleting its item fails rather than
    cascading the recovery record away."""
    _journal(receipts, SAM, "op-1")
    with pytest.raises(sqlite3.IntegrityError):
        receipts.execute("DELETE FROM upload_items WHERE owner_id = ? AND item_uuid = 'i-1'", (SAM,))


@pytest.mark.parametrize(
    "overrides",
    [
        {"state": "done"},
        {"state": None},
        {"write_tags": 2},
        {"base_review_version": -1},
        {"cover_art_created": 2},
        {"exact_state": "pending"},
        {"fp_state": "pending"},
        {"fp_duration_s": 0.0},
        {"digest_check": "maybe"},
        {"digest_check": ""},
    ],
)
def test_journal_constraints_reject_an_impossible_row(receipts, overrides):
    with pytest.raises(sqlite3.IntegrityError):
        _journal(receipts, SAM, "op-1", **overrides)


def test_a_journal_row_is_found_by_its_item(conn):
    assert _indexes(conn, "upload_commit_journal")["idx_upload_journal_item"] == [
        "owner_id", "item_uuid",
    ]


def test_a_zip_child_stays_in_its_archives_batch(conn):
    """Review r1 nit: a child in another batch would make one batch's delete
    cascade into another."""
    _batch(conn, SAM, "b-1")
    _batch(conn, SAM, "b-2")
    _item(conn, SAM, "zip-1", kind="zip")
    with pytest.raises(sqlite3.IntegrityError):
        _item(conn, SAM, "child-1", batch_uuid="b-2", parent_item_uuid="zip-1",
              member_order_key="a.flac", expected_bytes=None, expected_sha256=None)
