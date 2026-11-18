"""Phase 8 review r1 8-R1-05 and audit TR-DELETE-03: no deletion journal is
kept for ever with nothing that resolves it.

- A master absent at both the original and the quarantine path, with the
  owner's library root proven present, is not evidence the journal must
  protect: the journal is cleared and an item still running is requeued, so
  the rerun completes the deletion as a catalog-only one (``master_missing``),
  through a real commit. A terminal item keeps its outcome; the track is live
  again (with its master missing) and can be deleted again.
- With the root not proven present (unmounted, replaced) nothing changes: the
  journal is kept.
- The same happens at runtime, without a restart, when the master vanishes
  between the path check and the rename.
- A journal that is kept for a reason that later goes away is resolved by the
  deletion worker's periodic pass, not only by the next start.
"""

import os
import shutil
import sqlite3

import pytest

from app.services.deletion_recovery import DeletionJanitor
from app.services.deletion_worker import DeletionWorker
from tests.deletion_recovery_helpers import NEW_BOOT, crashed_at, recover
from tests.deletion_world import (
    BOOT,
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
from app.services.deletion_recovery import reclaim_deletion_items
from tests.deletion_recovery_helpers import restarted_db


@pytest.fixture
def world(tmp_path):
    return build_world(tmp_path)


def _status(world, op, uuid_id):
    it = item(world, op, uuid_id)
    return it["status"], it["error"], it["details"]


def _restart(world):
    recover(world)
    reclaim_deletion_items(restarted_db(world), boot_id=NEW_BOOT)


# ── at startup ─────────────────────────────────────────────────────────────


@pytest.mark.parametrize("point", ["after_journal", "after_rename", "after_moved"])
def test_a_master_gone_from_both_places_ends_as_a_catalog_only_deletion(world, point):
    uuid_id, rev, op = crashed_at(world, point)
    master = path_of(world, uuid_id)
    quarantine = journal(world, uuid_id)["quarantine_path"]
    for path in (master, quarantine):
        if os.path.lexists(path):
            os.unlink(path)

    _restart(world)
    _restart(world)  # twice: nothing more changes

    assert journal(world, uuid_id) is None
    assert live(world, uuid_id) and revision(world, uuid_id) == rev
    assert item(world, op, uuid_id)["status"] == "pending"

    drain(make_executor(world, boot_id=NEW_BOOT))

    assert _status(world, op, uuid_id) == ("deleted", None, ["master_missing"])
    assert tombstone(world, uuid_id) is not None and not live(world, uuid_id)
    assert journal(world, uuid_id) is None


def test_a_terminal_item_keeps_its_outcome_and_the_track_comes_back(world):
    uuid_id, rev, op = crashed_at(world, "after_rename")
    os.unlink(journal(world, uuid_id)["quarantine_path"])
    sql(world, "UPDATE deletion_job_items SET status = 'failed',"
        " error_code = 'recovery_required' WHERE uuid_id = ?", (uuid_id,))

    _restart(world)

    assert journal(world, uuid_id) is None
    assert live(world, uuid_id) and revision(world, uuid_id) == rev
    assert _status(world, op, uuid_id)[:2] == ("failed", "recovery_required")
    # Deleting it again is possible: a new job runs as a catalog-only deletion.
    op2 = accept_job(world, (uuid_id, rev), now=2_000_000_000)
    drain(make_executor(world, boot_id=NEW_BOOT))
    assert _status(world, op2, uuid_id) == ("deleted", None, ["master_missing"])


def test_without_the_owners_root_proven_present_the_journal_is_kept(world):
    uuid_id, rev, op = crashed_at(world, "after_rename")
    os.unlink(journal(world, uuid_id)["quarantine_path"])
    kept = journal(world, uuid_id)
    root = world.root(world.owner)
    shutil.move(root, world.tmp / "unmounted")  # the library root is not there

    _restart(world)

    assert journal(world, uuid_id) == kept
    assert not live(world, uuid_id)
    assert _status(world, op, uuid_id)[:2] == ("failed", "recovery_required")


# ── at runtime, without a restart ──────────────────────────────────────────


def test_a_master_that_vanishes_before_the_rename_is_deleted_in_the_same_boot(world):
    uuid_id = add_master(world, "A/Album/a.flac")
    master = path_of(world, uuid_id)
    op = accept_job(world, (uuid_id, revision(world, uuid_id)))

    def seam(name):
        if name == "after_journal" and master.exists():
            master.unlink()  # an outside tool removes the file mid-job

    executor = make_executor(world, seam=seam)
    drain(executor)

    assert _status(world, op, uuid_id) == ("deleted", None, ["master_missing"])
    assert tombstone(world, uuid_id) is not None
    assert journal(world, uuid_id) is None
    assert item(world, op, uuid_id)["lease"] == BOOT
    assert files_under(world.music / ".deleting") == {}


# ── the periodic pass resolves a journal kept for a reason that went away ──


class _Clock:
    def __init__(self):
        self.now = 1000.0

    def __call__(self):
        return self.now


def test_the_periodic_pass_resolves_a_kept_journal_once_the_evidence_is_clear(
    world, monkeypatch
):
    uuid_id = add_master(world, "A/Album/a.flac")
    master = path_of(world, uuid_id)
    rev = revision(world, uuid_id)
    op = accept_job(world, (uuid_id, rev))
    real = world.db._delete_track_in
    calls = {"n": 0}

    def failing_once(*args, **kwargs):
        calls["n"] += 1
        if calls["n"] == 1:
            raise sqlite3.OperationalError("database is locked")
        return real(*args, **kwargs)

    monkeypatch.setattr(world.db, "_delete_track_in", failing_once)

    def seam(name):
        if name == "after_moved" and not master.exists():
            master.write_bytes(b"a stray copy")  # the put-back must not replace it

    executor = make_executor(world, seam=seam)
    clock = _Clock()
    worker = DeletionWorker(
        executor, idle_poll_s=5,
        janitor=DeletionJanitor(world.db, executor=executor, music_library_dir=world.music),
        janitor_interval_s=60, clock=clock,
    )
    assert worker.process_one() == "done"
    assert _status(world, op, uuid_id)[:2] == ("failed", "recovery_required")
    assert journal(world, uuid_id) is not None and not live(world, uuid_id)

    master.unlink()  # the operator removes the stray file
    clock.now += 60
    assert worker.process_one() == "idle"  # the due periodic pass

    assert journal(world, uuid_id) is None
    assert live(world, uuid_id) and revision(world, uuid_id) == rev
    assert master.read_bytes() == b"master A/Album/a.flac"
    assert files_under(world.music / ".deleting") == {}
    # The item's terminal outcome is never rewritten (DEV-8A.3d-02).
    assert _status(world, op, uuid_id)[:2] == ("failed", "recovery_required")


# ── review of the fix (r1be review #1, #2) ─────────────────────────────────


def test_a_journal_the_periodic_pass_clears_requeues_an_item_left_by_an_old_boot(world):
    """The janitor pass runs after the startup reclaim: an item of an old boot
    whose journal it clears must not stay running for the rest of the boot."""
    uuid_id, rev, op = crashed_at(world, "after_rename")  # leased by BOOT, now dead
    executor = make_executor(world, boot_id=NEW_BOOT)

    DeletionJanitor(world.db, executor=executor, music_library_dir=world.music).retry_cleanups()

    assert journal(world, uuid_id) is None and live(world, uuid_id)
    assert (item(world, op, uuid_id)["status"], item(world, op, uuid_id)["lease"]) == (
        "pending", None,
    )


def test_a_moved_journal_without_its_quarantine_folder_is_kept(world):
    """'Both gone' is proven only when the owner's quarantine folder is there:
    a missing ``.deleting/<owner>`` may be an unmounted quarantine."""
    uuid_id, rev, op = crashed_at(world, "after_moved")
    kept = journal(world, uuid_id)
    shutil.rmtree(world.music / ".deleting" / str(world.owner))

    _restart(world)

    assert journal(world, uuid_id) == kept
    assert not live(world, uuid_id)
