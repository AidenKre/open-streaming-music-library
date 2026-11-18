"""Phase 8 server deletion: the deletion worker and the execution of one target
(spec §5 "Per-target execution"; piece 8A.3c)."""

import enum
import logging
import os
import re
import stat
import time
from dataclasses import dataclass, replace
from pathlib import Path

from app.core.durable_fs import fsync_dir
from app.core.sqlite_busy import is_sqlite_busy
from app.database.database import ANY_OWNER, DeletionRecheckFailed
from app.library import Library, library_root
from app.services import file_ops
from app.services.encoded_cache import evict_track_caches
from app.services.journal_recovery import finish_track_journal_rows
# The master-path judgements live in master_paths.py; they are still
# importable from here.
from app.services.master_paths import (  # noqa: F401
    check_master_in_root,
    check_master_path,
    is_journaled_file,
    master_exists_in_root,
    put_back_file,
    quarantine_dir,
    quarantine_state,
)
from app.services.path_sanitize import PathEscapesRoot, assert_within
from app.services.worker_thread import PollingWorkerThread

logger = logging.getLogger(__name__)
_EXTENSION = re.compile(r"^\.[A-Za-z0-9]{1,16}$")


_MAX_RELEASES = 3

# The outcome of a target whose deletion was undone (the file put back), by
# reason: (status, error code).
_UNDONE_OUTCOME = {
    "conflict": ("conflict", "conflict"),
    "busy": ("busy", "busy"),
    "internal_error": ("failed", "internal_error"),
}


def _key(item) -> tuple:
    return item["owner_id"], item["operation_uuid"], item["uuid_id"]


@dataclass(frozen=True, kw_only=True)
class _Deletion:
    """One target's deletion in progress, as its journal row names it."""

    item: dict  # the claimed item: owner_id, operation_uuid, uuid_id
    key: dict  # the journal row's key: the same three values
    original: Path  # the master's path, as the track row stores it
    quarantine: Path | None  # where the master is moved to; None: the master is missing
    identity: tuple | None  # (device, inode, size) of the journaled master; None: missing
    cause: Exception | None = None  # the error that made the commit fail, once it has


class RunResult(enum.Enum):
    """What one ``DeletionExecutor.run_one`` step did."""

    IDLE = "idle"  # nothing was pending
    DONE = "done"  # a target was worked on and is not back in the queue
    RELEASED = "released"  # the target went back to pending: wait before the next claim

    def __bool__(self) -> bool:
        """False only for ``IDLE``, so ``while executor.run_one():`` runs until
        nothing is pending."""
        return self is not RunResult.IDLE


class DeletionExecutor:
    def __init__(self, database, *, music_library_dir, track_locks, cover_art, cache,
                 default_cache, boot_id, lock_timeout_s=2.0, clock=time.time, seam=None,
                 pending_old_masters=None, identity_signal=None):
        self._database = database
        self._music_library_dir = music_library_dir
        self._track_locks = track_locks
        self._cover_art = cover_art
        self._cache = cache
        self._default_cache = default_cache
        self._boot_id = boot_id
        self._lock_timeout_s = lock_timeout_s
        self._clock = clock
        self._seam = seam
        # The server's one registry of old files kept after a failed flush (shared
        # with the tag editor and the conversion) and the identity worker's
        # wake-up; without the registry a kept row whose old file is still there
        # waits, as before.
        self._pending_old_masters = pending_old_masters
        self._identity_signal = identity_signal
        self._releases: dict[tuple, int] = {}
        # key -> (item, the error that led to its failed release)
        self._unreleased: dict[tuple, tuple[dict, Exception]] = {}
        # (job key, cleanup closure) of committed deletions waiting for a durable point.
        self._deferred: list[tuple[tuple, object]] = []

    @property
    def track_locks(self):
        return self._track_locks

    def durable_point(self) -> bool:
        """True when every committed catalog transaction is on disk."""
        try:
            return bool(self._database.make_durable())
        except Exception as exc:  # never BaseException: a simulated kill escapes
            logger.warning("deletion durable point failed: %s", type(exc).__name__)
            return False

    def flush_cleanups(self) -> None:
        """Run the deferred cleanups after one durable point. Without it they are
        dropped; their committed journals stay for the janitor."""
        batch, self._deferred = self._deferred, []
        if not batch:
            return
        if not self.durable_point():
            logger.warning("deletion storage cleanup waits for a durable database")
            return
        for _job, cleanup in batch:
            cleanup()

    def _at(self, name: str) -> None:
        """Test-only hook; a test may raise from it (only Exception is ever caught here)."""
        if self._seam is not None:
            self._seam(name)

    def run_one(self) -> RunResult:
        # A release that failed earlier is retried first; a failure here makes
        # this an error step.
        # The error that led to the failed release still decides its outcome.
        for key, (pending, cause) in list(self._unreleased.items()):
            self._release(pending, held=False, cause=cause)
            del self._unreleased[key]
        item = self._database.claim_next_deletion_item(boot_id=self._boot_id)
        if self._deferred and (
            item is None
            or any(
                job != (item["owner_id"], item["operation_uuid"])
                for job, _cleanup in self._deferred
            )
        ):
            self.flush_cleanups()
        if item is None:
            return RunResult.IDLE
        try:
            self._at("after_claim")
            outcome = self.execute(item)  # "pending": a keep site requeued it
        except Exception as exc:  # never BaseException: a simulated kill escapes
            logger.warning("deletion step failed: %s", type(exc).__name__)
            try:
                outcome = self._release(item, held=False, cause=exc)
            except Exception:
                self._unreleased[_key(item)] = (item, exc)
                raise
        if outcome == "pending":
            return RunResult.RELEASED  # the worker backs off before re-claiming
        return RunResult.DONE

    def _release(self, item, *, held: bool, cause: Exception | None = None) -> str:
        """The one release rule, deciding from persisted state only: no journal
        -> requeue; committed -> nothing; an uncommitted journal -> the startup
        verdict (cleared -> requeue, else failed:recovery_required). ``cause``
        is the error that led to the release (None: none), for ``_requeue``."""
        # Deferred: deletion_recovery imports this module.
        from app.services.deletion_recovery import settle_uncommitted_journal

        key = dict(
            owner_id=item["owner_id"],
            operation_uuid=item["operation_uuid"],
            uuid_id=item["uuid_id"],
        )
        row = self._database.get_deletion_journal(**key)
        if row is None:
            return self._requeue(item, cause)
        if row["stage"] == "committed":
            return "deleted"
        try:
            cleared = settle_uncommitted_journal(
                self._database,
                row,
                music_library_dir=self._music_library_dir,
                track_locks=self._track_locks,
                lock_timeout_s=self._lock_timeout_s,
                held=held,
            )
        except Exception as exc:
            logger.warning("deletion journal verdict failed: %s", type(exc).__name__)
            cleared = False
        if cleared:
            return self._requeue(item, cause)
        return self._finish(item, "failed", error="recovery_required")

    def _requeue(self, item, cause: Exception | None) -> str:
        """Back to pending, at most ``_MAX_RELEASES`` times in one run (never a
        hot loop). Then the last release's error decides: ``busy`` only for a
        busy database, otherwise ``failed:internal_error``."""
        key = _key(item)
        if self._releases.get(key, 0) >= _MAX_RELEASES:
            reason = "busy" if is_sqlite_busy(cause) else "internal_error"
            return self._finish_undone(item, reason)
        self._database.release_deletion_item(
            owner_id=item["owner_id"],
            operation_uuid=item["operation_uuid"],
            uuid_id=item["uuid_id"],
            boot_id=self._boot_id,
        )
        self._releases[key] = self._releases.get(key, 0) + 1
        return "pending"

    def settle_kept_journals(self) -> None:
        """Re-judge every uncommitted journal (the worker's periodic pass)."""
        from app.services.deletion_recovery import reconcile_deletion_journals

        reconcile_deletion_journals(
            self._database,
            music_library_dir=self._music_library_dir,
            track_locks=self._track_locks,
            boot_id=self._boot_id,
            log_kept=False,
        )
        # Items left running by an old boot whose journal is now gone.
        self._database.reclaim_deletion_items(boot_id=self._boot_id)

    def execute(self, item: dict) -> str:
        """Revalidate and execute one claimed target; returns its final status.
        The storage cleanup of a committed deletion runs after the track lock
        is released."""
        # Ownership first, lock-free: a foreign or unknown uuid must neither
        # wait on nor create a track lock (SC-28 existence oracle).
        facts = self._database.read_deletion_target(
            item["uuid_id"], owner_id=item["owner_id"]
        )
        if facts["state"] == "absent":
            return self._finish(item, "failed", error="not_found")
        if facts["state"] == "tombstone":
            return self._finish(
                item, "already_deleted", tombstone_revision=facts["revision"]
            )
        lock = self._track_locks.lock_for(item["uuid_id"])
        # A short bounded wait, never an unbounded one under another lock (O10).
        if not lock.acquire(timeout=self._lock_timeout_s):
            return self._finish(item, "busy", error="busy")
        try:
            status, cleanup = self._execute_locked(item)
        finally:
            lock.release()
        if cleanup is not None:
            job = (item["owner_id"], item["operation_uuid"])
            self._deferred.append((job, cleanup))
            try:
                pending = self._database.deletion_job_has_pending_items(
                    owner_id=job[0], operation_uuid=job[1]
                )
            except Exception:
                pending = False
            if not pending:
                self.flush_cleanups()
        return status

    def _read_target(self, uuid_id: str, owner: int) -> dict:
        """The target's facts, read under its lock. A finished edit or
        conversion can have left its journal row behind (its old file waits for
        a database flush): such rows are finished first, as an edit and a
        conversion do under this lock, so they do not make the track read busy.
        A row that cannot be finished stays, and the track stays busy."""
        facts = self._database.read_deletion_target(uuid_id, owner_id=owner)
        if (
            facts["state"] == "live"
            and facts["busy"]
            and not self._database.is_pending_deletion(uuid_id, owner_id=owner)
            and self._database.has_journal_entry_for_uuid(uuid_id, owner_id=owner)
        ):
            finish_track_journal_rows(
                Library(self._database, owner), uuid_id, self._music_library_dir,
                self._identity_signal, self._pending_old_masters,
            )
            facts = self._database.read_deletion_target(uuid_id, owner_id=owner)
        return facts

    def _execute_locked(self, item: dict):
        uuid_id, owner = item["uuid_id"], item["owner_id"]
        facts = self._read_target(uuid_id, owner)
        if facts["state"] == "tombstone":
            return self._finish(
                item, "already_deleted", tombstone_revision=facts["revision"]
            ), None
        if facts["state"] == "absent":
            return self._finish(item, "failed", error="not_found"), None
        if facts["revision"] != item["base_revision"]:
            return self._finish(item, "conflict", error="conflict"), None
        if facts["busy"]:
            return self._finish(item, "busy", error="busy"), None
        return self._delete_live(item, facts)

    def _delete_live(self, item: dict, facts: dict):
        owner = item["owner_id"]
        user = self._database.get_user(owner)
        verdict, st = check_master_path(
            self._music_library_dir, user, facts["file_path"]
        )
        if verdict == "rejected":
            return self._finish(item, "failed", error="path_rejected"), None
        missing = verdict == "missing"
        # Another track's row names this path, in any owner's library and in
        # any spelling a caseless disk reads as the same name: the file there
        # is not this track's to move or unlink. Only the catalog entry goes,
        # as for a missing master.
        if not missing and self._database.track_path_in_use(
            facts["file_path"], owner_id=ANY_OWNER, exclude_uuid=item["uuid_id"]
        ):
            missing = True
        original = Path(facts["file_path"])
        owner_quarantine = quarantine_dir(self._music_library_dir, owner)
        suffix = original.suffix if _EXTENSION.match(original.suffix) else ""
        quarantine = (
            owner_quarantine / item["operation_uuid"] / f"{item['uuid_id']}{suffix}"
        )
        identity = None
        if missing:
            quarantine = None  # no file to move: the journal names no quarantine
        else:
            try:
                assert_within(quarantine, owner_quarantine)
            except PathEscapesRoot:
                return self._finish(item, "failed", error="path_rejected"), None
            identity = (st.st_dev, st.st_ino, st.st_size)
        key = dict(
            owner_id=owner,
            operation_uuid=item["operation_uuid"],
            uuid_id=item["uuid_id"],
        )
        deletion = _Deletion(
            item=item, key=key, original=original, quarantine=quarantine, identity=identity
        )
        begun = self._database.begin_track_deletion(
            **key,
            boot_id=self._boot_id,
            base_revision=item["base_revision"],
            original_path=facts["file_path"],  # as stored (8-R1-08)
            quarantine_path=None if missing else str(quarantine),
            identity=identity,
            cover_art_id=facts["cover_art_id"],
            master_missing=missing,
            now=int(self._clock()),
        )
        if begun == "gone":
            return "gone", None
        if begun in ("conflict", "busy"):
            return self._finish(item, begun, error=begun), None
        self._at("after_journal")
        final_details = ["master_missing"] if missing else []
        try:
            if not missing:
                try:
                    moved = file_ops.move_file(original, quarantine)
                except Exception as exc:
                    # A raise (e.g. EACCES while looking at the paths) is a failed move.
                    logger.warning("deletion move failed: %s", type(exc).__name__)
                    moved = False
                if not moved:
                    return self._rename_failed(deletion), None
                if not is_journaled_file(quarantine, identity):
                    # Replaced by an outside rename after our lstat: commit
                    # nothing and put back what this call just moved.
                    return self._put_back(deletion, "conflict", prove_identity=None), None
                fsync_dir(quarantine.parent)
                fsync_dir(original.parent)
                self._at("after_rename")
                try:
                    self._database.mark_deletion_moved(**key, now=int(self._clock()))
                except Exception as exc:
                    # The stage update is advisory: recovery reads the files.
                    logger.warning("deletion stage update failed: %s", type(exc).__name__)
                self._at("after_moved")
            try:
                self._database.commit_track_deletion(
                    **key,
                    boot_id=self._boot_id,
                    base_revision=item["base_revision"],
                    original_path=facts["file_path"],  # as stored (8-R1-08)
                    details=[*final_details, "storage_cleanup_pending"],
                    now=int(self._clock()),
                )
            except Exception as exc:
                if isinstance(exc, DeletionRecheckFailed):
                    reason = "conflict"
                else:
                    reason = "busy" if is_sqlite_busy(exc) else "internal_error"
                    logger.warning("deletion commit failed: %s", type(exc).__name__)
                return self._after_failed_commit(replace(deletion, cause=exc), reason), None
        except Exception as exc:
            logger.warning("deletion failed after the journal: %s", type(exc).__name__)
            return self._release_held(item, cause=exc), None
        self._at("after_commit")

        def cleanup():
            self._cleanup(deletion, facts["cover_art_id"], user, final_details)

        return "deleted", cleanup

    def _clear_journal(self, key) -> bool:
        try:
            return bool(self._database.clear_deletion_journal(**key))
        except Exception as exc:
            logger.warning("deletion journal clear failed: %s", type(exc).__name__)
            return False

    def _release_held(self, item, cause: Exception | None = None):
        """A designed keep site (the track lock is held): the one release rule,
        so the item is requeued, left deleted, or ended
        ``failed:recovery_required``, as ``_release`` decides. ``cause`` is the
        error that led here, if any. A failing outcome write propagates to
        ``run_one``."""
        return self._release(item, held=True, cause=cause)

    def _rename_failed(self, deletion: _Deletion) -> str:
        """The move into quarantine failed: nothing moved. Clear the journal only
        when the master is verifiably still the journaled file and the quarantine
        path is proven not to hold it. Unknown is never "not ours"."""
        cleared = False
        try:
            state = quarantine_state(deletion.quarantine, deletion.identity)
            if state in ("free", "other") and is_journaled_file(
                deletion.original, deletion.identity
            ):
                if self._clear_journal(deletion.key):
                    cleared = True
                    try:
                        os.rmdir(deletion.quarantine.parent)
                    except OSError:
                        pass
        except Exception as exc:
            logger.warning("deletion rename recovery failed: %s", type(exc).__name__)
        if not cleared:
            return self._release_held(deletion.item)
        self._at("after_journal_clear")
        return self._finish(deletion.item, "failed", error="rename")

    def _after_failed_commit(self, deletion: _Deletion, reason) -> str:
        """The commit raised ``deletion.cause``. It may still have landed:
        re-read first, and only a track that is still live may be restored. A
        keep site on this path releases with that cause (or a newer error it
        caught)."""
        item = deletion.item
        try:
            facts = self._database.read_deletion_target(
                item["uuid_id"], owner_id=item["owner_id"]
            )
        except Exception as exc:
            logger.warning("deletion state re-read failed: %s", type(exc).__name__)
            return self._release_held(item, cause=exc)
        if facts["state"] == "tombstone":
            return "deleted"  # committed: never rolled back; cleanup is recovery's
        if facts["state"] != "live":
            return self._release_held(item, cause=deletion.cause)
        try:
            return self._restore_after_failed_commit(deletion, reason)
        except Exception as exc:
            logger.warning("deletion restore failed: %s", type(exc).__name__)
            return self._release_held(item, cause=exc)

    def _restore_after_failed_commit(self, deletion: _Deletion, reason) -> str:
        """Put the same file back, never replacing anything at the original path,
        and only when the quarantined file is the journaled one. Otherwise keep
        the journal (the track stays hidden)."""
        if deletion.quarantine is None:
            # A missing master: there is no file to restore.
            if self._clear_journal(deletion.key):
                self._at("after_journal_clear")
                return self._finish_undone(deletion.item, reason)
            return self._release_held(deletion.item, cause=deletion.cause)
        return self._put_back(deletion, reason, prove_identity=deletion.identity)

    def _put_back(self, deletion: _Deletion, reason, *, prove_identity) -> str:
        """The one link-back: return the quarantined file to the original path
        without replacing anything. After a failed commit the quarantined file
        and the restored one must both be the journaled identity
        (``prove_identity``); right after our own move there is no such
        requirement, because the file is the one this call just moved.
        ``deletion.cause`` is the error that led here (None: none), for a
        keep site."""
        if not put_back_file(
            deletion.original, deletion.quarantine, prove_identity=prove_identity
        ):
            return self._release_held(deletion.item, cause=deletion.cause)
        if not self._clear_journal(deletion.key):
            return self._release_held(deletion.item, cause=deletion.cause)
        self._at("after_journal_clear")
        return self._finish_undone(deletion.item, reason)

    def _finish_undone(self, item, reason) -> str:
        """End a target whose deletion did not happen, by ``reason`` (one of
        ``_UNDONE_OUTCOME``)."""
        status, error = _UNDONE_OUTCOME[reason]
        return self._finish(item, status, error=error)

    def finish_committed(self, row, user) -> None:
        """Finish the post-commit cleanup of a committed journal row (startup
        recovery). The caller has already checked the row's paths; ``_cleanup``
        keeps its own identity proof before the unlink."""
        missing = row["master_missing"] == 1
        key = dict(
            owner_id=row["owner_id"],
            operation_uuid=row["operation_uuid"],
            uuid_id=row["uuid_id"],
        )
        identity = (
            None
            if row["src_dev"] is None
            else (row["src_dev"], row["src_ino"], row["src_size"])
        )
        deletion = _Deletion(
            item=dict(key),
            key=key,
            original=Path(row["original_path"]),
            quarantine=None if missing else Path(row["quarantine_path"]),
            identity=identity,
        )
        self._cleanup(
            deletion, row["cover_art_id"], user, ["master_missing"] if missing else []
        )

    def _cleanup(self, deletion: _Deletion, cover_art_id, user, final_details):
        """Post-commit storage cleanup. A failure leaves the committed journal
        for a retry; the deletion stays logically committed."""
        quarantine = deletion.quarantine
        try:
            evict_track_caches(deletion.item["uuid_id"], self._cache, self._default_cache)
            self._at("after_evict")
            if cover_art_id is not None:
                self._cover_art.release_if_unreferenced(cover_art_id)
            if quarantine is not None:
                try:
                    st = os.lstat(quarantine)
                except FileNotFoundError:
                    pass
                else:
                    if not stat.S_ISREG(st.st_mode) or (
                        st.st_dev, st.st_ino, st.st_size
                    ) != deletion.identity[:3]:
                        return
                    os.unlink(quarantine)
                self._at("after_unlink")
            root = library_root(self._music_library_dir, user)
            file_ops.prune_empty_dirs(deletion.original.parent, root)
            if quarantine is not None:
                try:
                    os.rmdir(quarantine.parent)
                except OSError:
                    pass
            self._database.finish_deletion_cleanup(**deletion.key, details=final_details)
        except Exception as exc:
            logger.warning("deletion storage cleanup incomplete: %s", type(exc).__name__)

    def _finish(self, item, status, *, error=None, tombstone_revision=None, details=()):
        self._database.finish_deletion_item(
            owner_id=item["owner_id"],
            operation_uuid=item["operation_uuid"],
            uuid_id=item["uuid_id"],
            boot_id=self._boot_id,
            status=status,
            error_code=error,
            tombstone_revision=tombstone_revision,
            details=details,
        )
        return status


class DeletionWorker(PollingWorkerThread):
    """Executes accepted deletion jobs, one target per step, until stopped."""

    thread_name = "deletion worker"

    def __init__(self, executor, *, idle_poll_s, janitor=None, janitor_interval_s=None,
                 clock=time.monotonic):
        super().__init__(idle_poll_s=idle_poll_s)
        self._executor = executor
        self._janitor = janitor
        self._janitor_interval_s = janitor_interval_s
        self._clock = clock
        # Startup already ran a pass, so the first periodic one is an interval away.
        self._janitor_due = clock() + janitor_interval_s if janitor is not None else None

    # What the shared polling base is told for each result of a step: it waits
    # its idle interval after "idle" and "error".
    _OUTCOME = {RunResult.IDLE: "idle", RunResult.DONE: "done", RunResult.RELEASED: "error"}

    def process_one(self):
        try:
            outcome = self._OUTCOME[self._executor.run_one()]
        except Exception as exc:
            # One escaping would end the thread; the item's own state says why.
            logger.warning("deletion worker step failed: %s", type(exc).__name__)
            outcome = "error"
        if outcome == "done":
            return outcome
        # An idle or error step waits; a due pass runs first, so a fault that
        # keeps every step failing does not stop the janitor until a restart.
        self._run_due_pass()
        return outcome

    def _run_due_pass(self) -> None:
        if self._janitor is not None and self._clock() >= self._janitor_due:
            try:
                self._janitor.retry_cleanups()
            except Exception as exc:
                logger.warning("deletion janitor pass failed: %s", type(exc).__name__)
            self._janitor_due = self._clock() + self._janitor_interval_s
