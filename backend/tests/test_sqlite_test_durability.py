"""SF-BE-2: tests run their throwaway databases with ``PRAGMA synchronous=OFF``.

``tests/conftest.py`` wraps ``sqlite3.connect`` for the test process. These two
cases pin both sides on a connection the product itself opens:

- for an ordinary test the wrapper is in effect (OFF = 0);
- the product sets no ``synchronous`` of its own today, so a product connection
  reports exactly what a plain WAL connection reports on this SQLite build
  (``DEFAULT_WAL_SYNCHRONOUS``: NORMAL = 1 on the macOS build, FULL = 2 where
  it is not set). If the product ever sets the pragma itself, the second case
  fails and the conftest wrapper has to be revisited.
"""

import sqlite3

import pytest

from app.database.database import server_database
from app.database.table_rebuild import rebuild_tables

SYNCHRONOUS_OFF = 0


def _synchronous_of_a_product_connection(tmp_path) -> int:
    database = server_database(tmp_path)
    database.context.database_path.parent.mkdir(parents=True, exist_ok=True)
    assert database.initialize() is True
    with database._connection() as conn:
        return conn.execute("PRAGMA synchronous").fetchone()[0]


def _synchronous_of_a_plain_wal_connection(tmp_path) -> int:
    conn = sqlite3.connect(tmp_path / "plain.db")
    try:
        conn.execute("PRAGMA journal_mode=WAL")
        return conn.execute("PRAGMA synchronous").fetchone()[0]
    finally:
        conn.close()


def test_an_ordinary_test_database_does_not_sync(tmp_path):
    assert _synchronous_of_a_product_connection(tmp_path) == SYNCHRONOUS_OFF


@pytest.mark.real_sqlite_durability
def test_the_product_sets_no_synchronous_of_its_own(tmp_path):
    library_default = _synchronous_of_a_plain_wal_connection(tmp_path)
    assert library_default != SYNCHRONOUS_OFF  # the opt-out really is unwrapped
    assert _synchronous_of_a_product_connection(tmp_path) == library_default


def _synchronous_of_the_rebuild_connect(tmp_path) -> int:
    # rebuild_tables binds sqlite3.connect as a default argument at import
    # time; the opt-out must reach that captured function too.
    connect = rebuild_tables.__kwdefaults__["connect"]
    conn = connect(str(tmp_path / "rebuild.db"), isolation_level=None)
    try:
        conn.execute("PRAGMA journal_mode=WAL")
        return conn.execute("PRAGMA synchronous").fetchone()[0]
    finally:
        conn.close()


def test_the_rebuild_connect_does_not_sync_in_an_ordinary_test(tmp_path):
    assert _synchronous_of_the_rebuild_connect(tmp_path) == SYNCHRONOUS_OFF


@pytest.mark.real_sqlite_durability
def test_the_rebuild_connect_keeps_sqlites_own_sync_under_the_opt_out(tmp_path):
    assert _synchronous_of_the_rebuild_connect(tmp_path) == _synchronous_of_a_plain_wal_connection(tmp_path)
