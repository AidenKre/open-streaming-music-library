"""Phase 8 deletion startup recovery, job reclaim and quarantine janitor
(spec §5 "Startup recovery before serving consumers", SC-16e; piece 8A.3d)."""

import logging
import os
import stat
import uuid
from pathlib import Path

from app.core.durable_fs import fsync_dir
from app.core.internal_dirs import DELETING
from app.core.operator_log import operator_logger
from app.library import library_root
from app.services import organizer
from app.services.startup_recovery import StartupStep
from app.services.deletion_worker import (
    _EXTENSION,
    DeletionExecutor,
    check_master_path,
    is_journaled_file,
    put_back_file,
    quarantine_state,
)

logger = logging.getLogger(__name__)


def reclaim_deletion_items(database, *, boot_id: str) -> int:
    """Requeue interrupted deletion targets left by an older process; returns
    the count. Journal-backed items are left for journal recovery."""
    count = database.reclaim_deletion_items(boot_id=boot_id)
    if count > 0:
        operator_logger.info("%d interrupted deletion target(s) were requeued.", count)
    return count


def _is_real_dir(path) -> bool:
    try:
        return stat.S_ISDIR(os.lstat(path).st_mode)
    except OSError:
        return False


def _real_dir_or_absent(path) -> bool:
    """A real directory (lstat, so never a symlink) or not there at all; any
    other answer, including an unreadable one, is not trusted."""
    try:
        return stat.S_ISDIR(os.lstat(path).st_mode)
    except FileNotFoundError:
        return True
    except OSError:
        return False


def quarantine_trusted(music_library_dir, row) -> bool:
    """True only when the journaled quarantine path is exactly
    ``.deleting/<owner>/<operation>/<uuid><ext>`` under real directories."""
    raw = row["quarantine_path"]
    if not raw:
        return False
    raw = os.fspath(raw)
    if any(part in (".", "..") for part in raw.split("/")):
        return False
    uuid_id = str(row["uuid_id"])
    try:
        for value in (str(row["operation_uuid"]), uuid_id):
            if str(uuid.UUID(value)) != value:
                return False
    except Exception:
        return False
    quarantine = Path(raw)
    suffix = quarantine.name[len(uuid_id):] if quarantine.name.startswith(uuid_id) else None
    if suffix is None or (suffix and not _EXTENSION.match(suffix)):
        return False
    base = Path(music_library_dir) / DELETING
    op_dir = base / str(row["owner_id"]) / str(row["operation_uuid"])
    if quarantine != op_dir / quarantine.name:
        return False
    for folder in (base, base / str(row["owner_id"]), op_dir):
        if not _real_dir_or_absent(folder):
            return False
    return True


_CLEAR, _KEEP = "clear", "keep"


def _verdict(database, row, user, music_library_dir) -> str:
    owner, uuid_id = row["owner_id"], row["uuid_id"]
    facts = database.read_deletion_target(uuid_id, owner_id=owner)
    if not (
        facts["state"] == "live"
        and facts["revision"] == row["base_revision"]
        and facts["file_path"] == row["original_path"]
    ):
        return _KEEP
    if row["master_missing"] == 1:
        return _CLEAR
    identity = (row["src_dev"], row["src_ino"], row["src_size"])
    original = Path(row["original_path"])
    kind, _st = check_master_path(music_library_dir, user, row["original_path"])
    if kind == "rejected":
        return _KEEP
    if kind == "ok":
        o_state = "ours" if is_journaled_file(original, identity) else "other"
    else:
        o_state = "free"
    if not quarantine_trusted(music_library_dir, row):
        return _KEEP
    quarantine = Path(row["quarantine_path"])
    q_state = quarantine_state(quarantine, identity)
    if q_state == "ours" and not is_journaled_file(quarantine, identity):
        q_state = "other"

    if o_state == "ours":
        if q_state in ("free", "other"):
            return _CLEAR
        if q_state == "ours":
            if not organizer.is_own_hard_link(quarantine, original):
                return _KEEP
            os.unlink(quarantine)
            fsync_dir(quarantine.parent)
            try:
                os.rmdir(quarantine.parent)
            except OSError:
                pass
            return _CLEAR
        return _KEEP
    if o_state == "free" and q_state == "ours":
        if database.track_path_in_use(row["original_path"], owner_id=owner, exclude_uuid=uuid_id):
            return _KEEP

        def in_use(path):
            return database.track_path_in_use(str(path), owner_id=owner, exclude_uuid=uuid_id)

        if put_back_file(original, quarantine, prove_identity=identity, in_use=in_use):
            return _CLEAR
        return _KEEP
    if o_state == "free" and q_state == "free":
        # The master is gone from both places (check_master_path "missing" also
        # proves the owner's library root is a real directory): there is no file
        # left to protect and nothing was touched. The requeued rerun commits a
        # catalog-only deletion (master_missing). A "moved" journal proves the
        # move happened, so its owner's quarantine folder must still be a real
        # directory (an unmounted one would read as empty); an "intent" journal's
        # move may never have created it.
        quarantine_root = Path(music_library_dir) / DELETING / str(owner)
        if row["stage"] != "moved" or _is_real_dir(quarantine_root):
            return _CLEAR
    return _KEEP


def settle_uncommitted_journal(
    database, row, *, music_library_dir, track_locks, lock_timeout_s=0, held=False
) -> bool:
    """The one verdict for an uncommitted (intent/moved) journal row, used at
    startup and at runtime. True when the journal was cleared. Exceptions
    propagate: the caller decides (startup logs and keeps; the executor keeps).
    With ``held`` the caller already holds the track lock (never re-acquired)."""
    owner, uuid_id = row["owner_id"], row["uuid_id"]
    lock = None
    if not held:
        lock = track_locks.lock_for(uuid_id)
        if not lock.acquire(timeout=lock_timeout_s):
            return False
    try:
        user = database.get_user(owner)
        if user is None or user["deleting_at"] is not None:
            return False
        if _verdict(database, row, user, music_library_dir) != _CLEAR:
            return False
        database.clear_deletion_journal(
            owner_id=owner, operation_uuid=row["operation_uuid"], uuid_id=uuid_id
        )
        return True
    finally:
        if lock is not None:
            lock.release()


def reconcile_deletion_journals(
    database, *, music_library_dir, track_locks, boot_id: str, log_kept: bool = True
) -> None:
    """Resolve every uncommitted deletion journal left by an old process.

    A journal whose track is live at the journaled revision and path is either
    cleared (the delete never took effect, or the master is back) or, when the
    evidence is not clear, kept with its item failed as recovery_required. An
    exception is never a verdict: that row is left as it is."""
    cleared = kept = 0
    for row in database.list_deletion_journals(stages=("intent", "moved")):
        owner, op, uuid_id = row["owner_id"], row["operation_uuid"], row["uuid_id"]
        resolved = False
        try:
            resolved = settle_uncommitted_journal(
                database, row, music_library_dir=music_library_dir, track_locks=track_locks
            )
        except Exception as exc:
            logger.warning("deletion journal recovery failed: %s", type(exc).__name__)
        if resolved:
            cleared += 1
            continue
        # Every row left in place ends with its running item reported: the mark
        # only changes a running item of another boot and never touches the journal.
        kept += 1
        try:
            database.mark_deletion_recovery_required(
                owner_id=owner, operation_uuid=op, uuid_id=uuid_id, boot_id=boot_id
            )
        except Exception as exc:
            logger.warning("deletion recovery mark failed: %s", type(exc).__name__)
    if cleared:
        operator_logger.info("%d interrupted deletion(s) were resolved.", cleared)
    if kept and log_kept:
        operator_logger.warning(
            "%d interrupted deletion(s) need recovery; their tracks stay hidden.", kept
        )


def put_back_unrecorded(
    database, path, *, music_library_dir, track_locks, journaled_uuids
) -> bool:
    """Put a holding file that no journal row names back at its track's place
    (OPEN-8-01 part A). True only when it was put back; any doubt returns False
    and touches nothing."""
    try:
        parts = Path(path).relative_to(Path(music_library_dir) / DELETING).parts
    except ValueError:
        return False
    if len(parts) != 3:
        return False
    owner_s, op, name = parts
    if not (owner_s.isdigit() and str(int(owner_s)) == owner_s):
        return False
    owner = int(owner_s)
    uuid_id, suffix = name[:36], name[36:]
    try:
        for value in (op, uuid_id):
            if str(uuid.UUID(value)) != value:
                return False
    except ValueError:
        return False
    if uuid_id in journaled_uuids:
        return False
    user = database.get_user(owner)
    if user is None or user["deleting_at"] is not None:
        return False
    facts = database.read_deletion_target(uuid_id, owner_id=owner)
    if facts["state"] != "live":
        return False
    original = Path(facts["file_path"])
    expected = original.suffix if _EXTENSION.match(original.suffix) else ""
    if suffix != expected:
        return False
    if not quarantine_trusted(
        music_library_dir,
        {"quarantine_path": path, "owner_id": owner, "operation_uuid": op, "uuid_id": uuid_id},
    ):
        return False
    lock = track_locks.lock_for(uuid_id)
    if not lock.acquire(timeout=0):
        return False
    try:
        again = database.read_deletion_target(uuid_id, owner_id=owner)
        if again["state"] != "live" or again["file_path"] != facts["file_path"]:
            return False
        if check_master_path(music_library_dir, user, facts["file_path"])[0] != "missing":
            return False
        st = os.lstat(path)
        if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1:
            return False

        def in_use(p):
            return database.track_path_in_use(str(p), owner_id=owner, exclude_uuid=uuid_id)

        if in_use(original):
            return False
        return put_back_file(
            original,
            Path(path),
            prove_identity=(st.st_dev, st.st_ino, st.st_size),
            in_use=in_use,
        )
    finally:
        lock.release()


class DeletionJanitor:
    """Finishes committed deletions' storage cleanup after one durable point,
    and at startup puts back holding files that no journal row names when they
    prove to be their live track's missing master; any other such file is
    reported and kept (never deleted)."""

    def __init__(self, database, *, executor, music_library_dir):
        self._database = database
        self._executor = executor
        self._music_library_dir = music_library_dir

    def _cleanup_ready(self, row, user) -> bool:
        owner, uuid_id = row["owner_id"], row["uuid_id"]
        facts = self._database.read_deletion_target(uuid_id, owner_id=owner)
        if facts["state"] != "tombstone":
            return False
        if row["master_missing"] == 0:
            if not quarantine_trusted(self._music_library_dir, row):
                return False
            identity = (row["src_dev"], row["src_ino"], row["src_size"])
            quarantine = Path(row["quarantine_path"])
            state = quarantine_state(quarantine, identity)
            if state == "ours":
                return is_journaled_file(quarantine, identity)
            if state != "free":
                return False
            # Unknown presence is never "gone" (review r2 #1): an unmounted
            # library or quarantine reads as free, so prove both roots are there.
            try:
                roots = (
                    library_root(self._music_library_dir, user),
                    Path(self._music_library_dir) / DELETING / str(row["owner_id"]),
                )
            except Exception:
                return False
            return all(_is_real_dir(root) for root in roots)
        return True

    def retry_cleanups(self) -> None:
        try:
            # Kept uncommitted journals are re-judged here, not only at startup.
            self._executor.settle_kept_journals()
        except Exception as exc:
            logger.warning("deletion journal re-check failed: %s", type(exc).__name__)
        retried = kept = 0
        ready = []
        for row in self._database.list_deletion_journals(stages=("committed",)):
            try:
                user = self._database.get_user(row["owner_id"])
                if (
                    user is None
                    or user["deleting_at"] is not None
                    or not self._cleanup_ready(row, user)
                ):
                    kept += 1
                    continue
                ready.append((row, user))
            except Exception as exc:
                kept += 1
                logger.warning("deletion cleanup retry failed: %s", type(exc).__name__)
        # One durable point for the whole pass (OPEN-8-01 part B).
        if ready and not self._executor.durable_point():
            kept += len(ready)
            ready = []
        for row, user in ready:
            try:
                self._executor.finish_committed(row, user)
                retried += 1
            except Exception as exc:
                kept += 1
                logger.warning("deletion cleanup retry failed: %s", type(exc).__name__)
        if retried:
            # The executor keeps a journal whose cleanup fails again: "retried", not "finished".
            operator_logger.info("%d committed deletion cleanup(s) were retried.", retried)
        if kept:
            operator_logger.warning(
                "%d committed deletion clean-up(s) could not be finished; their journals are kept.",
                kept,
            )

    def report_orphans(self) -> int:
        """Startup only. A holding file no journal row names is put back at its
        track's place when it proves to be that live track's missing master;
        every other one is counted, reported and kept. Returns the kept count."""
        base = Path(self._music_library_dir) / DELETING
        try:
            entries = list(os.scandir(base))
        except OSError:
            return 0
        rows = self._database.list_deletion_journals(stages=("intent", "moved", "committed"))
        named = {os.fspath(r["quarantine_path"]) for r in rows if r["quarantine_path"]}
        journaled = {str(r["uuid_id"]) for r in rows}
        count = restored = 0
        unnamed: list[str] = []
        for entry in entries:
            try:
                if not stat.S_ISDIR(os.lstat(entry.path).st_mode):
                    continue
            except OSError:
                continue
            for dirpath, _dirs, files in os.walk(entry.path, followlinks=False):
                for name in files:
                    full = os.path.join(dirpath, name)
                    try:
                        if not stat.S_ISREG(os.lstat(full).st_mode):
                            continue
                    except OSError:
                        continue
                    if full not in named:
                        unnamed.append(full)
        seen: dict[str, int] = {}
        for full in unnamed:
            key = os.path.basename(full)[:36]
            seen[key] = seen.get(key, 0) + 1
        ambiguous = journaled | {key for key, n in seen.items() if n > 1}
        for full in unnamed:
            try:
                if put_back_unrecorded(
                    self._database,
                    full,
                    music_library_dir=self._music_library_dir,
                    track_locks=self._executor.track_locks,
                    journaled_uuids=ambiguous,
                ):
                    restored += 1
                    continue
            except Exception as exc:
                logger.warning(
                    "deletion holding file put-back failed: %s", type(exc).__name__
                )
            count += 1
        if restored:
            operator_logger.info(
                "%d file(s) in the deletion quarantine had no journal record and were put back at their tracks.",
                restored,
            )
        if count > 0:
            operator_logger.warning(
                "%d file(s) in the deletion quarantine have no journal record; they were kept.",
                count,
            )
        return count

    def run_startup_pass(self) -> None:
        try:
            self.retry_cleanups()
        except Exception as exc:
            logger.warning("deletion cleanup pass failed: %s", type(exc).__name__)
        self.report_orphans()


def startup_steps(database, *, music_library_dir, track_locks, cover_art, cache,
                  default_cache, boot_id):
    """The three non-fatal startup steps, in registry order: deletion journal,
    deletion jobs, deletion janitor. Functions are looked up at call time."""

    def journal() -> None:
        reconcile_deletion_journals(
            database,
            music_library_dir=music_library_dir,
            track_locks=track_locks,
            boot_id=boot_id,
        )

    def jobs() -> None:
        reclaim_deletion_items(database, boot_id=boot_id)

    def janitor() -> None:
        DeletionJanitor(
            database,
            executor=DeletionExecutor(
                database,
                music_library_dir=music_library_dir,
                track_locks=track_locks,
                cover_art=cover_art,
                cache=cache,
                default_cache=default_cache,
                boot_id=boot_id,
            ),
            music_library_dir=music_library_dir,
        ).run_startup_pass()

    return (
        StartupStep("deletion journal", journal),
        StartupStep("deletion jobs", jobs),
        StartupStep("deletion janitor", janitor),
    )
