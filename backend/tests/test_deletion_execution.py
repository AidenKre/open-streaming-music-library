"""Phase 8A.3c (spec §4 per-target outcomes, §5 "Per-target execution"; review
8-U03, 8-U06, 8-D02, 8-D03, 8-D06, 8-D11): one deletion target, executed by
``DeletionExecutor`` without a thread.

Revalidation first (under a bounded try-lock on the track, decision O10):
- the owner's own tombstone → ``already_deleted`` with its existing revision,
  no new revision (D9);
- an unknown uuid, another user's live track or another user's tombstone →
  ``failed:not_found``, nothing of the other user read (SC-28, 8A.2a M1);
- a revision other than the confirmed one → ``conflict``;
- an active conversion, an edit journal, an upload commit journal or another
  deletion → ``busy``;
- the track lock held elsewhere → ``busy`` without waiting.
None of these writes a journal row or touches a file.
"""

import threading

import pytest

from tests.deletion_world import (
    BOOT,
    accept_job,
    add_master,
    build_world,
    counter,
    drain,
    files_under,
    item,
    journal,
    make_executor,
    one,
    revision,
    sql,
    tombstone,
)
from tests.pending_deletion import mark_pending_deletion

UNKNOWN = "eeeeeeee-0000-4000-8000-00000000000e"


@pytest.fixture
def world(tmp_path):
    return build_world(tmp_path)


def _untouched(world, before_files, uuid_id, rev):
    assert files_under(world.music) == before_files
    assert journal(world, uuid_id) is None
    assert revision(world, uuid_id) == rev
    assert tombstone(world, uuid_id) is None


def test_nothing_pending_runs_nothing(world):
    assert make_executor(world).run_one() is False


# ── the lock (O10) ─────────────────────────────────────────────────────────


def test_a_held_track_lock_answers_busy_without_waiting(world):
    uuid_id = add_master(world, "Radiohead/OK Computer/01 Lucky.flac")
    rev = revision(world, uuid_id)
    op = accept_job(world, (uuid_id, rev))
    before = files_under(world.music)
    lock = world.locks.lock_for(uuid_id)
    assert lock.acquire()
    try:
        done = threading.Event()
        runner = threading.Thread(
            target=lambda: (make_executor(world, lock_timeout_s=0).run_one(), done.set())
        )
        runner.start()
        # Bounded: a try-lock returns at once; a blocking acquire would hang here.
        assert done.wait(30), "the executor waited for a held track lock"
        runner.join(30)
    finally:
        lock.release()

    assert item(world, op, uuid_id)["status"] == "busy"
    assert item(world, op, uuid_id)["error"] == "busy"
    _untouched(world, before, uuid_id, rev)


def test_the_lock_is_released_after_a_target(world):
    uuid_id = add_master(world, "Radiohead/OK Computer/01 Lucky.flac")
    accept_job(world, (uuid_id, revision(world, uuid_id) + 100))  # a conflict

    make_executor(world).run_one()

    lock = world.locks.lock_for(uuid_id)
    assert lock.acquire(blocking=False)
    lock.release()


# ── revalidation outcomes ──────────────────────────────────────────────────


def test_an_own_tombstone_is_already_deleted_with_its_revision_and_no_bump(world):
    uuid_id = add_master(world, "Radiohead/OK Computer/01 Lucky.flac")
    rev = revision(world, uuid_id)
    assert world.db.delete_track(uuid_id, owner_id=world.owner)
    tomb_rev = tombstone(world, uuid_id)[0]
    op = accept_job(world, (uuid_id, rev))
    before_counter = counter(world)

    make_executor(world).run_one()

    assert item(world, op, uuid_id) == {
        "status": "already_deleted", "error": None, "tombstone_revision": tomb_rev,
        "details": [], "lease": BOOT,
    }
    assert counter(world) == before_counter
    assert tombstone(world, uuid_id) == (tomb_rev, world.owner)
    assert journal(world, uuid_id) is None


def test_an_unknown_uuid_is_not_found(world):
    op = accept_job(world, (UNKNOWN, 1))
    before = files_under(world.music)

    make_executor(world).run_one()

    assert item(world, op, UNKNOWN)["status"] == "failed"
    assert item(world, op, UNKNOWN)["error"] == "not_found"
    assert item(world, op, UNKNOWN)["tombstone_revision"] is None
    assert files_under(world.music) == before


def test_another_users_live_track_is_not_found_and_untouched(world):
    theirs = add_master(world, "Radiohead/OK Computer/01 Lucky.flac", owner=world.sam)
    rev = revision(world, theirs)
    op = accept_job(world, (theirs, rev))  # the owner names sam's uuid
    before = files_under(world.music)

    make_executor(world).run_one()

    assert (item(world, op, theirs)["status"], item(world, op, theirs)["error"]) == (
        "failed", "not_found",
    )
    _untouched(world, before, theirs, rev)


def test_another_users_tombstone_is_not_found_like_an_unknown_uuid(world):
    theirs = add_master(world, "Radiohead/OK Computer/01 Lucky.flac", owner=world.sam)
    assert world.db.delete_track(theirs, owner_id=world.sam)
    op = accept_job(world, (theirs, 1))
    before_counter = counter(world)

    make_executor(world).run_one()

    assert item(world, op, theirs) == {
        "status": "failed", "error": "not_found", "tombstone_revision": None,
        "details": [], "lease": BOOT,
    }
    assert counter(world) == before_counter


def test_a_changed_revision_is_a_conflict_and_removes_nothing(world):
    uuid_id = add_master(world, "Radiohead/OK Computer/01 Lucky.flac")
    rev = revision(world, uuid_id)
    op = accept_job(world, (uuid_id, rev - 1))
    before = files_under(world.music)

    make_executor(world).run_one()

    assert (item(world, op, uuid_id)["status"], item(world, op, uuid_id)["error"]) == (
        "conflict", "conflict",
    )
    _untouched(world, before, uuid_id, rev)


def _queued_conversion(world, uuid_id):
    world.db.insert_conversion_job(uuid_id, "aac", "m4a", 192, owner_id=world.owner)


def _running_conversion(world, uuid_id):
    _queued_conversion(world, uuid_id)
    sql(world, "UPDATE conversion_jobs SET status = 'running' WHERE uuid_id = ?", (uuid_id,))


def _edit_journal(world, uuid_id):
    world.db.insert_journal_entry(
        "relocate", uuid_id, old_path="/a", new_path="/b", owner_id=world.owner
    )


def _upload_commit(world, uuid_id):
    sql(
        world,
        "INSERT INTO upload_commit_journal (owner_id, operation_uuid, item_uuid, state,"
        " base_review_version, reserved_track_uuid, edits, write_tags,"
        " acknowledged_duplicates, source_path, created_at, updated_at)"
        " VALUES (?, 'op', 'item', 'prepared', 0, ?, '{}', 0, '{}', '/s', 0, 0)",
        (world.owner, uuid_id),
    )


def _other_deletion(world, uuid_id):
    mark_pending_deletion(world.db.context.database_path, uuid_id)


@pytest.mark.parametrize(
    "plant", [_queued_conversion, _running_conversion, _edit_journal, _upload_commit,
              _other_deletion],
)
def test_a_track_mid_operation_is_busy_and_untouched(world, plant):
    uuid_id = add_master(world, "Radiohead/OK Computer/01 Lucky.flac")
    rev = revision(world, uuid_id)
    op = accept_job(world, (uuid_id, rev))
    plant(world, uuid_id)
    before = files_under(world.music)
    journals = sql(world, "SELECT * FROM deletion_journal")

    make_executor(world).run_one()

    assert (item(world, op, uuid_id)["status"], item(world, op, uuid_id)["error"]) == (
        "busy", "busy",
    )
    assert files_under(world.music) == before
    assert sql(world, "SELECT * FROM deletion_journal") == journals
    assert revision(world, uuid_id) == rev and tombstone(world, uuid_id) is None


def test_another_users_busy_rows_do_not_make_my_target_busy(world):
    # sam's conversion of a uuid never decides the owner's outcome (it is
    # read owner-scoped); here the owner's target is a revision conflict.
    mine = add_master(world, "Radiohead/OK Computer/01 Lucky.flac")
    op = accept_job(world, (mine, revision(world, mine) + 5))
    sql(world, "INSERT INTO conversion_jobs (uuid_id, target_codec, target_container, status,"
               " owner_id) VALUES (?, 'aac', 'm4a', 'running', ?)", (mine, world.sam))

    make_executor(world).run_one()

    assert item(world, op, mine)["status"] == "conflict"


def test_each_target_is_run_once_and_the_job_completes(world):
    a = add_master(world, "A/a.flac", title="A")
    op = accept_job(world, (a, revision(world, a) + 1), (UNKNOWN, 1))

    assert drain(make_executor(world)) == 2

    assert [item(world, op, u)["status"] for u in (a, UNKNOWN)] == ["conflict", "failed"]
    assert one(world, "SELECT status FROM deletion_jobs WHERE operation_uuid = ?", (op,)) == (
        "completed",
    )


# ── review r1 8-R1-02: ownership before the lock (SC-28) ───────────────────


def _outcome_row(world, op, uuid_id):
    row = item(world, op, uuid_id)
    return {k: row[k] for k in ("status", "error", "tombstone_revision", "details", "lease")}


def test_a_foreign_track_whose_lock_is_held_reads_exactly_like_an_unknown_uuid(world):
    theirs = add_master(world, "Radiohead/OK Computer/01 Lucky.flac", owner=world.sam)
    op_foreign = accept_job(world, (theirs, revision(world, theirs)), now=1)
    op_unknown = accept_job(world, (UNKNOWN, 1), now=2)
    lock = world.locks.lock_for(theirs)  # sam holds a long edit of the track
    assert lock.acquire()
    try:
        executor = make_executor(world, lock_timeout_s=0)
        assert executor.run_one() and executor.run_one()
    finally:
        lock.release()

    assert _outcome_row(world, op_foreign, theirs) == _outcome_row(world, op_unknown, UNKNOWN)
    assert _outcome_row(world, op_foreign, theirs) == {
        "status": "failed", "error": "not_found", "tombstone_revision": None,
        "details": [], "lease": BOOT,
    }


def test_a_foreign_or_unknown_uuid_never_takes_or_creates_a_track_lock(world):
    theirs = add_master(world, "Radiohead/OK Computer/01 Lucky.flac", owner=world.sam)
    accept_job(world, (theirs, revision(world, theirs)), (UNKNOWN, 1))

    drain(make_executor(world))

    assert theirs not in world.locks
    assert UNKNOWN not in world.locks


# ── review r1 8-R1-08: the stored path is compared as stored ───────────────


def test_a_non_canonical_stored_path_is_deleted_not_a_conflict(world):
    uuid_id = add_master(world, "Radiohead/OK Computer/01 Lucky.flac")
    root = world.root(world.owner)
    stored = f"{root}/Radiohead//OK Computer/01 Lucky.flac"  # a legacy doubled separator
    sql(world, "UPDATE tracks SET file_path = ? WHERE uuid_id = ?", (stored, uuid_id))
    op = accept_job(world, (uuid_id, revision(world, uuid_id)))

    drain(make_executor(world))

    assert (item(world, op, uuid_id)["status"], item(world, op, uuid_id)["error"]) == (
        "deleted", None,
    )
    assert tombstone(world, uuid_id) is not None
    assert not (root / "Radiohead" / "OK Computer" / "01 Lucky.flac").exists()
