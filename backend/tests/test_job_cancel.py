"""SC-16d cancellation (Phase 7A.1b): a durable cancel flag on the job row,
which survives a restart and never touches a terminal row, plus an in-memory
token per running job that wakes the worker promptly. Tested on a test table
(no upload table exists yet)."""

import sqlite3
import threading
from pathlib import Path

import pytest

from app.services.job_runtime import (
    CancelTokens,
    cancel_requested,
    register_job_table,
    request_cancel,
)

TABLE = "test_cancel_jobs"


@pytest.fixture(scope="module", autouse=True)
def registered():
    register_job_table(
        TABLE,
        key_columns=("owner_id", "job_uuid"),
        state_column="state",
        terminal_states=("done", "failed", "cancelled"),
    )


def _create(path: Path) -> None:
    conn = sqlite3.connect(path)
    try:
        conn.execute(
            f"CREATE TABLE {TABLE} ("
            " owner_id INTEGER NOT NULL, job_uuid TEXT NOT NULL,"
            " state TEXT NOT NULL, lease_boot_id TEXT,"
            " cancel_requested INTEGER NOT NULL DEFAULT 0,"
            " PRIMARY KEY (owner_id, job_uuid))"
        )
        conn.commit()
    finally:
        conn.close()


@pytest.fixture
def db_path(tmp_path):
    path = tmp_path / "jobs.sqlite"
    _create(path)
    return path


def _connect(path: Path) -> sqlite3.Connection:
    return sqlite3.connect(path, timeout=5)


def _insert(path: Path, owner: int, job: str, state: str = "pending", lease=None) -> None:
    conn = _connect(path)
    try:
        conn.execute(
            f"INSERT INTO {TABLE} (owner_id, job_uuid, state, lease_boot_id) VALUES (?, ?, ?, ?)",
            (owner, job, state, lease),
        )
        conn.commit()
    finally:
        conn.close()


def _row(path: Path, owner: int, job: str) -> dict:
    conn = _connect(path)
    conn.row_factory = sqlite3.Row
    try:
        found = conn.execute(
            f"SELECT * FROM {TABLE} WHERE owner_id = ? AND job_uuid = ?", (owner, job)
        ).fetchone()
        return dict(found) if found is not None else None
    finally:
        conn.close()


JOB = "6f1c0a7e-0000-4000-8000-000000000001"


# --- durable cancellation -------------------------------------------------------------------------


@pytest.mark.parametrize("state", ["pending", "running"])
def test_a_cancel_request_sets_the_durable_flag_on_a_live_row(db_path, state):
    _insert(db_path, 1, JOB, state=state)
    key = {"owner_id": 1, "job_uuid": JOB}
    conn = _connect(db_path)
    try:
        assert cancel_requested(conn, TABLE, key) is False
        assert request_cancel(conn, TABLE, key) is True
        conn.commit()
    finally:
        conn.close()

    other = _connect(db_path)
    try:
        assert cancel_requested(other, TABLE, key) is True
    finally:
        other.close()
    assert _row(db_path, 1, JOB)["state"] == state  # the flag alone; the worker acts on it


@pytest.mark.parametrize("state", ["done", "failed", "cancelled"])
def test_a_terminal_row_is_immutable_and_takes_no_cancel_flag(db_path, state):
    _insert(db_path, 1, JOB, state=state)
    key = {"owner_id": 1, "job_uuid": JOB}
    conn = _connect(db_path)
    try:
        assert request_cancel(conn, TABLE, key) is False
        conn.commit()
        assert cancel_requested(conn, TABLE, key) is False
    finally:
        conn.close()
    assert _row(db_path, 1, JOB)["cancel_requested"] == 0


def test_a_cancel_request_for_a_missing_row_changes_nothing(db_path):
    _insert(db_path, 2, JOB)
    conn = _connect(db_path)
    try:
        assert request_cancel(conn, TABLE, {"owner_id": 1, "job_uuid": JOB}) is False
        conn.commit()
        assert cancel_requested(conn, TABLE, {"owner_id": 1, "job_uuid": JOB}) is False
    finally:
        conn.close()
    assert _row(db_path, 2, JOB)["cancel_requested"] == 0


# --- in-memory cancellation tokens ----------------------------------------------------------------


def test_cancelling_a_registered_key_signals_its_token():
    tokens = CancelTokens()
    token = tokens.register((1, JOB))

    assert token.cancelled is False
    assert tokens.cancel((1, JOB)) is True
    assert token.cancelled is True
    assert token.wait(timeout=0) is True


def test_cancelling_an_unregistered_key_reports_nothing_was_signalled():
    tokens = CancelTokens()
    assert tokens.cancel((1, JOB)) is False


def test_registering_a_key_twice_returns_the_same_token():
    tokens = CancelTokens()
    assert tokens.register((1, JOB)) is tokens.register((1, JOB))


def test_tokens_are_per_key():
    tokens = CancelTokens()
    mine = tokens.register((1, JOB))
    other = tokens.register((2, JOB))

    tokens.cancel((1, JOB))

    assert (mine.cancelled, other.cancelled) == (True, False)


def test_a_discarded_key_is_forgotten():
    tokens = CancelTokens()
    old = tokens.register((1, JOB))
    tokens.discard((1, JOB))

    assert tokens.cancel((1, JOB)) is False
    assert old.cancelled is False
    assert tokens.register((1, JOB)) is not old


def test_a_waiter_on_another_thread_wakes_when_the_token_is_cancelled():
    tokens = CancelTokens()
    token = tokens.register((1, JOB))
    woke = []
    started = threading.Event()

    def waiter():
        started.set()
        woke.append(token.wait(timeout=10))

    thread = threading.Thread(target=waiter)
    thread.start()
    started.wait(timeout=5)
    tokens.cancel((1, JOB))
    thread.join(timeout=10)

    assert woke == [True]


def test_cancel_callbacks_run_once_and_late_callbacks_run_immediately():
    tokens = CancelTokens()
    token = tokens.register((1, JOB))
    calls = []
    token.on_cancel(lambda: calls.append("early"))

    tokens.cancel((1, JOB))
    tokens.cancel((1, JOB))
    token.on_cancel(lambda: calls.append("late"))

    assert calls == ["early", "late"]


def test_a_failing_cancel_callback_does_not_stop_the_others_or_the_canceller():
    tokens = CancelTokens()
    token = tokens.register((1, JOB))
    calls = []

    def broken():
        calls.append("broken")
        raise RuntimeError("callback failed")

    token.on_cancel(broken)
    token.on_cancel(lambda: calls.append("after"))

    assert tokens.cancel((1, JOB)) is True

    assert calls == ["broken", "after"]
    assert token.cancelled is True
