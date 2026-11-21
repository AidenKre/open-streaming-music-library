"""Cover art rows.

One part of ``Database`` (``app/database/database.py``). It imports the shared
core and never another part.
"""

import sqlite3
from pathlib import Path
from typing import Callable, List, Optional

from app.core.owner import _and_owner, ANY_OWNER, Owner, _require_owner
from app.database.core import DatabaseCore, _row_to_track, _track_select_columns
from app.models.cover_art import CoverArt
from app.models.track import Track


class CoverArtPart(DatabaseCore):
    """The shared ``cover_arts`` rows and a track's reference to one."""

    def get_cover_art_file_paths(self) -> set[str]:
        with self._connection() as conn:
            rows = conn.execute("SELECT file_path FROM cover_arts").fetchall()
        return {row[0] for row in rows}

    _COVER_ART_SELECT = "SELECT id, sha256, phash, phash_prefix, file_path FROM cover_arts"

    @staticmethod
    def _cover_art_from_row(row: sqlite3.Row) -> CoverArt:
        return CoverArt(
            id=row["id"], sha256=row["sha256"], phash=row["phash"],
            phash_prefix=row["phash_prefix"], file_path=Path(row["file_path"]),
        )

    def _find_cover_art_by_id(self, cover_art_id: int) -> CoverArt | None:
        """Like ``get_cover_art_by_id``, but a database error raises."""
        with self._connection() as conn:
            row = conn.execute(
                f"{self._COVER_ART_SELECT} WHERE id = ?",
                (cover_art_id,),
            ).fetchone()
            if row is None:
                return None
            return self._cover_art_from_row(row)

    def get_cover_art_by_id(self, cover_art_id: int) -> CoverArt | None:
        try:
            return self._find_cover_art_by_id(cover_art_id)
        except Exception as e:
            print(f"Failed to get cover art by id {cover_art_id}: {e}")
            return None

    def get_cover_art_by_sha256(self, sha256: str) -> CoverArt | None:
        try:
            with self._connection() as conn:
                row = conn.execute(
                    f"{self._COVER_ART_SELECT} WHERE sha256 = ?",
                    (sha256,),
                ).fetchone()
                if row is None:
                    return None
                return self._cover_art_from_row(row)
        except Exception as e:
            print(f"Failed to get cover art by sha256: {e}")
            return None

    def get_cover_arts_by_phash_prefix(self, prefix: str) -> list[CoverArt]:
        try:
            with self._connection() as conn:
                rows = conn.execute(
                    f"{self._COVER_ART_SELECT} WHERE phash_prefix = ?",
                    (prefix,),
                ).fetchall()
                return [self._cover_art_from_row(row) for row in rows]
        except Exception as e:
            print(f"Failed to get cover arts by phash prefix: {e}")
            return []

    def insert_cover_art(self, sha256: str, phash: str, phash_prefix: str, file_path: str) -> int:
        try:
            with self._connection(commit=True) as conn:
                cursor = conn.execute(
                    'INSERT INTO cover_arts (sha256, phash, phash_prefix, file_path) VALUES (?, ?, ?, ?)',
                    (sha256, phash, phash_prefix, file_path),
                )
                return cursor.lastrowid  # type: ignore[return-value]
        except Exception as e:
            print(f"Error inserting cover art: {e}")
            raise

    def delete_cover_art(
        self, cover_art_id: int, *, owner_id: Owner,
        remove_file: Optional[Callable[[], None]] = None,
    ) -> bool:
        """Delete the row only when no trackmetadata references it. The check
        spans every owner, so only ANY_OWNER is accepted. When the row matched,
        ``remove_file`` runs inside the same write transaction before the
        commit; if it raises, the deletion rolls back (the row stays) and the
        exception propagates."""
        if owner_id is not ANY_OWNER:
            raise TypeError("delete_cover_art requires owner_id=ANY_OWNER")
        with self._connection(commit=True, immediate=True) as conn:
            deleted = self._delete_cover_art_if_unreferenced_in(conn, cover_art_id)
            if deleted and remove_file is not None:
                remove_file()
            return deleted

    def owns_cover_art(self, cover_art_id: int, *, owner_id: int) -> bool:
        """True when a track owned by owner_id references this cover art."""
        _require_owner(owner_id)
        with self._connection() as conn:
            row = conn.execute(
                "SELECT EXISTS (SELECT 1 FROM trackmetadata tm "
                "JOIN tracks t ON t.uuid_id = tm.uuid_id "
                "WHERE tm.cover_art_id = ? AND t.owner_id = ?)",
                (cover_art_id, owner_id),
            ).fetchone()
        return bool(row[0])

    def get_owned_cover_art(self, cover_art_id: int, *, owner_id: int) -> CoverArt | None:
        """The cover art row when a track of owner_id references it, else None
        (foreign and unknown ids alike). A database error raises."""
        if not self.owns_cover_art(cover_art_id, owner_id=owner_id):
            return None
        return self._find_cover_art_by_id(cover_art_id)

    def get_tracks_missing_cover_art(self, *, owner_id: Owner) -> List[Track]:
        """Return tracks where has_album_art=1 AND cover_art_id IS NULL."""
        suffix, params = _and_owner("t.owner_id", owner_id)
        try:
            with self._connection() as conn:
                rows = conn.execute(
                    f"SELECT {_track_select_columns()} "
                    "FROM trackmetadata AS tm "
                    "JOIN tracks AS t ON tm.uuid_id = t.uuid_id "
                    "WHERE tm.has_album_art = 1 AND tm.cover_art_id IS NULL" + suffix,
                    params,
                ).fetchall()
                return [_row_to_track(row) for row in rows]
        except Exception as e:
            print(f"Failed to get tracks missing cover art: {e}")
            return []

    def update_track_cover_art_id(
        self, uuid_id: str, cover_art_id: int, *, owner_id: int
    ) -> bool:
        """Set cover_art_id for a specific track identified by uuid_id.

        Allocates a fresh revision so the frontend's incremental sync sees the
        cover-art assignment — without it, a backfill-only change would never
        appear in a ``GET /changes`` page.
        """
        _require_owner(owner_id)
        suffix, params = _and_owner("owner_id", owner_id)
        try:
            with self._connection(commit=True) as conn:
                cursor = conn.execute(
                    "UPDATE trackmetadata SET cover_art_id = ? WHERE uuid_id = ? "
                    "AND uuid_id IN (SELECT uuid_id FROM live_tracks WHERE uuid_id = ?"
                    + suffix
                    + ")",
                    (cover_art_id, uuid_id, uuid_id, *params),
                )
                if cursor.rowcount > 0:
                    self._bump_track_revision(conn, uuid_id)
                return cursor.rowcount > 0
        except Exception as e:
            print(f"Failed to update cover_art_id for track {uuid_id}: {e}")
            return False
