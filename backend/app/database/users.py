"""Users, sessions and per-user settings.

One part of ``Database`` (``app/database/database.py``). It imports the shared
core and never another part.
"""

from app.core.owner import _require_owner
from app.database.core import DatabaseCore
from app.database.table_registry import owner_predicate, REGISTRY


class UsernameTaken(Exception):
    """Another user already owns the requested username key."""


class UsersPart(DatabaseCore):
    """The ``users``, ``auth_sessions`` and ``user_settings`` rows, and the row
    side of ``users delete`` (mark, purge, drop)."""

    def list_users(self) -> list[dict]:
        with self._connection() as conn:
            rows = conn.execute(
                "SELECT u.*, (SELECT count(*) FROM tracks t WHERE t.owner_id = u.id) "
                "AS track_count FROM users u ORDER BY u.id"
            ).fetchall()
        return [dict(row) for row in rows]

    def get_master_admin(self) -> dict | None:
        with self._connection() as conn:
            row = conn.execute(
                "SELECT * FROM users WHERE is_master_admin = 1"
            ).fetchone()
        return dict(row) if row else None

    def get_user(self, user_id: int) -> dict | None:
        with self._connection() as conn:
            row = conn.execute(
                "SELECT * FROM users WHERE id = ?", (user_id,)
            ).fetchone()
        return dict(row) if row else None

    def get_library_folders(self) -> list[str]:
        with self._connection() as conn:
            rows = conn.execute("SELECT library_folder FROM users").fetchall()
        return [row["library_folder"] for row in rows]

    def list_user_folders(self) -> list[dict]:
        with self._connection() as conn:
            rows = conn.execute(
                "SELECT id, username, library_folder, deleting_at FROM users"
            ).fetchall()
        return [dict(row) for row in rows]

    def create_master_admin(
        self,
        username: str,
        username_key: str,
        password_hash: str,
        library_folder: str,
        created_at: int,
    ) -> int:
        with self._connection(commit=True) as conn:
            cursor = conn.execute(
                "INSERT INTO users (username, username_key, password_hash, is_admin, "
                "is_master_admin, library_folder, created_at) "
                "VALUES (?, ?, ?, 1, 1, ?, ?)",
                (username, username_key, password_hash, library_folder, created_at),
            )
            return cursor.lastrowid

    def start_login_session(
        self,
        *,
        user_id: int,
        verified_hash: str,
        new_hash: str | None,
        token_hash: str,
        media_hash: str,
        created_at: int,
    ) -> bool:
        """Insert the login session (and an optional rehash) only if the user
        still has the verified hash and is neither disabled nor deleting."""
        with self._connection(commit=True, immediate=True) as conn:
            row = conn.execute(
                "SELECT password_hash, disabled_at, deleting_at FROM users WHERE id = ?",
                (user_id,),
            ).fetchone()
            if (
                row is None
                or row["password_hash"] != verified_hash
                or row["disabled_at"] is not None
                or row["deleting_at"] is not None
            ):
                return False
            if new_hash is not None:
                conn.execute(
                    "UPDATE users SET password_hash = ? WHERE id = ?",
                    (new_hash, user_id),
                )
            self._insert_auth_session_in(
                conn, token_hash, media_hash, user_id, created_at
            )
            return True

    def get_user_by_username_key(self, username_key: str) -> dict | None:
        with self._connection() as conn:
            row = conn.execute(
                "SELECT * FROM users WHERE username_key = ?", (username_key,)
            ).fetchone()
        return dict(row) if row else None

    def rename_user(self, user_id: int, username: str, username_key: str) -> None:
        with self._connection(commit=True, immediate=True) as conn:
            taken = conn.execute(
                "SELECT 1 FROM users WHERE username_key = ? AND id != ?",
                (username_key, user_id),
            ).fetchone()
            if taken:
                raise UsernameTaken(username_key)
            conn.execute(
                "UPDATE users SET username = ?, username_key = ? WHERE id = ?",
                (username, username_key, user_id),
            )

    def register_user(
        self,
        *,
        username: str,
        username_key: str,
        password_hash: str,
        created_at: int,
        token_hash: str,
        media_hash: str,
        check,
        choose_folder,
    ) -> dict:
        with self._connection(commit=True, immediate=True) as conn:
            check(conn)
            if conn.execute(
                "SELECT 1 FROM users WHERE username_key = ?", (username_key,)
            ).fetchone():
                raise UsernameTaken(username_key)
            folders = [r[0] for r in conn.execute("SELECT library_folder FROM users")]
            folder = choose_folder(folders)
            cursor = conn.execute(
                "INSERT INTO users (username, username_key, password_hash, is_admin, "
                "is_master_admin, library_folder, created_at) "
                "VALUES (?, ?, ?, 0, 0, ?, ?)",
                (username, username_key, password_hash, folder, created_at),
            )
            user_id = cursor.lastrowid
            self._insert_auth_session_in(
                conn, token_hash, media_hash, user_id, created_at
            )
            return dict(
                conn.execute("SELECT * FROM users WHERE id = ?", (user_id,)).fetchone()
            )

    def set_password_hash(self, user_id: int, password_hash: str) -> None:
        with self._connection(commit=True) as conn:
            conn.execute(
                "UPDATE users SET password_hash = ? WHERE id = ?",
                (password_hash, user_id),
            )

    def set_password_hash_and_revoke_sessions(
        self, user_id: int, password_hash: str, revoked_at: int
    ) -> None:
        with self._connection(commit=True) as conn:
            conn.execute(
                "UPDATE users SET password_hash = ? WHERE id = ?",
                (password_hash, user_id),
            )
            conn.execute(
                "UPDATE auth_sessions SET revoked_at = ? "
                "WHERE user_id = ? AND revoked_at IS NULL",
                (revoked_at, user_id),
            )

    def set_user_disabled(self, user_id: int, disabled: bool, now: int) -> None:
        with self._connection(commit=True) as conn:
            conn.execute(
                "UPDATE users SET disabled_at = ? WHERE id = ?",
                (now if disabled else None, user_id),
            )
            if disabled:
                conn.execute(
                    "UPDATE auth_sessions SET revoked_at = ? "
                    "WHERE user_id = ? AND revoked_at IS NULL",
                    (now, user_id),
                )

    def mark_user_deleting(self, user_id: int, now: int) -> None:
        with self._connection(commit=True, immediate=True) as conn:
            conn.execute(
                "UPDATE users SET deleting_at = COALESCE(deleting_at, ?) WHERE id = ?",
                (now, user_id),
            )
            conn.execute("DELETE FROM auth_sessions WHERE user_id = ?", (user_id,))
            conn.execute(
                "INSERT OR IGNORE INTO user_delete_art_capture (user_id, cover_art_id) "
                "SELECT DISTINCT ?, tm.cover_art_id FROM trackmetadata tm "
                "JOIN tracks t ON t.id = tm.track_id "
                "WHERE t.owner_id = ? AND tm.cover_art_id IS NOT NULL",
                (user_id, user_id),
            )

    def purge_user_rows(self, user_id: int, table_order: list[str]) -> None:
        """Step 3 of ``users delete``: one transaction; any error rolls back."""
        with self._connection(commit=True, immediate=True) as conn:
            # FTS first: the album derivation joins artists.
            for row in conn.execute(
                "SELECT tm.track_id, tm.title, tm.artist, tm.album, tm.album_artist "
                "FROM trackmetadata tm JOIN tracks t ON t.id = tm.track_id "
                "WHERE t.owner_id = ?",
                (user_id,),
            ).fetchall():
                self._fts_delete_track_in(conn, row)
            for (album_id,) in conn.execute(
                "SELECT al.id FROM albums al JOIN artists ar ON ar.id = al.artist_id "
                "WHERE ar.owner_id = ?",
                (user_id,),
            ).fetchall():
                self._fts_delete_album_in(conn, album_id)
            for (artist_id,) in conn.execute(
                "SELECT id FROM artists WHERE owner_id = ?", (user_id,)
            ).fetchall():
                self._fts_delete_artist_in(conn, artist_id)
            for table in table_order:
                if table in ("users", "user_delete_art_capture"):
                    continue
                entry = REGISTRY[table]
                if entry.fts_rowid:
                    continue
                conn.execute(
                    f"DELETE FROM {table} WHERE {owner_predicate(table)}", (user_id,)
                )
            for (art_id,) in conn.execute(
                "SELECT cover_art_id FROM user_delete_art_capture WHERE user_id = ?",
                (user_id,),
            ).fetchall():
                self._delete_cover_art_if_unreferenced_in(conn, art_id)

    def delete_user_row(self, user_id: int) -> None:
        with self._connection(commit=True) as conn:
            conn.execute(
                "DELETE FROM user_delete_art_capture WHERE user_id = ?", (user_id,)
            )
            conn.execute("DELETE FROM users WHERE id = ?", (user_id,))

    @staticmethod
    def _insert_auth_session_in(
        conn, token_hash: str, media_hash: str, user_id: int, created_at: int
    ) -> None:
        conn.execute(
            "INSERT INTO auth_sessions (token_hash, media_hash, user_id, created_at) "
            "VALUES (?, ?, ?, ?)",
            (token_hash, media_hash, user_id, created_at),
        )

    def _live_session_by(self, column: str, value: str) -> dict | None:
        if column not in ("token_hash", "media_hash"):
            raise ValueError(f"unsupported session column: {column!r}")
        with self._connection() as conn:
            row = conn.execute(
                "SELECT auth_sessions.token_hash AS session_hash, "
                "users.id AS user_id, users.is_admin, users.is_master_admin, "
                "users.library_folder "
                "FROM auth_sessions JOIN users ON users.id = auth_sessions.user_id "
                f"WHERE auth_sessions.{column} = ? "
                "AND auth_sessions.revoked_at IS NULL "
                "AND users.disabled_at IS NULL AND users.deleting_at IS NULL",
                (value,),
            ).fetchone()
        return dict(row) if row else None

    def get_live_session(self, token_hash: str) -> dict | None:
        return self._live_session_by("token_hash", token_hash)

    def get_live_session_by_media_hash(self, media_hash: str) -> dict | None:
        return self._live_session_by("media_hash", media_hash)

    def revoke_auth_session(self, token_hash: str, revoked_at: int) -> None:
        with self._connection(commit=True) as conn:
            conn.execute(
                "UPDATE auth_sessions SET revoked_at = ? "
                "WHERE token_hash = ? AND revoked_at IS NULL",
                (revoked_at, token_hash),
            )

    def seed_user_setting(self, *, owner_id: int, key: str, value: str) -> None:
        _require_owner(owner_id)
        with self._connection(commit=True) as conn:
            conn.execute(
                "INSERT OR IGNORE INTO user_settings (user_id, key, value) "
                "VALUES (?, ?, ?)",
                (owner_id, key, value),
            )

    def get_user_setting(self, key: str, *, owner_id: int) -> str | None:
        _require_owner(owner_id)
        with self._connection() as conn:
            row = conn.execute(
                "SELECT value FROM user_settings WHERE user_id = ? AND key = ?",
                (owner_id, key),
            ).fetchone()
        return row[0] if row else None

    def set_user_setting(self, key: str, value: str, *, owner_id: int) -> None:
        _require_owner(owner_id)
        with self._connection(commit=True) as conn:
            conn.execute(
                "INSERT INTO user_settings (user_id, key, value) VALUES (?, ?, ?) "
                "ON CONFLICT(user_id, key) DO UPDATE SET value = excluded.value",
                (owner_id, key, value),
            )

    def get_deleting_user_ids(self) -> set[int]:
        with self._connection() as conn:
            rows = conn.execute(
                "SELECT id FROM users WHERE deleting_at IS NOT NULL"
            ).fetchall()
        return {row[0] for row in rows}

    def list_user_track_uuids_for_delete(self, user_id: int) -> set[str]:
        """The user's track and tombstone uuids. Unlike the swallowing reads
        above, a failure raises: a delete must not skip cleanup on a locked db."""
        with self._connection() as conn:
            tracks = conn.execute(
                "SELECT uuid_id FROM tracks WHERE owner_id = ?", (user_id,)
            ).fetchall()
            tombstones = conn.execute(
                "SELECT uuid_id FROM track_tombstones WHERE owner_id = ?", (user_id,)
            ).fetchall()
        return {row[0] for row in tracks} | {row[0] for row in tombstones}
