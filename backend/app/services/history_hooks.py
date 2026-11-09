"""SC-23: server-side `on_history_events_inserted(conn, new_events)` hooks.

`POST /history` calls every registered hook inside its write transaction,
with ONLY the newly inserted rows (never exact duplicates). Each hook runs in
its own SAVEPOINT: a raising hook rolls back only its own writes, a
`history_hook_failures` row is recorded, and the history batch still commits.
No subscriber exists in Phase 5 (Phase 9D adds the scrobble outbox).
"""

import sqlite3
from time import time_ns
from typing import Any, Callable

HistoryHook = Callable[[sqlite3.Connection, list[dict[str, Any]]], None]
_hooks: dict[str, HistoryHook] = {}


def register_history_hook(name: str, hook: HistoryHook) -> None:
    _hooks[name] = hook


def unregister_history_hook(name: str) -> None:
    del _hooks[name]


def on_history_events_inserted(
    conn: sqlite3.Connection, new_events: list[dict[str, Any]]
) -> None:
    if not new_events:
        return
    for index, (name, hook) in enumerate(tuple(_hooks.items())):
        savepoint = f"history_hook_{index}"
        conn.execute(f"SAVEPOINT {savepoint}")
        try:
            hook(conn, new_events)
        except Exception as exc:
            conn.execute(f"ROLLBACK TO SAVEPOINT {savepoint}")
            created_at = time_ns() // 1_000_000
            conn.executemany(
                "INSERT INTO history_hook_failures "
                "(subscriber, event_uuid, error, created_at) VALUES (?, ?, ?, ?)",
                [(name, event["event_uuid"], str(exc), created_at) for event in new_events],
            )
        finally:
            conn.execute(f"RELEASE SAVEPOINT {savepoint}")
