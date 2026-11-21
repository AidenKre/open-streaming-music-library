"""Last.fm connections and the scrobble outbox.

One part of ``Database`` (``app/database/database.py``). It imports the shared
core and never another part.
"""

import json
import sqlite3

from app.core.owner import _require_owner
import app.database.core as database_core
from app.database.core import DatabaseCore
from app.models.lastfm import (
    BindOutcome,
    BindResult,
    EnableOutcome,
    RESULT_TOO_MANY_TRIES,
    RESULT_TOO_OLD,
)

# How long the purge waits for other programs' read snapshots before giving up.
PURGE_BUSY_TIMEOUT_S = 5


class LastfmPurgeBusy(Exception):
    """Another program holds the write lock: nothing was deleted."""


class LastfmPurgeIncomplete(Exception):
    """The Last.fm rows were deleted, but the files could not be compacted."""


def _problem_fields(raw: bytes) -> tuple[str | None, str | None]:
    """(artist, track) of a stored scrobble payload; None for anything unreadable or
    not valid UTF-8 text (unknown, never "" or replacement text)."""
    try:
        payload = json.loads(raw.decode("utf-8", errors="surrogateescape"))
    except (ValueError, RecursionError):  # deep nesting recurses
        return None, None
    if not isinstance(payload, dict):
        return None, None

    def text(value):
        if not isinstance(value, str):
            return None
        try:
            value.encode("utf-8")
        except UnicodeEncodeError:
            return None
        return value

    return text(payload.get("artist")), text(payload.get("track"))


class LastfmPart(DatabaseCore):
    """The ``lastfm_connections`` and ``scrobble_outbox`` rows: the settings
    routes' reads and writes, the sender's reads and answers, the operator purge."""

    # --- Last.fm connection rows (9D.1b, spec §7.3/§7.4) -------------------------------

    def get_lastfm_connection(self, *, owner_id) -> dict | None:
        """The caller's connection row as stored (ciphertext as given), or None."""
        owner = _require_owner(owner_id)
        with self._connection() as conn:
            return self._lastfm_row(conn, owner)

    @staticmethod
    def _lastfm_row(conn, owner) -> dict | None:
        row = conn.execute(
            "SELECT connection_id, account_name, session_key_enc, opted_in, needs_reconnect,"
            " pending_token_enc, pending_token_expires_at, created_at, updated_at"
            " FROM lastfm_connections WHERE owner_id = ?",
            (owner,),
        ).fetchone()
        if row is None:
            return None
        found = dict(row)
        found["opted_in"] = bool(found["opted_in"])
        found["needs_reconnect"] = bool(found["needs_reconnect"])
        return found

    def store_lastfm_pending_token(self, token_enc, expires_at, now, *, owner_id) -> None:
        """One upsert: records the pending token; any binding and opt-in are untouched."""
        owner = _require_owner(owner_id)
        with self._connection(commit=True) as conn:
            conn.execute(
                "INSERT INTO lastfm_connections (owner_id, pending_token_enc,"
                " pending_token_expires_at, created_at, updated_at) VALUES (?, ?, ?, ?, ?)"
                " ON CONFLICT(owner_id) DO UPDATE SET pending_token_enc = excluded.pending_token_enc,"
                " pending_token_expires_at = excluded.pending_token_expires_at,"
                " updated_at = excluded.updated_at",
                (owner, token_enc, expires_at, now, now),
            )

    def clear_lastfm_pending_token(self, token_enc, now, *, owner_id) -> bool:
        """Clears the token only while the caller's row still holds it; True iff cleared."""
        owner = _require_owner(owner_id)
        with self._connection(commit=True) as conn:
            cursor = conn.execute(
                "UPDATE lastfm_connections SET pending_token_enc = NULL,"
                " pending_token_expires_at = NULL, updated_at = ?"
                " WHERE owner_id = ? AND pending_token_enc = ?",
                (now, owner, token_enc),
            )
            return cursor.rowcount > 0

    def bind_lastfm_session(self, token_enc, *, account_name, session_key_enc,
                            new_connection_id, now, owner_id) -> BindResult:
        """Applies a completed authorisation in one transaction, only if the caller's
        row still holds the token that was sent (spec §7.4); otherwise binds nothing."""
        owner = _require_owner(owner_id)
        with self._connection(commit=True, immediate=True) as conn:
            row = self._lastfm_row(conn, owner)
            if (
                row is None
                or token_enc is None
                or row["pending_token_enc"] is None
                or row["pending_token_enc"] != token_enc
            ):
                return BindResult(BindOutcome.TOKEN_CHANGED)
            if row["session_key_enc"] is None:
                changed = conn.execute(
                    "UPDATE lastfm_connections SET connection_id = ?, account_name = ?,"
                    " session_key_enc = ?, opted_in = 0, needs_reconnect = 0,"
                    " pending_token_enc = NULL, pending_token_expires_at = NULL, updated_at = ?"
                    " WHERE owner_id = ? AND pending_token_enc = ?",
                    (new_connection_id, account_name, session_key_enc, now, owner, token_enc),
                ).rowcount
                if changed != 1:
                    return BindResult(BindOutcome.TOKEN_CHANGED)
                return BindResult(BindOutcome.BOUND, connection_id=new_connection_id)
            if row["account_name"] == account_name:
                changed = conn.execute(
                    "UPDATE lastfm_connections SET session_key_enc = ?, needs_reconnect = 0,"
                    " pending_token_enc = NULL, pending_token_expires_at = NULL, updated_at = ?"
                    " WHERE owner_id = ? AND pending_token_enc = ?",
                    (session_key_enc, now, owner, token_enc),
                ).rowcount
                if changed != 1:
                    return BindResult(BindOutcome.TOKEN_CHANGED)
                return BindResult(BindOutcome.REBOUND, connection_id=row["connection_id"])
            changed = conn.execute(
                "UPDATE lastfm_connections SET pending_token_enc = NULL,"
                " pending_token_expires_at = NULL, updated_at = ?"
                " WHERE owner_id = ? AND pending_token_enc = ?",
                (now, owner, token_enc),
            ).rowcount
            if changed != 1:
                return BindResult(BindOutcome.TOKEN_CHANGED)
            return BindResult(BindOutcome.ACCOUNT_MISMATCH, stored_account=row["account_name"])

    def enable_lastfm_scrobbling(self, connection_id, now, *, owner_id) -> EnableOutcome:
        """Opts in the caller's current connection; harmless when repeated."""
        owner = _require_owner(owner_id)
        with self._connection(commit=True, immediate=True) as conn:
            row = self._lastfm_row(conn, owner)
            if row is None or row["session_key_enc"] is None:
                return EnableOutcome.NOT_CONNECTED
            if row["connection_id"] != connection_id:
                return EnableOutcome.CONNECTION_CHANGED
            if row["needs_reconnect"]:
                return EnableOutcome.RECONNECT_REQUIRED
            conn.execute(
                "UPDATE lastfm_connections SET opted_in = 1, updated_at = ?"
                " WHERE owner_id = ? AND connection_id = ? AND session_key_enc IS NOT NULL"
                " AND needs_reconnect = 0",
                (now, owner, connection_id),
            )
            return EnableOutcome.ENABLED

    @staticmethod
    def _lastfm_scrobbling_on_in(conn, *, owner_id) -> bool:
        """True when the owner has opted in on a usable connection (hook-safe: conn only)."""
        return (
            conn.execute(
                "SELECT 1 FROM lastfm_connections WHERE owner_id = ? AND opted_in = 1"
                " AND needs_reconnect = 0 AND session_key_enc IS NOT NULL",
                (owner_id,),
            ).fetchone()
            is not None
        )

    @staticmethod
    def _lastfm_track_fields_in(conn, uuid_id, *, owner_id) -> dict | None:
        """The owner's live track's scrobble fields, or None (hook-safe: conn only)."""
        row = conn.execute(
            "SELECT m.title, m.artist, m.album, m.album_artist, m.duration"
            " FROM live_tracks t JOIN trackmetadata m ON m.uuid_id = t.uuid_id"
            " WHERE t.owner_id = ? AND t.uuid_id = ?",
            (owner_id, uuid_id),
        ).fetchone()
        return dict(row) if row is not None else None

    @staticmethod
    def _queue_scrobble_in(
        conn, *, owner_id, event_uuid, payload: dict, listened_at_s, now
    ) -> None:
        """Adds one pending outbox row (hook-safe: conn only)."""
        conn.execute(
            "INSERT INTO scrobble_outbox (event_uuid, owner_id, payload, listened_at_s,"
            " status, attempts, alone, created_at) VALUES (?, ?, ?, ?, 'pending', 0, 0, ?)",
            (
                event_uuid,
                owner_id,
                json.dumps(payload, ensure_ascii=False),
                listened_at_s,
                now,
            ),
        )

    def disconnect_lastfm(self, *, owner_id) -> None:
        """Deletes the caller's connection row and all of their outbox rows together."""
        owner = _require_owner(owner_id)
        with self._connection(commit=True, immediate=True) as conn:
            conn.execute("DELETE FROM scrobble_outbox WHERE owner_id = ?", (owner,))
            conn.execute("DELETE FROM lastfm_connections WHERE owner_id = ?", (owner,))

    def list_due_lastfm_owners(self, *, listened_by_s, queued_by) -> list[int]:
        """Server-wide by design: the owners the sender should serve now (spec 7.8). An
        owner is due when opted in, not needing reconnect, not disabled or being
        deleted, with pending rows whose listen time has arrived, the earliest-queued
        of which was queued at or before queued_by."""
        with self._connection() as conn:
            return [
                r[0]
                for r in conn.execute(
                    "SELECT o.owner_id FROM scrobble_outbox o"
                    " JOIN lastfm_connections c ON c.owner_id = o.owner_id"
                    " JOIN users u ON u.id = o.owner_id"
                    " WHERE o.status = 'pending' AND o.listened_at_s <= ?"
                    " AND c.opted_in = 1 AND c.needs_reconnect = 0"
                    " AND c.session_key_enc IS NOT NULL"
                    " AND u.disabled_at IS NULL AND u.deleting_at IS NULL"
                    " GROUP BY o.owner_id HAVING MIN(o.created_at) <= ?"
                    " ORDER BY o.owner_id",
                    (listened_by_s, queued_by),
                )
            ]

    @staticmethod
    def _lastfm_sendable_connection_in(conn, owner):
        """The owner's connection_id/session_key_enc row when Last.fm may be sent for them
        (opted in, no reconnect needed, has a key, not disabled or being deleted), else None."""
        return conn.execute(
            "SELECT c.connection_id, c.session_key_enc FROM lastfm_connections c"
            " JOIN users u ON u.id = c.owner_id"
            " WHERE c.owner_id = ? AND c.opted_in = 1 AND c.needs_reconnect = 0"
            " AND c.session_key_enc IS NOT NULL"
            " AND u.disabled_at IS NULL AND u.deleting_at IS NULL",
            (owner,),
        ).fetchone()

    def read_lastfm_batch(self, *, owner_id, listened_by_s, listened_since_s, limit) -> dict | None:
        """The rows to send next for one owner, read in one transaction: one 'alone' row
        if they have any, else up to limit of the oldest. None when the owner may not
        be sent for (disabled, being deleted, not opted in, needs reconnect, no key)
        or has no pending row whose listen time has arrived. Rows listened before
        listened_since_s are too old to send and are never returned."""
        owner = _require_owner(owner_id)
        with self._connection(commit=True) as conn:
            conn.execute("BEGIN")
            connection = LastfmPart._lastfm_sendable_connection_in(conn, owner)
            if connection is None:
                return None
            order = " ORDER BY listened_at_s, created_at, event_uuid"
            rows = conn.execute(
                "SELECT event_uuid, CAST(payload AS BLOB) AS payload FROM scrobble_outbox WHERE owner_id = ?"
                " AND status = 'pending' AND alone = 1 AND listened_at_s <= ?"
                " AND listened_at_s >= ?" + order + " LIMIT 1",
                (owner, listened_by_s, listened_since_s),
            ).fetchall()
            if not rows:
                rows = conn.execute(
                    "SELECT event_uuid, CAST(payload AS BLOB) AS payload FROM scrobble_outbox WHERE owner_id = ?"
                    " AND status = 'pending' AND alone = 0 AND listened_at_s <= ?"
                    " AND listened_at_s >= ?" + order + " LIMIT ?",
                    (owner, listened_by_s, listened_since_s, limit),
                ).fetchall()
            if not rows:
                return None
            return {
                "connection_id": connection["connection_id"],
                "session_key_enc": connection["session_key_enc"],
                "rows": [(r["event_uuid"], r["payload"]) for r in rows],
            }

    def read_lastfm_now_playing(self, *, owner_id, track_uuid) -> dict | None:
        """The owner's sendable connection and the owner's live track's scrobble fields,
        read in one connection. None when the owner may not be sent for or lacks the track."""
        owner = _require_owner(owner_id)
        with self._connection(commit=True) as conn:
            conn.execute("BEGIN")
            connection = LastfmPart._lastfm_sendable_connection_in(conn, owner)
            if connection is None:
                return None
            track = LastfmPart._lastfm_track_fields_in(conn, track_uuid, owner_id=owner)
            if track is None:
                return None
            return {
                "connection_id": connection["connection_id"],
                "session_key_enc": connection["session_key_enc"],
                "track": track,
            }

    def settle_lastfm_rows(self, results, now, *, owner_id) -> None:
        """Writes each (event_uuid, status, result_code) outcome to the owner's row, only
        if it still exists and is still pending (a late answer after a disconnect
        changes nothing)."""
        owner = _require_owner(owner_id)
        with self._connection(commit=True, immediate=True) as conn:
            for event_uuid, status, result_code in results:
                conn.execute(
                    "UPDATE scrobble_outbox SET status = ?, result_code = ?, done_at = ?"
                    " WHERE event_uuid = ? AND owner_id = ? AND status = 'pending'",
                    (status, result_code, now, event_uuid, owner),
                )

    def prune_lastfm_outbox(self, now, *, keep_done_ms, max_age_s, skip_owners=()) -> None:
        """Server-wide by design (the sender's retention step): deletes terminal rows done
        more than keep_done_ms ago and drops pending rows whose listen time is more than
        max_age_s ago (too_old), except those of skip_owners. One write transaction."""
        owners = tuple(skip_owners)
        skip = (
            " AND owner_id NOT IN (" + ", ".join("?" * len(owners)) + ")" if owners else ""
        )
        with self._connection(commit=True, immediate=True) as conn:
            conn.execute(
                "DELETE FROM scrobble_outbox WHERE status <> 'pending' AND done_at < ?",
                (now - keep_done_ms,),
            )
            conn.execute(
                f"UPDATE scrobble_outbox SET status = 'dropped', result_code = '{RESULT_TOO_OLD}',"
                " done_at = ?"
                " WHERE status = 'pending' AND listened_at_s < ?" + skip,
                (now, now // 1000 - max_age_s, *owners),
            )

    def count_lastfm_try(self, event_uuids, now, *, max_tries, owner_id) -> None:
        """Adds one attempt to each still-pending row of the owner; a row reaching
        max_tries is dropped (too_many_tries)."""
        owner = _require_owner(owner_id)
        with self._connection(commit=True, immediate=True) as conn:
            for event_uuid in event_uuids:
                conn.execute(
                    "UPDATE scrobble_outbox SET attempts = attempts + 1,"
                    " status = CASE WHEN attempts + 1 >= ? THEN 'dropped' ELSE status END,"
                    " result_code = CASE WHEN attempts + 1 >= ?"
                    f" THEN '{RESULT_TOO_MANY_TRIES}' ELSE result_code END,"
                    " done_at = CASE WHEN attempts + 1 >= ? THEN ? ELSE done_at END"
                    " WHERE event_uuid = ? AND owner_id = ? AND status = 'pending'",
                    (max_tries, max_tries, max_tries, now, event_uuid, owner),
                )

    def mark_lastfm_needs_reconnect(self, connection_id, session_key_enc, now, *, owner_id) -> None:
        """Sets needs_reconnect on the owner's connection, only if it is still the same
        connection holding the same stored key (a replaced or repaired one is untouched). opted_in never changes."""
        owner = _require_owner(owner_id)
        with self._connection(commit=True, immediate=True) as conn:
            conn.execute(
                "UPDATE lastfm_connections SET needs_reconnect = 1, updated_at = ?"
                " WHERE owner_id = ? AND connection_id = ? AND session_key_enc = ?",
                (now, owner, connection_id, session_key_enc),
            )

    def mark_lastfm_alone(self, event_uuids, *, owner_id) -> None:
        """Marks the owner's still-pending rows alone: each is then sent as a request of
        its own. Attempts are unchanged."""
        owner = _require_owner(owner_id)
        with self._connection(commit=True, immediate=True) as conn:
            for event_uuid in event_uuids:
                conn.execute(
                    "UPDATE scrobble_outbox SET alone = 1"
                    " WHERE event_uuid = ? AND owner_id = ? AND status = 'pending'",
                    (event_uuid, owner),
                )

    def purge_lastfm_data(self) -> tuple[int, int]:
        """Operator purge: deletes every row of both Last.fm tables for every user, then
        VACUUMs and truncates the WAL so the deleted values leave the database files.
        Touches nothing else; returns (connections deleted, outbox rows deleted)."""
        try:
            with self._connection(
                commit=True, immediate=True, timeout=PURGE_BUSY_TIMEOUT_S
            ) as conn:
                outbox = conn.execute("DELETE FROM scrobble_outbox").rowcount
                connections = conn.execute("DELETE FROM lastfm_connections").rowcount
        except sqlite3.OperationalError:
            raise LastfmPurgeBusy(
                "nothing was deleted: another program is writing to the database"
            ) from None
        # VACUUM cannot run inside a transaction: use an autocommit connection.
        # The opener is looked up in its module at call time.
        conn = None
        try:
            conn = database_core.open_connection(
                self.context.database_path, timeout=PURGE_BUSY_TIMEOUT_S, isolation_level=None
            )
            conn.execute("VACUUM")
            busy, log, checkpointed = conn.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone()
            incomplete = busy != 0 or log != checkpointed
        except sqlite3.OperationalError:
            incomplete = True
        finally:
            if conn is not None:
                conn.close()
        if incomplete:
            raise LastfmPurgeIncomplete(
                "the Last.fm rows were deleted, but the database file could not be compacted "
                "(another program may have it open, or the disk may be full)"
            ) from None
        return connections, outbox

    def get_lastfm_outbox_summary(self, done_since, *, owner_id, problem_limit=20) -> dict:
        """The caller's outbox facts, read consistently: per-status counts (pending rows
        plus terminal rows done at or after done_since, 0 when none), the newest problem
        rows, and the newest sent time (None when nothing was sent)."""
        owner = _require_owner(owner_id)
        with self._connection(commit=True) as conn:
            # One read transaction so the three reads see one snapshot.
            conn.execute("BEGIN")
            counts = {"pending": 0, "sent": 0, "ignored": 0, "failed": 0, "dropped": 0}
            for status, n in conn.execute(
                "SELECT status, count(*) FROM scrobble_outbox"
                " WHERE owner_id = ? AND (status = 'pending' OR done_at >= ?) GROUP BY status",
                (owner, done_since),
            ):
                counts[status] = n
            problems = []
            for row in conn.execute(
                "SELECT CAST(payload AS BLOB) AS payload, listened_at_s, status, result_code FROM scrobble_outbox"
                " WHERE owner_id = ? AND status IN ('ignored','failed','dropped')"
                " AND done_at >= ? ORDER BY done_at DESC, listened_at_s DESC, event_uuid LIMIT ?",
                (owner, done_since, problem_limit),
            ):
                artist, track = _problem_fields(row["payload"])
                problems.append({
                    "artist": artist,
                    "track": track,
                    "listened_at_s": row["listened_at_s"],
                    "status": row["status"],
                    "code": row["result_code"],
                })
            last_success = conn.execute(
                "SELECT MAX(done_at) FROM scrobble_outbox WHERE owner_id = ? AND status = 'sent'",
                (owner,),
            ).fetchone()[0]
        return {"counts": counts, "recent_problems": problems, "last_success_at": last_success}
