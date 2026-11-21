"""Track writes, and the reads by uuid and by path.

One part of ``Database`` (``app/database/database.py``). It imports the shared
core and never another part.
"""

import re
import sqlite3
import unicodedata
from typing import Any, List, Optional

from app.core.owner import _and_owner, Owner, _owner_predicate, _require_owner
from app.database.core import (
    CoverArtGone,
    DatabaseCore,
    _fold_path,
    _is_taken_path,
    _row_to_track,
    track_path_values,
    _track_select_columns,
    TrackNotFound,
    TrackPathTaken,
)
from app.models.edit_fields import EDIT_FIELD_SPECS
from app.models.track import Track

# Track tag fields a user may edit via Get Info / PATCH — derived from the
# single field-spec table (see app/models/edit_fields.py). Deliberately NOT
# ``ALLOWED_METADATA_COLUMNS`` — that list includes audio-derived columns
# (codec/duration/bitrate_kbps/sample_rate_hz/channels/has_album_art/
# cover_art_id) which must never be hand-edited.
EDITABLE_METADATA_COLUMNS = [spec.key for spec in EDIT_FIELD_SPECS]


class EmptyTrackEdit(Exception):
    """Raised when an edit would blank a track's whole identity (title, artist,
    and album all empty). Distinct from ``add_track``'s ``is_empty`` audio-field
    check — this guards the human-meaningful fields."""


class RevisionConflict(Exception):
    """Raised when an edit's ``base_revision`` no longer matches the stored
    revision — the row moved on under the editor (Option A 409)."""

    def __init__(self, uuid_id: str, base_revision: Optional[int], current_revision: int):
        self.uuid_id = uuid_id
        self.base_revision = base_revision
        self.current_revision = current_revision
        super().__init__(
            f"revision conflict on {uuid_id}: base={base_revision} "
            f"current={current_revision}"
        )


class ConversionJobActive(Exception):
    """A conversion is already queued or running for this uuid."""

    def __init__(self, uuid_id: str, job_id: int):
        self.uuid_id = uuid_id
        self.job_id = job_id
        super().__init__(f"conversion job {job_id} already active for {uuid_id}")


class ConversionJobNotRunning(Exception):
    """The job left 'running' (e.g. cancelled) before its result committed."""


# Leading 4-digit year prefix of a `date` string (e.g. "2019-05-01" -> "2019").
_YEAR_PREFIX = re.compile(r"^\s*(\d{4})")


def normalize_edit_fields(fields: dict) -> dict:
    """Canonicalize a validated edit-field dict before it is applied or used to
    derive file/tag/path state. Idempotent; returns a new dict; an untouched
    field stays untouched.

    - NFC-normalizes every string value: the identity upsert is keyed on
      ``LOWER(name)`` (which doesn't fold Unicode composition), and the on-disk
      layout must be derived from the same bytes the DB stores.
    - Keeps ``year``/``date`` consistent, with ``date`` canonical: editing
      ``date`` re-derives ``year`` from its leading 4 digits (unparseable /
      cleared -> ``year`` cleared); editing only ``year`` sets ``date`` to the
      bare year.

    Lives in the spine so every caller of ``apply_track_metadata_edit`` (PATCH
    today; conversion and bulk edit later) gets the invariants without knowing
    about them."""
    out = {
        k: unicodedata.normalize("NFC", v) if isinstance(v, str) else v
        for k, v in fields.items()
    }
    if "date" in out:
        d = out["date"]
        m = _YEAR_PREFIX.match(d) if isinstance(d, str) else None
        out["year"] = int(m.group(1)) if m else None
    elif "year" in out:
        y = out["year"]
        out["date"] = str(y) if y is not None else None
    return out


class TracksPart(DatabaseCore):
    """A track's rows: add, the tag-edit spine, the edit journal, conversion jobs,
    the file-derived fields, delete; and the reads by uuid and by path. The list,
    count, change-stream and search reads are in ``browse.py``."""

    def add_track(
        self, track: Track, timeout: float = 5, *, owner_id: int,
        fingerprinter_present: bool = False,
    ) -> bool:
        _require_owner(owner_id)
        if track.metadata.is_empty():
            print(
                f"empty metadata track passed to Database.add_track(): {track.metadata}"
            )
            return False

        try:
            # Local import: app.services' package init imports this module (cycle).
            from app.services.audio_identity import stat_snapshot

            # Stat before taking the write lock.
            stat = stat_snapshot(track.file_path)
            with self._connection(commit=True, timeout=timeout) as conn:
                self._insert_track_in(
                    conn, track, owner_id=owner_id,
                    fingerprinter_present=fingerprinter_present, stat=stat,
                )

            return True
        except (CoverArtGone, TrackPathTaken):
            # The caller has an answer of its own for each: register the art
            # again; choose another name for the file.
            raise
        except Exception as e:
            print(f"Failed to add track {track}. {e}")
            return False

    @staticmethod
    def _recompute_named_album_year(conn, album_id: Optional[int]) -> None:
        """Reset a *named* album's year to MAX over its remaining members.
        ``_upsert_album`` only ever raises an album's year, so a downward edit
        (a member lowering/clearing its year, or leaving the album) needs this.
        Single-grouping albums carry year as identity and are reconciled by the
        normal upsert path, so they are excluded."""
        if album_id is None:
            return
        conn.execute(
            'UPDATE albums SET "year" = '
            '(SELECT MAX("year") FROM trackmetadata WHERE album_id = ?) '
            "WHERE id = ? AND is_single_grouping = 0",
            (album_id, album_id),
        )

    def _update_track_metadata(
        self, conn, uuid_id: str, fields: dict, new_file_path: Optional[str] = None
    ) -> int:
        """Pure-DB metadata edit — no file I/O. ``fields`` is the validated,
        present subset of ``EDITABLE_METADATA_COLUMNS`` (an explicit ``None``
        means "clear"). Reassigns artist/album identity, reconciles orphaned
        parents + FTS, and bumps the track revision. When ``new_file_path`` is
        given (a master relocation already moved the file), the ``tracks.file_path``
        is updated to match — still pure-DB. Reused by the PATCH orchestration
        and (future) bulk edit, all inside one caller txn."""
        cur = conn.execute(
            "SELECT track_id, artist_id, album_id, title, artist, album, "
            'album_artist, "year", "date", genre, track_number, disc_number '
            "FROM trackmetadata WHERE uuid_id = ?",
            (uuid_id,),
        ).fetchone()
        if cur is None:
            raise TrackNotFound(uuid_id)

        track_db_id = cur["track_id"]
        owner_id = conn.execute(
            "SELECT owner_id FROM tracks WHERE id = ?", (track_db_id,)
        ).fetchone()["owner_id"]
        old_artist_id = cur["artist_id"]
        old_album_id = cur["album_id"]

        # Merge present edits over current values, then NFC-normalize the
        # identity strings before they reach the LOWER()-keyed upsert
        # (otherwise canonically-equivalent spellings won't dedup).
        def pick(col):
            return fields[col] if col in fields else cur[col]

        new = {col: pick(col) for col in EDITABLE_METADATA_COLUMNS}
        for col in ("artist", "album", "album_artist"):
            if isinstance(new[col], str):
                new[col] = unicodedata.normalize("NFC", new[col])

        # Don't let an edit blank the whole track — checked on the *merged*
        # post-edit state so a partial clear (e.g. just the title) is fine as
        # long as some identity survives. album_artist counts: effective_artist
        # prefers it over artist, so a compilation track whose album_artist
        # remains keeps full library identity.
        def _blank(v):
            return v is None or (isinstance(v, str) and not v.strip())

        if (
            _blank(new["title"])
            and _blank(new["artist"])
            and _blank(new["album"])
            and _blank(new["album_artist"])
        ):
            raise EmptyTrackEdit(uuid_id)

        # No effective artist ⇒ artist cleared; both ids are None (an album row
        # requires a non-null artist).
        new_artist_id, new_album_id = self._upsert_identity(
            conn, owner_id, new["artist"], new["album"], new["album_artist"], new["year"],
        )
        self._assert_parents_owned(conn, owner_id, new_artist_id, new_album_id)

        conn.execute(
            "UPDATE trackmetadata SET title = ?, artist = ?, album = ?, "
            'album_artist = ?, "year" = ?, "date" = ?, genre = ?, '
            "track_number = ?, disc_number = ?, artist_id = ?, album_id = ? "
            "WHERE uuid_id = ?",
            (
                new["title"], new["artist"], new["album"], new["album_artist"],
                new["year"], new["date"], new["genre"], new["track_number"],
                new["disc_number"], new_artist_id, new_album_id, uuid_id,
            ),
        )

        # Reconcile parents with the row already reassigned: GC the old ones if
        # now empty, then recompute year for any surviving named album whose
        # membership changed.
        if old_album_id != new_album_id:
            self._orphan_gc_album(conn, old_album_id)
        if old_artist_id != new_artist_id:
            self._orphan_gc_artist(conn, old_artist_id)
        # Only recompute the old album's year when this edit could actually
        # move it: membership changed, or year/date was itself touched.
        if old_album_id is not None and (
            old_album_id != new_album_id
            or not fields.keys().isdisjoint(("year", "date"))
        ):
            self._recompute_named_album_year(conn, old_album_id)
        if new_album_id != old_album_id:
            self._recompute_named_album_year(conn, new_album_id)

        # Rewrite this track's own FTS row: delete old terms, insert new ones.
        self._fts_delete_track_in(conn, cur)
        self._fts_add_track_in(
            conn, track_db_id, new["title"], new["artist"], new["album"], new["album_artist"],
        )

        if new_file_path is not None:
            self._set_track_path_in(conn, uuid_id, new_file_path)

        return self._bump_track_revision(conn, uuid_id)

    @staticmethod
    def _set_track_path_in(conn, uuid_id: str, path: str) -> None:
        """The one statement that changes a track's path, its folded forms with
        it. Raises ``TrackPathTaken`` when another track's row names the path
        (any spelling of it); a new spelling of the track's own path is fine."""
        try:
            conn.execute(
                "UPDATE tracks SET file_path = ?, file_path_fold = ?, file_folder_fold = ? "
                "WHERE uuid_id = ?",
                (*track_path_values(path), uuid_id),
            )
        except sqlite3.IntegrityError as e:
            if _is_taken_path(e):
                raise TrackPathTaken(uuid_id) from e
            raise

    def apply_track_metadata_edit(
        self,
        uuid_id: str,
        fields: dict,
        base_revision: Optional[int],
        new_file_path: Optional[str] = None,
        timeout: float = 5,
        *,
        owner_id: int,
        master_rewritten: bool = False,
    ) -> int:
        """DB orchestration for a track metadata edit. Opens one write txn
        with ``BEGIN IMMEDIATE`` (so the revision check below actually holds
        SQLite's write lock -- a plain read holds none, so without this a
        second concurrent call could pass the same check against the same
        stale revision before either has written), enforces the Option-A 409
        (``base_revision`` vs the stored revision) *before* the bump, runs the
        pure-DB spine, and commits. ``new_file_path`` (set by the
        master-relocation path after it has moved the file) is written to
        ``tracks.file_path`` in the same txn. ``master_rewritten`` (the master's
        bytes were rewritten) also marks the audio identity stale ('tag_write') in
        the same txn. Returns the new revision. Raises
        ``TrackNotFound`` / ``RevisionConflict``; lets
        ``sqlite3.OperationalError`` ("database is locked") propagate so the
        caller can surface a retryable error rather than a silent failure."""
        _require_owner(owner_id)
        fields = normalize_edit_fields(fields)
        with self._connection(commit=True, timeout=timeout, immediate=True) as conn:
            suffix, params = _and_owner("owner_id", owner_id)
            row = conn.execute(
                "SELECT revision FROM tracks WHERE uuid_id = ?" + suffix,
                (uuid_id, *params),
            ).fetchone()
            if row is None:
                raise TrackNotFound(uuid_id)
            current_revision = row["revision"]
            if base_revision is None or base_revision != current_revision:
                raise RevisionConflict(uuid_id, base_revision, current_revision)

            revision = self._update_track_metadata(conn, uuid_id, fields, new_file_path)
            if master_rewritten:
                self._mark_audio_identity_stale_in(conn, uuid_id, "tag_write")
            return revision

    # ── Edit journal (crash-safety for master-file writes) ──────────────────

    def insert_journal_entry(
        self,
        intent: str,
        uuid_id: str,
        old_path: Optional[str] = None,
        new_path: Optional[str] = None,
        temp_path: Optional[str] = None,
        *,
        owner_id: int,
    ) -> int:
        """Record a pending destructive FS step *before* performing it. Returns
        the journal row id so the caller can clear it once the step is durably
        finished (or reverted)."""
        _require_owner(owner_id)
        with self._connection(commit=True) as conn:
            cursor = conn.execute(
                "INSERT INTO edit_journal "
                "(intent, uuid_id, old_path, new_path, temp_path, created_at, owner_id) "
                "VALUES (?, ?, ?, ?, ?, unixepoch(), ?)",
                (intent, uuid_id, old_path, new_path, temp_path, owner_id),
            )
            return cursor.lastrowid  # type: ignore[return-value]

    def list_journal_entries(self, *, owner_id: Owner) -> List[dict]:
        """All outstanding journal rows, oldest first. Read once at startup by
        the reconcile pass."""
        clause, params = _owner_predicate("owner_id", owner_id)
        with self._connection() as conn:
            rows = conn.execute(
                "SELECT id, intent, uuid_id, old_path, new_path, temp_path, "
                "created_at, owner_id FROM edit_journal"
                + (f" WHERE {clause}" if clause else "")
                + " ORDER BY id",
                params,
            ).fetchall()
            return [dict(row) for row in rows]

    def has_journal_entry_for_uuid(self, uuid_id: str, *, owner_id: Owner) -> bool:
        """Whether a destructive FS step on this track is still awaiting
        reconcile (e.g. a same-path replace that failed in-process)."""
        suffix, params = _and_owner("owner_id", owner_id)
        with self._connection() as conn:
            return conn.execute(
                "SELECT 1 FROM edit_journal WHERE uuid_id = ?" + suffix + " LIMIT 1",
                (uuid_id, *params),
            ).fetchone() is not None

    def delete_journal_entry(self, entry_id: int, *, owner_id: int) -> None:
        _require_owner(owner_id)
        with self._connection(commit=True) as conn:
            conn.execute(
                "DELETE FROM edit_journal WHERE id = ? AND owner_id = ?",
                (entry_id, owner_id),
            )

    def get_track_by_uuid(self, uuid_id: str, *, owner_id: Owner) -> Optional[Track]:
        """The hydrated track for a uuid, or None. The one lookup shared by
        the editor, the streaming source resolver, and GET /tracks/{uuid}.
        A database error raises; it is never read as "no such track"."""
        owner_clause, owner_values = _and_owner("t.owner_id", owner_id)
        with self._connection(timeout=5) as conn:
            row = conn.execute(
                f"SELECT {_track_select_columns()} "
                "FROM trackmetadata AS tm "
                "JOIN tracks AS t ON tm.uuid_id = t.uuid_id "
                f"WHERE t.uuid_id = ?{owner_clause}",
                (uuid_id, *owner_values),
            ).fetchone()
        return _row_to_track(row) if row is not None else None

    def get_track_file_path(self, uuid_id: str, *, owner_id: Owner) -> Optional[str]:
        """Current ``tracks.file_path`` for a uuid, or None if the track is gone.
        Used by journal reconcile to tell whether a relocate's DB commit landed."""
        suffix, params = _and_owner("owner_id", owner_id)
        with self._connection() as conn:
            row = conn.execute(
                "SELECT file_path FROM tracks WHERE uuid_id = ?" + suffix,
                (uuid_id, *params),
            ).fetchone()
            return row["file_path"] if row is not None else None

    def track_path_in_use(
        self, path: str, *, owner_id: Owner, exclude_uuid: Optional[str] = None
    ) -> bool:
        """True when a track (of ``owner_id``, or of any owner with ``ANY_OWNER``)
        other than ``exclude_uuid`` has ``path`` as its master file. Paths compare
        by canonical caseless form (NFD, casefold, NFD): APFS folds Unicode case and ignores the NFC/NFD
        difference (SQLite's NOCASE folds ASCII only), and ingest paths are not
        NFC-normalised, so two spellings can be the same file. Answering "in use"
        too often is the safe side. One probe of the unique index on the stored
        folded path (at most one row has it), whatever the size of the library."""
        suffix, params = _and_owner("owner_id", owner_id)
        if exclude_uuid is not None:
            suffix += " AND uuid_id != ?"
            params = (*params, exclude_uuid)
        with self._connection() as conn:
            return conn.execute(
                "SELECT 1 FROM tracks WHERE file_path_fold = ?" + suffix + " LIMIT 1",
                (_fold_path(path), *params),
            ).fetchone() is not None

    def track_identities_in_folder(self, folder: str, *, owner_id: Owner) -> list[dict]:
        """Every track (of ``owner_id``, or of any owner with ``ANY_OWNER``) whose
        master file sits directly in ``folder``, with its stored exact audio hash
        (None columns when it has no identity row). Folders compare by the same
        canonical caseless form as ``track_path_in_use``. One probe of the index
        on the stored folded folder: only the folder's own tracks are read,
        whatever lies below it and whatever the size of the library."""
        suffix, params = _and_owner("t.owner_id", owner_id)
        with self._connection() as conn:
            rows = conn.execute(
                "SELECT t.file_path, i.exact_state, i.exact_kind, i.exact_digest, "
                "i.sample_rate_hz, i.channels, i.bits_per_sample "
                "FROM tracks t INDEXED BY idx_tracks_file_folder_fold "
                "LEFT JOIN track_audio_identity i ON i.uuid_id = t.uuid_id "
                "WHERE t.file_folder_fold = ?" + suffix,
                (_fold_path(folder), *params),
            ).fetchall()
            return [dict(row) for row in rows]

    # ── Conversion jobs (Phase 2 master-type conversion) ─────────────────────

    _CONVERSION_JOB_COLUMNS = (
        "id, uuid_id, target_codec, target_container, target_bitrate, "
        "base_revision, status, error_text, batch_id, created_at, updated_at, owner_id"
    )

    def insert_conversion_job(
        self,
        uuid_id: str,
        target_codec: str,
        target_container: str,
        target_bitrate: Optional[int],
        base_revision: Optional[int] = None,
        *,
        owner_id: int,
    ) -> int:
        """Persist a new queued conversion job. Returns its id. Raises
        ``ConversionJobActive`` instead if the uuid already has a queued or
        running job -- checked in the same write transaction, so two racing
        POSTs can't both get in."""
        _require_owner(owner_id)
        # TODO(bulk-jobs): a bulk conversion enqueue sets batch_id here (uploads
        # are not jobs: /tracks/uploads, Phase 7).
        with self._connection(commit=True, immediate=True) as conn:
            active = conn.execute(
                "SELECT id FROM conversion_jobs WHERE uuid_id = ? "
                "AND status IN ('queued', 'running') ORDER BY id LIMIT 1",
                (uuid_id,),
            ).fetchone()
            if active is not None:
                raise ConversionJobActive(uuid_id, active["id"])
            cursor = conn.execute(
                "INSERT INTO conversion_jobs "
                "(uuid_id, target_codec, target_container, target_bitrate, "
                "base_revision, status, created_at, updated_at, owner_id) "
                "VALUES (?, ?, ?, ?, ?, 'queued', unixepoch(), unixepoch(), ?)",
                (
                    uuid_id, target_codec, target_container, target_bitrate,
                    base_revision, owner_id,
                ),
            )
            return cursor.lastrowid  # type: ignore[return-value]

    def get_conversion_job(self, job_id: int, *, owner_id: Owner) -> Optional[dict]:
        suffix, params = _and_owner("owner_id", owner_id)
        with self._connection() as conn:
            row = conn.execute(
                f"SELECT {self._CONVERSION_JOB_COLUMNS} FROM conversion_jobs "
                "WHERE id = ?" + suffix,
                (job_id, *params),
            ).fetchone()
            return dict(row) if row is not None else None

    def list_conversion_jobs_with_status(
        self, status: str, *, owner_id: Owner
    ) -> List[dict]:
        """Every job in ``status``, oldest first -- read once at startup to
        fail orphaned ``running`` rows and resubmit ``queued`` ones (no
        worker thread or in-memory queue survives a restart)."""
        suffix, params = _and_owner("owner_id", owner_id)
        with self._connection() as conn:
            rows = conn.execute(
                f"SELECT {self._CONVERSION_JOB_COLUMNS} FROM conversion_jobs "
                "WHERE status = ?" + suffix + " ORDER BY id",
                (status, *params),
            ).fetchall()
            return [dict(row) for row in rows]

    def list_conversion_jobs(
        self,
        *,
        uuid_id: Optional[str] = None,
        statuses: Optional[List[str]] = None,
        batch_id: Optional[str] = None,
        after_id: int = 0,
        limit: int = 50,
        owner_id: Owner,
    ) -> tuple[List[dict], Optional[int]]:
        """Jobs with id > after_id (ascending), optionally filtered. Returns
        (jobs, next_cursor) -- next_cursor is the highest id consumed when the
        page filled exactly `limit` (more rows may exist), else None. Mirrors
        get_changes' "page-fullness implies more" cursor convention."""
        clauses = ["id > ?"]
        params: List[Any] = [after_id]
        if uuid_id is not None:
            clauses.append("uuid_id = ?")
            params.append(uuid_id)
        if statuses:
            clauses.append(f"status IN ({', '.join('?' for _ in statuses)})")
            params.extend(statuses)
        if batch_id is not None:
            clauses.append("batch_id = ?")
            params.append(batch_id)
        owner_clause, owner_params = _owner_predicate("owner_id", owner_id)
        if owner_clause:
            clauses.append(owner_clause)
            params.extend(owner_params)
        where = " AND ".join(clauses)
        with self._connection() as conn:
            rows = conn.execute(
                f"SELECT {self._CONVERSION_JOB_COLUMNS} FROM conversion_jobs "
                f"WHERE {where} ORDER BY id ASC LIMIT ?",
                (*params, limit),
            ).fetchall()
        jobs = [dict(row) for row in rows]
        next_cursor = jobs[-1]["id"] if len(jobs) == limit else None
        return jobs, next_cursor

    def mark_conversion_job_running(self, job_id: int, *, owner_id: int) -> bool:
        """Transition queued->running. Returns False if the job already lost
        a race (e.g. cancelled while queued) -- the caller should no-op."""
        _require_owner(owner_id)
        suffix, params = _and_owner("owner_id", owner_id)
        with self._connection(commit=True) as conn:
            cursor = conn.execute(
                "UPDATE conversion_jobs SET status = 'running', "
                "updated_at = unixepoch() WHERE id = ? AND status = 'queued'" + suffix,
                (job_id, *params),
            )
            return cursor.rowcount > 0

    def mark_conversion_job_failed(
        self, job_id: int, error_text: str, *, owner_id: int, after_commit: bool = False
    ) -> bool:
        """Transition queued/running->failed (queued: the worker died before
        it could even claim the job). Never touches a terminal job, so one
        already cancelled by an external request is never clobbered.

        With ``after_commit`` it moves only a ``done`` job instead: a same-file
        conversion that committed, whose final file swap was refused and could
        not be taken back (``undo_inplace_conversion``): the next start checks
        the track and settles the job from what it finds, or keeps the row."""
        _require_owner(owner_id)
        suffix, params = _and_owner("owner_id", owner_id)
        status_clause = "status = 'done'" if after_commit else "status IN ('queued', 'running')"
        with self._connection(commit=True) as conn:
            cursor = conn.execute(
                "UPDATE conversion_jobs SET status = 'failed', "
                "error_text = ?, updated_at = unixepoch() "
                "WHERE id = ? AND " + status_clause + suffix,
                (error_text, job_id, *params),
            )
            return cursor.rowcount > 0

    def undo_inplace_conversion(
        self,
        job_id: int,
        uuid_id: str,
        journal_id: int,
        error_text: str,
        *,
        codec: Optional[str],
        bitrate_kbps: Optional[float],
        sample_rate_hz: Optional[int],
        channels: Optional[int],
        owner_id: int,
    ) -> Optional[int]:
        """One transaction that takes back an in-place ``complete_conversion_job``
        whose final file swap was refused (the original is still the track's
        file): the four intrinsic fields are written back as given (what they
        were before that commit; ``file_path`` never changed), the revision is
        bumped (a client that read the committed row reads the track again), the
        journal row is deleted and the job goes done -> failed with
        ``error_text``. The audio identity stays marked stale from the commit:
        the worker hashes the file again.

        Only a conversion still as its commit left it is undone: the owner's
        job ``done`` and its own ``convert`` journal row still there. Otherwise
        nothing changes and None is returned. Returns the new revision."""
        _require_owner(owner_id)
        with self._connection(commit=True, immediate=True) as conn:
            pending = conn.execute(
                "SELECT 1 FROM conversion_jobs j "
                "JOIN tracks t ON t.uuid_id = j.uuid_id AND t.owner_id = j.owner_id "
                "JOIN edit_journal e ON e.uuid_id = j.uuid_id AND e.owner_id = j.owner_id "
                "WHERE j.id = ? AND j.uuid_id = ? AND j.owner_id = ? AND j.status = 'done' "
                "AND e.id = ? AND e.intent = 'convert'",
                (job_id, uuid_id, owner_id, journal_id),
            ).fetchone()
            if pending is None:
                return None
            revision = self._apply_conversion_result(
                conn, uuid_id, codec, bitrate_kbps, sample_rate_hz, channels
            )
            conn.execute("DELETE FROM edit_journal WHERE id = ?", (journal_id,))
            conn.execute(
                "UPDATE conversion_jobs SET status = 'failed', error_text = ?, "
                "updated_at = unixepoch() WHERE id = ?",
                (error_text, job_id),
            )
            return revision

    def settle_swapped_conversion_job(
        self, job_id: int, uuid_id: str, *, owner_id: int, error_text: Optional[str] = None
    ) -> bool:
        """Settle a same-file conversion job whose swap startup recovery finished:
        done (text cleared) when ``error_text`` is None, else failed with that
        text. Only a failed or done job of ``uuid_id`` moves. Returns whether a
        row moved."""
        _require_owner(owner_id)
        suffix, params = _and_owner("owner_id", owner_id)
        status = "done" if error_text is None else "failed"
        with self._connection(commit=True) as conn:
            cursor = conn.execute(
                "UPDATE conversion_jobs SET status = ?, error_text = ?, "
                "updated_at = unixepoch() "
                "WHERE id = ? AND uuid_id = ? AND status IN ('failed', 'done')" + suffix,
                (status, error_text, job_id, uuid_id, *params),
            )
            return cursor.rowcount > 0

    def bump_track_revision(self, uuid_id: str, *, owner_id: int) -> Optional[int]:
        """Bump an owned track to the next revision in one transaction (its file's
        bytes changed with no column change, so clients see the track as
        changed). Returns the new revision, or None when the owner has no such
        track."""
        _require_owner(owner_id)
        with self._connection(commit=True) as conn:
            owned = conn.execute(
                "SELECT 1 FROM tracks WHERE uuid_id = ? AND owner_id = ?",
                (uuid_id, owner_id),
            ).fetchone()
            if owned is None:
                return None
            return self._bump_track_revision(conn, uuid_id)

    def mark_conversion_job_cancelled(self, job_id: int, *, owner_id: int) -> bool:
        """Transition queued or running -> cancelled. Returns False if the
        job was already terminal (done/failed/cancelled)."""
        _require_owner(owner_id)
        suffix, params = _and_owner("owner_id", owner_id)
        with self._connection(commit=True) as conn:
            cursor = conn.execute(
                "UPDATE conversion_jobs SET status = 'cancelled', "
                "updated_at = unixepoch() "
                "WHERE id = ? AND status IN ('queued', 'running')" + suffix,
                (job_id, *params),
            )
            return cursor.rowcount > 0

    def complete_conversion_job(
        self,
        job_id: int,
        uuid_id: str,
        codec: str,
        bitrate_kbps: Optional[float],
        sample_rate_hz: Optional[int],
        channels: Optional[int],
        file_path: Optional[str] = None,
        inplace_journal: Optional[tuple[str, str]] = None,
        *,
        owner_id: int,
        identity=None,
        audio_unchanged: bool = False,
        stat: Optional[tuple[int, int, int]] = None,
    ) -> tuple[int, Optional[int]]:
        """One transaction: mark the job done and write the probed intrinsic
        fields (+ file_path if the path changed). Raises
        ``ConversionJobNotRunning`` -- rolling back, so the track is untouched
        -- when the job is no longer 'running' (cancelled out-of-band), so a
        cancel the client saw succeed can never be followed by the conversion
        landing anyway.

        ``inplace_journal=(old_path, temp_path)`` also writes the same-path
        "convert" journal row on this commit, so for that case a journal row
        exists iff the DB advanced -- the invariant start-up recovery
        (``journal_settle``) relies on to redo the pending replace. That commit
        also marks the identity stale ('conversion', old digest cleared), so it
        never leaves the old digest ``current``. A non-None ``identity`` is written
        in the same transaction (None leaves it untouched) with ``stat``, the
        new master's snapshot (None stores NULL). Returns
        ``(revision, journal_id)``."""
        _require_owner(owner_id)
        suffix, params = _and_owner("owner_id", owner_id)
        with self._connection(commit=True) as conn:
            cursor = conn.execute(
                "UPDATE conversion_jobs SET status = 'done', "
                "updated_at = unixepoch() WHERE id = ? AND status = 'running'" + suffix,
                (job_id, *params),
            )
            if cursor.rowcount == 0:
                raise ConversionJobNotRunning(job_id)
            revision = self._apply_conversion_result(
                conn, uuid_id, codec, bitrate_kbps, sample_rate_hz, channels, file_path
            )
            if identity is not None:
                self._write_conversion_identity_in(
                    conn, uuid_id, identity, audio_unchanged=audio_unchanged, stat=stat
                )
            journal_id = None
            if inplace_journal is not None:
                old_path, temp_path = inplace_journal
                journal_id = conn.execute(
                    "INSERT INTO edit_journal "
                    "(intent, uuid_id, old_path, new_path, temp_path, created_at, "
                    "owner_id) "
                    "SELECT 'convert', ?, ?, NULL, ?, unixepoch(), owner_id "
                    "FROM conversion_jobs WHERE id = ?",
                    (uuid_id, old_path, temp_path, job_id),
                ).lastrowid
                self._mark_audio_identity_stale_in(conn, uuid_id, "conversion")
            return revision, journal_id

    def _apply_conversion_result(
        self,
        conn,
        uuid_id: str,
        codec: str,
        bitrate_kbps: Optional[float],
        sample_rate_hz: Optional[int],
        channels: Optional[int],
        file_path: Optional[str] = None,
        duration: Optional[float] = None,
    ) -> int:
        """Pure-DB sibling of ``_update_track_metadata``: writes only the
        intrinsic audio fields a conversion (re)probed, plus ``file_path`` if
        the extension changed. Shares ``_bump_track_revision`` but does no
        artist/album reconciliation and no FTS update (codec/bitrate aren't
        FTS-indexed) -- those columns are untouched by a conversion. These
        columns are deliberately NOT part of ``EDITABLE_METADATA_COLUMNS``;
        only ingestion or conversion may (re)write them."""
        row = conn.execute(
            "SELECT track_id FROM trackmetadata WHERE uuid_id = ?", (uuid_id,)
        ).fetchone()
        if row is None:
            raise TrackNotFound(uuid_id)

        conn.execute(
            "UPDATE trackmetadata SET codec = ?, bitrate_kbps = ?, "
            "sample_rate_hz = ?, channels = ? WHERE uuid_id = ?",
            (codec, bitrate_kbps, sample_rate_hz, channels, uuid_id),
        )
        if duration is not None:
            conn.execute(
                "UPDATE trackmetadata SET duration = ? WHERE uuid_id = ?",
                (duration, uuid_id),
            )
        if file_path is not None:
            self._set_track_path_in(conn, uuid_id, file_path)
        return self._bump_track_revision(conn, uuid_id)

    def refresh_track_audio_properties(
        self,
        uuid_id: str,
        *,
        codec: Optional[str],
        bitrate_kbps: Optional[float],
        sample_rate_hz: Optional[int],
        channels: Optional[int],
        duration: Optional[float],
        owner_id: int,
        file_path: Optional[str] = None,
    ) -> Optional[int]:
        """Re-write the file-derived fields of an owned track (settle check,
        m-L-08) in one transaction and bump its revision. Unknown stays None.
        The audio identity is marked stale ('settle') in the same transaction.
        Returns the new revision, or None when the owner has no such track."""
        _require_owner(owner_id)
        with self._connection(commit=True) as conn:
            owned = conn.execute(
                "SELECT 1 FROM tracks WHERE uuid_id = ? AND owner_id = ?",
                (uuid_id, owner_id),
            ).fetchone()
            if owned is None:
                return None
            revision = self._apply_conversion_result(
                conn, uuid_id, codec, bitrate_kbps, sample_rate_hz, channels,
                file_path=file_path, duration=duration,
            )
            # The file changed after import: every identity layer is stale.
            self._mark_audio_identity_stale_in(conn, uuid_id, "settle")
            return revision

    def delete_track(
        self, uuid_id: str, timeout: float = 5, *, owner_id: int
    ) -> bool:
        _require_owner(owner_id)
        try:
            with self._connection(
                commit=True, timeout=timeout, immediate=True
            ) as conn:
                self._delete_track_in(conn, uuid_id, owner_id=owner_id)
            return True
        except Exception as e:
            print(f"Failed to delete track {uuid_id}. {e}")
            return False

    def get_track_tombstones(self, *, owner_id: Owner) -> list[str]:
        """Return uuids of all hard-deleted tracks. Incremental sync streams
        tombstones by revision via ``get_changes``; this remains as a simple
        helper for ops and tests."""
        suffix, params = _and_owner("owner_id", owner_id)
        try:
            with self._connection() as conn:
                rows = conn.execute(
                    "SELECT uuid_id FROM track_tombstones WHERE 1 = 1" + suffix,
                    params,
                ).fetchall()
                return [row[0] for row in rows]
        except Exception as e:
            print(f"Error fetching track tombstones: {e}")
            return []

    def filter_owned_track_uuids(
        self, uuid_ids: list[str], *, owner_id: int
    ) -> list[str]:
        """The given uuids that are the owner's tracks, in input order
        (duplicates kept); unknown and foreign uuids are dropped."""
        _require_owner(owner_id)
        if not uuid_ids:
            return []
        placeholders = ",".join("?" * len(uuid_ids))
        with self._connection() as conn:
            rows = conn.execute(
                f"SELECT uuid_id FROM tracks WHERE owner_id = ? "
                f"AND uuid_id IN ({placeholders})",
                [owner_id, *uuid_ids],
            ).fetchall()
        owned = {row[0] for row in rows}
        return [u for u in uuid_ids if u in owned]

    def get_all_track_uuids(self, *, owner_id: Owner) -> list[str]:
        suffix, params = _and_owner("owner_id", owner_id)
        try:
            with self._connection() as conn:
                rows = conn.execute(
                    "SELECT uuid_id FROM tracks WHERE 1 = 1" + suffix, params
                ).fetchall()
                return [row[0] for row in rows]
        except Exception as e:
            print(f"Error fetching all track UUIDs: {e}")
            return []
