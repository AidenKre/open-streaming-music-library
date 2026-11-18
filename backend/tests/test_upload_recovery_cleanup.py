"""7A.3c S4 (spec §6 step 6 and restart rules, D38, 7A.3b hand-over; 7-U07):
the startup step finishes what a finished commit journal left behind.

- ``imported``: clean-up only. The staged source goes (its quota row is
  released in the transaction that clears the item's path), a leftover work
  name goes (its ``upload_work`` row released), then the journal row is
  deleted (the receipt stays). The track and its master are never touched.
- ``duplicate_conflict`` / ``failed``: the work file goes (row released), the
  final file goes only when the journal says this operation placed it and no
  track of any owner names it, art this operation created is released through
  ``release_if_unreferenced`` (shared art survives), the insert is never
  retried, and the staged source is kept for the retained review.
- A removal that fails keeps the row (and its counted reservation) for the next
  pass; nothing outside the operation's own paths is ever removed."""

import os

import pytest

from app.services.upload_publish import SimulatedCrash
from app.services.upload_receipt import ReceiptFiles
from tests.identity_worker_fixtures import add_track, make_db, sql
from tests.owned_database import add_test_user
from tests.upload_commit_fixtures import journal, reservations
from tests.upload_publish_fixtures import RecordingSeam, library_track, track_row
from tests.upload_recovery_fixtures import World, art_ids
from tests.upload_validation_fixtures import item_row, stage_item


@pytest.fixture
def db(tmp_path):
    return make_db(tmp_path)


@pytest.fixture
def music(tmp_path):
    path = tmp_path / "music"
    (path / ".uploads").mkdir(parents=True)
    return path


@pytest.fixture
def world(db, music):
    return World(db, music)


def journal_rows(db, commit) -> list:
    return sql(db, "SELECT state FROM upload_commit_journal WHERE owner_id = ? AND operation_uuid = ?",
               (commit["owner_id"], commit["op"]))


def purposes(db, commit) -> list[str]:
    return [r["purpose"] for r in reservations(db, commit["owner_id"])]


def receipt_rows(db, commit) -> list:
    return sql(db, "SELECT kind FROM operation_receipts WHERE owner_id = ? AND operation_uuid = ?",
               (commit["owner_id"], commit["op"]))


def add_work_row(db, commit, nbytes=7):
    sql(db, "INSERT INTO storage_reservations (owner_id, purpose, subject_ref, bytes, lease_boot_id,"
            " created_at) VALUES (?, 'upload_work', ?, ?, NULL, 0)", (commit["owner_id"], commit["op"], nbytes))


@pytest.fixture
def bystanders(db, music):
    """Things recovery must never touch: another user's staged item and an
    unrelated file in the library."""
    other = add_test_user(db, "bystander")
    staged = stage_item(db, music / ".uploads", owner_id=other, state="review_ready", content=b"theirs")
    loose = music / "loose.txt"
    loose.write_bytes(b"not ours")
    return staged, loose


def assert_bystanders_untouched(bystanders):
    staged, loose = bystanders
    assert staged["source"].read_bytes() == b"theirs"
    assert loose.read_bytes() == b"not ours"


# ── imported: clean-up only ────────────────────────────────────────────────

def assert_imported_and_clean(world, commit, final):
    db = world.db
    assert item_row(db, commit)["state"] == "imported"
    assert track_row(db, commit["track"])["file_path"] == final
    assert open(final, "rb").read() == commit["content"]
    assert not commit["source"].exists()
    assert not commit["work"].exists()
    assert item_row(db, commit)["source_path"] is None
    assert purposes(db, commit) == []
    assert journal_rows(db, commit) == []
    assert receipt_rows(db, commit) == [{"kind": "upload_commit"}]  # receipts are never pruned


@pytest.mark.parametrize("point", ["after_insert_commit", "after_source_removed"])
def test_a_crash_after_the_insert_is_cleaned_up_only(world, bystanders, point):
    commit = world.crash_at(point)
    final = journal(world.db, commit)["final_path"]

    world.recover()

    assert_imported_and_clean(world, commit, final)
    assert_bystanders_untouched(bystanders)


def test_a_finished_import_loses_its_journal_row_once_clean(world):
    commit = world.commit()
    assert world.worker().process_one() == "imported"
    final = track_row(world.db, commit["track"])["file_path"]
    assert journal_rows(world.db, commit) == [{"state": "imported"}]  # 7A.3b keeps it

    world.recover()

    assert_imported_and_clean(world, commit, final)


def test_a_leftover_work_link_of_an_import_goes_but_the_master_stays(world):
    commit = world.commit()
    world.worker().process_one()
    final = track_row(world.db, commit["track"])["file_path"]
    os.link(final, commit["work"])  # an unlink that failed at step 4
    add_work_row(world.db, commit)

    world.recover()

    assert_imported_and_clean(world, commit, final)


def test_an_import_whose_source_cannot_be_removed_keeps_its_row_until_a_later_pass(world, monkeypatch):
    commit = world.crash_at("after_insert_commit")
    final = journal(world.db, commit)["final_path"]
    real = ReceiptFiles.remove

    def refuse(self, path):
        raise PermissionError("busy")

    monkeypatch.setattr(ReceiptFiles, "remove", refuse)
    world.recover()

    assert commit["source"].exists()
    assert item_row(world.db, commit)["source_path"] == str(commit["source"])
    assert "upload_source" in purposes(world.db, commit)  # still counted
    assert journal_rows(world.db, commit) == [{"state": "imported"}]

    monkeypatch.setattr(ReceiptFiles, "remove", real)
    world.recover()

    assert_imported_and_clean(world, commit, final)


def test_an_import_never_removes_a_source_its_item_no_longer_records(world):
    """The item's recorded path (state imported) is the proof; a journal path
    the item does not record is not ours to remove."""
    commit = world.crash_at("after_insert_commit")
    sql(world.db, "UPDATE upload_items SET source_path = NULL WHERE owner_id = ? AND item_uuid = ?",
        (commit["owner_id"], commit["item_uuid"]))

    world.recover()

    assert commit["source"].exists()


def test_an_import_journal_pointing_outside_the_owners_stage_removes_nothing(world, bystanders):
    staged, _ = bystanders
    commit = world.crash_at("after_insert_commit")
    for column in ("source_path", "work_path"):
        sql(world.db, f"UPDATE upload_commit_journal SET {column} = ? WHERE owner_id = ? AND operation_uuid = ?",
            (str(staged["source"]), commit["owner_id"], commit["op"]))
    sql(world.db, "UPDATE upload_items SET source_path = ? WHERE owner_id = ? AND item_uuid = ?",
        (str(staged["source"]), commit["owner_id"], commit["item_uuid"]))

    world.recover()

    assert_bystanders_untouched(bystanders)


# ── duplicate_conflict ─────────────────────────────────────────────────────

def _conflict_commit(world):
    """A commit whose preflight finds an unacknowledged exact match."""
    winner = library_track(world.db, world.music, b"audio-A")
    return world.commit(), winner


def assert_conflict_clean(world, commit):
    db = world.db
    item = item_row(db, commit)
    assert item["state"] == "duplicate_conflict"
    assert commit["source"].read_bytes() == commit["content"]  # retained review
    assert item["source_path"] == str(commit["source"])
    assert not commit["work"].exists()
    assert purposes(db, commit) == ["upload_source"]
    assert journal_rows(db, commit) == []
    assert track_row(db, commit["track"]) is None  # the insert is never retried


@pytest.mark.parametrize("point", ["after_conflict_journal", "after_conflict_cleanup"])
def test_a_crash_inside_the_preflight_conflict_clean_up_is_finished(world, bystanders, point):
    commit, _ = _conflict_commit(world)
    world.crash_at(point, commit)
    assert journal(world.db, commit)["cover_art_created"] == 1

    world.recover()
    world.recover()

    assert_conflict_clean(world, commit)
    assert art_ids(world.db) == []  # created, unreferenced: released
    assert_bystanders_untouched(bystanders)


def _placed_conflict(world, commit):
    """A duplicate_conflict journal from the insert transaction: final file placed, kept in the journal."""
    world.crash_at("after_work_unlink", commit)
    row = journal(world.db, commit)
    sql(world.db, "UPDATE upload_commit_journal SET state = 'duplicate_conflict'"
                  " WHERE owner_id = ? AND operation_uuid = ?", (commit["owner_id"], commit["op"]))
    sql(world.db, "UPDATE upload_items SET state = 'duplicate_conflict', conflict_track_uuids = '[]'"
                  " WHERE owner_id = ? AND item_uuid = ?", (commit["owner_id"], commit["item_uuid"]))
    return row["final_path"]


def test_a_conflict_that_placed_its_final_file_removes_it_and_its_empty_folders(world):
    commit = world.commit()
    final = _placed_conflict(world, commit)
    assert os.path.isfile(final)

    world.recover()

    assert not os.path.lexists(final)
    assert not os.path.exists(os.path.dirname(final))  # empty album/artist folders pruned
    assert_conflict_clean(world, commit)


def test_a_placed_final_file_that_a_track_names_is_never_removed(world):
    commit = world.commit()
    final = _placed_conflict(world, commit)
    other = add_test_user(world.db, "other-owner")
    add_track(world.db, final, owner_id=other)

    world.recover()

    assert os.path.isfile(final)
    assert not commit["work"].exists()


def test_shared_art_survives_the_conflict_clean_up(world):
    commit, winner = _conflict_commit(world)
    world.crash_at("after_conflict_journal", commit)
    art = journal(world.db, commit)["cover_art_id"]
    sql(world.db, "UPDATE trackmetadata SET cover_art_id = ? WHERE uuid_id = ?", (art, winner))

    world.recover()

    assert art in art_ids(world.db)
    assert_conflict_clean(world, commit)


# ── failed ─────────────────────────────────────────────────────────────────

def _collision(world, commit):
    """A crash right after the failure journal of a final-path collision."""
    world.crash_at("before_link", commit)
    final = journal(world.db, commit)["final_path"]
    os.makedirs(os.path.dirname(final), exist_ok=True)
    with open(final, "wb") as f:
        f.write(b"someone else's file")
    seam = RecordingSeam(crash_at="after_failure_journal")
    with pytest.raises(SimulatedCrash):
        world.publisher(seam)(journal(world.db, commit))
    return final


def test_a_crash_after_a_failure_journal_is_cleaned_and_the_unrelated_file_kept(world, bystanders):
    commit = world.commit()
    final = _collision(world, commit)
    assert journal(world.db, commit)["state"] == "failed"
    assert commit["work"].exists() and "upload_work" in purposes(world.db, commit)

    world.recover()
    world.recover()

    assert open(final, "rb").read() == b"someone else's file"
    assert not commit["work"].exists()
    assert purposes(world.db, commit) == ["upload_source"]
    assert art_ids(world.db) == []  # 7A.3a review #4b: created art released
    assert journal_rows(world.db, commit) == []
    item = item_row(world.db, commit)
    assert item["state"] == "review_ready" and item["source_path"] == str(commit["source"])
    assert commit["source"].exists()
    assert_bystanders_untouched(bystanders)


def test_a_failed_work_copy_that_cannot_be_removed_stays_counted(world, monkeypatch):
    commit = world.commit()
    _collision(world, commit)
    monkeypatch.setattr(ReceiptFiles, "remove", lambda self, path: (_ for _ in ()).throw(OSError("busy")))

    world.recover()

    assert commit["work"].exists()
    assert "upload_work" in purposes(world.db, commit)
    assert journal_rows(world.db, commit) == [{"state": "failed"}]


def test_a_failure_before_prepared_with_a_kept_work_copy_is_cleaned(world):
    """7A.3a review #4a: fail_upload_commit kept the work copy's durable row."""
    commit = world.crash_at("after_work_fsync")
    sql(world.db, "UPDATE upload_commit_journal SET state = 'failed', lease_boot_id = NULL"
                  " WHERE owner_id = ? AND operation_uuid = ?", (commit["owner_id"], commit["op"]))
    sql(world.db, "UPDATE upload_items SET state = 'review_ready', lease_boot_id = NULL"
                  " WHERE owner_id = ? AND item_uuid = ?", (commit["owner_id"], commit["item_uuid"]))
    sql(world.db, "DELETE FROM storage_reservations WHERE owner_id = ? AND purpose <> 'upload_source'",
        (commit["owner_id"],))
    add_work_row(world.db, commit)

    world.recover()

    assert not commit["work"].exists()
    assert purposes(world.db, commit) == ["upload_source"]
    assert journal_rows(world.db, commit) == []
    assert commit["source"].exists()
