"""Phase 7A.2b S2: received upload bytes in the SC-16g ledger (7A.2a open point).

While a file is being received, its reservation holds the expected bytes
against free space and the staged quotas (purpose ``upload_receive``, leased by
this boot). Once the file is fully received its bytes are on disk: the row is
*settled* into an on-disk purpose (``upload_source``) with no lease. It keeps
counting toward the per-user and server-wide staged quotas, across restarts,
but no longer against free space, because the filesystem's free count already
excludes those bytes.
"""

import pytest

from app.services.storage_ledger import (
    CONVERSION,
    UPLOAD_RECEIVE,
    UPLOAD_SOURCE,
    InsufficientStorage,
    StagedQuota,
    StorageLedger,
    register_purpose,
)
from tests.test_storage_ledger import FakeDisk, _rows, library_dir  # noqa: F401  (fixtures)

BOOT = "boot-current"
QUOTA = StagedQuota(user_bytes=1000, total_bytes=1000)


def _ledger(db, library_dir, free, *, floor=100, boot_id=BOOT):
    return StorageLedger(
        db, path=library_dir, floor_bytes=floor, boot_id=boot_id, disk_usage=FakeDisk(free)
    )


def _receive(ledger, db, nbytes, subject="item-1"):
    return ledger.reserve(
        owner_id=db.owner_id, purpose=UPLOAD_RECEIVE, nbytes=nbytes, subject_ref=subject, quota=QUOTA
    )


def test_a_reservation_being_received_counts_against_free_space_and_the_quota(db, library_dir):
    ledger = _ledger(db, library_dir, free=1000)
    _receive(ledger, db, 800)

    # 1000 free - 800 held - 100 floor = 100 left on disk.
    with pytest.raises(InsufficientStorage) as refused:
        ledger.reserve(owner_id=db.owner_id, purpose=CONVERSION, nbytes=101, subject_ref="7")
    assert (refused.value.code, refused.value.available) == ("insufficient_storage", 100)
    # ...and 1000 - 800 = 200 of my staged quota.
    with pytest.raises(InsufficientStorage) as refused:
        _receive(ledger, db, 201, subject="item-2")
    assert (refused.value.code, refused.value.available) == ("user_staged_quota_exceeded", 200)


def test_a_settled_row_is_a_durable_on_disk_row_of_the_same_size(db, library_dir):
    ledger = _ledger(db, library_dir, free=1000)
    rid = _receive(ledger, db, 800)

    assert ledger.settle(rid, purpose=UPLOAD_SOURCE) is True

    [row] = _rows(db)
    assert row[:6] == (rid, db.owner_id, UPLOAD_SOURCE, "item-1", 800, None)


def test_settled_bytes_keep_counting_toward_the_quota_but_not_against_free_space(db, library_dir):
    ledger = _ledger(db, library_dir, free=1000)
    rid = _receive(ledger, db, 800)
    ledger.settle(rid, purpose=UPLOAD_SOURCE)

    # Free space: the 800 bytes are already off the disk's free count, so they
    # are not subtracted again: of 1000 - 100 floor = 900, a 700-byte conversion
    # fits (it would not if the settled 800 still counted: 1000 - 800 - 100 = 100).
    ledger.reserve(owner_id=db.owner_id, purpose=CONVERSION, nbytes=700, subject_ref="7")
    # Quota: still 800 of my 1000 are staged.
    with pytest.raises(InsufficientStorage) as refused:
        _receive(ledger, db, 201, subject="item-2")
    assert (refused.value.code, refused.value.available, refused.value.limit) == (
        "user_staged_quota_exceeded", 200, 1000,
    )
    _receive(ledger, db, 200, subject="item-2")


def test_a_settled_row_survives_the_restart_reconcile(db, library_dir):
    rid = _receive(_ledger(db, library_dir, free=1000, boot_id="boot-old"), db, 800)
    _ledger(db, library_dir, free=1000, boot_id="boot-old").settle(rid, purpose=UPLOAD_SOURCE)
    _receive(_ledger(db, library_dir, free=10_000, boot_id="boot-old"), db, 50, subject="item-2")

    released = _ledger(db, library_dir, free=1000, boot_id="boot-new").reconcile()

    # The in-flight row of the dead boot goes; the received file's row stays.
    assert released == 1
    assert [(r[2], r[3], r[5]) for r in _rows(db)] == [(UPLOAD_SOURCE, "item-1", None)]


def test_settling_happens_once_and_an_unknown_id_settles_nothing(db, library_dir):
    ledger = _ledger(db, library_dir, free=1000)
    rid = _receive(ledger, db, 800)

    assert ledger.settle(rid, purpose=UPLOAD_SOURCE) is True
    assert ledger.settle(rid, purpose=UPLOAD_SOURCE) is False
    assert ledger.settle(rid + 1000, purpose=UPLOAD_SOURCE) is False
    assert len(_rows(db)) == 1


def test_a_settled_row_is_released_like_any_other(db, library_dir):
    ledger = _ledger(db, library_dir, free=1000)
    rid = _receive(ledger, db, 800)
    ledger.settle(rid, purpose=UPLOAD_SOURCE)

    assert ledger.release(rid) is True
    assert _rows(db) == []


@pytest.mark.parametrize("purpose", [UPLOAD_RECEIVE, CONVERSION, "never_registered"])
def test_only_an_on_disk_purpose_can_be_settled_into(db, library_dir, purpose):
    ledger = _ledger(db, library_dir, free=1000)
    rid = _receive(ledger, db, 800)

    with pytest.raises(ValueError):
        ledger.settle(rid, purpose=purpose)
    [row] = _rows(db)
    assert (row[2], row[5]) == (UPLOAD_RECEIVE, BOOT)


def test_the_on_disk_flag_is_part_of_a_purpose_registration():
    register_purpose("test_on_disk", staged_quota=True, on_disk=True)
    register_purpose("test_on_disk", staged_quota=True, on_disk=True)  # identical: fine
    with pytest.raises(ValueError):
        register_purpose("test_on_disk", staged_quota=True, on_disk=False)
    with pytest.raises(ValueError):
        register_purpose("test_on_disk_flag", staged_quota=True, on_disk="yes")
