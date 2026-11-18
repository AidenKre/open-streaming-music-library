"""Phase 8 server deletion: the deletion worker and the execution of one target
(spec §5 "Per-target execution"; piece 8A.3c)."""

import logging
import os
import re
import stat
import time
from pathlib import Path

from app.core.durable_fs import fsync_dir
from app.core.sqlite_busy import is_sqlite_busy
from app.core.internal_dirs import DELETING
from app.database.database import DeletionRecheckFailed
from app.library import library_root
from app.services import organizer
from app.services.encoded_cache import evict_track_caches
from app.services.path_sanitize import PathEscapesRoot, assert_within
from app.services.worker_thread import PollingWorkerThread

logger = logging.getLogger(__name__)
_EXTENSION = re.compile(r"^\.[A-Za-z0-9]{1,16}$")


def check_master_path(music_library_dir, user, file_path):
    """Judge a stored master path without touching anything: ("ok", lstat),
    ("missing", None) or ("rejected", None). A symlink or non-regular file on the
    way is rejected; an unknown error is never "missing"."""
    if user is None:
        return "rejected", None
    try:
        root = library_root(music_library_dir, user)
    except (PathEscapesRoot, OSError):
        return "rejected", None
    return check_master_in_root(root, file_path)


def check_master_in_root(root, file_path):
    """The one master-present judgement (worker, recovery, preview, duplicates)
    against the owner's library root; same answers as ``check_master_path``."""
    if root is None:
        return "rejected", None
    root = Path(root)
    try:
        root_stat = os.lstat(root)
    except OSError:
        return "rejected", None
    if not stat.S_ISDIR(root_stat.st_mode):
        return "rejected", None
    path = Path(file_path)
    parts = None
    for base in (root, Path(os.path.realpath(root))):
        if path.is_relative_to(base):
            parts = path.relative_to(base).parts
            break
    if not parts or any(part in ("", ".", "..") for part in parts):
        return "rejected", None
    current = root
    for index, part in enumerate(parts):
        current = current / part
        try:
            st = os.lstat(current)
        except FileNotFoundError:
            return "missing", None
        except OSError:
            return "rejected", None
        if stat.S_ISLNK(st.st_mode):
            return "rejected", None
        last = index == len(parts) - 1
        if not (stat.S_ISREG(st.st_mode) if last else stat.S_ISDIR(st.st_mode)):
            return "rejected", None
    try:
        assert_within(file_path, root)
    except PathEscapesRoot:
        return "rejected", None
    return "ok", st


def master_exists_in_root(root, file_path):
    """``check_master_in_root`` as a three-valued existence plus its lstat:
    (True, lstat) when present, (False, None) when missing, and (None, None)
    when the server refused to judge it. Unknown is never "missing"."""
    verdict, st = check_master_in_root(root, file_path)
    if verdict == "ok":
        return True, st
    if verdict == "missing":
        return False, None
    return None, None


def is_journaled_file(path, identity) -> bool:
    """True only when ``path`` is, by lstat, the regular file the journal
    names. Any error is "not the same": unknown is never proof."""
    try:
        st = os.lstat(path)
    except OSError:
        return False
    return stat.S_ISREG(st.st_mode) and (
        st.st_dev, st.st_ino, st.st_size
    ) == tuple(identity[:3])


def quarantine_state(quarantine, identity) -> str:
    """"free", "ours", "other" (proven a different file) or "unknown"."""
    try:
        st = os.lstat(quarantine)
    except FileNotFoundError:
        return "free"
    except OSError:
        return "unknown"
    if stat.S_ISREG(st.st_mode) and (st.st_dev, st.st_ino) == tuple(identity[:2]):
        return "ours"
    return "other"


def put_back_file(original, quarantine, *, prove_identity, in_use=None) -> bool:
    """Put the quarantined file back at ``original`` without replacing anything:
    a hard link (then the quarantine name is removed), or, on a filesystem that
    refuses hard links, a rename (never a copy: a quarantine on another
    filesystem raises EXDEV).

    True: the file is back at ``original`` and the quarantine name is gone.
    False: not put back or not proven, so the caller must keep the journal.
    Note that a False after a successful link leaves both names on one inode,
    and after a rename the file is at ``original`` only. Exceptions propagate.
    When ``prove_identity`` is given, both the quarantined file and the restored
    one must be that journaled file; a rename is also proven by the
    quarantine's own identity taken just before it."""
    if prove_identity is not None and not is_journaled_file(quarantine, prove_identity):
        return False
    if os.path.lexists(original):
        return False
    before_rename = []

    def remember_quarantine(_mode):  # rename only: allow_copy=False raises before a copy
        before_rename.append(os.lstat(quarantine))

    # The original is our own track's master, so no other track check applies;
    # existence is refused by the primitive itself, under the directory lock.
    placed = organizer.place_no_replace(
        quarantine, original, in_use=in_use or (lambda _path: False), allow_copy=False,
        before_fallback=remember_quarantine)
    if placed == "moved":
        try:
            st = os.lstat(original)
        except OSError:
            return False  # unknown is never proof
        q = before_rename[0]
        if not stat.S_ISREG(st.st_mode) or (st.st_dev, st.st_ino) != (q.st_dev, q.st_ino) or (
            prove_identity is not None and not is_journaled_file(original, prove_identity)
        ):
            return False  # unproven: nothing removed, the journal stays
        fsync_dir(quarantine.parent)  # the primitive flushed the original's folder
    elif placed == "linked":
        if not organizer.is_own_hard_link(quarantine, original) or (
            prove_identity is not None and not is_journaled_file(original, prove_identity)
        ):
            return False
        fsync_dir(original.parent)  # the new name is on disk before the old one goes
        os.unlink(quarantine)  # proof: O is now the same inode as Q
        fsync_dir(quarantine.parent)
    else:
        return False
    try:
        os.rmdir(quarantine.parent)
    except OSError:
        pass
    return True


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


class DeletionExecutor:
    def __init__(self, database, *, music_library_dir, track_locks, cover_art, cache,
                 default_cache, boot_id, lock_timeout_s=2.0, clock=time.time, seam=None):
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

    def run_one(self) -> bool | str:
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
            return False
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
            return "released"  # truthy; the worker backs off before re-claiming
        return True

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

    def _execute_locked(self, item: dict):
        uuid_id, owner = item["uuid_id"], item["owner_id"]
        facts = self._database.read_deletion_target(uuid_id, owner_id=owner)
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
        original = Path(facts["file_path"])
        owner_quarantine = Path(self._music_library_dir) / DELETING / str(owner)
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
            identity = (st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns)
        key = dict(
            owner_id=owner,
            operation_uuid=item["operation_uuid"],
            uuid_id=item["uuid_id"],
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
                    moved = organizer.move_file(original, quarantine)
                except Exception as exc:
                    # A raise (e.g. EACCES while looking at the paths) is a failed move.
                    logger.warning("deletion move failed: %s", type(exc).__name__)
                    moved = False
                if not moved:
                    return self._rename_failed(
                        item, key, original, quarantine, identity
                    ), None
                if not is_journaled_file(quarantine, identity):
                    # Replaced by an outside rename after our lstat: commit
                    # nothing and put back what this call just moved.
                    return self._put_back(
                        item, key, original, quarantine, "conflict", prove_identity=None
                    ), None
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
                return self._after_failed_commit(
                    item, key, original, quarantine, identity, reason, exc
                ), None
        except Exception as exc:
            logger.warning("deletion failed after the journal: %s", type(exc).__name__)
            return self._recovery_required(item, cause=exc), None
        self._at("after_commit")

        def cleanup():
            self._cleanup(item, key, original, quarantine, identity,
                          facts["cover_art_id"], user, final_details)

        return "deleted", cleanup

    def _clear_journal(self, key) -> bool:
        try:
            return bool(self._database.clear_deletion_journal(**key))
        except Exception as exc:
            logger.warning("deletion journal clear failed: %s", type(exc).__name__)
            return False

    def _recovery_required(self, item, cause: Exception | None = None):
        """A designed keep site (the track lock is held): the one release rule.
        ``cause`` is the error that led here, if any. A failing outcome write
        propagates to ``run_one``."""
        return self._release(item, held=True, cause=cause)

    def _rename_failed(self, item, key, original, quarantine, identity) -> str:
        """The move into quarantine failed: nothing moved. Clear the journal only
        when the master is verifiably still the journaled file and the quarantine
        path is proven not to hold it. Unknown is never "not ours"."""
        cleared = False
        try:
            state = quarantine_state(quarantine, identity)
            if state in ("free", "other") and is_journaled_file(original, identity):
                if self._clear_journal(key):
                    cleared = True
                    try:
                        os.rmdir(quarantine.parent)
                    except OSError:
                        pass
        except Exception as exc:
            logger.warning("deletion rename recovery failed: %s", type(exc).__name__)
        if not cleared:
            return self._recovery_required(item)
        self._at("after_journal_clear")
        return self._finish(item, "failed", error="rename")

    def _after_failed_commit(
        self, item, key, original, quarantine, identity, reason, cause
    ) -> str:
        """The commit raised ``cause``. It may still have landed: re-read first,
        and only a track that is still live may be restored. A keep site on
        this path releases with ``cause`` (or a newer error it caught)."""
        try:
            facts = self._database.read_deletion_target(
                item["uuid_id"], owner_id=item["owner_id"]
            )
        except Exception as exc:
            logger.warning("deletion state re-read failed: %s", type(exc).__name__)
            return self._recovery_required(item, cause=exc)
        if facts["state"] == "tombstone":
            return "deleted"  # committed: never rolled back; cleanup is recovery's
        if facts["state"] != "live":
            return self._recovery_required(item, cause=cause)
        try:
            return self._restore_after_failed_commit(
                item, key, original, quarantine, identity, reason, cause
            )
        except Exception as exc:
            logger.warning("deletion restore failed: %s", type(exc).__name__)
            return self._recovery_required(item, cause=exc)

    def _restore_after_failed_commit(
        self, item, key, original, quarantine, identity, reason, cause
    ) -> str:
        """Put the same file back, never replacing anything at the original path,
        and only when the quarantined file is the journaled one. Otherwise keep
        the journal (the track stays hidden)."""
        if quarantine is None:
            # A missing master: there is no file to restore.
            if self._clear_journal(key):
                self._at("after_journal_clear")
                return self._finish_undone(item, reason)
            return self._recovery_required(item, cause=cause)
        return self._put_back(
            item, key, original, quarantine, reason, prove_identity=identity,
            cause=cause,
        )

    def _put_back(
        self, item, key, original, quarantine, reason, *, prove_identity, cause=None
    ) -> str:
        """The one link-back: return the quarantined file to the original path
        without replacing anything. After a failed commit the quarantined file
        and the restored one must both be the journaled identity
        (``prove_identity``); right after our own move there is no such
        requirement, because the file is the one this call just moved.
        ``cause`` is the error that led here (None: none), for a keep site."""
        if not put_back_file(original, quarantine, prove_identity=prove_identity):
            return self._recovery_required(item, cause=cause)
        if not self._clear_journal(key):
            return self._recovery_required(item, cause=cause)
        self._at("after_journal_clear")
        return self._finish_undone(item, reason)

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
        self._cleanup(
            dict(key),
            key,
            Path(row["original_path"]),
            None if missing else Path(row["quarantine_path"]),
            identity,
            row["cover_art_id"],
            user,
            ["master_missing"] if missing else [],
        )

    def _cleanup(self, item, key, original, quarantine, identity, cover_art_id, user,
                 final_details):
        """Post-commit storage cleanup. A failure leaves the committed journal
        for a retry; the deletion stays logically committed."""
        try:
            evict_track_caches(item["uuid_id"], self._cache, self._default_cache)
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
                    ) != identity[:3]:
                        return
                    os.unlink(quarantine)
                self._at("after_unlink")
            root = library_root(self._music_library_dir, user)
            organizer.prune_empty_dirs(original.parent, root)
            if quarantine is not None:
                try:
                    os.rmdir(quarantine.parent)
                except OSError:
                    pass
            self._database.finish_deletion_cleanup(**key, details=final_details)
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

    def process_one(self):
        try:
            stepped = self._executor.run_one()
            outcome = "error" if stepped == "released" else "done" if stepped else "idle"
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
