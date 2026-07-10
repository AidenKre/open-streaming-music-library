import os
from pathlib import Path
from typing import Optional

from app.database.database import (
    Database,
    EDITABLE_METADATA_COLUMNS,
    RevisionConflict,
    SearchParameter,
    TrackNotFound,
    normalize_edit_fields,
)
from app.models.track import Track
from app.services.metadata import is_wav, write_metadata_tags
from app.services.organizer import move_file, sanitized_destination_path
from app.services.track_edit import WriteMode

# DB column -> ffmpeg metadata key, for the columns whose tag name differs.
_FFMPEG_TAG_KEY = {"track_number": "track", "disc_number": "disc"}


class MasterWriteError(Exception):
    """A ``db_and_master`` edit could not place the master on disk (staging or
    move failed). The DB is left unchanged so the caller can surface a 5xx."""


def _build_ffmpeg_tags(fields: dict) -> dict[str, Optional[str]]:
    """Map DB columns to ffmpeg metadata keys for the columns present in
    ``fields``: a present ``None`` clears the tag, an absent column leaves the
    file's tag untouched (the caller decides which columns to reconcile).
    ``year``/``date`` both target the file's ``date`` tag — an explicit
    ``date`` wins, else ``year``."""
    tags: dict[str, Optional[str]] = {}
    for col in ("title", "artist", "album", "album_artist", "genre"):
        if col in fields:
            tags[col] = fields[col]
    for col in ("track_number", "disc_number"):
        if col in fields:
            v = fields[col]
            tags[_FFMPEG_TAG_KEY[col]] = str(v) if v is not None else None
    if "date" in fields:
        tags["date"] = fields["date"]
    elif "year" in fields:
        v = fields["year"]
        tags["date"] = str(v) if v is not None else None
    return tags


class TrackEditor:
    """Orchestrates a track metadata edit across the DB and (optionally) the
    master file. File I/O lives here, never in the pure-DB spine. A per-uuid
    ``TrackLocks`` lock (held by the caller) serializes the staging→move→commit
    region; the ``edit_journal`` + ``reconcile_journal`` make the move↔commit
    window crash-safe."""

    def __init__(self, database: Database, music_library_dir: Path, staging_dir: Path):
        self._db = database
        self._library = Path(music_library_dir)
        self._staging = Path(staging_dir)

    def apply_edit(
        self,
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
            return self._db.apply_track_metadata_edit(uuid_id, fields, base_revision), False

        track = self._current_track(uuid_id)
        if track is None:
            raise TrackNotFound(uuid_id)
        source = Path(track.file_path)

        if is_wav(source) or not source.exists():
            # WAV tagging is out of scope and a missing master can't be written;
            # degrade to DB-only rather than fail the edit.
            rev = self._db.apply_track_metadata_edit(uuid_id, fields, base_revision)
            return rev, False

        return self._apply_with_master(uuid_id, fields, base_revision, track, source)

    def _current_track(self, uuid_id: str) -> Optional[Track]:
        rows = self._db.get_tracks(
            search_parameters=[
                SearchParameter(column="uuid_id", operator="=", value=uuid_id)
            ]
        )
        return rows[0] if rows else None

    def _apply_with_master(
        self, uuid_id: str, fields: dict, base_revision: Optional[int],
        track: Track, source: Path,
    ) -> tuple[int, bool]:
        merged = track.metadata.model_copy(update=fields)
        dest = sanitized_destination_path(source.name, merged, self._library)

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
        temp = self._staging / f"{uuid_id}{source.suffix}"
        write_metadata_tags(source, temp, _build_ffmpeg_tags(reconcile_fields))

        if dest == source:
            rev = self._inplace(uuid_id, fields, base_revision, source, temp)
        else:
            rev = self._relocate(uuid_id, fields, base_revision, source, dest, temp)
        return rev, True

    def _inplace(
        self, uuid_id: str, fields: dict, base_revision: Optional[int],
        source: Path, temp: Path,
    ) -> int:
        # Commit the DB first; a crash before the replace leaves file=old/DB=new
        # — the same benign divergence as a DB-only edit.
        journaled = False
        try:
            rev = self._db.apply_track_metadata_edit(uuid_id, fields, base_revision)
            # Journal AFTER the commit (a journal row implies the DB advanced)
            # and BEFORE the destructive replace. From here the journal owns
            # `temp`: a hard crash *or* a caught os.replace error leaves temp +
            # row for reconcile_journal to redo, so we must not delete temp on
            # the error path once journaled.
            entry = self._db.insert_journal_entry(
                "inplace", uuid_id, old_path=str(source), temp_path=str(temp)
            )
            journaled = True
            os.replace(temp, source)
            self._db.delete_journal_entry(entry)
            return rev
        except BaseException:
            if not journaled:
                # DB commit or journal insert failed — nothing references `temp`.
                temp.unlink(missing_ok=True)
            raise

    def _relocate(
        self, uuid_id: str, fields: dict, base_revision: Optional[int],
        source: Path, dest: Path, temp: Path,
    ) -> int:
        # Journal the move BEFORE doing it: a crash in the move↔commit window is
        # reverted (DB not advanced) or finished (DB advanced) at startup.
        try:
            entry = self._db.insert_journal_entry(
                "relocate", uuid_id,
                old_path=str(source), new_path=str(dest), temp_path=str(temp),
            )
        except BaseException:
            temp.unlink(missing_ok=True)  # nothing journaled yet
            raise
        if not move_file(file_path=temp, destination_path=dest):
            self._db.delete_journal_entry(entry)
            temp.unlink(missing_ok=True)  # move failed; drop the staged copy
            raise MasterWriteError(f"could not place master at {dest}")
        try:
            rev = self._db.apply_track_metadata_edit(
                uuid_id, fields, base_revision, new_file_path=str(dest)
            )
        except BaseException:
            # DB did not commit → revert: drop the new copy, keep the old master.
            dest.unlink(missing_ok=True)
            self._db.delete_journal_entry(entry)
            raise
        # Committed: DB now points at `dest`; the old master is redundant.
        source.unlink(missing_ok=True)
        self._db.delete_journal_entry(entry)
        return rev


def reconcile_journal(database: Database) -> None:
    """Idempotent startup pass that finishes or reverts every outstanding
    ``edit_journal`` row, closing the move↔commit window. Safe to run on every
    boot; a clean shutdown leaves no rows."""
    for entry in database.list_journal_entries():
        try:
            _reconcile_one(database, entry)
        except Exception as e:  # never let one bad row block startup
            print(f"journal reconcile failed for entry {entry['id']}: {e}")


def _reconcile_one(database: Database, entry: dict) -> None:
    intent = entry["intent"]
    if intent == "relocate":
        _reconcile_relocate(database, entry)
    elif intent == "inplace":
        _reconcile_inplace(database, entry)
    else:
        # Unknown intent (shouldn't happen) — drop it so it can't loop forever.
        database.delete_journal_entry(entry["id"])


def _reconcile_relocate(database: Database, entry: dict) -> None:
    # Whether the DB commit landed is the source of truth: if file_path == the
    # journal's new_path the move is durable → finish (delete the old master);
    # otherwise the move never committed → revert (delete the new copy, keep old).
    current = database.get_track_file_path(entry["uuid_id"])
    old_path, new_path, temp_path = entry["old_path"], entry["new_path"], entry["temp_path"]
    if current is not None and current == new_path:
        if old_path:
            Path(old_path).unlink(missing_ok=True)
    else:
        if new_path:
            Path(new_path).unlink(missing_ok=True)
    if temp_path:
        Path(temp_path).unlink(missing_ok=True)
    database.delete_journal_entry(entry["id"])


def _reconcile_inplace(database: Database, entry: dict) -> None:
    old_path, temp_path = entry["old_path"], entry["temp_path"]
    # The DB is already committed for in-place; only the atomic replace may be
    # pending. If the staged temp still exists, redo it; otherwise it's done.
    if temp_path and old_path and Path(temp_path).exists():
        os.replace(temp_path, old_path)
    database.delete_journal_entry(entry["id"])
