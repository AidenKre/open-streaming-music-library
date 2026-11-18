"""What the deletion executor does for one target, call by call (refactor
piece BE-DEL, written before the executor's helpers were reshaped).

The other ``test_deletion_*`` suites assert where a target ends: its item, its
journal, its files. These tests pin how it gets there: each one drives the real
executor through one branch of ``_delete_live`` (or of the release and cleanup
that follow it) and compares every database call, lock, path judgement, file
operation, seam and log line, in order, with the list written out below. A
path or an identity that reaches the wrong call, an operation on the wrong
file, a dropped error or a changed order shows as a changed line.

The recording rig is ``tests/deletion_trace.py``. In the lists, paths are
relative to the music folder (the owner's library is ``owner/``, the
quarantine ``.deleting/1/``); ``worker.`` and ``recovery.`` name the module
whose code asked for a path judgement.
"""

import errno
import os
import shutil
import sqlite3
from pathlib import Path

import pytest

from app.services import deletion_worker
from app.services.path_sanitize import PathEscapesRoot
from tests.deletion_trace import DeletionRig
from tests.deletion_world import add_art, build_world, sql

_REAL_REPLACE, _REAL_LINK, _REAL_UNLINK = os.replace, os.link, os.unlink


# What every target that reaches ``_delete_live`` does first: the claim, the
# ownership read without the lock, the lock, the read under it, the owner.
_CLAIMED = """
    db.claim_next_deletion_item(boot_id=boot-test) -> <item <uuid>>
    seam after_claim
    db.read_deletion_target(<uuid>, owner_id=1) -> <live>
    lock(<uuid>).acquire(timeout=0) -> True
    db.read_deletion_target(<uuid>, owner_id=1) -> <live>
    db.get_user(1) -> <user owner>
"""

# ... then the master is judged present and the journal row is written.
_JOURNALED = _CLAIMED + """
    worker.check_master_path(<music>, <user owner>, owner/A/Album/a.flac) -> (ok, <stat>)
    db.track_path_in_use(owner/A/Album/a.flac, exclude_uuid=<uuid>, owner_id=ANY_OWNER) -> False
    db.begin_track_deletion(<key>, base_revision=1, boot_id=boot-test, cover_art_id=None, identity=<identity>, master_missing=False, now=1700000005, original_path=owner/A/Album/a.flac, quarantine_path=.deleting/1/<op>/<uuid>.flac) -> ok
    seam after_journal
"""

# ... then the file is moved into quarantine, proven, flushed, and the stage noted.
_MOVED = _JOURNALED + """
    os.mkdir .deleting/1
    os.mkdir .deleting/1/<op>
    os.replace owner/A/Album/a.flac -> .deleting/1/<op>/<uuid>.flac
    worker.is_journaled_file(.deleting/1/<op>/<uuid>.flac, <identity>) -> True
    os.fsync .deleting/1/<op>
    os.fsync owner/A/Album
    seam after_rename
    db.mark_deletion_moved(<key>, now=1700000005) -> None
    seam after_moved
"""


@pytest.fixture
def rig(tmp_path, monkeypatch):
    rig = DeletionRig(build_world(tmp_path), monkeypatch)
    yield rig
    rig.close()


def _locked():
    return sqlite3.OperationalError("database is locked")


def _denied():
    return PermissionError(errno.EACCES, "Permission denied")


def _bump_revision(rig):
    sql(rig.world, "UPDATE tracks SET revision = revision + 1000 WHERE uuid_id = ?", (rig.uuid,))


def _another_file_in_quarantine(rig):
    """The same bytes under another inode at the quarantine path."""
    copy = rig.quarantine.with_name("copy")
    shutil.copyfile(rig.quarantine, copy)
    _REAL_REPLACE(copy, rig.quarantine)


def _taken_back_and_replaced(rig):
    """Another program moves the quarantined file back to the original path
    and leaves a different file at the quarantine path."""
    _REAL_REPLACE(rig.quarantine, rig.master)
    rig.quarantine.write_bytes(b"another file")


# ── the deletion goes through ──────────────────────────────────────────────


def test_a_deletion_that_succeeds(rig):
    rig.job(cover_art_id=add_art(rig.world, "cover"))
    rig.start().step()
    rig.expect("step -> done", _CLAIMED, """
        worker.check_master_path(<music>, <user owner>, owner/A/Album/a.flac) -> (ok, <stat>)
        db.track_path_in_use(owner/A/Album/a.flac, exclude_uuid=<uuid>, owner_id=ANY_OWNER) -> False
        db.begin_track_deletion(<key>, base_revision=1, boot_id=boot-test, cover_art_id=1, identity=<identity>, master_missing=False, now=1700000005, original_path=owner/A/Album/a.flac, quarantine_path=.deleting/1/<op>/<uuid>.flac) -> ok
        seam after_journal
        os.mkdir .deleting/1
        os.mkdir .deleting/1/<op>
        os.replace owner/A/Album/a.flac -> .deleting/1/<op>/<uuid>.flac
        worker.is_journaled_file(.deleting/1/<op>/<uuid>.flac, <identity>) -> True
        os.fsync .deleting/1/<op>
        os.fsync owner/A/Album
        seam after_rename
        db.mark_deletion_moved(<key>, now=1700000005) -> None
        seam after_moved
        db.commit_track_deletion(<key>, base_revision=1, boot_id=boot-test, details=[storage_cleanup_pending], now=1700000005, original_path=owner/A/Album/a.flac) -> 2
        seam after_commit
        lock(<uuid>).release()
        db.deletion_job_has_pending_items(operation_uuid=<op>, owner_id=1) -> False
        db.make_durable() -> True
        cache.remove_all_for_uuid(<uuid>)
        default_cache.remove_all_for_uuid(<uuid>)
        seam after_evict
        cover_art.release_if_unreferenced(1) -> True
        os.unlink <tmp>/art/cover.jpg
        os.unlink .deleting/1/<op>/<uuid>.flac
        seam after_unlink
        os.rmdir owner/A/Album
        os.rmdir owner/A
        os.rmdir .deleting/1/<op>
        db.finish_deletion_cleanup(<key>, details=[]) -> None
        end <uuid>: item=deleted/None lease=boot-test details=[] journal=None
        end files: []
    """)


def test_a_deletion_whose_master_is_already_gone(rig):
    rig.job(create_file=False)
    rig.start().step()
    rig.expect("step -> done", _CLAIMED, """
        worker.check_master_path(<music>, <user owner>, owner/A/Album/a.flac) -> (missing, None)
        db.begin_track_deletion(<key>, base_revision=1, boot_id=boot-test, cover_art_id=None, identity=None, master_missing=True, now=1700000005, original_path=owner/A/Album/a.flac, quarantine_path=None) -> ok
        seam after_journal
        db.commit_track_deletion(<key>, base_revision=1, boot_id=boot-test, details=[master_missing, storage_cleanup_pending], now=1700000005, original_path=owner/A/Album/a.flac) -> 2
        seam after_commit
        lock(<uuid>).release()
        db.deletion_job_has_pending_items(operation_uuid=<op>, owner_id=1) -> False
        db.make_durable() -> True
        cache.remove_all_for_uuid(<uuid>)
        default_cache.remove_all_for_uuid(<uuid>)
        seam after_evict
        os.rmdir owner/A/Album raises FileNotFoundError(ENOENT)
        db.finish_deletion_cleanup(<key>, details=[master_missing]) -> None
        end <uuid>: item=deleted/None lease=boot-test details=[master_missing] journal=None
        end files: []
    """)


def test_two_targets_of_one_job_are_cleaned_up_after_the_second(rig):
    rig.job("A/Album/a.flac", "A/Album/b.flac")
    rig.start().step(3)
    rig.expect("step -> done", _MOVED, """
        db.commit_track_deletion(<key>, base_revision=1, boot_id=boot-test, details=[storage_cleanup_pending], now=1700000005, original_path=owner/A/Album/a.flac) -> 3
        seam after_commit
        lock(<uuid>).release()
        db.deletion_job_has_pending_items(operation_uuid=<op>, owner_id=1) -> True
        step -> done
        db.claim_next_deletion_item(boot_id=boot-test) -> <item <uuid2>>
        seam after_claim
        db.read_deletion_target(<uuid2>, owner_id=1) -> <live>
        lock(<uuid2>).acquire(timeout=0) -> True
        db.read_deletion_target(<uuid2>, owner_id=1) -> <live>
        db.get_user(1) -> <user owner>
        worker.check_master_path(<music>, <user owner>, owner/A/Album/b.flac) -> (ok, <stat>)
        db.track_path_in_use(owner/A/Album/b.flac, exclude_uuid=<uuid2>, owner_id=ANY_OWNER) -> False
        db.begin_track_deletion(<key2>, base_revision=2, boot_id=boot-test, cover_art_id=None, identity=<identity2>, master_missing=False, now=1700000005, original_path=owner/A/Album/b.flac, quarantine_path=.deleting/1/<op>/<uuid2>.flac) -> ok
        seam after_journal
        os.replace owner/A/Album/b.flac -> .deleting/1/<op>/<uuid2>.flac
        worker.is_journaled_file(.deleting/1/<op>/<uuid2>.flac, <identity2>) -> True
        os.fsync .deleting/1/<op>
        os.fsync owner/A/Album
        seam after_rename
        db.mark_deletion_moved(<key2>, now=1700000005) -> None
        seam after_moved
        db.commit_track_deletion(<key2>, base_revision=2, boot_id=boot-test, details=[storage_cleanup_pending], now=1700000005, original_path=owner/A/Album/b.flac) -> 4
        seam after_commit
        lock(<uuid2>).release()
        db.deletion_job_has_pending_items(operation_uuid=<op>, owner_id=1) -> False
        db.make_durable() -> True
        cache.remove_all_for_uuid(<uuid>)
        default_cache.remove_all_for_uuid(<uuid>)
        seam after_evict
        os.unlink .deleting/1/<op>/<uuid>.flac
        seam after_unlink
        os.rmdir owner/A/Album
        os.rmdir owner/A
        os.rmdir .deleting/1/<op> raises OSError(ENOTEMPTY)
        db.finish_deletion_cleanup(<key>, details=[]) -> None
        cache.remove_all_for_uuid(<uuid2>)
        default_cache.remove_all_for_uuid(<uuid2>)
        seam after_evict
        os.unlink .deleting/1/<op>/<uuid2>.flac
        seam after_unlink
        os.rmdir owner/A/Album raises FileNotFoundError(ENOENT)
        os.rmdir .deleting/1/<op>
        db.finish_deletion_cleanup(<key2>, details=[]) -> None
        step -> idle
        db.claim_next_deletion_item(boot_id=boot-test) -> None
        end <uuid>: item=deleted/None lease=boot-test details=[] journal=None
        end <uuid2>: item=deleted/None lease=boot-test details=[] journal=None
        end files: []
    """)


def test_a_step_with_nothing_to_do(rig):
    rig.start().step()
    rig.expect("""
        step -> idle
        db.claim_next_deletion_item(boot_id=boot-test) -> None
        end files: []
    """)


def test_a_failed_stage_update_does_not_stop_the_deletion(rig):
    rig.job()
    rig.db_fault("mark_deletion_moved", RuntimeError("database is locked"))
    rig.start().step()
    rig.expect("step -> done", _JOURNALED, """
        os.mkdir .deleting/1
        os.mkdir .deleting/1/<op>
        os.replace owner/A/Album/a.flac -> .deleting/1/<op>/<uuid>.flac
        worker.is_journaled_file(.deleting/1/<op>/<uuid>.flac, <identity>) -> True
        os.fsync .deleting/1/<op>
        os.fsync owner/A/Album
        seam after_rename
        db.mark_deletion_moved(<key>, now=1700000005) raises RuntimeError
        log WARNING deletion_worker: deletion stage update failed: RuntimeError
        seam after_moved
        db.commit_track_deletion(<key>, base_revision=1, boot_id=boot-test, details=[storage_cleanup_pending], now=1700000005, original_path=owner/A/Album/a.flac) -> 2
        seam after_commit
        lock(<uuid>).release()
        db.deletion_job_has_pending_items(operation_uuid=<op>, owner_id=1) -> False
        db.make_durable() -> True
        cache.remove_all_for_uuid(<uuid>)
        default_cache.remove_all_for_uuid(<uuid>)
        seam after_evict
        os.unlink .deleting/1/<op>/<uuid>.flac
        seam after_unlink
        os.rmdir owner/A/Album
        os.rmdir owner/A
        os.rmdir .deleting/1/<op>
        db.finish_deletion_cleanup(<key>, details=[]) -> None
        end <uuid>: item=deleted/None lease=boot-test details=[] journal=None
        end files: []
    """)


# ── refused before anything moves ──────────────────────────────────────────


def test_a_track_locked_by_someone_else_is_busy(rig):
    rig.job()
    held = rig.world.locks.lock_for(rig.uuid)
    assert held.acquire()
    try:
        rig.start().step()
    finally:
        held.release()
    rig.expect("""
        step -> done
        db.claim_next_deletion_item(boot_id=boot-test) -> <item <uuid>>
        seam after_claim
        db.read_deletion_target(<uuid>, owner_id=1) -> <live>
        lock(<uuid>).acquire(timeout=0) -> False
        db.finish_deletion_item(<key>, boot_id=boot-test, details=(), error_code=busy, status=busy, tombstone_revision=None) -> True
        end <uuid>: item=busy/busy lease=boot-test details=[] journal=None
        end files: [owner/A/Album/a.flac]
    """)


def test_a_master_path_that_is_a_symbolic_link_is_rejected(rig):
    rig.job()
    elsewhere = rig.world.tmp / "elsewhere.flac"
    os.rename(rig.master, elsewhere)
    os.symlink(elsewhere, rig.master)
    rig.start().step()
    rig.expect("step -> done", _CLAIMED, """
        worker.check_master_path(<music>, <user owner>, owner/A/Album/a.flac) -> (rejected, None)
        db.finish_deletion_item(<key>, boot_id=boot-test, details=(), error_code=path_rejected, status=failed, tombstone_revision=None) -> True
        lock(<uuid>).release()
        end <uuid>: item=failed/path_rejected lease=boot-test details=[] journal=None
        end files: []
    """)


def test_a_quarantine_path_outside_the_owners_quarantine_is_rejected(rig, monkeypatch):
    rig.job()

    real = deletion_worker.assert_within
    owner_quarantine = rig.world.music / ".deleting" / str(rig.world.owner)

    def escapes(path, root):
        if Path(root) == owner_quarantine:
            raise PathEscapesRoot(str(path))
        return real(path, root)

    monkeypatch.setattr(deletion_worker, "assert_within", escapes)
    rig.start().step()
    rig.expect("step -> done", _CLAIMED, """
        worker.check_master_path(<music>, <user owner>, owner/A/Album/a.flac) -> (ok, <stat>)
        db.track_path_in_use(owner/A/Album/a.flac, exclude_uuid=<uuid>, owner_id=ANY_OWNER) -> False
        db.finish_deletion_item(<key>, boot_id=boot-test, details=(), error_code=path_rejected, status=failed, tombstone_revision=None) -> True
        lock(<uuid>).release()
        end <uuid>: item=failed/path_rejected lease=boot-test details=[] journal=None
        end files: [owner/A/Album/a.flac]
    """)


def test_a_journal_write_that_finds_the_item_gone(rig):
    rig.job()
    rig.db_fault("begin_track_deletion", answer="gone")
    rig.start().step()
    rig.expect("step -> done", _CLAIMED, """
        worker.check_master_path(<music>, <user owner>, owner/A/Album/a.flac) -> (ok, <stat>)
        db.track_path_in_use(owner/A/Album/a.flac, exclude_uuid=<uuid>, owner_id=ANY_OWNER) -> False
        db.begin_track_deletion(<key>, base_revision=1, boot_id=boot-test, cover_art_id=None, identity=<identity>, master_missing=False, now=1700000005, original_path=owner/A/Album/a.flac, quarantine_path=.deleting/1/<op>/<uuid>.flac) -> gone
        lock(<uuid>).release()
        end <uuid>: item=running/None lease=boot-test details=[] journal=None
        end files: [owner/A/Album/a.flac]
    """)


@pytest.mark.parametrize("answer", ["conflict", "busy"])
def test_a_journal_write_refused_by_the_database_ends_the_target(rig, answer):
    rig.job()
    rig.db_fault("begin_track_deletion", answer=answer)
    rig.start().step()
    rig.expect("step -> done", _CLAIMED, """
        worker.check_master_path(<music>, <user owner>, owner/A/Album/a.flac) -> (ok, <stat>)
        db.track_path_in_use(owner/A/Album/a.flac, exclude_uuid=<uuid>, owner_id=ANY_OWNER) -> False
        db.begin_track_deletion(<key>, base_revision=1, boot_id=boot-test, cover_art_id=None, identity=<identity>, master_missing=False, now=1700000005, original_path=owner/A/Album/a.flac, quarantine_path=.deleting/1/<op>/<uuid>.flac) -> ANSWER
        db.finish_deletion_item(<key>, boot_id=boot-test, details=(), error_code=ANSWER, status=ANSWER, tombstone_revision=None) -> True
        lock(<uuid>).release()
        end <uuid>: item=ANSWER/ANSWER lease=boot-test details=[] journal=None
        end files: [owner/A/Album/a.flac]
    """.replace("ANSWER", answer))


# ── the move into quarantine fails ─────────────────────────────────────────


def test_a_refused_move_clears_the_journal_and_fails_the_target(rig):
    rig.job()
    rig.os_fault("replace", _denied(), path=rig.master)
    rig.start().step()
    rig.expect("step -> done", _JOURNALED, """
        os.mkdir .deleting/1
        os.mkdir .deleting/1/<op>
        os.replace owner/A/Album/a.flac -> .deleting/1/<op>/<uuid>.flac raises PermissionError(EACCES)
        log WARNING organizer: could not move a file: Permission denied
        worker.quarantine_state(.deleting/1/<op>/<uuid>.flac, <identity>) -> free
        worker.is_journaled_file(owner/A/Album/a.flac, <identity>) -> True
        db.clear_deletion_journal(<key>) -> True
        os.rmdir .deleting/1/<op>
        seam after_journal_clear
        db.finish_deletion_item(<key>, boot_id=boot-test, details=(), error_code=rename, status=failed, tombstone_revision=None) -> True
        lock(<uuid>).release()
        end <uuid>: item=failed/rename lease=boot-test details=[] journal=None
        end files: [owner/A/Album/a.flac]
    """)


def test_a_move_that_raises_is_a_refused_move(rig):
    rig.job()
    # Not an OSError: move_file answers False for those; this one escapes it.
    rig.os_fault("replace", RuntimeError("/music/secret"), path=rig.master)
    rig.start().step()
    rig.expect("step -> done", _JOURNALED, """
        os.mkdir .deleting/1
        os.mkdir .deleting/1/<op>
        os.replace owner/A/Album/a.flac -> .deleting/1/<op>/<uuid>.flac raises RuntimeError
        log WARNING deletion_worker: deletion move failed: RuntimeError
        worker.quarantine_state(.deleting/1/<op>/<uuid>.flac, <identity>) -> free
        worker.is_journaled_file(owner/A/Album/a.flac, <identity>) -> True
        db.clear_deletion_journal(<key>) -> True
        os.rmdir .deleting/1/<op>
        seam after_journal_clear
        db.finish_deletion_item(<key>, boot_id=boot-test, details=(), error_code=rename, status=failed, tombstone_revision=None) -> True
        lock(<uuid>).release()
        end <uuid>: item=failed/rename lease=boot-test details=[] journal=None
        end files: [owner/A/Album/a.flac]
    """)


def test_a_refused_move_with_an_unreadable_quarantine_keeps_the_journal(rig):
    rig.job()
    rig.os_fault("replace", _denied(), path=rig.master, then=lambda: rig.os_fault(
        "lstat", _denied(), path=rig.quarantine, times=99))
    rig.start().step()
    rig.expect("step -> done", _JOURNALED, """
        os.mkdir .deleting/1
        os.mkdir .deleting/1/<op>
        os.replace owner/A/Album/a.flac -> .deleting/1/<op>/<uuid>.flac raises PermissionError(EACCES)
        log WARNING organizer: could not move a file: Permission denied
        worker.quarantine_state(.deleting/1/<op>/<uuid>.flac, <identity>) -> unknown
        db.get_deletion_journal(<key>) -> <journal intent>
        db.get_user(1) -> <user owner>
        db.read_deletion_target(<uuid>, owner_id=1) -> <live>
        recovery.check_master_path(<music>, <user owner>, owner/A/Album/a.flac) -> (ok, <stat>)
        recovery.is_journaled_file(owner/A/Album/a.flac, <identity>) -> True
        recovery.quarantine_trusted(<music>, <journal intent>) -> True
        recovery.quarantine_state(.deleting/1/<op>/<uuid>.flac, <identity>) -> unknown
        db.finish_deletion_item(<key>, boot_id=boot-test, details=(), error_code=recovery_required, status=failed, tombstone_revision=None) -> True
        lock(<uuid>).release()
        end <uuid>: item=failed/recovery_required lease=boot-test details=[] journal=intent
        end files: [owner/A/Album/a.flac]
    """)


def test_a_refused_move_whose_journal_clear_fails_is_released(rig):
    rig.job()
    rig.os_fault("replace", _denied(), path=rig.master)
    rig.db_fault("clear_deletion_journal", _locked())
    rig.start().step()
    rig.expect("step -> error", _JOURNALED, """
        os.mkdir .deleting/1
        os.mkdir .deleting/1/<op>
        os.replace owner/A/Album/a.flac -> .deleting/1/<op>/<uuid>.flac raises PermissionError(EACCES)
        log WARNING organizer: could not move a file: Permission denied
        worker.quarantine_state(.deleting/1/<op>/<uuid>.flac, <identity>) -> free
        worker.is_journaled_file(owner/A/Album/a.flac, <identity>) -> True
        db.clear_deletion_journal(<key>) raises OperationalError
        log WARNING deletion_worker: deletion journal clear failed: OperationalError
        db.get_deletion_journal(<key>) -> <journal intent>
        db.get_user(1) -> <user owner>
        db.read_deletion_target(<uuid>, owner_id=1) -> <live>
        recovery.check_master_path(<music>, <user owner>, owner/A/Album/a.flac) -> (ok, <stat>)
        recovery.is_journaled_file(owner/A/Album/a.flac, <identity>) -> True
        recovery.quarantine_trusted(<music>, <journal intent>) -> True
        recovery.quarantine_state(.deleting/1/<op>/<uuid>.flac, <identity>) -> free
        db.clear_deletion_journal(<key>) -> True
        db.release_deletion_item(<key>, boot_id=boot-test) -> True
        lock(<uuid>).release()
        end <uuid>: item=pending/None lease=None details=[] journal=None
        end files: [owner/A/Album/a.flac]
    """)


def test_an_error_while_judging_a_refused_move_is_released(rig):
    rig.job()
    rig.os_fault("replace", _denied(), path=rig.master, then=lambda: rig.os_fault(
        "lstat", RuntimeError("/music/secret"), path=rig.quarantine))
    rig.start().step()
    rig.expect("step -> error", _JOURNALED, """
        os.mkdir .deleting/1
        os.mkdir .deleting/1/<op>
        os.replace owner/A/Album/a.flac -> .deleting/1/<op>/<uuid>.flac raises PermissionError(EACCES)
        log WARNING organizer: could not move a file: Permission denied
        worker.quarantine_state(.deleting/1/<op>/<uuid>.flac, <identity>) raises RuntimeError
        log WARNING deletion_worker: deletion rename recovery failed: RuntimeError
        db.get_deletion_journal(<key>) -> <journal intent>
        db.get_user(1) -> <user owner>
        db.read_deletion_target(<uuid>, owner_id=1) -> <live>
        recovery.check_master_path(<music>, <user owner>, owner/A/Album/a.flac) -> (ok, <stat>)
        recovery.is_journaled_file(owner/A/Album/a.flac, <identity>) -> True
        recovery.quarantine_trusted(<music>, <journal intent>) -> True
        recovery.quarantine_state(.deleting/1/<op>/<uuid>.flac, <identity>) -> free
        db.clear_deletion_journal(<key>) -> True
        db.release_deletion_item(<key>, boot_id=boot-test) -> True
        lock(<uuid>).release()
        end <uuid>: item=pending/None lease=None details=[] journal=None
        end files: [owner/A/Album/a.flac]
    """)


# ── after the move, before the commit ──────────────────────────────────────


def test_a_file_replaced_in_quarantine_right_after_the_move_is_put_back(rig):
    rig.job()
    rig.os_fault("replace", path=rig.master, then=lambda: _another_file_in_quarantine(rig))
    rig.start().step()
    rig.expect("step -> done", _JOURNALED, """
        os.mkdir .deleting/1
        os.mkdir .deleting/1/<op>
        os.replace owner/A/Album/a.flac -> .deleting/1/<op>/<uuid>.flac
        worker.is_journaled_file(.deleting/1/<op>/<uuid>.flac, <identity>) -> False
        worker.put_back_file(owner/A/Album/a.flac, .deleting/1/<op>/<uuid>.flac, prove_identity=None) -> True
        os.link .deleting/1/<op>/<uuid>.flac -> owner/A/Album/a.flac
        os.fsync owner/A/Album
        os.unlink .deleting/1/<op>/<uuid>.flac
        os.fsync .deleting/1/<op>
        os.rmdir .deleting/1/<op>
        db.clear_deletion_journal(<key>) -> True
        seam after_journal_clear
        db.finish_deletion_item(<key>, boot_id=boot-test, details=(), error_code=conflict, status=conflict, tombstone_revision=None) -> True
        lock(<uuid>).release()
        end <uuid>: item=conflict/conflict lease=boot-test details=[] journal=None
        end files: [owner/A/Album/a.flac]
    """)


def test_an_error_right_after_the_journal_write_is_released(rig):
    rig.job()
    raised = []

    def once():
        if not raised:
            raised.append(True)
            raise RuntimeError("/music/secret")

    rig.at("after_journal", once)
    rig.start().step()
    rig.expect("step -> error", _JOURNALED, """
        lock(<uuid>).release()
        log WARNING deletion_worker: deletion step failed: RuntimeError
        db.get_deletion_journal(<key>) -> <journal intent>
        lock(<uuid>).acquire(timeout=0) -> True
        db.get_user(1) -> <user owner>
        db.read_deletion_target(<uuid>, owner_id=1) -> <live>
        recovery.check_master_path(<music>, <user owner>, owner/A/Album/a.flac) -> (ok, <stat>)
        recovery.is_journaled_file(owner/A/Album/a.flac, <identity>) -> True
        recovery.quarantine_trusted(<music>, <journal intent>) -> True
        recovery.quarantine_state(.deleting/1/<op>/<uuid>.flac, <identity>) -> free
        db.clear_deletion_journal(<key>) -> True
        lock(<uuid>).release()
        db.release_deletion_item(<key>, boot_id=boot-test) -> True
        end <uuid>: item=pending/None lease=None details=[] journal=None
        end files: [owner/A/Album/a.flac]
    """)


def test_an_error_from_the_folder_flush_after_the_move_is_released(rig):
    rig.job()
    rig.os_fault("fsync", RuntimeError("/music/secret"), path=rig.quarantine.parent)
    rig.start().step()
    rig.expect("step -> error", _JOURNALED, """
        os.mkdir .deleting/1
        os.mkdir .deleting/1/<op>
        os.replace owner/A/Album/a.flac -> .deleting/1/<op>/<uuid>.flac
        worker.is_journaled_file(.deleting/1/<op>/<uuid>.flac, <identity>) -> True
        os.fsync .deleting/1/<op> raises RuntimeError
        log WARNING deletion_worker: deletion failed after the journal: RuntimeError
        db.get_deletion_journal(<key>) -> <journal intent>
        db.get_user(1) -> <user owner>
        db.read_deletion_target(<uuid>, owner_id=1) -> <live>
        recovery.check_master_path(<music>, <user owner>, owner/A/Album/a.flac) -> (missing, None)
        recovery.quarantine_trusted(<music>, <journal intent>) -> True
        recovery.quarantine_state(.deleting/1/<op>/<uuid>.flac, <identity>) -> ours
        recovery.is_journaled_file(.deleting/1/<op>/<uuid>.flac, <identity>) -> True
        db.track_path_in_use(owner/A/Album/a.flac, exclude_uuid=<uuid>, owner_id=1) -> False
        recovery.put_back_file(owner/A/Album/a.flac, .deleting/1/<op>/<uuid>.flac, in_use=<function>, prove_identity=<identity>) -> True
        db.track_path_in_use(owner/A/Album/a.flac, exclude_uuid=<uuid>, owner_id=1) -> False
        os.link .deleting/1/<op>/<uuid>.flac -> owner/A/Album/a.flac
        os.fsync owner/A/Album
        os.unlink .deleting/1/<op>/<uuid>.flac
        os.fsync .deleting/1/<op>
        os.rmdir .deleting/1/<op>
        db.clear_deletion_journal(<key>) -> True
        db.release_deletion_item(<key>, boot_id=boot-test) -> True
        lock(<uuid>).release()
        end <uuid>: item=pending/None lease=None details=[] journal=None
        end files: [owner/A/Album/a.flac]
    """)


def test_a_put_back_refused_right_after_the_move_is_released(rig):
    rig.job()
    rig.os_fault("replace", path=rig.master, then=lambda: _taken_back_and_replaced(rig))
    rig.start().step()
    rig.expect("step -> error", _JOURNALED, """
        os.mkdir .deleting/1
        os.mkdir .deleting/1/<op>
        os.replace owner/A/Album/a.flac -> .deleting/1/<op>/<uuid>.flac
        worker.is_journaled_file(.deleting/1/<op>/<uuid>.flac, <identity>) -> False
        worker.put_back_file(owner/A/Album/a.flac, .deleting/1/<op>/<uuid>.flac, prove_identity=None) -> False
        db.get_deletion_journal(<key>) -> <journal intent>
        db.get_user(1) -> <user owner>
        db.read_deletion_target(<uuid>, owner_id=1) -> <live>
        recovery.check_master_path(<music>, <user owner>, owner/A/Album/a.flac) -> (ok, <stat>)
        recovery.is_journaled_file(owner/A/Album/a.flac, <identity>) -> True
        recovery.quarantine_trusted(<music>, <journal intent>) -> True
        recovery.quarantine_state(.deleting/1/<op>/<uuid>.flac, <identity>) -> other
        db.clear_deletion_journal(<key>) -> True
        db.release_deletion_item(<key>, boot_id=boot-test) -> True
        lock(<uuid>).release()
        end <uuid>: item=pending/None lease=None details=[] journal=None
        end files: [.deleting/1/<op>/<uuid>.flac, owner/A/Album/a.flac]
    """)


# ── the commit fails ───────────────────────────────────────────────────────


def test_a_commit_refused_because_the_track_changed_puts_the_file_back(rig):
    rig.job()
    rig.at("after_moved", lambda: _bump_revision(rig))
    rig.start().step()
    rig.expect("step -> done", _MOVED, """
        db.commit_track_deletion(<key>, base_revision=1, boot_id=boot-test, details=[storage_cleanup_pending], now=1700000005, original_path=owner/A/Album/a.flac) raises DeletionRecheckFailed
        db.read_deletion_target(<uuid>, owner_id=1) -> <live>
        worker.put_back_file(owner/A/Album/a.flac, .deleting/1/<op>/<uuid>.flac, prove_identity=<identity>) -> True
        os.link .deleting/1/<op>/<uuid>.flac -> owner/A/Album/a.flac
        os.fsync owner/A/Album
        os.unlink .deleting/1/<op>/<uuid>.flac
        os.fsync .deleting/1/<op>
        os.rmdir .deleting/1/<op>
        db.clear_deletion_journal(<key>) -> True
        seam after_journal_clear
        db.finish_deletion_item(<key>, boot_id=boot-test, details=(), error_code=conflict, status=conflict, tombstone_revision=None) -> True
        lock(<uuid>).release()
        end <uuid>: item=conflict/conflict lease=boot-test details=[] journal=None
        end files: [owner/A/Album/a.flac]
    """)


def test_a_commit_that_meets_a_busy_database_puts_the_file_back(rig):
    rig.job()
    rig.db_fault("commit_track_deletion", _locked())
    rig.start().step()
    rig.expect("step -> done", _MOVED, """
        db.commit_track_deletion(<key>, base_revision=1, boot_id=boot-test, details=[storage_cleanup_pending], now=1700000005, original_path=owner/A/Album/a.flac) raises OperationalError
        log WARNING deletion_worker: deletion commit failed: OperationalError
        db.read_deletion_target(<uuid>, owner_id=1) -> <live>
        worker.put_back_file(owner/A/Album/a.flac, .deleting/1/<op>/<uuid>.flac, prove_identity=<identity>) -> True
        os.link .deleting/1/<op>/<uuid>.flac -> owner/A/Album/a.flac
        os.fsync owner/A/Album
        os.unlink .deleting/1/<op>/<uuid>.flac
        os.fsync .deleting/1/<op>
        os.rmdir .deleting/1/<op>
        db.clear_deletion_journal(<key>) -> True
        seam after_journal_clear
        db.finish_deletion_item(<key>, boot_id=boot-test, details=(), error_code=busy, status=busy, tombstone_revision=None) -> True
        lock(<uuid>).release()
        end <uuid>: item=busy/busy lease=boot-test details=[] journal=None
        end files: [owner/A/Album/a.flac]
    """)


def test_a_commit_that_fails_otherwise_puts_the_file_back_and_fails_the_target(rig):
    rig.job()
    rig.db_fault("commit_track_deletion", OSError(errno.EIO, "I/O error"))
    rig.start().step()
    rig.expect("step -> done", _MOVED, """
        db.commit_track_deletion(<key>, base_revision=1, boot_id=boot-test, details=[storage_cleanup_pending], now=1700000005, original_path=owner/A/Album/a.flac) raises OSError(EIO)
        log WARNING deletion_worker: deletion commit failed: OSError
        db.read_deletion_target(<uuid>, owner_id=1) -> <live>
        worker.put_back_file(owner/A/Album/a.flac, .deleting/1/<op>/<uuid>.flac, prove_identity=<identity>) -> True
        os.link .deleting/1/<op>/<uuid>.flac -> owner/A/Album/a.flac
        os.fsync owner/A/Album
        os.unlink .deleting/1/<op>/<uuid>.flac
        os.fsync .deleting/1/<op>
        os.rmdir .deleting/1/<op>
        db.clear_deletion_journal(<key>) -> True
        seam after_journal_clear
        db.finish_deletion_item(<key>, boot_id=boot-test, details=(), error_code=internal_error, status=failed, tombstone_revision=None) -> True
        lock(<uuid>).release()
        end <uuid>: item=failed/internal_error lease=boot-test details=[] journal=None
        end files: [owner/A/Album/a.flac]
    """)


def test_a_commit_that_landed_but_reported_an_error_is_never_rolled_back(rig):
    rig.job()
    rig.db_fault("commit_track_deletion", sqlite3.OperationalError("disk I/O error"), after=True)
    rig.start().step()
    rig.expect("step -> done", _MOVED, """
        db.commit_track_deletion(<key>, base_revision=1, boot_id=boot-test, details=[storage_cleanup_pending], now=1700000005, original_path=owner/A/Album/a.flac) raises OperationalError
        log WARNING deletion_worker: deletion commit failed: OperationalError
        db.read_deletion_target(<uuid>, owner_id=1) -> <tombstone>
        lock(<uuid>).release()
        end <uuid>: item=deleted/None lease=boot-test details=[storage_cleanup_pending] journal=committed
        end files: [.deleting/1/<op>/<uuid>.flac]
    """)


def test_a_failed_commit_whose_re_read_fails_is_released(rig):
    rig.job()
    rig.db_fault("commit_track_deletion", _locked())
    # 1 = the read without the lock, 2 = the read under it, 3 = the re-read.
    rig.db_fault("read_deletion_target", sqlite3.OperationalError("disk I/O error"), on_call=3)
    rig.start().step()
    rig.expect("step -> error", _MOVED, """
        db.commit_track_deletion(<key>, base_revision=1, boot_id=boot-test, details=[storage_cleanup_pending], now=1700000005, original_path=owner/A/Album/a.flac) raises OperationalError
        log WARNING deletion_worker: deletion commit failed: OperationalError
        db.read_deletion_target(<uuid>, owner_id=1) raises OperationalError
        log WARNING deletion_worker: deletion state re-read failed: OperationalError
        db.get_deletion_journal(<key>) -> <journal moved>
        db.get_user(1) -> <user owner>
        db.read_deletion_target(<uuid>, owner_id=1) -> <live>
        recovery.check_master_path(<music>, <user owner>, owner/A/Album/a.flac) -> (missing, None)
        recovery.quarantine_trusted(<music>, <journal moved>) -> True
        recovery.quarantine_state(.deleting/1/<op>/<uuid>.flac, <identity>) -> ours
        recovery.is_journaled_file(.deleting/1/<op>/<uuid>.flac, <identity>) -> True
        db.track_path_in_use(owner/A/Album/a.flac, exclude_uuid=<uuid>, owner_id=1) -> False
        recovery.put_back_file(owner/A/Album/a.flac, .deleting/1/<op>/<uuid>.flac, in_use=<function>, prove_identity=<identity>) -> True
        db.track_path_in_use(owner/A/Album/a.flac, exclude_uuid=<uuid>, owner_id=1) -> False
        os.link .deleting/1/<op>/<uuid>.flac -> owner/A/Album/a.flac
        os.fsync owner/A/Album
        os.unlink .deleting/1/<op>/<uuid>.flac
        os.fsync .deleting/1/<op>
        os.rmdir .deleting/1/<op>
        db.clear_deletion_journal(<key>) -> True
        db.release_deletion_item(<key>, boot_id=boot-test) -> True
        lock(<uuid>).release()
        end <uuid>: item=pending/None lease=None details=[] journal=None
        end files: [owner/A/Album/a.flac]
    """)


def test_a_failed_commit_whose_track_is_no_longer_there_is_released(rig):
    rig.job()
    rig.db_fault("commit_track_deletion", _locked())
    rig.db_fault("read_deletion_target", answer={"state": "absent"}, on_call=3)
    rig.start().step()
    rig.expect("step -> error", _MOVED, """
        db.commit_track_deletion(<key>, base_revision=1, boot_id=boot-test, details=[storage_cleanup_pending], now=1700000005, original_path=owner/A/Album/a.flac) raises OperationalError
        log WARNING deletion_worker: deletion commit failed: OperationalError
        db.read_deletion_target(<uuid>, owner_id=1) -> <absent>
        db.get_deletion_journal(<key>) -> <journal moved>
        db.get_user(1) -> <user owner>
        db.read_deletion_target(<uuid>, owner_id=1) -> <live>
        recovery.check_master_path(<music>, <user owner>, owner/A/Album/a.flac) -> (missing, None)
        recovery.quarantine_trusted(<music>, <journal moved>) -> True
        recovery.quarantine_state(.deleting/1/<op>/<uuid>.flac, <identity>) -> ours
        recovery.is_journaled_file(.deleting/1/<op>/<uuid>.flac, <identity>) -> True
        db.track_path_in_use(owner/A/Album/a.flac, exclude_uuid=<uuid>, owner_id=1) -> False
        recovery.put_back_file(owner/A/Album/a.flac, .deleting/1/<op>/<uuid>.flac, in_use=<function>, prove_identity=<identity>) -> True
        db.track_path_in_use(owner/A/Album/a.flac, exclude_uuid=<uuid>, owner_id=1) -> False
        os.link .deleting/1/<op>/<uuid>.flac -> owner/A/Album/a.flac
        os.fsync owner/A/Album
        os.unlink .deleting/1/<op>/<uuid>.flac
        os.fsync .deleting/1/<op>
        os.rmdir .deleting/1/<op>
        db.clear_deletion_journal(<key>) -> True
        db.release_deletion_item(<key>, boot_id=boot-test) -> True
        lock(<uuid>).release()
        end <uuid>: item=pending/None lease=None details=[] journal=None
        end files: [owner/A/Album/a.flac]
    """)


def test_a_failed_commit_of_a_missing_master_clears_the_journal(rig):
    rig.job(create_file=False)
    rig.db_fault("commit_track_deletion", _locked())
    rig.start().step()
    rig.expect("step -> done", _CLAIMED, """
        worker.check_master_path(<music>, <user owner>, owner/A/Album/a.flac) -> (missing, None)
        db.begin_track_deletion(<key>, base_revision=1, boot_id=boot-test, cover_art_id=None, identity=None, master_missing=True, now=1700000005, original_path=owner/A/Album/a.flac, quarantine_path=None) -> ok
        seam after_journal
        db.commit_track_deletion(<key>, base_revision=1, boot_id=boot-test, details=[master_missing, storage_cleanup_pending], now=1700000005, original_path=owner/A/Album/a.flac) raises OperationalError
        log WARNING deletion_worker: deletion commit failed: OperationalError
        db.read_deletion_target(<uuid>, owner_id=1) -> <live>
        db.clear_deletion_journal(<key>) -> True
        seam after_journal_clear
        db.finish_deletion_item(<key>, boot_id=boot-test, details=(), error_code=busy, status=busy, tombstone_revision=None) -> True
        lock(<uuid>).release()
        end <uuid>: item=busy/busy lease=boot-test details=[] journal=None
        end files: []
    """)


def test_a_failed_commit_of_a_missing_master_whose_journal_clear_fails_is_released(rig):
    rig.job(create_file=False)
    rig.db_fault("commit_track_deletion", _locked())
    rig.db_fault("clear_deletion_journal", _locked())
    rig.start().step()
    rig.expect("step -> error", _CLAIMED, """
        worker.check_master_path(<music>, <user owner>, owner/A/Album/a.flac) -> (missing, None)
        db.begin_track_deletion(<key>, base_revision=1, boot_id=boot-test, cover_art_id=None, identity=None, master_missing=True, now=1700000005, original_path=owner/A/Album/a.flac, quarantine_path=None) -> ok
        seam after_journal
        db.commit_track_deletion(<key>, base_revision=1, boot_id=boot-test, details=[master_missing, storage_cleanup_pending], now=1700000005, original_path=owner/A/Album/a.flac) raises OperationalError
        log WARNING deletion_worker: deletion commit failed: OperationalError
        db.read_deletion_target(<uuid>, owner_id=1) -> <live>
        db.clear_deletion_journal(<key>) raises OperationalError
        log WARNING deletion_worker: deletion journal clear failed: OperationalError
        db.get_deletion_journal(<key>) -> <journal intent>
        db.get_user(1) -> <user owner>
        db.read_deletion_target(<uuid>, owner_id=1) -> <live>
        db.clear_deletion_journal(<key>) -> True
        db.release_deletion_item(<key>, boot_id=boot-test) -> True
        lock(<uuid>).release()
        end <uuid>: item=pending/None lease=None details=[] journal=None
        end files: []
    """)


def test_a_failed_commit_whose_original_path_is_taken_keeps_the_journal(rig):
    rig.job()
    rig.at("after_moved", lambda: rig.master.write_bytes(b"a new import took the path"))
    rig.db_fault("commit_track_deletion", _locked())
    rig.start().step()
    rig.expect("step -> done", _MOVED, """
        db.commit_track_deletion(<key>, base_revision=1, boot_id=boot-test, details=[storage_cleanup_pending], now=1700000005, original_path=owner/A/Album/a.flac) raises OperationalError
        log WARNING deletion_worker: deletion commit failed: OperationalError
        db.read_deletion_target(<uuid>, owner_id=1) -> <live>
        worker.put_back_file(owner/A/Album/a.flac, .deleting/1/<op>/<uuid>.flac, prove_identity=<identity>) -> False
        db.get_deletion_journal(<key>) -> <journal moved>
        db.get_user(1) -> <user owner>
        db.read_deletion_target(<uuid>, owner_id=1) -> <live>
        recovery.check_master_path(<music>, <user owner>, owner/A/Album/a.flac) -> (ok, <stat>)
        recovery.is_journaled_file(owner/A/Album/a.flac, <identity>) -> False
        recovery.quarantine_trusted(<music>, <journal moved>) -> True
        recovery.quarantine_state(.deleting/1/<op>/<uuid>.flac, <identity>) -> ours
        recovery.is_journaled_file(.deleting/1/<op>/<uuid>.flac, <identity>) -> True
        db.finish_deletion_item(<key>, boot_id=boot-test, details=(), error_code=recovery_required, status=failed, tombstone_revision=None) -> True
        lock(<uuid>).release()
        end <uuid>: item=failed/recovery_required lease=boot-test details=[] journal=moved
        end files: [.deleting/1/<op>/<uuid>.flac, owner/A/Album/a.flac]
    """)


def test_a_put_back_whose_journal_clear_fails_is_released(rig):
    rig.job()
    rig.db_fault("commit_track_deletion", _locked())
    rig.db_fault("clear_deletion_journal", _locked())
    rig.start().step()
    rig.expect("step -> error", _MOVED, """
        db.commit_track_deletion(<key>, base_revision=1, boot_id=boot-test, details=[storage_cleanup_pending], now=1700000005, original_path=owner/A/Album/a.flac) raises OperationalError
        log WARNING deletion_worker: deletion commit failed: OperationalError
        db.read_deletion_target(<uuid>, owner_id=1) -> <live>
        worker.put_back_file(owner/A/Album/a.flac, .deleting/1/<op>/<uuid>.flac, prove_identity=<identity>) -> True
        os.link .deleting/1/<op>/<uuid>.flac -> owner/A/Album/a.flac
        os.fsync owner/A/Album
        os.unlink .deleting/1/<op>/<uuid>.flac
        os.fsync .deleting/1/<op>
        os.rmdir .deleting/1/<op>
        db.clear_deletion_journal(<key>) raises OperationalError
        log WARNING deletion_worker: deletion journal clear failed: OperationalError
        db.get_deletion_journal(<key>) -> <journal moved>
        db.get_user(1) -> <user owner>
        db.read_deletion_target(<uuid>, owner_id=1) -> <live>
        recovery.check_master_path(<music>, <user owner>, owner/A/Album/a.flac) -> (ok, <stat>)
        recovery.is_journaled_file(owner/A/Album/a.flac, <identity>) -> True
        recovery.quarantine_trusted(<music>, <journal moved>) -> True
        recovery.quarantine_state(.deleting/1/<op>/<uuid>.flac, <identity>) -> free
        db.clear_deletion_journal(<key>) -> True
        db.release_deletion_item(<key>, boot_id=boot-test) -> True
        lock(<uuid>).release()
        end <uuid>: item=pending/None lease=None details=[] journal=None
        end files: [owner/A/Album/a.flac]
    """)


def test_a_put_back_that_raises_keeps_the_journal(rig):
    rig.job()
    rig.db_fault("commit_track_deletion", _locked())
    rig.os_fault("link", _denied(), times=99)
    rig.start().step()
    rig.expect("step -> done", _MOVED, """
        db.commit_track_deletion(<key>, base_revision=1, boot_id=boot-test, details=[storage_cleanup_pending], now=1700000005, original_path=owner/A/Album/a.flac) raises OperationalError
        log WARNING deletion_worker: deletion commit failed: OperationalError
        db.read_deletion_target(<uuid>, owner_id=1) -> <live>
        worker.put_back_file(owner/A/Album/a.flac, .deleting/1/<op>/<uuid>.flac, prove_identity=<identity>) raises HardLinkError(EACCES)
        os.link .deleting/1/<op>/<uuid>.flac -> owner/A/Album/a.flac raises PermissionError(EACCES)
        log WARNING deletion_worker: deletion restore failed: HardLinkError
        db.get_deletion_journal(<key>) -> <journal moved>
        db.get_user(1) -> <user owner>
        db.read_deletion_target(<uuid>, owner_id=1) -> <live>
        recovery.check_master_path(<music>, <user owner>, owner/A/Album/a.flac) -> (missing, None)
        recovery.quarantine_trusted(<music>, <journal moved>) -> True
        recovery.quarantine_state(.deleting/1/<op>/<uuid>.flac, <identity>) -> ours
        recovery.is_journaled_file(.deleting/1/<op>/<uuid>.flac, <identity>) -> True
        db.track_path_in_use(owner/A/Album/a.flac, exclude_uuid=<uuid>, owner_id=1) -> False
        recovery.put_back_file(owner/A/Album/a.flac, .deleting/1/<op>/<uuid>.flac, in_use=<function>, prove_identity=<identity>) raises HardLinkError(EACCES)
        db.track_path_in_use(owner/A/Album/a.flac, exclude_uuid=<uuid>, owner_id=1) -> False
        os.link .deleting/1/<op>/<uuid>.flac -> owner/A/Album/a.flac raises PermissionError(EACCES)
        log WARNING deletion_worker: deletion journal verdict failed: HardLinkError
        db.finish_deletion_item(<key>, boot_id=boot-test, details=(), error_code=recovery_required, status=failed, tombstone_revision=None) -> True
        lock(<uuid>).release()
        end <uuid>: item=failed/recovery_required lease=boot-test details=[] journal=moved
        end files: [.deleting/1/<op>/<uuid>.flac]
    """)


# ── releases ───────────────────────────────────────────────────────────────


def test_a_fault_that_never_clears_is_released_three_times_then_ended(rig):
    rig.job()
    rig.db_fault("read_deletion_target", _locked(), times=99)
    rig.start().step(5)
    rig.expect("""
        step -> error
        db.claim_next_deletion_item(boot_id=boot-test) -> <item <uuid>>
        seam after_claim
        db.read_deletion_target(<uuid>, owner_id=1) raises OperationalError
        log WARNING deletion_worker: deletion step failed: OperationalError
        db.get_deletion_journal(<key>) -> None
        db.release_deletion_item(<key>, boot_id=boot-test) -> True
        step -> error
        db.claim_next_deletion_item(boot_id=boot-test) -> <item <uuid>>
        seam after_claim
        db.read_deletion_target(<uuid>, owner_id=1) raises OperationalError
        log WARNING deletion_worker: deletion step failed: OperationalError
        db.get_deletion_journal(<key>) -> None
        db.release_deletion_item(<key>, boot_id=boot-test) -> True
        step -> error
        db.claim_next_deletion_item(boot_id=boot-test) -> <item <uuid>>
        seam after_claim
        db.read_deletion_target(<uuid>, owner_id=1) raises OperationalError
        log WARNING deletion_worker: deletion step failed: OperationalError
        db.get_deletion_journal(<key>) -> None
        db.release_deletion_item(<key>, boot_id=boot-test) -> True
        step -> done
        db.claim_next_deletion_item(boot_id=boot-test) -> <item <uuid>>
        seam after_claim
        db.read_deletion_target(<uuid>, owner_id=1) raises OperationalError
        log WARNING deletion_worker: deletion step failed: OperationalError
        db.get_deletion_journal(<key>) -> None
        db.finish_deletion_item(<key>, boot_id=boot-test, details=(), error_code=busy, status=busy, tombstone_revision=None) -> True
        step -> idle
        db.claim_next_deletion_item(boot_id=boot-test) -> None
        end <uuid>: item=busy/busy lease=boot-test details=[] journal=None
        end files: [owner/A/Album/a.flac]
    """)


def test_a_release_that_fails_is_retried_first_by_the_next_step(rig):
    rig.job()
    rig.db_fault("read_deletion_target", _locked())
    rig.db_fault("release_deletion_item", sqlite3.OperationalError("unable to open database file"))
    rig.start().step(2)
    rig.expect("""
        step -> error
        db.claim_next_deletion_item(boot_id=boot-test) -> <item <uuid>>
        seam after_claim
        db.read_deletion_target(<uuid>, owner_id=1) raises OperationalError
        log WARNING deletion_worker: deletion step failed: OperationalError
        db.get_deletion_journal(<key>) -> None
        db.release_deletion_item(<key>, boot_id=boot-test) raises OperationalError
        log WARNING deletion_worker: deletion worker step failed: OperationalError
        step -> done
        db.get_deletion_journal(<key>) -> None
        db.release_deletion_item(<key>, boot_id=boot-test) -> True
        db.claim_next_deletion_item(boot_id=boot-test) -> <item <uuid>>
        seam after_claim
        db.read_deletion_target(<uuid>, owner_id=1) -> <live>
        lock(<uuid>).acquire(timeout=0) -> True
        db.read_deletion_target(<uuid>, owner_id=1) -> <live>
        db.get_user(1) -> <user owner>
        worker.check_master_path(<music>, <user owner>, owner/A/Album/a.flac) -> (ok, <stat>)
        db.track_path_in_use(owner/A/Album/a.flac, exclude_uuid=<uuid>, owner_id=ANY_OWNER) -> False
        db.begin_track_deletion(<key>, base_revision=1, boot_id=boot-test, cover_art_id=None, identity=<identity>, master_missing=False, now=1700000005, original_path=owner/A/Album/a.flac, quarantine_path=.deleting/1/<op>/<uuid>.flac) -> ok
        seam after_journal
        os.mkdir .deleting/1
        os.mkdir .deleting/1/<op>
        os.replace owner/A/Album/a.flac -> .deleting/1/<op>/<uuid>.flac
        worker.is_journaled_file(.deleting/1/<op>/<uuid>.flac, <identity>) -> True
        os.fsync .deleting/1/<op>
        os.fsync owner/A/Album
        seam after_rename
        db.mark_deletion_moved(<key>, now=1700000005) -> None
        seam after_moved
        db.commit_track_deletion(<key>, base_revision=1, boot_id=boot-test, details=[storage_cleanup_pending], now=1700000005, original_path=owner/A/Album/a.flac) -> 2
        seam after_commit
        lock(<uuid>).release()
        db.deletion_job_has_pending_items(operation_uuid=<op>, owner_id=1) -> False
        db.make_durable() -> True
        cache.remove_all_for_uuid(<uuid>)
        default_cache.remove_all_for_uuid(<uuid>)
        seam after_evict
        os.unlink .deleting/1/<op>/<uuid>.flac
        seam after_unlink
        os.rmdir owner/A/Album
        os.rmdir owner/A
        os.rmdir .deleting/1/<op>
        db.finish_deletion_cleanup(<key>, details=[]) -> None
        end <uuid>: item=deleted/None lease=boot-test details=[] journal=None
        end files: []
    """)


# ── the error a release carries ────────────────────────────────────────────
#
# A target is put back to pending at most three times in one run; the fourth
# time, the error that led to that release ends it: ``busy`` for a busy
# database, ``failed:internal_error`` otherwise. Each test repeats one fault on
# every step, at one place that keeps the journal and releases, and checks
# which error that place carried.


def _run_to_the_end(rig):
    rig.start()
    for _ in range(6):
        rig.step()
        if rig.outcome()[0] not in ("pending", "running"):
            break
    assert rig.count("db.release_deletion_item(") == 3
    return rig.outcome()


def _eio():
    return OSError(errno.EIO, "I/O error")


def test_at_the_cap_a_failed_re_read_ends_the_target_by_its_own_error(rig):
    rig.job()
    rig.db_fault("commit_track_deletion", _eio(), times=99)
    rig.at("after_moved", lambda: rig.db_fault("read_deletion_target", _locked()))
    assert _run_to_the_end(rig) == ("busy", "busy")


def test_at_the_cap_a_track_no_longer_there_ends_the_target_by_the_commits_error(rig):
    rig.job()
    rig.db_fault("commit_track_deletion", _locked(), times=99)
    rig.at("after_moved", lambda: rig.db_fault("read_deletion_target", answer={"state": "absent"}))
    assert _run_to_the_end(rig) == ("busy", "busy")


def test_at_the_cap_a_put_back_that_raised_ends_the_target_by_its_own_error(rig):
    rig.job()
    rig.db_fault("commit_track_deletion", _locked(), times=99)
    rig.at("after_moved", lambda: rig.os_fault("link", _denied()))
    assert _run_to_the_end(rig) == ("failed", "internal_error")


def test_at_the_cap_a_missing_masters_failed_journal_clear_ends_by_the_commits_error(rig):
    rig.job(create_file=False)
    rig.db_fault("commit_track_deletion", _locked(), times=99)
    rig.at("after_claim", lambda: rig.db_fault("clear_deletion_journal", _locked()))
    assert _run_to_the_end(rig) == ("busy", "busy")


def test_at_the_cap_a_refused_put_back_ends_the_target_by_the_commits_error(rig):
    rig.job()
    rig.db_fault("commit_track_deletion", _locked(), times=99)
    # The same file appears at the original path: the put-back refuses to
    # replace it, and the verdict then finds the master back and clears.
    rig.at("after_moved", lambda: _REAL_LINK(rig.quarantine, rig.master))
    assert _run_to_the_end(rig) == ("busy", "busy")


def test_at_the_cap_a_put_backs_failed_journal_clear_ends_by_the_commits_error(rig):
    rig.job()
    rig.db_fault("commit_track_deletion", _locked(), times=99)
    rig.at("after_moved", lambda: rig.db_fault("clear_deletion_journal", _locked()))
    assert _run_to_the_end(rig) == ("busy", "busy")


def test_at_the_cap_an_error_after_the_journal_ends_the_target_by_that_error(rig):
    rig.job()

    def busy():
        raise _locked()

    rig.at("after_rename", busy)
    assert _run_to_the_end(rig) == ("busy", "busy")


def test_at_the_cap_a_refused_move_that_was_released_ends_the_target_failed(rig):
    rig.job()
    rig.os_fault("replace", _denied(), path=rig.master, times=99)
    rig.at("after_journal", lambda: rig.db_fault("clear_deletion_journal", _locked()))
    assert _run_to_the_end(rig) == ("failed", "internal_error")


def test_at_the_cap_a_put_back_refused_after_our_own_move_ends_the_target_failed(rig):
    rig.job()
    rig.os_fault("replace", path=rig.master, times=99,
                 then=lambda: _taken_back_and_replaced(rig))
    # The stray file of the step before is taken away, so the next move goes through.
    rig.at("after_claim", lambda: os.path.lexists(rig.quarantine) and _REAL_UNLINK(rig.quarantine))
    assert _run_to_the_end(rig) == ("failed", "internal_error")


# ── the storage cleanup after the commit ───────────────────────────────────


def test_a_quarantined_file_replaced_before_the_cleanup_is_never_removed(rig):
    rig.job()
    rig.at("after_commit", lambda: _another_file_in_quarantine(rig))
    rig.start().step()
    rig.expect("step -> done", _MOVED, """
        db.commit_track_deletion(<key>, base_revision=1, boot_id=boot-test, details=[storage_cleanup_pending], now=1700000005, original_path=owner/A/Album/a.flac) -> 2
        seam after_commit
        lock(<uuid>).release()
        db.deletion_job_has_pending_items(operation_uuid=<op>, owner_id=1) -> False
        db.make_durable() -> True
        cache.remove_all_for_uuid(<uuid>)
        default_cache.remove_all_for_uuid(<uuid>)
        seam after_evict
        end <uuid>: item=deleted/None lease=boot-test details=[storage_cleanup_pending] journal=committed
        end files: [.deleting/1/<op>/<uuid>.flac]
    """)


def test_a_failed_cleanup_is_finished_by_the_janitor_pass(rig):
    rig.job(cover_art_id=add_art(rig.world, "cover"))
    rig.start()
    rig.cache.fail = True
    rig.step()
    rig.cache.fail = False
    rig.janitor_pass()
    rig.expect("step -> done", _CLAIMED, """
        worker.check_master_path(<music>, <user owner>, owner/A/Album/a.flac) -> (ok, <stat>)
        db.track_path_in_use(owner/A/Album/a.flac, exclude_uuid=<uuid>, owner_id=ANY_OWNER) -> False
        db.begin_track_deletion(<key>, base_revision=1, boot_id=boot-test, cover_art_id=1, identity=<identity>, master_missing=False, now=1700000005, original_path=owner/A/Album/a.flac, quarantine_path=.deleting/1/<op>/<uuid>.flac) -> ok
        seam after_journal
        os.mkdir .deleting/1
        os.mkdir .deleting/1/<op>
        os.replace owner/A/Album/a.flac -> .deleting/1/<op>/<uuid>.flac
        worker.is_journaled_file(.deleting/1/<op>/<uuid>.flac, <identity>) -> True
        os.fsync .deleting/1/<op>
        os.fsync owner/A/Album
        seam after_rename
        db.mark_deletion_moved(<key>, now=1700000005) -> None
        seam after_moved
        db.commit_track_deletion(<key>, base_revision=1, boot_id=boot-test, details=[storage_cleanup_pending], now=1700000005, original_path=owner/A/Album/a.flac) -> 2
        seam after_commit
        lock(<uuid>).release()
        db.deletion_job_has_pending_items(operation_uuid=<op>, owner_id=1) -> False
        db.make_durable() -> True
        cache.remove_all_for_uuid(<uuid>) raises OSError
        log WARNING deletion_worker: deletion storage cleanup incomplete: OSError
        janitor.retry_cleanups -> None
        db.list_deletion_journals(stages=(intent, moved)) -> []
        db.reclaim_deletion_items(boot_id=boot-test) -> 0
        db.list_deletion_journals(stages=(committed)) -> [<journal committed>]
        db.get_user(1) -> <user owner>
        db.read_deletion_target(<uuid>, owner_id=1) -> <tombstone>
        recovery.quarantine_trusted(<music>, <journal committed>) -> True
        recovery.quarantine_state(.deleting/1/<op>/<uuid>.flac, <identity>) -> ours
        recovery.is_journaled_file(.deleting/1/<op>/<uuid>.flac, <identity>) -> True
        db.make_durable() -> True
        cache.remove_all_for_uuid(<uuid>)
        default_cache.remove_all_for_uuid(<uuid>)
        seam after_evict
        cover_art.release_if_unreferenced(1) -> True
        os.unlink <tmp>/art/cover.jpg
        os.unlink .deleting/1/<op>/<uuid>.flac
        seam after_unlink
        os.rmdir owner/A/Album
        os.rmdir owner/A
        os.rmdir .deleting/1/<op>
        db.finish_deletion_cleanup(<key>, details=[]) -> None
        log INFO uvicorn.error: 1 committed deletion cleanup(s) were retried.
        end <uuid>: item=deleted/None lease=boot-test details=[] journal=None
        end files: []
    """)


def test_a_failed_cleanup_of_a_missing_master_is_finished_by_the_janitor_pass(rig):
    rig.job(create_file=False)
    rig.start()
    rig.cache.fail = True
    rig.step()
    rig.cache.fail = False
    rig.janitor_pass()
    rig.expect("step -> done", _CLAIMED, """
        worker.check_master_path(<music>, <user owner>, owner/A/Album/a.flac) -> (missing, None)
        db.begin_track_deletion(<key>, base_revision=1, boot_id=boot-test, cover_art_id=None, identity=None, master_missing=True, now=1700000005, original_path=owner/A/Album/a.flac, quarantine_path=None) -> ok
        seam after_journal
        db.commit_track_deletion(<key>, base_revision=1, boot_id=boot-test, details=[master_missing, storage_cleanup_pending], now=1700000005, original_path=owner/A/Album/a.flac) -> 2
        seam after_commit
        lock(<uuid>).release()
        db.deletion_job_has_pending_items(operation_uuid=<op>, owner_id=1) -> False
        db.make_durable() -> True
        cache.remove_all_for_uuid(<uuid>) raises OSError
        log WARNING deletion_worker: deletion storage cleanup incomplete: OSError
        janitor.retry_cleanups -> None
        db.list_deletion_journals(stages=(intent, moved)) -> []
        db.reclaim_deletion_items(boot_id=boot-test) -> 0
        db.list_deletion_journals(stages=(committed)) -> [<journal committed>]
        db.get_user(1) -> <user owner>
        db.read_deletion_target(<uuid>, owner_id=1) -> <tombstone>
        db.make_durable() -> True
        cache.remove_all_for_uuid(<uuid>)
        default_cache.remove_all_for_uuid(<uuid>)
        seam after_evict
        os.rmdir owner/A/Album raises FileNotFoundError(ENOENT)
        db.finish_deletion_cleanup(<key>, details=[master_missing]) -> None
        log INFO uvicorn.error: 1 committed deletion cleanup(s) were retried.
        end <uuid>: item=deleted/None lease=boot-test details=[master_missing] journal=None
        end files: []
    """)
