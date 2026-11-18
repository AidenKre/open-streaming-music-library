"""Pre-merge A1-02: a user left "being deleted" (``users.deleting_at`` set, the
removal not finished, for example a refused resume at start-up) gets no more
background work. The deletion worker, the conversion resume, the cover-art
backfill and the import scans already skip such a user; the upload validation
and commit claims and the identity worker's queue skip them the same way, while
another user's work is still claimed."""

from app.database import ANY_OWNER
from tests.identity_worker_fixtures import add_track, sql
from tests.owned_database import add_test_user
from tests.upload_commit_fixtures import accept, ready_item
from tests.upload_validation_fixtures import stage_item

BOOT = "this-boot"
NOW = 1_800_000_000


def _deleting(db, user_id: int) -> None:
    sql(db, "UPDATE users SET deleting_at = 5 WHERE id = ?", (user_id,))


def test_upload_validation_skips_a_user_being_deleted(db, tmp_path):
    sam, alex = add_test_user(db, "sam"), add_test_user(db, "alex")
    root = tmp_path / "uploads"
    stage_item(db, root, owner_id=sam, progress_at=1)  # the older: claimed first if allowed
    theirs = stage_item(db, root, owner_id=alex, progress_at=2)
    _deleting(db, sam)

    claimed = db.claim_upload_validation(boot_id=BOOT)

    assert (claimed["owner_id"], claimed["item_uuid"]) == (alex, theirs["item_uuid"])
    assert db.claim_upload_validation(boot_id=BOOT) is None


def test_upload_commit_skips_a_user_being_deleted(db, tmp_path):
    sam, alex = add_test_user(db, "sam"), add_test_user(db, "alex")
    root = tmp_path / "uploads"
    accept(db, ready_item(db, root, owner_id=sam), created_at=1)  # the older
    theirs = accept(db, ready_item(db, root, owner_id=alex), created_at=2)
    _deleting(db, sam)

    claimed = db.claim_upload_commit(boot_id=BOOT)

    assert (claimed["owner_id"], claimed["operation_uuid"]) == (alex, theirs["op"])
    assert db.claim_upload_commit(boot_id=BOOT) is None


def test_the_identity_queue_skips_a_user_being_deleted(db):
    sam, alex = add_test_user(db, "sam"), add_test_user(db, "alex")
    add_track(db, "/m/sam.flac", owner_id=sam, identity={"priority": 0})  # first in line if allowed
    theirs = add_track(db, "/m/alex.flac", owner_id=alex, identity={"priority": 1})
    _deleting(db, sam)

    for fingerprint in (False, True):
        assert db.next_identity_work(NOW, skip={}, owner_id=ANY_OWNER, fingerprint=fingerprint) == theirs
