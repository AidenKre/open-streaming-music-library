"""Phase 8A.3d S2 (spec §5 "Startup recovery before serving consumers", cases
1, 4 and the master_missing note; review 8-U06, 8-D09): the "deletion journal"
startup step, the cases that touch no file.

- Journal + own live track at the journaled revision and path + the original
  intact + nothing in quarantine: an ordinary pre-rename crash. The journal is
  cleared (the track is live again) and the revision is unchanged; the item is
  left for the reclaim step, which requeues it.
- A journal of a planned catalog-only deletion (``master_missing``): cleared,
  requeued with revalidation.
- Journal + no matching live row (gone, tombstoned, another revision or path):
  ambiguous. The journal is kept (the track stays hidden), a running item is
  ``failed:recovery_required``, and no file is touched.
- Committed journals are not this step's (the janitor's); a terminal item's
  outcome is never rewritten; a row whose check raises is kept untouched and
  the other rows are still resolved; a track lock held elsewhere skips the row.
- Running twice changes nothing more.

Recovery runs on a fresh ``Database`` over the same file (an independent
connection, like a restarted process).
"""

import os

import pytest

from app.database.database import Database
from app.services import deletion_recovery
from app.services.track_locks import TrackLocks
from tests.deletion_recovery_helpers import (
    NEW_BOOT,
    crashed_at,
    disk,
    recover,
    restarted_db,
    run_until_crash,
)
from tests.deletion_world import (
    accept_job,
    add_master,
    build_world,
    drain,
    item,
    journal,
    live,
    make_executor,
    path_of,
    revision,
    sql,
    tombstone,
)


@pytest.fixture
def world(tmp_path):
    return build_world(tmp_path)


def crashed_after_journal(world, rel="Portishead/Dummy/01 Mysterons.flac", **kwargs):
    uuid_id, rev, op = crashed_at(world, "after_journal", rel, **kwargs)
    assert journal(world, uuid_id)["stage"] == "intent" and not live(world, uuid_id)
    return uuid_id, rev, op


# ── case 1: pre-rename crash ────────────────────────────────────────────────


def test_a_crash_before_the_rename_clears_the_journal_and_keeps_the_revision(world):
    uuid_id, rev, op = crashed_after_journal(world)
    master = path_of(world, uuid_id)
    before = disk(world)

    recover(world)

    assert journal(world, uuid_id) is None
    assert live(world, uuid_id) and revision(world, uuid_id) == rev
    assert disk(world) == before and master.exists()
    assert tombstone(world, uuid_id) is None
    # Left for the reclaim step (it has no journal now).
    assert item(world, op, uuid_id)["status"] == "running"


def test_after_reclaim_the_cleared_item_is_deleted_by_the_next_worker_run(world):
    uuid_id, rev, op = crashed_after_journal(world)
    master = path_of(world, uuid_id)
    recover(world)
    deletion_recovery.reclaim_deletion_items(restarted_db(world), boot_id=NEW_BOOT)
    assert item(world, op, uuid_id)["status"] == "pending"

    assert drain(make_executor(world, boot_id=NEW_BOOT)) == 1

    assert item(world, op, uuid_id)["status"] == "deleted"
    assert not master.exists() and tombstone(world, uuid_id) is not None


def test_recovering_twice_changes_nothing_more(world):
    uuid_id, rev, op = crashed_after_journal(world)
    recover(world)
    first = (journal(world, uuid_id), item(world, op, uuid_id), revision(world, uuid_id), disk(world))

    recover(world)

    assert (journal(world, uuid_id), item(world, op, uuid_id), revision(world, uuid_id), disk(world)) == first


def test_a_planned_catalog_only_deletion_is_cleared_for_revalidation(world):
    uuid_id, rev, op = crashed_after_journal(world, create_file=False)
    assert journal(world, uuid_id)["master_missing"] == 1

    recover(world)

    assert journal(world, uuid_id) is None
    assert live(world, uuid_id) and revision(world, uuid_id) == rev
    assert item(world, op, uuid_id)["status"] == "running"


# ── case 4: ambiguous, never guessed ────────────────────────────────────────


def _assert_kept(world, uuid_id, op, before_disk, journal_before):
    assert journal(world, uuid_id) == journal_before
    assert not live(world, uuid_id)
    assert disk(world) == before_disk
    after = item(world, op, uuid_id)
    assert (after["status"], after["error"]) == ("failed", "recovery_required")
    assert sql(world, "SELECT status FROM deletion_jobs WHERE operation_uuid = ?", (op,)) == [
        ("completed",)
    ]


def test_a_journal_whose_track_row_is_gone_is_kept_and_reported(world):
    uuid_id, rev, op = crashed_after_journal(world)
    sql(world, "DELETE FROM trackmetadata WHERE uuid_id = ?", (uuid_id,))
    sql(world, "DELETE FROM tracks WHERE uuid_id = ?", (uuid_id,))
    before, kept = disk(world), journal(world, uuid_id)

    recover(world)

    _assert_kept(world, uuid_id, op, before, kept)


def test_a_journal_whose_track_has_another_revision_is_kept(world):
    uuid_id, rev, op = crashed_after_journal(world)
    sql(world, "UPDATE tracks SET revision = revision + 5 WHERE uuid_id = ?", (uuid_id,))
    before, kept = disk(world), journal(world, uuid_id)

    recover(world)

    _assert_kept(world, uuid_id, op, before, kept)


def test_a_journal_whose_track_points_at_another_path_is_kept(world):
    uuid_id, rev, op = crashed_after_journal(world)
    other = world.root(world.owner) / "Elsewhere" / "x.flac"
    sql(world, "UPDATE tracks SET file_path = ? WHERE uuid_id = ?", (str(other), uuid_id))
    before, kept = disk(world), journal(world, uuid_id)

    recover(world)

    _assert_kept(world, uuid_id, op, before, kept)


def test_a_journal_without_commit_evidence_but_with_a_tombstone_is_kept(world):
    uuid_id, rev, op = crashed_after_journal(world)
    sql(world, "DELETE FROM trackmetadata WHERE uuid_id = ?", (uuid_id,))
    sql(world, "DELETE FROM tracks WHERE uuid_id = ?", (uuid_id,))
    sql(
        world,
        "INSERT INTO track_tombstones (uuid_id, deleted_at, revision, owner_id) VALUES (?, 1, ?, ?)",
        (uuid_id, rev + 1, world.owner),
    )
    before, kept = disk(world), journal(world, uuid_id)

    recover(world)

    _assert_kept(world, uuid_id, op, before, kept)


def test_an_ambiguous_journal_stays_put_on_a_second_restart(world):
    uuid_id, rev, op = crashed_after_journal(world)
    sql(world, "UPDATE tracks SET revision = revision + 5 WHERE uuid_id = ?", (uuid_id,))
    recover(world)
    first = (journal(world, uuid_id), item(world, op, uuid_id), disk(world))

    recover(world)

    assert (journal(world, uuid_id), item(world, op, uuid_id), disk(world)) == first


def test_a_journal_of_a_user_being_deleted_is_left_for_users_delete(world):
    uuid_id, rev, op = crashed_after_journal(world)
    sql(world, "UPDATE users SET deleting_at = 1 WHERE id = ?", (world.owner,))
    before, kept, item_before = disk(world), journal(world, uuid_id), item(world, op, uuid_id)

    recover(world)

    assert journal(world, uuid_id) == kept and disk(world) == before
    # Review r1 #1: never left running (no stuck job); the journal stays.
    assert item_before["status"] == "running"
    assert (item(world, op, uuid_id)["status"], item(world, op, uuid_id)["error"]) == (
        "failed", "recovery_required")


# ── what this step leaves alone ─────────────────────────────────────────────


def test_a_committed_journal_is_left_to_the_janitor(world):
    uuid_id = add_master(world, "A/a.flac")
    op = accept_job(world, (uuid_id, revision(world, uuid_id)))
    run_until_crash(world, "after_commit")
    before, kept, item_before = disk(world), journal(world, uuid_id), item(world, op, uuid_id)
    assert kept["stage"] == "committed"

    recover(world)

    assert journal(world, uuid_id) == kept and disk(world) == before
    assert item(world, op, uuid_id) == item_before


def test_a_terminal_item_keeps_its_outcome_when_its_journal_is_resolved(world):
    uuid_id, rev, op = crashed_after_journal(world)
    sql(
        world,
        "UPDATE deletion_job_items SET status = 'failed', error_code = 'recovery_required'"
        " WHERE operation_uuid = ?",
        (op,),
    )
    item_before = item(world, op, uuid_id)

    recover(world)

    assert journal(world, uuid_id) is None and live(world, uuid_id)
    assert item(world, op, uuid_id) == item_before


def test_a_row_whose_check_raises_is_kept_and_the_others_are_still_resolved(world, monkeypatch):
    bad, _, bad_op = crashed_after_journal(world, "A/bad.flac")
    good, good_rev, _ = crashed_after_journal(world, "A/good.flac")
    database = restarted_db(world)
    real = Database.read_deletion_target

    def flaky(self, uuid_id, *, owner_id):
        if uuid_id == bad:
            raise OSError("database is locked")
        return real(self, uuid_id, owner_id=owner_id)

    monkeypatch.setattr(Database, "read_deletion_target", flaky)
    before_bad, bad_item = journal(world, bad), item(world, bad_op, bad)

    recover(world, database=database)

    # An exception is no verdict: the journal and the file stay. Review r1 #1:
    # the item is not left running for ever (the journal is re-evaluated at
    # every later start).
    assert bad_item["status"] == "running"
    assert journal(world, bad) == before_bad
    assert (item(world, bad_op, bad)["status"], item(world, bad_op, bad)["error"]) == (
        "failed", "recovery_required")
    assert path_of(world, bad).exists()
    assert journal(world, good) is None and revision(world, good) == good_rev


def test_a_track_lock_held_elsewhere_skips_the_row(world):
    uuid_id, rev, op = crashed_after_journal(world)
    locks = TrackLocks()
    lock = locks.lock_for(uuid_id)
    assert lock.acquire(timeout=0)
    kept, item_before = journal(world, uuid_id), item(world, op, uuid_id)
    try:
        recover(world, locks=locks)
    finally:
        lock.release()

    assert journal(world, uuid_id) == kept
    # Review r1 #1: a skipped row's item is not left running either.
    assert item_before["status"] == "running"
    assert item(world, op, uuid_id)["error"] == "recovery_required"


def test_items_of_other_journals_are_marked_under_their_own_owner(world):
    mine, _, op_me = crashed_after_journal(world, "A/a.flac")
    theirs = add_master(world, "A/a.flac", owner=world.sam)
    op_sam = accept_job(world, (theirs, revision(world, theirs)), owner=world.sam)
    run_until_crash(world, "after_journal")
    sql(world, "UPDATE tracks SET revision = revision + 5 WHERE uuid_id = ?", (theirs,))

    recover(world)

    assert journal(world, mine) is None  # resolved
    assert journal(world, theirs) is not None  # ambiguous: kept
    assert item(world, op_sam, theirs, owner=world.sam)["error"] == "recovery_required"
    assert item(world, op_me, mine)["status"] == "running"
    assert os.path.exists(path_of(world, theirs))
