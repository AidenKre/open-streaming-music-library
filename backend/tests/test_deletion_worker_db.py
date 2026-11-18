"""Phase 8A.3c (spec §5 "Durable worker claiming", SC-16d): the deletion
worker's queue.

``Database.claim_next_deletion_item(*, boot_id)`` claims one pending item of
any owner (the worker is server-wide; every later write names the owner read
from the claimed row) by a pending -> running compare-and-swap stamping the
boot id. Order: oldest job first (``created_at``, then ``operation_uuid``),
then the request order (``position``).

``Database.finish_deletion_item(...)`` writes a terminal outcome only while the
item is still ``running`` under this boot id (terminal states are immutable),
and marks the job ``completed`` once every item is terminal.

Expected values are written out or read with plain SQL.
"""

import json
import sqlite3

import pytest

from app.database.database import DatabaseContext
from app.library import Library
from app.models.deletions import DeletionJobRequest
from tests.owned_database import OwnedTestDatabase, add_test_user
from tests.schema_fixtures import INIT_SQL

OP1 = "11111111-1111-4111-8111-111111111111"
OP2 = "22222222-2222-4222-8222-222222222222"
OP3 = "33333333-3333-4333-8333-333333333333"
A = "aaaaaaaa-0000-4000-8000-000000000001"
B = "bbbbbbbb-0000-4000-8000-000000000002"
C = "cccccccc-0000-4000-8000-000000000003"
BOOT = "boot-1"


@pytest.fixture
def db(tmp_path):
    database = OwnedTestDatabase(
        DatabaseContext(database_path=tmp_path / "db.sqlite", init_sql_path=INIT_SQL)
    )
    assert database.initialize()
    return database


@pytest.fixture
def sam_id(db):
    return add_test_user(db, "sam")


def _job(db, owner, op, *targets, now=500):
    request = DeletionJobRequest.model_validate({
        "operation_uuid": op,
        "targets": [{"uuid_id": u, "base_revision": r} for u, r in targets],
        "confirmed_count": len(targets),
    })
    assert Library(db, owner).create_deletion_job(request, now=now)


def _rows(db, sql, params=()):
    conn = sqlite3.connect(db.context.database_path)
    try:
        rows = conn.execute(sql, params).fetchall()
        conn.commit()
        return rows
    finally:
        conn.close()


def _items(db):
    return _rows(
        db,
        "SELECT owner_id, operation_uuid, uuid_id, status, lease_boot_id, error_code,"
        " tombstone_revision, detail_json FROM deletion_job_items"
        " ORDER BY owner_id, operation_uuid, position",
    )


def _claimed(item):
    return (item["owner_id"], item["operation_uuid"], item["uuid_id"], item["base_revision"])


# ── claim ──────────────────────────────────────────────────────────────────


def test_nothing_pending_claims_nothing(db):
    assert db.claim_next_deletion_item(boot_id=BOOT) is None


def test_a_claim_takes_the_oldest_job_first_then_the_request_order(db, sam_id):
    _job(db, sam_id, OP2, (C, 7), now=600)
    _job(db, db.owner_id, OP3, (B, 2), (A, 1), now=500)
    _job(db, db.owner_id, OP1, (C, 9), now=500)

    order = []
    while (item := db.claim_next_deletion_item(boot_id=BOOT)) is not None:
        order.append(_claimed(item))

    assert order == [
        (db.owner_id, OP1, C, 9),
        (db.owner_id, OP3, B, 2),
        (db.owner_id, OP3, A, 1),
        (sam_id, OP2, C, 7),
    ]


def test_a_claim_stamps_running_with_the_boot_id_and_touches_nothing_else(db):
    _job(db, db.owner_id, OP1, (A, 1), (B, 2))

    item = db.claim_next_deletion_item(boot_id=BOOT)

    assert _claimed(item) == (db.owner_id, OP1, A, 1)
    assert _items(db) == [
        (db.owner_id, OP1, A, "running", BOOT, None, None, None),
        (db.owner_id, OP1, B, "pending", None, None, None, None),
    ]
    assert _rows(db, "SELECT status FROM deletion_jobs") == [("accepted",)]


def test_a_running_or_terminal_item_is_never_claimed_again(db):
    _job(db, db.owner_id, OP1, (A, 1))
    _rows(db, "UPDATE deletion_job_items SET status = 'running', lease_boot_id = 'old'")
    assert db.claim_next_deletion_item(boot_id=BOOT) is None

    _rows(db, "UPDATE deletion_job_items SET status = 'conflict', error_code = 'conflict'")
    assert db.claim_next_deletion_item(boot_id=BOOT) is None


def test_an_owner_being_deleted_is_skipped_and_keeps_its_items_pending(db, sam_id):
    """Review r1 8-R1-03: like recovery, the janitor and the conversion worker,
    the claim never takes an item of a user whose deletion has begun."""
    _job(db, sam_id, OP1, (A, 1), now=400)
    _job(db, db.owner_id, OP2, (B, 2), now=500)
    _rows(db, "UPDATE users SET deleting_at = 1 WHERE id = ?", (sam_id,))

    first = db.claim_next_deletion_item(boot_id=BOOT)

    assert _claimed(first) == (db.owner_id, OP2, B, 2)
    assert db.claim_next_deletion_item(boot_id=BOOT) is None
    assert _rows(
        db, "SELECT status, lease_boot_id FROM deletion_job_items WHERE owner_id = ?", (sam_id,)
    ) == [("pending", None)]


def test_two_claims_never_take_the_same_item(db):
    _job(db, db.owner_id, OP1, (A, 1))

    first = db.claim_next_deletion_item(boot_id=BOOT)
    second = db.claim_next_deletion_item(boot_id="boot-2")

    assert first is not None and second is None
    assert _items(db)[0][3:5] == ("running", BOOT)


# ── outcome ────────────────────────────────────────────────────────────────


def _finish(db, owner, op, uuid_id, **kwargs):
    kwargs.setdefault("boot_id", BOOT)
    return db.finish_deletion_item(
        owner_id=owner, operation_uuid=op, uuid_id=uuid_id, **kwargs
    )


@pytest.mark.parametrize(
    "outcome, stored",
    [
        ({"status": "deleted", "tombstone_revision": 42},
         ("deleted", None, 42, "[]")),
        ({"status": "deleted", "tombstone_revision": 42,
          "details": ("master_missing", "storage_cleanup_pending")},
         ("deleted", None, 42, '["master_missing", "storage_cleanup_pending"]')),
        ({"status": "already_deleted", "tombstone_revision": 7},
         ("already_deleted", None, 7, "[]")),
        ({"status": "conflict", "error_code": "conflict"}, ("conflict", "conflict", None, "[]")),
        ({"status": "busy", "error_code": "busy"}, ("busy", "busy", None, "[]")),
        ({"status": "failed", "error_code": "path_rejected"},
         ("failed", "path_rejected", None, "[]")),
    ],
)
def test_an_outcome_is_written_for_the_running_item(db, outcome, stored):
    _job(db, db.owner_id, OP1, (A, 1))
    db.claim_next_deletion_item(boot_id=BOOT)

    assert _finish(db, db.owner_id, OP1, A, **outcome) is True

    status, code, revision, detail = _items(db)[0][3], *_items(db)[0][5:8]
    assert (status, code, revision) == stored[:3]
    assert json.loads(detail) == json.loads(stored[3])


def test_an_outcome_needs_this_boot_ids_running_item(db):
    _job(db, db.owner_id, OP1, (A, 1), (B, 2))
    db.claim_next_deletion_item(boot_id="old-boot")

    # Another boot's lease, and a pending item, are both refused untouched.
    assert _finish(db, db.owner_id, OP1, A, status="busy", error_code="busy") is False
    assert _finish(db, db.owner_id, OP1, B, status="busy", error_code="busy") is False
    assert [r[3] for r in _items(db)] == ["running", "pending"]


def test_a_terminal_outcome_is_immutable(db):
    _job(db, db.owner_id, OP1, (A, 1))
    db.claim_next_deletion_item(boot_id=BOOT)
    assert _finish(db, db.owner_id, OP1, A, status="deleted", tombstone_revision=5)

    assert _finish(db, db.owner_id, OP1, A, status="conflict", error_code="conflict") is False
    assert _items(db)[0][3] == "deleted" and _items(db)[0][6] == 5


def test_an_outcome_names_its_owner(db, sam_id):
    # Two owners may hold the same operation uuid and the same target uuid.
    _job(db, db.owner_id, OP1, (A, 1))
    _job(db, sam_id, OP1, (A, 1))
    db.claim_next_deletion_item(boot_id=BOOT)
    db.claim_next_deletion_item(boot_id=BOOT)

    assert _finish(db, sam_id, OP1, A, status="busy", error_code="busy")

    assert [(r[0], r[3]) for r in _items(db)] == [(db.owner_id, "running"), (sam_id, "busy")]


def test_the_job_completes_when_its_last_item_ends(db):
    _job(db, db.owner_id, OP1, (A, 1), (B, 2))
    db.claim_next_deletion_item(boot_id=BOOT)
    db.claim_next_deletion_item(boot_id=BOOT)

    _finish(db, db.owner_id, OP1, A, status="deleted", tombstone_revision=3)
    assert _rows(db, "SELECT status FROM deletion_jobs") == [("accepted",)]

    _finish(db, db.owner_id, OP1, B, status="conflict", error_code="conflict")
    assert _rows(db, "SELECT status FROM deletion_jobs") == [("completed",)]


def test_an_unknown_detail_code_is_refused_before_any_write(db):
    _job(db, db.owner_id, OP1, (A, 1))
    db.claim_next_deletion_item(boot_id=BOOT)

    with pytest.raises(ValueError):
        _finish(db, db.owner_id, OP1, A, status="deleted", tombstone_revision=3,
                details=("/music/owner/a.flac",))

    assert _items(db)[0][3] == "running"
