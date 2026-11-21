"""Listening history.

One part of ``Database`` (``app/database/database.py``). It imports the shared
core and never another part.
"""

from time import time_ns
from typing import Any

from app.core.owner import _require_owner
from app.database.core import DatabaseCore
from app.models.history import HistoryEvent


class HistoryEventConflict(Exception):
    def __init__(self, event_uuids: list[str]):
        self.event_uuids = event_uuids
        super().__init__("History event payload conflict")


class HistoryPart(DatabaseCore):
    """The ``history_events`` rows: the change stream and the insert that runs the
    registered hooks in its transaction."""

    def get_history_changes(
        self, after: int, limit: int, *, owner_id: int
    ) -> tuple[list[dict[str, Any]], int, int | None]:
        _require_owner(owner_id)
        with self._connection(commit=True) as conn:
            # A connection context alone does not give SELECTs a shared snapshot.
            conn.execute("BEGIN")
            rows = conn.execute(
                "SELECT event_uuid, revision, kind, entity_type, entity_ref, "
                "occurred_at, seconds_played, track_length, received_at "
                "FROM history_events WHERE owner_id = ? AND revision > ? "
                "ORDER BY revision ASC LIMIT ?",
                (owner_id, after, limit + 1),
            ).fetchall()
            latest_revision = conn.execute(
                "SELECT COALESCE(MAX(revision), 0) FROM history_events "
                "WHERE owner_id = ?",
                (owner_id,),
            ).fetchone()[0]
        next_cursor = rows[limit - 1]["revision"] if len(rows) > limit else None
        return [dict(row) for row in rows[:limit]], latest_revision, next_cursor

    def insert_history_events(
        self, events: list[HistoryEvent], *, owner_id: int
    ) -> list[str]:
        _require_owner(owner_id)
        # Import here because the services package itself depends on Database.
        from app.services.history_hooks import on_history_events_inserted

        with self._connection(commit=True, immediate=True) as conn:
            payloads = {}
            conflicts = set()
            for event in events:
                payload = event.model_dump()
                if event.event_uuid in payloads and payloads[event.event_uuid] != payload:
                    conflicts.add(event.event_uuid)
                payloads[event.event_uuid] = payload
            if conflicts:
                raise HistoryEventConflict(sorted(conflicts))

            columns = tuple(HistoryEvent.model_fields)
            placeholders = ",".join("?" for _ in payloads)
            existing = {}
            existing_owner = {}
            for row in conn.execute(
                f"SELECT {', '.join(columns)}, owner_id FROM history_events "
                f"WHERE event_uuid IN ({placeholders})",
                tuple(payloads),
            ):
                existing[row["event_uuid"]] = {c: row[c] for c in columns}
                existing_owner[row["event_uuid"]] = row["owner_id"]
            conflicts = {
                uid for uid, payload in payloads.items()
                if uid in existing
                and (existing_owner[uid] != owner_id or existing[uid] != payload)
            }
            if conflicts:
                raise HistoryEventConflict(sorted(conflicts))

            new_events = []
            for uid, payload in payloads.items():
                if uid in existing:
                    continue
                row = {
                    **payload,
                    "revision": self._next_revision(conn),
                    "received_at": time_ns() // 1_000_000,
                    "owner_id": owner_id,
                }
                conn.execute(
                    f"INSERT INTO history_events ({', '.join(row)}) "
                    f"VALUES ({', '.join('?' for _ in row)})",
                    tuple(row.values()),
                )
                new_events.append(row)
            on_history_events_inserted(conn, new_events)
        return list(payloads)
