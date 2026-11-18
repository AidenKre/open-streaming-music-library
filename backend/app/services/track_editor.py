import logging
import os
import unicodedata
import uuid
from pathlib import Path
from typing import Optional

from app.core.durable_fs import fsync_file
from app.library import Library
from app.database.database import (
    EDITABLE_METADATA_COLUMNS,
    RevisionConflict,
    TrackNotFound,
    TrackPendingDeletion,
    normalize_edit_fields,
)
from app.models.track import Track
from app.services.metadata import build_ffmpeg_tags, is_wav, write_metadata_tags
from app.services.organizer import flush_move, sanitized_destination_path
from app.services.path_sanitize import assert_within
from app.services.track_edit import WriteMode

# Journal recovery lives in ``journal_recovery`` (runtime) and ``journal_settle``
# (start-up); these names stay importable from here.
from app.services.journal_recovery import (  # noqa: F401
    JournalOwnershipUnproven,
    JournalRecoveryDeferred,
    PendingOldMasters,
    finish_kept_journal_rows,
    finish_track_journal_rows,
    reached_durable_point,
)
from app.services.journal_settle import reconcile_journal  # noqa: F401
from app.services.master_replace import (  # noqa: F401
    MoveRefused,
    flush_journal_row,
    move_to_new_path,
    settle_old_master,
)


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

    def __init__(
        self, music_library_dir: Path, staging_dir: Path, identity_signal=None,
        pending_old_masters=None,
    ):
        self._library = Path(music_library_dir)
        # Anything with notify() (the app passes the identity worker's wake-up); None = no wake-up.
        self._identity_signal = identity_signal
        self._staging = Path(staging_dir)
        # Old masters kept after a failed durable point (shared with conversion).
        self._pending = pending_old_masters if pending_old_masters is not None else PendingOldMasters()

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
        degrade to DB-only with ``master_written=False``. Raises
        ``TrackPendingDeletion`` (writing nothing) for a track whose deletion
        is pending."""
        # The caller holds the track lock, and the deletion worker writes its
        # journal row only under that same lock, so this check holds for the
        # whole edit.
        if library.is_pending_deletion(uuid_id):
            raise TrackPendingDeletion(uuid_id)
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
        """Finish this track's kept journal rows (runtime recovery,
        ``journal_recovery.reconcile_one``) before staging or writing; refuse
        the edit if any row remains."""
        finish_track_journal_rows(
            library, uuid_id, self._library, self._identity_signal, self._pending
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
        # The shared moving sequence journals the move before doing it and
        # undoes it when the commit raises. The staged temp is dropped here,
        # at once, whenever the sequence releases it (no row names it then).
        placed = True
        try:
            rev = move_to_new_path(
                library, uuid_id, intent="relocate", source=source, dest=dest, staged=temp,
                root=root, pending_old_masters=self._pending,
                commit=lambda: library.apply_track_metadata_edit(
                    uuid_id, fields, base_revision, new_file_path=str(dest),
                    master_rewritten=True,
                ),
                release_staged=lambda: temp.unlink(missing_ok=True),
            )
        except MoveRefused:
            placed = False
        if not placed:
            logger.warning("could not place the master of %s at its new location", uuid_id)
            raise MasterWriteError("could not place the master at its new location")
        self._notify_identity()
        return rev


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
