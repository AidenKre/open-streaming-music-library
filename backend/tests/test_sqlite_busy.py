"""Sign-off DEV-8-17 item 4: the one rule that says whether a database error
means "the database was busy" (SQLite's busy/locked answers). The identity
worker and the deletion worker share it."""

import sqlite3

import pytest

from app.core.sqlite_busy import is_sqlite_busy
from app.services import deletion_worker, identity_worker


@pytest.mark.parametrize("error", [
    sqlite3.OperationalError("database is locked"),
    sqlite3.OperationalError("database table is locked"),
    sqlite3.OperationalError("database is busy"),
    sqlite3.OperationalError("Database Is Locked"),
])
def test_busy_and_locked_are_busy(error):
    assert is_sqlite_busy(error) is True


@pytest.mark.parametrize("error", [
    sqlite3.OperationalError("disk I/O error"),
    sqlite3.OperationalError("database or disk is full"),
    sqlite3.DatabaseError("database disk image is malformed"),
    sqlite3.IntegrityError("UNIQUE constraint failed: tracks.uuid_id"),
    OSError(5, "I/O error"),
    RuntimeError("database is locked"),  # not a SQLite error
])
def test_any_other_error_is_not_busy(error):
    assert is_sqlite_busy(error) is False


def test_both_workers_use_the_shared_rule():
    assert identity_worker.is_sqlite_busy is is_sqlite_busy
    assert deletion_worker.is_sqlite_busy is is_sqlite_busy
