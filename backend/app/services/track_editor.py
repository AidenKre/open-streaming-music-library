import logging
import os
import re
import stat
import unicodedata
import uuid
from pathlib import Path
from typing import Optional

from app.core.durable_fs import fsync_file
from app.core.internal_dirs import STAGING
from app.core.operator_log import operator_logger
from app.database import ANY_OWNER
from app.library import Library, library_root
from app.database.database import (
    Database,
    EDITABLE_METADATA_COLUMNS,
    RevisionConflict,
    TrackNotFound,
    normalize_edit_fields,
)
from app.models.track import Track
from app.services import audio_identity
from app.services.metadata import (
    build_ffmpeg_tags,
    build_track_metadata,
    ffprobe_for_metadata,
    is_wav,
    write_metadata_tags,
)
from app.services.organizer import (
    move_back,
    flush_move,
    move_file,
    prune_empty_dirs,
    sanitized_destination_path,
)
from app.services.path_sanitize import assert_within
from app.services.track_edit import WriteMode


class MasterWriteError(Exception):
    """A ``db_and_master`` edit could not place the master on disk (staging or
    move failed). The DB is left unchanged so the caller can surface a 5xx."""


class MasterSwapPending(Exception):
    """An in-place ``db_and_master`` edit committed and kept its journal row,
    but swapping the new master in failed; the kept row finishes the swap
    (the track's next edit, or startup). A retry with the old base revision
    gets the usual revision conflict."""


logger = logging.getLogger(__name__)


class TrackEditor:
    """Orchestrates a track metadata edit across the DB and (optionally) the
    master file. File I/O lives here, never in the pure-DB spine. A per-uuid
    ``TrackLocks`` lock (held by the caller) serializes the staging→move→commit
    region; the ``edit_journal`` + ``reconcile_journal`` make the move↔commit
    window crash-safe."""

    def __init__(self, music_library_dir: Path, staging_dir: Path, identity_signal=None):
        self._library = Path(music_library_dir)
        # Anything with notify() (the app passes the identity worker's wake-up); None = no wake-up.
        self._identity_signal = identity_signal
        self._staging = Path(staging_dir)

    def apply_edit(
        self,
        library: Library,
        uuid_id: str,
        fields: dict,
        base_revision: Optional[int],
        write_mode: WriteMode,
    ) -> tuple[int, bool]:
        """Returns ``(new_revision, master_written)``. ``db_only`` never touches
        the file. ``db_and_master`` also rewrites the file's tags and relocates
        it when artist/album change — except for WAV or a missing master, which
        degrade to DB-only with ``master_written=False``."""
        # Canonicalize up front (NFC + year/date reconciliation) so the merged
        # state, the destination path, and the file tags are all derived from
        # the same bytes the DB spine will store. The spine normalizes again
        # itself (idempotent) for callers that skip this orchestrator.
        fields = normalize_edit_fields(fields)
        if write_mode is WriteMode.db_only:
            return library.apply_track_metadata_edit(uuid_id, fields, base_revision), False

        track = library.get_track_by_uuid(uuid_id)
        if track is None:
            raise TrackNotFound(uuid_id)
        # Fail a stale edit fast, before the full-file staging remux (and the
        # relocate path's journal + move). This is a pure optimization: the
        # in-transaction check inside apply_track_metadata_edit's own
        # BEGIN IMMEDIATE is authoritative on its own (independent of the
        # per-uuid TrackLocks held by the caller), so a stale edit that slips
        # past this fast-path check still can't corrupt the DB -- it just pays
        # for the staging work before getting the same RevisionConflict.
        if base_revision is None or base_revision != track.revision:
            raise RevisionConflict(uuid_id, base_revision, track.revision)
        source = Path(track.file_path)

        if is_wav(source) or not source.exists():
            # WAV tagging is out of scope and a missing master can't be written;
            # degrade to DB-only rather than fail the edit.
            rev = library.apply_track_metadata_edit(uuid_id, fields, base_revision)
            return rev, False

        return self._apply_with_master(
            library, uuid_id, fields, base_revision, track, source
        )

    def _finish_kept_rows(self, library: Library, uuid_id: str) -> None:
        """Finish this track's kept journal rows (same recovery as startup)
        before staging or writing; refuse the edit if any row remains."""
        for entry in library.list_journal_entries():
            if entry["uuid_id"] != uuid_id:
                continue
            try:
                _reconcile_one(
                    library.database, entry, self._library, self._identity_signal,
                    runtime=True,
                )
            except Exception as e:
                logger.warning(
                    "could not finish kept journal entry %s: %s",
                    entry["id"], type(e).__name__,
                )
        if library.has_journal_entry_for_uuid(uuid_id):
            raise MasterWriteError(
                "an earlier file operation on this track could not be finished"
            )

    def _apply_with_master(
        self, library: Library, uuid_id: str, fields: dict, base_revision: Optional[int],
        track: Track, source: Path,
    ) -> tuple[int, bool]:
        self._finish_kept_rows(library, uuid_id)
        merged = track.metadata.model_copy(update=fields)
        root = library.root
        if root is None:
            raise RuntimeError("a master write needs the library to have a root")
        dest = sanitized_destination_path(source.name, merged, root)
        # Before anything touches the disk (explicit raises, hold under -O).
        assert_within(root, self._library)
        assert_within(source, root)
        assert_within(dest, root)

        self._staging.mkdir(parents=True, exist_ok=True)
        # Stage the new-tags copy outside any watched tree; audio bytes are
        # copied (-c copy) so the (uuid, quality) encoded cache stays valid.
        # `write_metadata_tags` removes `temp` itself on any failure, so a failed
        # stage leaks nothing. Once it succeeds, ownership of `temp` passes to
        # _inplace / _relocate, which clean it on pre-journal failures and
        # otherwise hand it to the journal for reconcile to consume.
        # A master write reconciles the file to the merged DB metadata without
        # destroying data the DB never captured: a field edited right now always
        # lands (an explicit None clears the tag); an untouched field is
        # rewritten only when the DB holds a value for it (repairing earlier
        # db_only drift, including the no-field "re-tag from DB" save); an
        # untouched NULL column is omitted — the DB cannot distinguish "cleared
        # long ago" from "never captured" (ffprobe misses, external taggers),
        # so the file tag is left alone rather than erased.
        reconcile_fields = {
            col: getattr(merged, col)
            for col in EDITABLE_METADATA_COLUMNS
            if col in fields or getattr(merged, col) is not None
        }
        # One name per operation, so a later edit of the track never touches a
        # temp a kept journal row still owns.
        temp = self._staging / f"{uuid_id}.{uuid.uuid4().hex}.edit{source.suffix}"
        write_metadata_tags(source, temp, build_ffmpeg_tags(reconcile_fields))
        try:
            fsync_file(temp)
        except OSError:
            temp.unlink(missing_ok=True)
            logger.warning("could not flush the staged master of %s", uuid_id)
            raise MasterWriteError("could not write the new master to disk")

        # On a case-insensitive disk a case-only rename builds another spelling
        # of the same file: edit in place, keeping the on-disk spelling (it
        # resolves on both kinds of disk, so the next edit takes this branch).
        if dest == source or _another_spelling_of(dest, source):
            rev = self._inplace(
                library, uuid_id, fields, base_revision, source, temp
            )
        else:
            rev = self._relocate(
                library, uuid_id, fields, base_revision, source, dest, temp, root
            )
        return rev, True

    def _inplace(
        self, library, uuid_id: str, fields: dict, base_revision: Optional[int],
        source: Path, temp: Path,
    ) -> int:
        # Commit the DB first; a crash before the replace leaves file=old/DB=new
        # — the same benign divergence as a DB-only edit.
        journaled = False
        try:
            rev = library.apply_track_metadata_edit(uuid_id, fields, base_revision)
            # Journal AFTER the commit (a journal row implies the DB advanced)
            # and BEFORE the destructive replace. From here the journal owns
            # `temp`: a hard crash *or* a caught os.replace error leaves temp +
            # row for reconcile_journal to redo, so we must not delete temp on
            # the error path once journaled.
            entry = library.insert_journal_entry(
                "inplace", uuid_id, old_path=str(source), temp_path=str(temp),
            )
            journaled = True
            try:
                os.replace(temp, source)
            except OSError as e:
                logger.warning(
                    "could not swap in the new master of %s: %s",
                    uuid_id, type(e).__name__,
                )
                raise MasterSwapPending("could not write the new master to disk") from e
            flush_move(source, temp)
            # The new bytes are in place: mark the audio identity stale in its own
            # short txn (the edit committed before the replace). If this raises,
            # the journal row stays and the identity worker (when idle) or startup
            # recovery marks it.
            try:
                library.mark_audio_identity_stale(uuid_id, "tag_write")
            except Exception as e:
                # The edit is complete; keep the journal row so the identity
                # worker (when idle) or startup recovery marks the identity.
                logger.warning(
                    "identity mark failed after tag write for %s: %s",
                    uuid_id, type(e).__name__,
                )
                return rev
            library.delete_journal_entry(entry)
            self._notify_identity()
            return rev
        except BaseException:
            if not journaled:
                # DB commit or journal insert failed — nothing references `temp`.
                temp.unlink(missing_ok=True)
            raise

    def _notify_identity(self) -> None:
        """Wake the identity worker; call only after the marking txn committed."""
        if self._identity_signal is not None:
            self._identity_signal.notify()

    def _relocate(
        self, library, uuid_id: str, fields: dict, base_revision: Optional[int],
        source: Path, dest: Path, temp: Path, root: Path,
    ) -> int:
        # Journal the move BEFORE doing it: a crash in the move↔commit window is
        # reverted (DB not advanced) or finished (DB advanced) at startup.
        try:
            entry = library.insert_journal_entry(
                "relocate", uuid_id,
                old_path=str(source), new_path=str(dest), temp_path=str(temp),
            )
        except BaseException:
            temp.unlink(missing_ok=True)  # nothing journaled yet
            raise
        if not move_file(file_path=temp, destination_path=dest):
            # The staged temp stays until the row is gone: while the row exists
            # it shows recovery that the move never happened.
            library.delete_journal_entry(entry)
            temp.unlink(missing_ok=True)  # move failed; drop the staged copy
            logger.warning("could not place the master of %s at its new location", uuid_id)
            raise MasterWriteError("could not place the master at its new location")
        flush_move(dest, temp, root)
        try:
            rev = library.apply_track_metadata_edit(
                uuid_id, fields, base_revision, new_file_path=str(dest),
                master_rewritten=True,
            )
        except BaseException:
            # DB did not commit → revert: put the new copy back in staging and
            # keep the old master. The temp goes only after the row is deleted,
            # so a kept row still shows that the move was undone.
            if not move_back(dest, temp):
                dest.unlink(missing_ok=True)
            prune_empty_dirs(dest.parent, root)
            library.delete_journal_entry(entry)
            temp.unlink(missing_ok=True)
            raise
        # Committed: DB now points at `dest`; the old master is redundant.
        # Never delete the new master through another spelling of its path.
        if not _is_current_master(str(source), str(dest)):
            source.unlink(missing_ok=True)
            prune_empty_dirs(source.parent, root)
        library.delete_journal_entry(entry)
        self._notify_identity()
        return rev


def reconcile_journal(
    database: Database, music_library_dir: Path, identity_signal=None
) -> None:
    """Idempotent startup pass that finishes or reverts every outstanding
    ``edit_journal`` row, closing the move↔commit window. Safe to run on every
    boot; a clean shutdown leaves no rows. A recovered master write marks the track's
    audio identity stale and then wakes ``identity_signal`` (anything with notify())."""
    for entry in database.list_journal_entries(owner_id=ANY_OWNER):
        try:
            _reconcile_one(database, entry, music_library_dir, identity_signal)
        except Exception as e:  # never let one bad row block startup
            reason = str(e) if isinstance(e, JournalOwnershipUnproven) else type(e).__name__
            operator_logger.warning(
                "journal entry %s for track %s kept: %s", entry["id"], entry["uuid_id"], reason
            )


def _reconcile_one(
    database: Database, entry: dict, music_library_dir: Path, identity_signal=None,
    *, runtime: bool = False,
) -> None:
    # ``runtime`` is recovery while the server is up: it never deletes a library
    # file and never places converted bytes (rows that need that wait for startup).
    # Each row's root comes from its owner; every check precedes any disk touch.
    root = library_root(music_library_dir, database.get_user(entry["owner_id"]))
    for key in ("old_path", "new_path"):
        if entry[key]:
            assert_within(entry[key], root)
    if entry["temp_path"]:
        assert_within(entry["temp_path"], Path(music_library_dir) / STAGING)
    intent = entry["intent"]
    if intent == "relocate":
        _reconcile_relocate(database, entry, root, identity_signal, runtime=runtime)
    elif intent == "inplace":
        _reconcile_inplace(database, entry, identity_signal, runtime=runtime)
    elif intent == "convert":
        # A conversion's extension change (e.g. .flac -> .m4a) is physically
        # the same situation _reconcile_relocate already handles; a
        # same-codec re-encode (path unchanged) is exactly _reconcile_inplace.
        # No separate reconcile body needed.
        if entry["new_path"] and entry["new_path"] != entry["old_path"]:
            _reconcile_relocate(database, entry, root, identity_signal, runtime=runtime)
        else:
            _reconcile_inplace(database, entry, identity_signal, runtime=runtime)
    else:
        # Unknown intent (shouldn't happen) — drop it so it can't loop forever.
        database.delete_journal_entry(entry["id"], owner_id=entry["owner_id"])


def _mark_identity_stale(database: Database, entry: dict, identity_signal) -> None:
    """Mark by the journal intent (convert -> every layer, else tag_write), in the
    row owner's own short txn, then wake the worker if a row was marked."""
    reason = "conversion" if entry["intent"] == "convert" else "tag_write"
    if database.mark_audio_identity_stale(
        entry["uuid_id"], reason, owner_id=entry["owner_id"]
    ) and identity_signal is not None:
        identity_signal.notify()


class JournalOwnershipUnproven(Exception):
    """Recovery could not show that the file at a journal row's ``new_path`` is
    the row's own output, so the file and the row are left as they are."""


class JournalRecoveryDeferred(Exception):
    """A journal row that only startup recovery may finish; it is kept."""


def _defer_unlink(path: str, current: Optional[str], entry: dict) -> None:
    """Runtime recovery never deletes a library file: raise if a file that is not
    the track's master sits at ``path`` (the row waits for startup)."""
    if os.path.lexists(path) and not _is_current_master(path, current):
        raise JournalRecoveryDeferred(
            f"journal entry {entry['id']} waits for startup recovery"
        )


def _reconcile_relocate(
    database: Database, entry: dict, root: Path, identity_signal=None,
    *, runtime: bool = False,
) -> None:
    # Whether the DB commit landed is the source of truth: if file_path == the
    # journal's new_path the move is durable → finish (delete the old master);
    # otherwise the move never committed → revert (delete the new copy, keep old).
    current = database.get_track_file_path(
        entry["uuid_id"], owner_id=entry["owner_id"]
    )
    old_path, new_path, temp_path = entry["old_path"], entry["new_path"], entry["temp_path"]
    if current is not None and current == new_path:
        if not (_is_regular_file(new_path) and not _temp_present(entry)):
            raise JournalOwnershipUnproven("the moved file is not at its new location")
        # Our old master goes, unless another track's master has since landed
        # at that path.
        if (
            old_path
            and not database.track_path_in_use(
                old_path, owner_id=ANY_OWNER, exclude_uuid=entry["uuid_id"])
            and not _is_current_master(old_path, current)
        ):
            if runtime:
                _defer_unlink(old_path, current, entry)
            else:
                Path(old_path).unlink(missing_ok=True)
                prune_empty_dirs(Path(old_path).parent, root)
        _mark_identity_stale(database, entry, identity_signal)
    else:
        if (
            (_temp_present(entry) or (new_path and os.path.lexists(new_path)))
            and not _is_regular_file(current)
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
                # Never delete the track's own master through another spelling of
                # its path (a case-only move on a case-insensitive filesystem).
                if runtime:
                    _defer_unlink(new_path, current, entry)
                elif not _is_current_master(new_path, current):
                    Path(new_path).unlink(missing_ok=True)
                    prune_empty_dirs(Path(new_path).parent, root)
            else:
                raise JournalOwnershipUnproven(
                    f"cannot show that the file at the new location is the output of journal entry {entry['id']}"
                )
    if temp_path:
        Path(temp_path).unlink(missing_ok=True)
    database.delete_journal_entry(entry["id"], owner_id=entry["owner_id"])


def _another_spelling_of(dest: Path, source: Path) -> bool:
    """Whether ``dest`` is a different spelling (case/Unicode form) of ``source``."""
    if str(dest) == str(source):
        return False
    fold = lambda p: unicodedata.normalize("NFC", str(p)).casefold()
    if fold(dest) != fold(source):
        return False
    try:
        return os.path.samefile(dest, source)
    except OSError:
        return False


def _is_regular_file(path) -> bool:
    """Whether ``path`` is a regular file (a symlink is not)."""
    if not path:
        return False
    try:
        return stat.S_ISREG(os.lstat(path).st_mode)
    except OSError:
        return False


def _is_current_master(path: str, current: Optional[str]) -> bool:
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


def _reconcile_inplace(
    database: Database, entry: dict, identity_signal=None, *, runtime: bool = False
) -> None:
    old_path, temp_path = entry["old_path"], entry["temp_path"]
    convert = entry["intent"] == "convert"
    if runtime and convert and _swap_job_failed(database, entry):
        # Its job's own swap failed: only the next start may settle the row (it
        # proves the swap, bumps the revision and settles the job), also when the
        # staged file has gone missing meanwhile.
        raise JournalRecoveryDeferred(
            f"journal entry {entry['id']} waits for startup recovery"
        )
    # The DB is already committed for in-place; only the atomic replace may be
    # pending. If the staged temp still exists, redo it; otherwise it's done.
    placed = False
    if temp_path and old_path and Path(temp_path).exists():
        if runtime and convert:
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
            if not _is_regular_file(current):
                _end_swap_job(database, entry, SWAP_UNPROVEN_TEXT)
                raise JournalOwnershipUnproven("the track's file is missing")
            logger.warning(
                "journal entry %s: track no longer at its recorded path; "
                "discarding its staged temp", entry["id"],
            )
            _end_swap_job(database, entry, TRACK_CHANGED_TEXT)
            Path(temp_path).unlink(missing_ok=True)
            database.delete_journal_entry(entry["id"], owner_id=entry["owner_id"])
            return
        if convert and database.track_path_in_use(
            old_path, owner_id=ANY_OWNER, exclude_uuid=entry["uuid_id"]
        ):
            # Another track's file is at the path (this track's master vanished
            # and something else landed there): never write over it.
            _end_swap_job(database, entry, SWAP_UNPROVEN_TEXT)
            raise JournalOwnershipUnproven("another track's file is at the path")
        if not _is_regular_file(temp_path):
            _end_swap_job(database, entry, SWAP_UNPROVEN_TEXT)
            raise JournalOwnershipUnproven("the staged copy is not a regular file")
        fsync_file(Path(temp_path))
        os.replace(temp_path, old_path)
        flush_move(Path(old_path), Path(temp_path))
        placed = True
    if convert and not runtime and not placed:
        # The staged file is already gone: prove the swap happened before the job
        # may say done; the old audio still in place means it was lost. First the
        # track must still be at the row's path, with its file there.
        current = database.get_track_file_path(
            entry["uuid_id"], owner_id=entry["owner_id"]
        )
        if current != old_path or not _is_regular_file(old_path):
            if current != old_path and _is_regular_file(current):
                # The track moved on (a crash after this row's own "track
                # changed" settle, or an older row): nothing is left to place.
                _end_swap_job(database, entry, TRACK_CHANGED_TEXT)
                database.delete_journal_entry(entry["id"], owner_id=entry["owner_id"])
                return
            _end_swap_job(database, entry, SWAP_UNPROVEN_TEXT)
            raise JournalOwnershipUnproven("the track's file is missing")
        if _job_settled_lost(database, entry):
            # A crash after this row's own "lost" settle: the track may already
            # describe the old file, so it is never matched again.
            probed = _probe_master(entry)
        else:
            probed = _probe_swapped_master(database, entry)
        if probed is not None:
            # Settled first: a later failure keeps the row and nothing a later
            # probe could mistake for a done swap.
            _end_swap_job(database, entry, SWAP_LOST_TEXT)
            database.refresh_track_audio_properties(
                entry["uuid_id"], codec=probed.codec, bitrate_kbps=probed.bitrate_kbps,
                sample_rate_hz=probed.sample_rate_hz, channels=probed.channels,
                duration=probed.duration, owner_id=entry["owner_id"],
            )
            database.delete_journal_entry(entry["id"], owner_id=entry["owner_id"])
            return
    _mark_identity_stale(database, entry, identity_signal)
    if convert and not runtime:
        # The bytes changed under the revision the conversion committed: clients
        # must see the change. Then the job is done.
        database.bump_track_revision(entry["uuid_id"], owner_id=entry["owner_id"])
        _end_swap_job(database, entry, None)
    database.delete_journal_entry(entry["id"], owner_id=entry["owner_id"])


def _probe_master(entry: dict):
    """The master at a row's ``old_path`` as read by ffprobe. Raises
    JournalOwnershipUnproven when it cannot be read (the row stays)."""
    try:
        raw = ffprobe_for_metadata(
            Path(entry["old_path"]), timeout=audio_identity.PROBE_TIMEOUT_S
        )
        probed = build_track_metadata(raw) if raw is not None else None
    except Exception:
        probed = None
    if probed is None:
        raise JournalOwnershipUnproven("the track's file could not be read")
    return probed


def _probe_swapped_master(database: Database, entry: dict):
    """Prove that a convert row's swap happened (its staged file is gone): None
    when the master at ``old_path`` has the properties the conversion committed,
    else the master's probed metadata (the swap never happened). Raises
    JournalOwnershipUnproven when the master cannot be read (the row stays)."""
    probed = _probe_master(entry)
    track = database.get_track_by_uuid(entry["uuid_id"], owner_id=entry["owner_id"])
    if track is None:
        raise JournalOwnershipUnproven("the track's file could not be read")
    committed = track.metadata
    if (
        probed.codec == committed.codec
        and probed.sample_rate_hz == committed.sample_rate_hz
        and probed.channels == committed.channels
        and _same_bitrate(probed.bitrate_kbps, committed.bitrate_kbps)
    ):
        return None
    return probed


def _same_bitrate(a: Optional[float], b: Optional[float]) -> bool:
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
    if entry["new_path"] and entry["new_path"] != entry["old_path"]:
        return False
    job_id = conversion_job_id_of(entry)
    if job_id is None:
        return False
    job = database.get_conversion_job(job_id, owner_id=entry["owner_id"])
    return job is not None and job["uuid_id"] == entry["uuid_id"] and job["status"] == "failed"


def _job_settled_lost(database: Database, entry: dict) -> bool:
    """Whether this row's job was already ended "lost" (a crash came after it)."""
    job_id = conversion_job_id_of(entry)
    if job_id is None:
        return False
    job = database.get_conversion_job(job_id, owner_id=entry["owner_id"])
    return (
        job is not None and job["uuid_id"] == entry["uuid_id"]
        and job["status"] == "failed" and job["error_text"] == SWAP_LOST_TEXT
    )


def _end_swap_job(database: Database, entry: dict, error_text: Optional[str]) -> None:
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
    database, music_library_dir, track_locks, identity_signal=None, *, reported=None
) -> int:
    """Finish journal rows kept after a failed identity mark, in a running server.

    Only a row whose staged temp is gone (empty or missing: the file operation is
    over) is considered, and only while no writer holds the track's lock (every
    journal writer holds it, so a held lock means one is in flight and the row
    is skipped). Under the lock the row is re-read and re-checked, then finished
    through the same per-intent recovery startup uses. A failure leaves the row
    for the next pass or for startup. ``reported`` (a set the caller keeps
    across passes) logs a row that keeps failing once, not on every pass; it is
    keyed by (id, uuid, created_at) because row ids are reused, and forgets
    rows that are gone.
    Returns the number of rows finished."""
    finished = 0
    entries = database.list_journal_entries(owner_id=ANY_OWNER)
    if reported is not None:
        # Forget rows that are gone, so a later row reusing an id is logged too.
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
            _reconcile_one(
                database, current, music_library_dir, identity_signal, runtime=True
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
