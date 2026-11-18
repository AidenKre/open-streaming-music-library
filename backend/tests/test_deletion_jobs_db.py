"""Piece 8A.2b S4 (spec §4 job row, §5 schema; SC-16c with DEV-7-01; plan D6,
O5): ``Database.create_deletion_job`` durably accepts a deletion job through
the shared operation receipt (kind ``track_deletion``, keyed by owner +
operation UUID): one ``deletion_jobs`` row ``accepted`` and one ``pending``
item per target in request order. An exact replay returns False and writes no
second row; the same UUID with different targets or revisions raises
``OperationConflict``. Targets are frozen as given: nothing is looked up, so a
foreign or unknown UUID is stored like any other (8A.3c answers it
``not_found``). ``get_deletion_job`` reads the caller's own job only.
"""

import sqlite3
import uuid

import pytest

from app.database.operation_receipts import OperationConflict
from app.library import Library
from app.models.deletions import DeletionJobRequest
from tests.owned_database import add_test_user
from tests.sqlite_helpers import sql_rows

OP = "11111111-1111-4111-8111-111111111111"
A = "aaaaaaaa-0000-4000-8000-000000000001"
B = "bbbbbbbb-0000-4000-8000-000000000002"
C = "cccccccc-0000-4000-8000-000000000003"


@pytest.fixture
def me(db):
    return Library(db, db.owner_id)


@pytest.fixture
def sam(db):
    return Library(db, add_test_user(db, "sam"))


def _request(*targets, op=OP):
    return DeletionJobRequest.model_validate({
        "operation_uuid": op,
        "targets": [{"uuid_id": u, "base_revision": r} for u, r in targets],
        "confirmed_count": len(targets),
    })


def _job_rows(db):
    return (
        sql_rows(db, "SELECT owner_id, operation_uuid, created_at, status FROM deletion_jobs"
                  " ORDER BY owner_id"),
        sql_rows(db, "SELECT owner_id, operation_uuid, uuid_id, position, base_revision, status,"
                  " error_code, tombstone_revision, detail_json, lease_boot_id, cancel_requested"
                  " FROM deletion_job_items ORDER BY owner_id, position"),
        sql_rows(db, "SELECT owner_id, operation_uuid, kind, created_at, result_ref"
                  " FROM operation_receipts ORDER BY owner_id"),
    )


def test_a_new_job_is_accepted_with_pending_items_in_request_order(db, me):
    created = me.create_deletion_job(_request((C, 3), (A, 1), (B, 2)), now=500)

    assert created is True
    jobs, items, receipts = _job_rows(db)
    owner = me.owner_id
    assert jobs == [(owner, OP, 500, "accepted")]
    assert items == [
        (owner, OP, C, 0, 3, "pending", None, None, None, None, 0),
        (owner, OP, A, 1, 1, "pending", None, None, None, None, 0),
        (owner, OP, B, 2, 2, "pending", None, None, None, None, 0),
    ]
    assert receipts == [(owner, OP, "track_deletion", 500, OP)]


def test_an_exact_replay_returns_false_and_writes_no_second_row(db, me):
    assert me.create_deletion_job(_request((A, 1), (B, 2)), now=500)
    before = _job_rows(db)

    assert me.create_deletion_job(_request((A, 1), (B, 2)), now=900) is False

    assert _job_rows(db) == before


def test_a_replay_with_the_targets_reordered_is_the_same_request(db, me):
    # Plan D6: the hashed request is order-normalised; the job keeps its first order.
    assert me.create_deletion_job(_request((A, 1), (B, 2)), now=500)
    before = _job_rows(db)

    assert me.create_deletion_job(_request((B, 2), (A, 1)), now=900) is False

    assert _job_rows(db) == before


@pytest.mark.parametrize("changed", [
    [(A, 1), (B, 3)],          # a revision changed
    [(A, 1), (C, 2)],          # a target changed
    [(A, 1)],                  # a target dropped
    [(A, 1), (B, 2), (C, 3)],  # a target added
], ids=["revision", "target", "dropped", "added"])
def test_the_same_uuid_with_a_different_body_conflicts_and_writes_nothing(db, me, changed):
    assert me.create_deletion_job(_request((A, 1), (B, 2)), now=500)
    before = _job_rows(db)

    with pytest.raises(OperationConflict):
        me.create_deletion_job(_request(*changed), now=900)

    assert _job_rows(db) == before


def test_an_operation_uuid_used_for_another_kind_conflicts(db, me):
    conn = sqlite3.connect(db.context.database_path)
    conn.execute(
        "INSERT INTO operation_receipts (owner_id, operation_uuid, kind, request_hash, created_at)"
        " VALUES (?, ?, 'upload_commit', ?, 1)", (me.owner_id, OP, "0" * 64))
    conn.commit()
    conn.close()

    with pytest.raises(OperationConflict):
        me.create_deletion_job(_request((A, 1)), now=500)

    assert sql_rows(db, "SELECT COUNT(*) FROM deletion_jobs") == [(0,)]


def test_another_users_operation_uuid_is_no_handle_on_my_job(db, me, sam):
    # Receipts are keyed per owner (DEV-7-01): sam reusing my UUID gets his own job.
    assert me.create_deletion_job(_request((A, 1)), now=500)

    assert sam.create_deletion_job(_request((B, 7)), now=600) is True

    jobs, items, _ = _job_rows(db)
    assert jobs == sorted([(me.owner_id, OP, 500, "accepted"), (sam.owner_id, OP, 600, "accepted")])
    assert [(i[0], i[2], i[4]) for i in items] == sorted([(me.owner_id, A, 1), (sam.owner_id, B, 7)])


def test_a_failure_inside_the_transaction_leaves_no_receipt_job_or_item(db, me, monkeypatch):
    def boom(*args, **kwargs):
        raise RuntimeError("injected")

    monkeypatch.setattr(type(db), "_set_operation_result_in", staticmethod(boom))

    with pytest.raises(RuntimeError, match="injected"):
        me.create_deletion_job(_request((A, 1), (B, 2)), now=500)

    assert _job_rows(db) == ([], [], [])


def test_a_hundred_targets_are_stored(db, me):
    targets = [(str(uuid.uuid4()), i) for i in range(100)]

    assert me.create_deletion_job(_request(*targets), now=1)

    items = sql_rows(db, "SELECT uuid_id, position, base_revision FROM deletion_job_items"
                      " ORDER BY position")
    assert items == [(u, i, r) for i, (u, r) in enumerate(targets)]


# ── get_deletion_job ────────────────────────────────────────────────────────

def test_get_reads_the_job_and_its_items_in_position_order(db, me):
    assert me.create_deletion_job(_request((C, 3), (A, 1)), now=500)

    job = me.get_deletion_job(OP)

    assert job == {
        "operation_uuid": OP,
        "created_at": 500,
        "items": [
            {"uuid_id": C, "position": 0, "base_revision": 3, "status": "pending",
             "error_code": None, "tombstone_revision": None, "detail_json": None},
            {"uuid_id": A, "position": 1, "base_revision": 1, "status": "pending",
             "error_code": None, "tombstone_revision": None, "detail_json": None},
        ],
    }


def test_get_accepts_any_uuid_spelling(db, me):
    assert me.create_deletion_job(_request((A, 1)), now=500)

    assert me.get_deletion_job(OP.upper())["operation_uuid"] == OP
    assert me.get_deletion_job(uuid.UUID(OP))["operation_uuid"] == OP


def test_get_of_an_unknown_or_foreign_job_is_none(db, me, sam):
    assert sam.create_deletion_job(_request((A, 1)), now=500)

    assert me.get_deletion_job(OP) is None
    assert me.get_deletion_job("22222222-2222-4222-8222-222222222222") is None
    assert sam.get_deletion_job(OP) is not None  # control
