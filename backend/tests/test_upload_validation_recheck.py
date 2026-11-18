"""7A.2c review r1 re-check regressions (7A.2c-review.md "Re-check r1": RC1–RC6)."""

import os
from pathlib import Path

import pytest

from app.services.storage_ledger import UPLOAD_SOURCE
from app.services.upload_errors import probe_timeout
from app.services.upload_receipt import reconcile_upload_receipts
from app.services.upload_validation import ValidationFailed
from tests.identity_worker_fixtures import sql
from tests.owned_database import add_test_user
from tests.upload_validation_fixtures import (
    BOOT,
    DEAD_BOOT,
    FakeProbe,
    item_row,
    make_worker,
    source_rows,
    stage_item,
)

BATCH, ITEM = "c3000000-0000-4000-8000-000000000001", "c3000000-0000-4000-8000-000000000002"


@pytest.fixture
def env(app_client):
    db = app_client.app.state.database
    root = app_client.app.state.upload_receipt.uploads_root
    root.mkdir(parents=True, exist_ok=True)
    return app_client, db, root, app_client.app.state.admin_user_id


@pytest.fixture
def db_env(tmp_path):
    """``env`` without the app, for the cases that make no HTTP call: a plain
    ``Database`` (as the app uses) with one real user and an uploads folder."""
    from app.database.database import Database, DatabaseContext
    from tests.identity_worker_fixtures import INIT_SQL

    db = Database(DatabaseContext(database_path=tmp_path / "db.sqlite", init_sql_path=INIT_SQL))
    assert db.initialize()
    root = tmp_path / "music" / ".uploads"
    root.mkdir(parents=True)
    return None, db, root, add_test_user(db, "alice")


# RC1: the startup reconcile builds each row's path with that row's own owner.
def test_a_dead_receipt_of_one_user_never_touches_the_others_file_at_startup(db_env):
    _, db, root, alice = db_env
    sam = add_test_user(db, "sam")
    mine = stage_item(db, root, owner_id=alice, batch_uuid=BATCH, item_uuid=ITEM, content=b"alice")
    make_worker(db, root).process_one()
    # Sam's dead transfer of the same ids, with other expected bytes and no file of its own.
    sql(db, "INSERT INTO upload_batches (owner_id, batch_uuid, created_at, updated_at) VALUES (?, ?, 1, 1)",
        (sam, BATCH))
    sql(db, "INSERT INTO upload_items (owner_id, item_uuid, batch_uuid, filename, selection_index, "
            "expected_bytes, expected_sha256, state, lease_boot_id, created_at, updated_at, progress_at) "
            "VALUES (?, ?, ?, 'x.flac', 0, 5, ?, 'receiving', ?, 1, 1, 1)",
        (sam, ITEM, BATCH, "ee" * 32, DEAD_BOOT))

    reconcile_upload_receipts(db, root, boot_id=BOOT)

    assert mine["source"].read_bytes() == b"alice"
    assert item_row(db, mine)["state"] == "review_ready"
    assert sql(db, "SELECT state FROM upload_items WHERE owner_id = ?", (sam,)) == [{"state": "allocated"}]


# RC2: a step that keeps failing backs off instead of spinning.
def test_after_an_error_the_loop_waits_its_poll_before_the_next_step(db_env):
    _, db, root, _ = db_env
    worker = make_worker(db, root, idle_poll_s=123)
    waits = []

    class Wake:
        def wait(self, timeout=None):
            waits.append(timeout)
            worker.request_stop()
            return False

        def set(self):
            pass

        def clear(self):
            pass

    steps = []

    def failing_step():
        steps.append(1)
        if len(steps) > 3:  # bounded: a loop that never waits fails, never hangs
            worker.request_stop()
        return "error"

    worker._wake = Wake()
    worker.process_one = failing_step

    worker._run_loop()

    assert waits == [123]


# RC3: an item whose failure write raised is given back to the queue.
def test_an_item_whose_failure_could_not_be_recorded_is_requeued(db_env, monkeypatch):
    _, db, root, alice = db_env
    staged = stage_item(db, root, owner_id=alice)

    def broken(**kwargs):
        raise OSError("disk I/O error")

    monkeypatch.setattr(db, "fail_upload_validation", broken)
    outcome = make_worker(db, root, probe=FakeProbe(ValidationFailed(probe_timeout()))).process_one()

    row = item_row(db, staged)
    assert (outcome, row["state"], row["lease_boot_id"]) == ("error", "validating", None)


# RC4: a cancelled item's file that cannot be inspected stays counted.
def test_a_cancelled_items_file_that_cannot_be_inspected_keeps_its_quota_row(db_env, monkeypatch):
    _, db, root, alice = db_env
    staged = stage_item(db, root, owner_id=alice)
    make_worker(db, root).process_one()
    sql(db, "UPDATE upload_items SET state = 'cancelled' WHERE item_uuid = ?", (staged["item_uuid"],))
    real = os.lstat
    target = str(staged["source"])

    def denied(path, *args, **kwargs):
        if os.fspath(path) == target:
            raise PermissionError(13, "denied")
        return real(path, *args, **kwargs)

    monkeypatch.setattr(os, "lstat", denied)
    reconcile_upload_receipts(db, root, boot_id=BOOT)
    monkeypatch.undo()

    assert source_rows(db, staged) == [{"purpose": UPLOAD_SOURCE, "bytes": 7}]


# RC5: a recorded path is used only inside its own owner's folder.
def _point_at_other_owners_file(db, root, alice):
    sam = add_test_user(db, "sam")
    theirs = stage_item(db, root, owner_id=sam, content=b"sams bytes")
    mine = stage_item(db, root, owner_id=alice)
    return sam, theirs, mine


def test_a_row_pointing_into_another_owners_folder_is_never_served(env):
    client, db, root, alice = env
    _, theirs, mine = _point_at_other_owners_file(db, root, alice)
    make_worker(db, root).process_one()
    make_worker(db, root).process_one()
    sql(db, "UPDATE upload_items SET source_path = ? WHERE owner_id = ? AND item_uuid = ?",
        (str(theirs["source"]), alice, mine["item_uuid"]))

    response = client.get(f"/tracks/uploads/items/{mine['item_uuid']}/preview")

    assert response.status_code == 404
    assert b"sams bytes" not in response.content


def test_a_cancel_never_removes_a_file_in_another_owners_folder(env):
    client, db, root, alice = env
    _, theirs, mine = _point_at_other_owners_file(db, root, alice)
    make_worker(db, root).process_one()
    make_worker(db, root).process_one()
    sql(db, "UPDATE upload_items SET source_path = ? WHERE owner_id = ? AND item_uuid = ?",
        (str(theirs["source"]), alice, mine["item_uuid"]))

    assert client.delete(f"/tracks/uploads/items/{mine['item_uuid']}").status_code == 200

    assert theirs["source"].read_bytes() == b"sams bytes"


def test_the_worker_never_reads_a_file_in_another_owners_folder(db_env):
    _, db, root, alice = db_env
    _, theirs, mine = _point_at_other_owners_file(db, root, alice)
    sql(db, "UPDATE upload_items SET source_path = ?, progress_at = 0 WHERE owner_id = ? AND item_uuid = ?",
        (str(theirs["source"]), alice, mine["item_uuid"]))
    probe = FakeProbe()

    make_worker(db, root, probe=probe).process_one()

    assert item_row(db, mine)["state"] == "failed"
    assert Path(theirs["source"]) not in [c["path"] for c in probe.calls]
    assert theirs["source"].read_bytes() == b"sams bytes"


def test_a_retry_never_treats_a_path_outside_its_folder_as_its_source(env, tmp_path):
    client, db, root, alice = env
    staged = stage_item(db, root, owner_id=alice)
    make_worker(db, root, probe=FakeProbe(ValidationFailed(probe_timeout()))).process_one()
    outside = tmp_path / "elsewhere.flac"
    outside.write_bytes(b"not ours")
    sql(db, "UPDATE upload_items SET source_path = ? WHERE item_uuid = ?", (str(outside), staged["item_uuid"]))

    response = client.post(f"/tracks/uploads/items/{staged['item_uuid']}/retry",
                           json={"expected_review_version": 0})

    assert response.json()["state"] == "allocated"
    assert outside.read_bytes() == b"not ours"


# RC6: the release after a failed item's removal is guarded by its state.
def test_a_cancelled_source_release_needs_the_item_to_be_cancelled(db_env):
    _, db, root, alice = db_env
    staged = stage_item(db, root, owner_id=alice)

    released = db.release_cancelled_upload_source(
        staged["item_uuid"], owner_id=alice, source_path=str(staged["source"]), now=1)

    assert released is False
    assert item_row(db, staged)["source_path"] == str(staged["source"])
    assert source_rows(db, staged) == [{"purpose": UPLOAD_SOURCE, "bytes": 7}]
