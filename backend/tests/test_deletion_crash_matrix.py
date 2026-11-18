"""Phase 8A.3d S6 (review 8-D09 "Crash after acceptance, after running claim
before journal, journal-written/original-intact, before/after rename and DB
commit; run recovery twice", 8-U06 "crash at every boundary"; spec §5 "Tests
crash before/after journal, rename, DB commit, cache eviction and unlink, then
run real startup recovery twice"): the crash matrix.

For every boundary the real executor is stopped dead (``SimulatedCrash``, a
BaseException, like a kill), then the three real deletion startup steps run
on a fresh connection with a new boot id, twice:

- the two restarts leave the same state (convergence);
- an uncommitted deletion's master is back at its path with its bytes, inode
  and revision unchanged, and its item is pending again;
- a committed deletion is never resurrected: the tombstone stays, the
  quarantine file is gone, the journal is gone, the item is ``deleted`` with
  no ``storage_cleanup_pending``;
- no item is left ``running`` (no stuck job);
- a worker of the new boot then finishes the job: every target deleted, the
  job completed, nothing left in quarantine.

Sign-off DEV-7-25 Part B: every case also runs on a library that refuses hard
links (``no-links``); the put-back then renames the file back.
"""

import errno
import os

import pytest

from app.services import organizer

from app.services import deletion_recovery
from app.services.startup_recovery import run_startup_recovery
from app.services.upload_publish import SimulatedCrash
from app.services.track_locks import TrackLocks
from tests.deletion_recovery_helpers import NEW_BOOT, disk, restarted_db, run_until_crash
from tests.deletion_world import (
    accept_job,
    add_master,
    build_world,
    drain,
    files_under,
    item,
    journal,
    live,
    make_executor,
    path_of,
    revision,
    sql,
    tombstone,
)

UNCOMMITTED = ["acceptance", "after_claim", "after_journal", "after_rename", "after_moved"]
COMMITTED = ["after_commit", "after_evict", "after_unlink"]
MISSING_MASTER = ["acceptance", "after_claim", "after_journal", "after_commit", "after_evict"]


@pytest.fixture(autouse=True, params=["links", "no-links"])
def links(request, monkeypatch):
    if request.param == "no-links":
        def refuse(src, dst, *args, **kwargs):
            raise OSError(errno.ENOTSUP, os.strerror(errno.ENOTSUP))

        monkeypatch.setattr(organizer.os, "link", refuse)
    return request.param


@pytest.fixture
def world(tmp_path):
    return build_world(tmp_path)


def restart(world):
    """The three real deletion startup steps, in registry order, of a new process."""
    run_startup_recovery(
        deletion_recovery.startup_steps(
            restarted_db(world),
            music_library_dir=world.music,
            track_locks=TrackLocks(),
            cover_art=world.cover_art,
            cache=world.cache,
            default_cache=world.default_cache,
            boot_id=NEW_BOOT,
        )
    )


def state(world, op, uuid_id):
    return {
        "disk": disk(world),
        "journal": journal(world, uuid_id),
        "item": item(world, op, uuid_id),
        "job": sql(world, "SELECT status FROM deletion_jobs WHERE operation_uuid = ?", (op,)),
        "revision": revision(world, uuid_id),
        "tombstone": tombstone(world, uuid_id),
        "live": live(world, uuid_id),
    }


def crash(world, point, *, create_file=True):
    uuid_id = add_master(
        world, "Portishead/Dummy/01 Mysterons.flac", create_file=create_file
    )
    master = path_of(world, uuid_id)
    original = (
        {"bytes": master.read_bytes(), "ino": os.lstat(master).st_ino} if create_file else None
    )
    rev = revision(world, uuid_id)
    op = accept_job(world, (uuid_id, rev))
    if point != "acceptance":
        run_until_crash(world, point)
    return uuid_id, rev, op, master, original


def assert_finishes(world, op, uuid_id, master):
    drain(make_executor(world, boot_id=NEW_BOOT))
    after = item(world, op, uuid_id)
    assert after["status"] == "deleted"
    assert tombstone(world, uuid_id) is not None and not master.exists()
    assert journal(world, uuid_id) is None
    assert sql(world, "SELECT status FROM deletion_jobs WHERE operation_uuid = ?", (op,)) == [("completed",)]
    assert files_under(world.music / ".deleting") == {}


@pytest.mark.parametrize("point", UNCOMMITTED)
def test_an_uncommitted_deletion_is_rolled_back_and_requeued(world, point):
    uuid_id, rev, op, master, original = crash(world, point)

    restart(world)
    first = state(world, op, uuid_id)
    restart(world)

    assert state(world, op, uuid_id) == first
    assert first["journal"] is None and first["live"] and first["revision"] == rev
    assert first["tombstone"] is None
    assert master.read_bytes() == original["bytes"] and os.lstat(master).st_ino == original["ino"]
    assert files_under(world.music / ".deleting") == {}
    assert first["item"]["status"] == "pending" and first["item"]["lease"] is None
    assert first["job"] == [("accepted",)]
    assert_finishes(world, op, uuid_id, master)


@pytest.mark.parametrize("point", COMMITTED)
def test_a_committed_deletion_is_never_resurrected_and_its_cleanup_finishes(world, point):
    uuid_id, rev, op, master, original = crash(world, point)
    tomb = tombstone(world, uuid_id)

    restart(world)
    first = state(world, op, uuid_id)
    restart(world)

    assert state(world, op, uuid_id) == first
    assert first["tombstone"] == tomb and not first["live"] and first["revision"] is None
    assert not master.exists()
    assert first["journal"] is None
    assert files_under(world.music / ".deleting") == {}
    assert first["item"]["status"] == "deleted" and first["item"]["details"] == []
    assert first["item"]["tombstone_revision"] == tomb[0]
    assert first["job"] == [("completed",)]
    assert_finishes(world, op, uuid_id, master)


@pytest.mark.parametrize("point", MISSING_MASTER)
def test_a_catalog_only_deletion_converges_at_every_boundary(world, point):
    uuid_id, rev, op, master, _ = crash(world, point, create_file=False)

    restart(world)
    first = state(world, op, uuid_id)
    restart(world)

    assert state(world, op, uuid_id) == first
    assert first["journal"] is None
    if point in ("after_commit", "after_evict"):
        assert first["item"]["status"] == "deleted"
        assert first["item"]["details"] == ["master_missing"]
    else:
        assert first["live"] and first["revision"] == rev
        assert first["item"]["status"] == "pending"
    assert_finishes(world, op, uuid_id, master)


def test_a_job_of_three_crashed_mid_way_converges_and_completes(world):
    done = add_master(world, "A/done.flac")
    mid = add_master(world, "A/mid.flac")
    todo = add_master(world, "A/todo.flac")
    op = accept_job(world, *[(u, revision(world, u)) for u in (done, mid, todo)])
    assert make_executor(world).run_one()  # the first target is deleted
    run_until_crash(world, "after_moved")  # the second one dies in quarantine

    restart(world)
    first = [item(world, op, u)["status"] for u in (done, mid, todo)]
    restart(world)

    assert [item(world, op, u)["status"] for u in (done, mid, todo)] == first == [
        "deleted", "pending", "pending",
    ]
    assert live(world, mid) and path_of(world, mid).exists()
    drain(make_executor(world, boot_id=NEW_BOOT))
    assert [item(world, op, u)["status"] for u in (done, mid, todo)] == ["deleted"] * 3
    assert sql(world, "SELECT status FROM deletion_jobs WHERE operation_uuid = ?", (op,)) == [("completed",)]


# ── review r1 8-R1-13: between the journal clear and the outcome write ─────


@pytest.mark.parametrize("cause", ["commit_failed", "rename_failed"])
def test_a_crash_after_the_journal_clear_before_the_outcome_converges(
    world, monkeypatch, cause
):
    """A rolled-back target clears its journal and then writes its outcome. A
    crash between the two leaves the item running with no journal and the
    track live: restart requeues it and the worker of the new boot deletes it."""
    import sqlite3

    from app.services import file_ops
    from tests.deletion_recovery_helpers import crash_at

    uuid_id = add_master(world, "Portishead/Dummy/01 Mysterons.flac")
    master = path_of(world, uuid_id)
    original = {"bytes": master.read_bytes(), "ino": os.lstat(master).st_ino}
    rev = revision(world, uuid_id)
    op = accept_job(world, (uuid_id, rev))
    with monkeypatch.context() as patch:
        if cause == "commit_failed":
            def failing(conn, uuid, *, owner_id):
                raise sqlite3.OperationalError("database is locked")

            patch.setattr(world.db, "_delete_track_in", failing)
        else:
            patch.setattr(file_ops, "move_file", lambda *a, **k: False)
        with pytest.raises(SimulatedCrash):
            make_executor(world, seam=crash_at("after_journal_clear")).run_one()
    assert journal(world, uuid_id) is None and item(world, op, uuid_id)["status"] == "running"

    restart(world)
    first = state(world, op, uuid_id)
    restart(world)

    assert state(world, op, uuid_id) == first
    assert first["live"] and first["revision"] == rev and first["tombstone"] is None
    assert master.read_bytes() == original["bytes"] and os.lstat(master).st_ino == original["ino"]
    assert first["item"]["status"] == "pending" and first["item"]["lease"] is None
    assert_finishes(world, op, uuid_id, master)


# ── OPEN-8-01: a power cut that loses the last commits (2026-11-14) ────────
#
# The database runs at SQLite's NORMAL durability, so a power cut can roll it
# back to before any commit that no durable point covered, while every file
# operation already reached the disk. Each case copies the database at a seam
# before a commit, lets the file operations go on until the run stops (at a
# later seam, or at the deletion's durable point), puts the copy back and runs
# the real startup steps twice. Expected: the master is back at its path with
# its bytes and inode, the catalog never lost it, and the job then finishes.

from tests.deletion_recovery_helpers import (  # noqa: E402
    DatabaseSnapshot,
    snapshot_then_crash,
)

DURABLE = "durable_point"  # not a seam: the database's make_durable is stopped

# (the seam before the lost commit, where the run stops)
LOST_COMMITS = [
    # the journal commit lost: the file sits in the holding folder unrecorded
    ("after_claim", "after_rename"),
    ("after_claim", "after_moved"),
    ("after_claim", "after_commit"),
    ("after_claim", DURABLE),
    # the "moved" mark lost: an intent journal and the file in the holding folder
    ("after_journal", "after_moved"),
    ("after_journal", DURABLE),
    # the catalog commit lost: a moved journal and the file in the holding folder
    ("after_moved", "after_commit"),
    ("after_moved", DURABLE),
]


def _stop_at_the_durable_point(*_args, **_kwargs):
    raise SimulatedCrash(DURABLE)


def run_with_lost_commits(world, monkeypatch, *, take_at, stop_at):
    """Run one deletion until ``stop_at``, then lose every commit after
    ``take_at``. A run that is never stopped (it found no durable point to stop
    at) completes; the lost commits are lost all the same."""
    snapshot = DatabaseSnapshot(world)
    crash_seam = None if stop_at == DURABLE else stop_at
    executor = make_executor(
        world, seam=snapshot_then_crash(snapshot, take_at=take_at, crash_at_point=crash_seam)
    )
    with monkeypatch.context() as patch:  # only the killed run stops there
        if stop_at == DURABLE:
            patch.setattr(world.db, "make_durable", _stop_at_the_durable_point, raising=False)
        try:
            executor.run_one()
        except SimulatedCrash:
            pass
    snapshot.restore()


@pytest.mark.parametrize("take_at,stop_at", LOST_COMMITS)
def test_a_lost_commit_never_loses_the_master(world, monkeypatch, take_at, stop_at):
    uuid_id = add_master(world, "Portishead/Dummy/01 Mysterons.flac")
    master = path_of(world, uuid_id)
    original = {"bytes": master.read_bytes(), "ino": os.lstat(master).st_ino}
    rev = revision(world, uuid_id)
    op = accept_job(world, (uuid_id, rev))

    run_with_lost_commits(world, monkeypatch, take_at=take_at, stop_at=stop_at)
    restart(world)
    first = state(world, op, uuid_id)
    restart(world)

    assert state(world, op, uuid_id) == first
    assert master.exists(), "the master was lost"
    assert master.read_bytes() == original["bytes"] and os.lstat(master).st_ino == original["ino"]
    assert files_under(world.music / ".deleting") == {}
    assert first["live"] and first["revision"] == rev and first["tombstone"] is None
    assert first["journal"] is None
    assert first["item"]["status"] == "pending" and first["item"]["lease"] is None
    assert first["job"] == [("accepted",)]
    assert_finishes(world, op, uuid_id, master)


def test_a_cleanup_commit_lost_after_the_durable_point_finishes(world):
    """After the durable point the catalog commit is on disk: losing the later
    journal clear leaves a committed journal whose holding file is gone, and
    the janitor finishes it (the deletion is never undone)."""
    uuid_id = add_master(world, "Portishead/Dummy/01 Mysterons.flac")
    master = path_of(world, uuid_id)
    op = accept_job(world, (uuid_id, revision(world, uuid_id)))
    snapshot = DatabaseSnapshot(world)
    make_executor(world, seam=snapshot_then_crash(snapshot, take_at="after_unlink")).run_one()
    tomb = tombstone(world, uuid_id)
    snapshot.restore()
    assert journal(world, uuid_id)["stage"] == "committed"

    restart(world)
    first = state(world, op, uuid_id)
    restart(world)

    assert state(world, op, uuid_id) == first
    assert first["tombstone"] == tomb and not first["live"] and not master.exists()
    assert first["journal"] is None and files_under(world.music / ".deleting") == {}
    assert first["item"]["status"] == "deleted" and first["item"]["details"] == []


def test_a_restart_cut_at_its_durable_point_never_loses_the_master(world, monkeypatch):
    """The janitor at startup finishes a committed deletion's cleanup only
    after its own durable point: a power cut there, which loses the catalog
    commit the killed run made, finds the file still in the holding folder."""
    from app.database.database import Database

    uuid_id = add_master(world, "Portishead/Dummy/01 Mysterons.flac")
    master = path_of(world, uuid_id)
    original = {"bytes": master.read_bytes(), "ino": os.lstat(master).st_ino}
    rev = revision(world, uuid_id)
    op = accept_job(world, (uuid_id, rev))
    snapshot = DatabaseSnapshot(world)
    with pytest.raises(SimulatedCrash):
        make_executor(
            world,
            seam=snapshot_then_crash(snapshot, take_at="after_moved", crash_at_point="after_commit"),
        ).run_one()
    assert journal(world, uuid_id)["stage"] == "committed"

    with monkeypatch.context() as patch:
        patch.setattr(Database, "make_durable", _stop_at_the_durable_point, raising=False)
        try:
            restart(world)
        except SimulatedCrash:
            pass
    snapshot.restore()
    restart(world)
    first = state(world, op, uuid_id)
    restart(world)

    assert state(world, op, uuid_id) == first
    assert master.exists(), "the master was lost"
    assert master.read_bytes() == original["bytes"] and os.lstat(master).st_ino == original["ino"]
    assert first["live"] and first["revision"] == rev and first["journal"] is None
    assert first["item"]["status"] == "pending"
    assert_finishes(world, op, uuid_id, master)


def test_the_boot_of_a_lost_claim_does_not_matter(world, monkeypatch):
    """The claim itself lost too: the item is pending again in the copy."""
    uuid_id = add_master(world, "A/x.flac")
    master = path_of(world, uuid_id)
    op = accept_job(world, (uuid_id, revision(world, uuid_id)))
    snapshot = DatabaseSnapshot(world)
    snapshot.take()  # before the claim
    with monkeypatch.context() as patch:
        patch.setattr(world.db, "make_durable", _stop_at_the_durable_point, raising=False)
        try:
            make_executor(world).run_one()
        except SimulatedCrash:
            pass
    snapshot.restore()
    assert item(world, op, uuid_id)["status"] == "pending"

    restart(world)

    assert master.exists() and journal(world, uuid_id) is None
    assert item(world, op, uuid_id)["status"] == "pending"
    assert_finishes(world, op, uuid_id, master)
