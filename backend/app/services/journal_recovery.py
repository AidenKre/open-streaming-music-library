"""Recovery of the edit journal while the server runs, and the facts both recoveries read.

An ``edit_journal`` row records a change of a track's master file that a writer
(a tag edit, a conversion; ``master_replace``) may not have finished. Two
recoveries settle such rows, with different rules:

- **Runtime recovery, here** (``reconcile_one``): before the same track's next
  edit or conversion, under its lock (``finish_track_journal_rows``), and in the
  idle identity worker (``finish_kept_journal_rows``). It never deletes a
  library file (except an old master this process remembered,
  ``PendingOldMasters``, after a durable point) and never places converted
  bytes; a row that needs that waits for start-up (``JournalRecoveryDeferred``).
- **Start-up recovery** is ``journal_settle``: it settles every row.

Both read the same facts, defined here once: whether a path is a regular file,
whether it is the track's current master, the identity mark, the replay of a
staged copy, and the job of a same-file conversion (its id in the staged file's
name, its texts, whether its own swap failed).

These functions used to live in ``track_editor.py``; that module still exports
the public names (``PendingOldMasters``, ``finish_track_journal_rows``,
``finish_kept_journal_rows``, ``reached_durable_point``,
``JournalOwnershipUnproven``, ``JournalRecoveryDeferred``).
"""

import logging
import os
import re
import stat
import threading
from pathlib import Path
from typing import Optional

from app.core.durable_fs import fsync_file
from app.core.internal_dirs import STAGING
from app.database import ANY_OWNER
from app.database.database import Database
from app.library import Library, library_root
from app.services.organizer import flush_move, prune_empty_dirs
from app.services.path_sanitize import assert_within

# The lines these functions log keep the logger name they had in track_editor.py.
logger = logging.getLogger("app.services.track_editor")


def finish_track_journal_rows(
    library: Library, uuid_id: str, music_library_dir: Path, identity_signal,
    pending_old_masters,
) -> None:
    """Finish this track's kept journal rows at runtime (``reconcile_one``).
    The caller holds the track lock; a row that cannot finish stays."""
    for entry in library.list_journal_entries():
        if entry["uuid_id"] != uuid_id:
            continue
        try:
            reconcile_one(
                library.database, entry, music_library_dir, identity_signal,
                pending_old_masters=pending_old_masters,
            )
        except Exception as e:
            logger.warning(
                "could not finish kept journal entry %s: %s",
                entry["id"], type(e).__name__,
            )


def reached_durable_point(database: Database, *, wait: bool = True) -> bool:
    """Whether every committed transaction is on disk; a failure counts as no.
    ``wait=False`` asks once without waiting (``make_durable(timeout=0)``)."""
    try:
        if not wait:
            return bool(database.make_durable(timeout=0))
        return bool(database.make_durable())
    except Exception as e:
        logger.warning("durable point failed: %s", type(e).__name__)
        return False


def reconcile_one(
    database: Database, entry: dict, music_library_dir: Path, identity_signal=None,
    *, pending_old_masters: Optional["PendingOldMasters"] = None,
) -> None:
    # Recovery while the server is up (startup settles rows in ``journal_settle``):
    # it never deletes a library file and never places converted bytes (rows that
    # need that wait for startup).
    root = row_root(database, entry, music_library_dir)
    intent = entry["intent"]
    if intent == "relocate":
        _reconcile_relocate(
            database, entry, root, identity_signal, pending_old_masters=pending_old_masters,
        )
    elif intent == "inplace":
        _reconcile_inplace(database, entry, identity_signal)
    elif intent == "convert":
        # A conversion's extension change (e.g. .flac -> .m4a) is physically
        # the same situation _reconcile_relocate already handles; a
        # same-codec re-encode (path unchanged) is exactly _reconcile_inplace.
        # No separate reconcile body needed.
        if entry["new_path"] and entry["new_path"] != entry["old_path"]:
            _reconcile_relocate(
                database, entry, root, identity_signal, pending_old_masters=pending_old_masters,
            )
        else:
            _reconcile_inplace(database, entry, identity_signal)
    else:
        # Unknown intent (shouldn't happen) — drop it so it can't loop forever.
        database.delete_journal_entry(entry["id"], owner_id=entry["owner_id"])


def row_root(
    database: Database, entry: dict, music_library_dir: Path, check=assert_within
) -> Path:
    """The row owner's library root, after ``check`` shows that every path of the
    row lies inside it (the staged copy inside the staging dir); before any disk
    touch. Startup checks the entries themselves (``assert_name_within``): it
    never follows a symlink at a row's path, it settles around it."""
    root = library_root(music_library_dir, database.get_user(entry["owner_id"]))
    for key in ("old_path", "new_path"):
        if entry[key]:
            check(entry[key], root)
    if entry["temp_path"]:
        check(entry["temp_path"], Path(music_library_dir) / STAGING)
    return root


def mark_identity_stale(database: Database, entry: dict, identity_signal) -> None:
    """Mark by the journal intent (convert -> every layer, else tag_write), in the
    row owner's own short txn, then wake the worker if a row was marked."""
    reason = "conversion" if entry["intent"] == "convert" else "tag_write"
    if database.mark_audio_identity_stale(
        entry["uuid_id"], reason, owner_id=entry["owner_id"]
    ) and identity_signal is not None:
        identity_signal.notify()


class PendingOldMasters:
    """Old masters this process kept because the commit that replaced them was not
    yet durable, keyed by journal row. Runtime recovery deletes one only while the
    file at its path is still that same file object."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._files: dict[tuple, tuple] = {}

    def remember(self, entry: dict, path) -> None:
        identity = _file_identity(path)
        if identity is not None:
            with self._lock:
                self._files[_row_key(entry)] = identity

    def holds(self, entry: dict) -> bool:
        with self._lock:
            return _row_key(entry) in self._files

    def is_same_file(self, entry: dict, path) -> bool:
        with self._lock:
            identity = self._files.get(_row_key(entry))
        return identity is not None and _file_identity(path) == identity

    def forget(self, entry: dict) -> None:
        with self._lock:
            self._files.pop(_row_key(entry), None)


def _file_identity(path) -> Optional[tuple]:
    """A regular file's or a symbolic link's own (lstat) device, inode, size,
    mtime, ctime; None otherwise. Removing a link removes only its name."""
    try:
        st = os.lstat(path)
    except OSError:
        return None
    if not (stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode)):
        return None
    return (st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns, st.st_ctime_ns)


class JournalOwnershipUnproven(Exception):
    """Recovery could not show that the file at a journal row's ``new_path`` is
    the row's own output, so the file and the row are left as they are."""


class JournalRecoveryDeferred(Exception):
    """A journal row that only startup recovery may finish; it is kept."""


def _defer_unlink(path: str, current: Optional[str], entry: dict) -> None:
    """Runtime recovery never deletes a library file: raise if a file that is not
    the track's master sits at ``path`` (the row waits for startup)."""
    if os.path.lexists(path) and not is_current_master(path, current):
        raise JournalRecoveryDeferred(
            f"journal entry {entry['id']} waits for startup recovery"
        )


def _finish_old_master_at_runtime(
    database: Database, entry: dict, old_path: str, current: str, root: Path,
    pending_old_masters: Optional[PendingOldMasters],
) -> None:
    """Delete an old master this process remembered, once the commit is durable
    and only while it is still the same file; otherwise defer like any row."""
    if (
        pending_old_masters is not None
        and pending_old_masters.holds(entry)
        and os.path.lexists(old_path)
    ):
        if pending_old_masters.is_same_file(entry, old_path):
            if not reached_durable_point(database):
                raise JournalRecoveryDeferred(
                    f"journal entry {entry['id']} waits for a database flush"
                )
            # Again after the point: an outside change during the checkpoint.
            if pending_old_masters.is_same_file(entry, old_path):
                Path(old_path).unlink(missing_ok=True)  # a link: only its name
                prune_empty_dirs(Path(old_path).parent, root)
                return
        pending_old_masters.forget(entry)
    _defer_unlink(old_path, current, entry)


def _reconcile_relocate(
    database: Database, entry: dict, root: Path, identity_signal=None,
    *, pending_old_masters: Optional["PendingOldMasters"] = None,
) -> None:
    # Whether the DB commit landed is the source of truth: if file_path == the
    # journal's new_path the move is durable → finish (delete the old master);
    # otherwise the move never committed → revert (delete the new copy, keep old).
    current = database.get_track_file_path(
        entry["uuid_id"], owner_id=entry["owner_id"]
    )
    old_path, new_path, temp_path = entry["old_path"], entry["new_path"], entry["temp_path"]
    if current is not None and current == new_path:
        if not (is_regular_file(new_path) and not _temp_present(entry)):
            raise JournalOwnershipUnproven("the moved file is not at its new location")
        # Our old master goes, unless another track's master has since landed
        # at that path.
        if (
            old_path
            and not database.track_path_in_use(
                old_path, owner_id=ANY_OWNER, exclude_uuid=entry["uuid_id"])
            and not is_current_master(old_path, current)
        ):
            _finish_old_master_at_runtime(
                database, entry, old_path, current, root, pending_old_masters
            )
        mark_identity_stale(database, entry, identity_signal)
    else:
        if (
            (_temp_present(entry) or (new_path and os.path.lexists(new_path)))
            and not is_regular_file(current)
        ):
            raise JournalOwnershipUnproven("the track's file is missing")
        if new_path:
            # Revert: delete the new copy only when it is shown to be this row's own.
            # A staged temp that still exists means the move never happened, so
            # whatever sits at new_path is not ours. A consumed temp means the move
            # happened, which makes the file ours unless a track's master is that
            # path. With no recorded temp nothing shows ownership.
            if temp_path and Path(temp_path).exists():
                pass
            elif temp_path and not database.track_path_in_use(
                new_path, owner_id=ANY_OWNER, exclude_uuid=entry["uuid_id"]
            ):
                # The new copy is this row's own, but a running server never
                # deletes a library file: the row waits for startup (unless the
                # path is another spelling of the track's own master).
                _defer_unlink(new_path, current, entry)
            else:
                raise JournalOwnershipUnproven(
                    f"cannot show that the file at the new location is the output of journal entry {entry['id']}"
                )
    if temp_path:
        Path(temp_path).unlink(missing_ok=True)
    database.delete_journal_entry(entry["id"], owner_id=entry["owner_id"])
    if pending_old_masters is not None:
        pending_old_masters.forget(entry)


def is_regular_file(path) -> bool:
    """Whether ``path`` is a regular file (a symlink is not)."""
    if not path:
        return False
    try:
        return stat.S_ISREG(os.lstat(path).st_mode)
    except OSError:
        return False


def is_current_master(path: str, current: Optional[str]) -> bool:
    """Whether ``path`` is the same file as the track's current master."""
    if not current:
        return False
    try:
        return os.path.samefile(path, current)
    except OSError:
        return False


# Job texts startup recovery stores when it settles a same-file conversion whose
# own swap failed (U06-B-06). TRACK_CHANGED_TEXT equals
# conversion.TRACK_CHANGED_ERROR (not imported: conversion imports this module on
# later phases).
TRACK_CHANGED_TEXT = "track changed since the conversion was requested"
SWAP_LOST_TEXT = "The converted file was lost, so the original was kept. Convert it again."
SWAP_UNPROVEN_TEXT = "could not place the converted master"
# The probe of a swap that happened earlier: bitrates are compared within this.
_SWAP_BITRATE_TOLERANCE_KBPS = 0.5


def _reconcile_inplace(database: Database, entry: dict, identity_signal=None) -> None:
    old_path, temp_path = entry["old_path"], entry["temp_path"]
    convert = entry["intent"] == "convert"
    if _swap_job_failed(database, entry):
        # Its job's own swap failed: only the next start may settle the row (it
        # proves the swap, bumps the revision and settles the job), also when the
        # staged file has gone missing meanwhile.
        raise JournalRecoveryDeferred(
            f"journal entry {entry['id']} waits for startup recovery"
        )
    # The DB is already committed for in-place; only the atomic replace may be
    # pending. If the staged temp still exists, redo it; otherwise it's done.
    if temp_path and old_path and Path(temp_path).exists():
        if convert:
            # Converted bytes change the audio; only startup evicts encoded caches.
            raise JournalRecoveryDeferred(
                f"journal entry {entry['id']} waits for startup recovery"
            )
        current = database.get_track_file_path(
            entry["uuid_id"], owner_id=entry["owner_id"]
        )
        if current != old_path:
            # The track moved on (or is gone): the staged bytes are stale and
            # old_path may now hold another track. Drop the temp, write nothing,
            # unless the track's own file is missing: the temp may be its last copy.
            if not is_regular_file(current):
                raise JournalOwnershipUnproven("the track's file is missing")
            logger.warning(
                "journal entry %s: track no longer at its recorded path; "
                "discarding its staged temp", entry["id"],
            )
            Path(temp_path).unlink(missing_ok=True)
            database.delete_journal_entry(entry["id"], owner_id=entry["owner_id"])
            return
        if database.track_path_in_use(
            old_path, owner_id=ANY_OWNER, exclude_uuid=entry["uuid_id"]
        ):
            # Another track's file is at the path (this track's master vanished
            # and something else landed there): never write over it.
            raise JournalOwnershipUnproven("another track's file is at the path")
        if not is_regular_file(temp_path):
            raise JournalOwnershipUnproven("the staged copy is not a regular file")
        replay_staged_copy(Path(temp_path), Path(old_path))
    mark_identity_stale(database, entry, identity_signal)
    database.delete_journal_entry(entry["id"], owner_id=entry["owner_id"])


def replay_staged_copy(temp: Path, target: Path) -> None:
    """Redo an in-place row's replace: flush the staged copy, then put it in place."""
    fsync_file(temp)
    os.replace(temp, target)
    flush_move(target, temp)


def same_bitrate(a: Optional[float], b: Optional[float]) -> bool:
    if a is None or b is None:
        return a is None and b is None
    return abs(a - b) <= _SWAP_BITRATE_TOLERANCE_KBPS


_TAGGED_JOB_ID_RE = re.compile(r"(\d+)\.tagged\.")


def conversion_job_id_of(entry: dict) -> Optional[int]:
    """The conversion job id in a convert row's staged file name,
    ``<uuid>.<job_id>.tagged.<ext>`` (conversion's fixed scheme), else None."""
    if not entry["temp_path"]:
        return None
    name = Path(entry["temp_path"]).name
    prefix = entry["uuid_id"] + "."
    if not name.startswith(prefix):
        return None
    match = _TAGGED_JOB_ID_RE.match(name, len(prefix))
    return int(match.group(1)) if match is not None else None


def _swap_job_failed(database: Database, entry: dict) -> bool:
    """Whether a same-file convert row belongs to a job its own failed swap left
    failed (U06-B-06): only startup settles such a row."""
    if entry["intent"] != "convert":
        return False
    if entry["new_path"] and entry["new_path"] != entry["old_path"]:
        return False
    job_id = conversion_job_id_of(entry)
    if job_id is None:
        return False
    job = database.get_conversion_job(job_id, owner_id=entry["owner_id"])
    return job is not None and job["uuid_id"] == entry["uuid_id"] and job["status"] == "failed"


def swap_waits_for_start(library: Library, uuid_id: str) -> bool:
    """Whether a kept row of this track is one ``_swap_job_failed`` leaves to
    the next start."""
    return any(
        entry["uuid_id"] == uuid_id and _swap_job_failed(library.database, entry)
        for entry in library.list_journal_entries()
    )


def job_settled_lost(database: Database, entry: dict) -> bool:
    """Whether this row's job was already ended "lost" (a crash came after it)."""
    job_id = conversion_job_id_of(entry)
    if job_id is None:
        return False
    job = database.get_conversion_job(job_id, owner_id=entry["owner_id"])
    return (
        job is not None and job["uuid_id"] == entry["uuid_id"]
        and job["status"] == "failed" and job["error_text"] == SWAP_LOST_TEXT
    )


def end_swap_job(database: Database, entry: dict, error_text: Optional[str]) -> None:
    """Settle a convert row's job: done when ``error_text`` is None, else failed
    with that final text. Not a convert row, or a name with no job id: nothing.
    A failing update raises (the row is kept)."""
    if entry["intent"] != "convert":
        return
    job_id = conversion_job_id_of(entry)
    if job_id is None:
        return
    database.settle_swapped_conversion_job(
        job_id, entry["uuid_id"], owner_id=entry["owner_id"], error_text=error_text
    )


def finish_kept_journal_rows(
    database, music_library_dir, track_locks, identity_signal=None, *, reported=None,
    pending_old_masters=None,
) -> int:
    """Finish journal rows kept after a failed identity mark, in a running server.

    Only a row whose staged temp is gone (empty or missing: the file operation is
    over) is considered, and only while no writer holds the track's lock (every
    journal writer holds it, so a held lock means one is in flight and the row
    is skipped). Under the lock the row is re-read and re-checked, then finished
    through runtime recovery (``reconcile_one``). A failure leaves the row
    for the next pass or for startup. ``reported`` (a set the caller keeps
    across passes) logs a row that keeps failing once, not on every pass; it is
    keyed by (id, uuid, created_at), and forgets rows that are gone, so it
    holds only rows still in the journal. A row whose track is pending deletion is left for later.
    Returns the number of rows finished."""
    finished = 0
    entries = database.list_journal_entries(owner_id=ANY_OWNER)
    if reported is not None:
        # Forget rows that are gone, so the set holds only rows still in the journal.
        reported.intersection_update(_row_key(e) for e in entries)
    for entry in entries:
        if _temp_present(entry):
            continue
        lock = track_locks.lock_for(entry["uuid_id"])
        if not lock.acquire(blocking=False):
            continue
        try:
            current = next(
                (e for e in database.list_journal_entries(owner_id=ANY_OWNER) if e["id"] == entry["id"]),
                None,
            )
            if current is None or _temp_present(current):
                continue
            # The row is kept for a later pass; finally still releases the lock.
            if database.is_pending_deletion(
                current["uuid_id"], owner_id=current["owner_id"]
            ):
                continue
            reconcile_one(
                database, current, music_library_dir, identity_signal,
                pending_old_masters=pending_old_masters,
            )
            finished += 1
        except Exception as e:  # noqa: BLE001 - the row stays for the next pass or startup
            if reported is None or _row_key(entry) not in reported:
                logger.warning("journal finish failed for entry %s: %s", entry["id"], type(e).__name__)
                if reported is not None:
                    reported.add(_row_key(entry))
        finally:
            lock.release()
    return finished


def _row_key(entry: dict) -> tuple:
    return (entry["id"], entry["uuid_id"], entry["created_at"])


def _temp_present(entry: dict) -> bool:
    return bool(entry["temp_path"]) and Path(entry["temp_path"]).exists()
