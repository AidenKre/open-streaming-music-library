"""SF-BE-2: tests run their throwaway databases with ``PRAGMA synchronous=OFF``.

``tests/conftest.py`` wraps ``sqlite3.connect`` for the test process. These two
cases pin both sides on a connection the product itself opens:

- for an ordinary test the wrapper is in effect (OFF = 0), although the
  product sets ``synchronous=FULL`` on every connection it opens:
  ``tests/conftest.py`` switches a product connection back to OFF
  after the product has set it up;
- under the opt-out a product connection reports the product's own setting
  (FULL = 2), whatever a plain WAL connection reports on this SQLite build
  (``DEFAULT_WAL_SYNCHRONOUS``: NORMAL = 1 on the macOS build, FULL = 2 where
  it is not set). ``tests/test_database_durable_commits.py`` holds the rest of
  what the product's setting guarantees.
"""

import sqlite3

import pytest

from app.database.database import server_database
from app.database.table_rebuild import rebuild_tables

SYNCHRONOUS_OFF = 0
SYNCHRONOUS_FULL = 2


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
def test_under_the_opt_out_a_product_connection_keeps_the_products_full_sync(tmp_path):
    library_default = _synchronous_of_a_plain_wal_connection(tmp_path)
    assert library_default != SYNCHRONOUS_OFF  # the opt-out really is unwrapped
    assert _synchronous_of_a_product_connection(tmp_path) == SYNCHRONOUS_FULL


def _synchronous_of_the_rebuild_connect(tmp_path) -> int:
    # rebuild_tables' default connect opens through the product's opener;
    # the opt-out must reach it too.
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
def test_under_the_opt_out_the_rebuild_connect_keeps_the_products_full_sync(tmp_path):
    """The rebuild opens its connection through the product's one opener, so
    it gets the product's setting, not SQLite's default."""
    assert _synchronous_of_the_rebuild_connect(tmp_path) == SYNCHRONOUS_FULL


class _SettingsAtVacuum(sqlite3.Connection):
    """Records the connection's own sync settings when it runs ``VACUUM``."""

    seen: list = []

    def execute(self, sql, *args):
        if sql == "VACUUM":
            _SettingsAtVacuum.seen.append(
                {
                    "synchronous": super().execute("PRAGMA synchronous").fetchone()[0],
                    "fullfsync": super().execute("PRAGMA fullfsync").fetchone()[0],
                }
            )
        return super().execute(sql, *args)


def _settings_of_the_purges_compacting_connection(tmp_path, monkeypatch) -> dict:
    # The Last.fm purge compacts on a second connection of its own, opened
    # through the product's opener, looked up in its module at call time.
    database = server_database(tmp_path)
    database.context.database_path.parent.mkdir(parents=True, exist_ok=True)
    assert database.initialize() is True
    real_connect = sqlite3.connect
    _SettingsAtVacuum.seen = []

    def connect(*args, **kwargs):
        kwargs.setdefault("factory", _SettingsAtVacuum)
        return real_connect(*args, **kwargs)

    monkeypatch.setattr(sqlite3, "connect", connect)
    assert database.purge_lastfm_data() == (0, 0)
    (seen,) = _SettingsAtVacuum.seen
    return seen


def test_the_purges_compacting_connection_does_not_sync_in_an_ordinary_test(tmp_path, monkeypatch):
    seen = _settings_of_the_purges_compacting_connection(tmp_path, monkeypatch)

    assert seen["synchronous"] == SYNCHRONOUS_OFF


@pytest.mark.real_sqlite_durability
def test_under_the_opt_out_the_purges_compacting_connection_keeps_the_products_settings(
        tmp_path, monkeypatch):
    seen = _settings_of_the_purges_compacting_connection(tmp_path, monkeypatch)

    assert seen == {"synchronous": SYNCHRONOUS_FULL, "fullfsync": 1}

