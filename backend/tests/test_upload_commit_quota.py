"""Refactor audit TR-UPLOAD-01, coordinator decision 2026-11-13 (amends
DEV-7-02 and DEV-7-13). Spec §3 (phase-7-uploads.md:62): "Global staged-byte
quota ... includes pending source files, extraction output, reserved receive
bytes, work copies and cleanup-pending files" and "Reserve/check free disk
space before transfer/extraction/commit with a configurable floor".

A commit's work copy stays counted in the staged totals (it still limits new
receipts), but the commit itself is admitted against the free-disk floor only:
it converts bytes the quota already accepted and releases the source when it
publishes. Before, a quota filled by received files refused every import."""

import pytest

from app.services.storage_ledger import (
    UPLOAD_RECEIVE, UPLOAD_SOURCE, UPLOAD_WORK_RESERVE, InsufficientStorage, StagedQuota,
)
from app.services.upload_commit import TAG_WRITE_HEADROOM_BYTES
from tests import upload_commit_fixtures
from tests.owned_database import add_test_user
from tests.upload_commit_fixtures import accept, make_commit_worker, make_ledger, ready_item, reservations
from tests.upload_publish_fixtures import make_publisher
from tests.upload_validation_fixtures import item_row

SIZE = 100


@pytest.fixture
def music(tmp_path):
    path = tmp_path / "music"
    (path / ".uploads").mkdir(parents=True)
    return path


def _quota(monkeypatch, *, user, total) -> StagedQuota:
    """The quota the commit worker is built with (``make_commit_worker`` reads it)."""
    quota = StagedQuota(user_bytes=user, total_bytes=total)
    monkeypatch.setattr(upload_commit_fixtures, "QUOTA", quota)
    return quota


def _received(db, music, n, *, owner_id=None, first=0) -> list[dict]:
    """``n`` received files of SIZE bytes each (distinct content), counted as upload_source."""
    return [ready_item(db, music / ".uploads", owner_id=owner_id, content=bytes([65 + first + i]) * SIZE)
            for i in range(n)]


def _next_receipt_refused(ledger, owner_id, quota) -> str:
    with pytest.raises(InsufficientStorage) as refused:
        ledger.check(owner_id=owner_id, purpose=UPLOAD_RECEIVE, nbytes=SIZE, quota=quota)
    return refused.value.code


def _worker(db, music, ledger):
    return make_commit_worker(db, music, ledger=ledger, after_prepared=make_publisher(db, music))


def test_a_full_user_quota_still_lets_a_received_file_be_imported(db, music, monkeypatch):
    quota = _quota(monkeypatch, user=3 * SIZE + SIZE // 2, total=10**9)
    ledger = make_ledger(db, music)
    staged = _received(db, music, 3)
    assert _next_receipt_refused(ledger, db.owner_id, quota) == "user_staged_quota_exceeded"

    commit = accept(db, staged[0])
    assert _worker(db, music, ledger).process_one() == "imported"

    assert item_row(db, commit)["state"] == "imported"
    # Published: the source and the work copy are gone, so the refused receipt now fits.
    purposes = [r["purpose"] for r in reservations(db, db.owner_id)]
    assert purposes.count(UPLOAD_SOURCE) == 2 and "upload_work" not in purposes
    ledger.check(owner_id=db.owner_id, purpose=UPLOAD_RECEIVE, nbytes=SIZE, quota=quota)


def test_two_users_who_fill_the_server_total_can_each_import(db, music, monkeypatch):
    quota = _quota(monkeypatch, user=2 * SIZE, total=4 * SIZE)
    sam = add_test_user(db, "sam")
    mine = _received(db, music, 2)
    theirs = _received(db, music, 2, owner_id=sam, first=10)
    ledger = make_ledger(db, music)
    for owner in (db.owner_id, sam):
        assert _next_receipt_refused(ledger, owner, quota) in (
            "user_staged_quota_exceeded", "staged_quota_exceeded")

    commits = [accept(db, mine[0]), accept(db, theirs[0])]
    worker = _worker(db, music, ledger)
    assert [worker.process_one(), worker.process_one()] == ["imported", "imported"]

    assert [item_row(db, c)["state"] for c in commits] == ["imported", "imported"]


def test_the_disk_floor_still_refuses_a_commit_with_its_fixed_text(db, music, monkeypatch):
    _quota(monkeypatch, user=10**9, total=10**10)
    commit = accept(db, _received(db, music, 1)[0])
    ledger = make_ledger(db, music, free=SIZE - 1)  # floor 0: one byte short of the work copy

    _worker(db, music, ledger).process_one()

    item = item_row(db, commit)
    assert (item["state"], item["error_code"], item["error_retryable"]) == (
        "review_ready", "insufficient_storage", 1)
    # DEV-7-10 / 7-R1-04: the free room moves with other users' uploads; no figure is shown.
    assert item["error_message"] and not any(ch.isdigit() for ch in item["error_message"])
    assert not commit["work"].exists()
    assert commit["source"].read_bytes() == commit["content"]


def test_the_disk_check_still_reserves_the_worst_case_tag_output(db, music, monkeypatch):
    _quota(monkeypatch, user=10**9, total=10**10)
    commit = accept(db, _received(db, music, 1)[0], edits={"title": "New"}, write_tags=True)
    ledger = make_ledger(db, music, free=SIZE + TAG_WRITE_HEADROOM_BYTES)  # short of the edits' share

    _worker(db, music, ledger).process_one()

    assert item_row(db, commit)["error_code"] == "insufficient_storage"


def test_the_work_copy_still_counts_against_new_receipts(db, music, monkeypatch):
    quota = _quota(monkeypatch, user=2 * SIZE, total=10**9)
    ledger = make_ledger(db, music)
    commit = accept(db, _received(db, music, 1)[0])
    ledger.check(owner_id=db.owner_id, purpose=UPLOAD_RECEIVE, nbytes=SIZE, quota=quota)  # fits before

    assert make_commit_worker(db, music, ledger=ledger).process_one() == "prepared"  # work copy made

    assert commit["work"].exists()
    assert {r["purpose"] for r in reservations(db, db.owner_id)} >= {UPLOAD_SOURCE}
    assert _next_receipt_refused(ledger, db.owner_id, quota) == "user_staged_quota_exceeded"


def test_only_the_commit_reservation_is_admitted_without_the_quota_check(db, music):
    """The ledger rule itself: the commit's work reservation is counted but not
    gated; every other staged purpose is still gated."""
    quota = StagedQuota(user_bytes=SIZE, total_bytes=SIZE)
    ledger = make_ledger(db, music)
    _received(db, music, 1)  # the quota is now full

    ledger.reserve(owner_id=db.owner_id, purpose=UPLOAD_WORK_RESERVE, nbytes=SIZE, quota=quota)

    assert _next_receipt_refused(ledger, db.owner_id, quota) == "user_staged_quota_exceeded"
    with pytest.raises(InsufficientStorage):
        ledger.reserve(owner_id=db.owner_id, purpose=UPLOAD_RECEIVE, nbytes=1, quota=quota)
    with pytest.raises(ValueError):  # a staged purpose still needs its quota
        ledger.reserve(owner_id=db.owner_id, purpose=UPLOAD_WORK_RESERVE, nbytes=SIZE)
