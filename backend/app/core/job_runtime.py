"""SC-16d durable job runtime: claim and lease rules for background workers.

- Each process has one boot id, ``app.state.boot_id`` (never logged).
- A claim is a compare-and-swap (pending -> running) that stamps the boot id
  into ``lease_boot_id``.
- The startup flock guarantees one process, so any lease with another boot id
  is dead and needs no expiry. Reclaiming dead leases is each job type's own
  startup recovery step.
- Terminal states are immutable.
- Cancellation is a durable ``cancel_requested`` flag plus an in-memory token.

Every claimable table must be registered here and have the fixed columns
``lease_boot_id`` (TEXT) and ``cancel_requested`` (INTEGER 0/1) next to its key
and state columns. Table and column names are identifiers, so they come only
from the registry; every value is bound. Helpers never open, commit or close a
transaction: they run on the caller's connection.
"""

import logging
import re
import sqlite3
import threading
from typing import Callable, Hashable, Mapping

from app.core.deletion_states import DELETION_ITEM_TERMINAL_STATES
from app.core.upload_states import ENDED_STATES

# The log name is the one this module had as app/services/job_runtime.py.
logger = logging.getLogger("app.services.job_runtime")
_IDENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
# name -> (key_columns, state_column, terminal_states)
_TABLES: dict[str, tuple[tuple[str, ...], str, tuple[str, ...]]] = {}


def register_job_table(name, *, key_columns, state_column="status", terminal_states=()):
    if isinstance(key_columns, str) or isinstance(terminal_states, str):
        raise ValueError("key_columns and terminal_states must be sequences, not str")
    key_columns = tuple(key_columns)
    terminal_states = tuple(terminal_states)
    if not all(isinstance(state, str) for state in terminal_states):
        raise ValueError("terminal states must be str")
    if not key_columns:
        raise ValueError("key_columns must not be empty")
    for ident in (name, state_column, *key_columns):
        if not isinstance(ident, str) or not _IDENT.fullmatch(ident):
            raise ValueError("job table identifiers must be plain names")
    definition = (key_columns, state_column, tuple(terminal_states))
    if _TABLES.setdefault(name, definition) != definition:
        raise ValueError(f"job table {name!r} is already registered differently")


def _target(table, key):
    """Validated (state column, terminal states, WHERE clause, bound key values)."""
    if table not in _TABLES:
        raise ValueError("job table is not registered")
    key_columns, state_column, terminal = _TABLES[table]
    if set(key) != set(key_columns):
        raise ValueError("key must name exactly the registered key columns")
    where = " AND ".join(f"{col}=?" for col in key_columns)
    return state_column, terminal, where, tuple(key[col] for col in key_columns)


def _not_terminal(state_column, terminal):
    if not terminal:
        return "", ()
    return f" AND {state_column} NOT IN ({','.join('?' * len(terminal))})", terminal


def claim(
    conn: sqlite3.Connection,
    table: str,
    key: Mapping[str, object],
    *,
    boot_id: str,
    from_state: str = "pending",
    to_state: str = "running",
) -> bool:
    """CAS from_state -> to_state, stamping the boot id.

    A claim does not look at ``cancel_requested``: a worker re-checks the flag
    right after claiming and terminalizes a cancelled job itself (a pending row
    cancelled before any claim must still reach a terminal state through its
    worker).
    """
    state_column, terminal, where, values = _target(table, key)
    if from_state in terminal:
        raise ValueError("a claim never reopens a terminal state")
    cursor = conn.execute(
        f"UPDATE {table} SET {state_column}=?, lease_boot_id=? "
        f"WHERE {where} AND {state_column}=?",
        (to_state, boot_id, *values, from_state),
    )
    return _one_row(cursor)


def _one_row(cursor) -> bool:
    if cursor.rowcount > 1:
        # Registered key columns must be unique; the caller's transaction rolls back.
        raise RuntimeError("key matched more than one row")
    return cursor.rowcount == 1


def is_live(lease_boot_id, *, boot_id) -> bool:
    return lease_boot_id is not None and lease_boot_id == boot_id


def request_cancel(conn: sqlite3.Connection, table: str, key: Mapping[str, object]) -> bool:
    """Set the durable cancel flag; a terminal row is immutable and untouched."""
    state_column, terminal, where, values = _target(table, key)
    clause, params = _not_terminal(state_column, terminal)
    cursor = conn.execute(
        f"UPDATE {table} SET cancel_requested=1 WHERE {where}{clause}", (*values, *params)
    )
    return _one_row(cursor)


def cancel_requested(conn: sqlite3.Connection, table: str, key: Mapping[str, object]) -> bool:
    state_column, terminal, where, values = _target(table, key)
    clause, params = _not_terminal(state_column, terminal)
    row = conn.execute(
        f"SELECT cancel_requested FROM {table} WHERE {where}{clause}", (*values, *params)
    ).fetchone()
    return row is not None and bool(row[0])


class CancelToken:
    """In-memory cancellation signal, thread-safe.

    ``on_cancel`` callbacks run exactly once: at once in the caller's thread if
    already cancelled, else from the thread that cancels. Async code bridges
    with ``loop.call_soon_threadsafe`` inside the callback.
    """

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._event = threading.Event()
        self._callbacks: list[Callable[[], None]] = []

    @property
    def cancelled(self) -> bool:
        return self._event.is_set()

    def wait(self, timeout: float | None = None) -> bool:
        return self._event.wait(timeout)

    def cancel(self) -> None:
        with self._lock:
            if self._event.is_set():
                return
            self._event.set()
            callbacks, self._callbacks = self._callbacks, []
        for callback in callbacks:
            try:
                callback()
            except Exception as exc:
                # Never re-raise to the canceller; type name only.
                logger.warning("cancel callback failed: %s", type(exc).__name__)
                logger.debug("cancel callback failed", exc_info=True)

    def on_cancel(self, callback: Callable[[], None]) -> None:
        with self._lock:
            if not self._event.is_set():
                self._callbacks.append(callback)
                return
        callback()


class CancelTokens:
    """Per-process registry of tokens by hashable key, e.g. (owner_id, item_uuid)."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._tokens: dict[Hashable, CancelToken] = {}

    def register(self, key: Hashable) -> CancelToken:
        # The holder must ``discard`` its key when its job ends; a stale
        # cancelled token is otherwise returned to the next registrant.
        with self._lock:
            return self._tokens.setdefault(key, CancelToken())

    def cancel(self, key: Hashable) -> bool:
        with self._lock:
            token = self._tokens.get(key)
        if token is None:
            return False
        token.cancel()
        return True

    def discard(self, key: Hashable) -> None:
        with self._lock:
            self._tokens.pop(key, None)


# The claimable tables. They are registered here, with the runtime, so that a
# table is registered in every process that can claim a row of it.
register_job_table(
    "upload_items",
    key_columns=("owner_id", "item_uuid"),
    state_column="state",
    terminal_states=ENDED_STATES,
)
register_job_table(
    "deletion_job_items",
    key_columns=("owner_id", "operation_uuid", "uuid_id"),
    state_column="status",
    terminal_states=DELETION_ITEM_TERMINAL_STATES,
)
