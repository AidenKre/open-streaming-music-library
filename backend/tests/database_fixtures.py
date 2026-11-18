"""Test databases built under ``tmp_path`` (xdist-safe), from the product's
``init.sql``.

- ``make_db``: the owner-taking test adapter (``OwnedTestDatabase``) most
  database tests use; ``tests/conftest.py``'s ``db`` fixture returns one.
- ``plain_database``: the product's own ``Database``, as the app uses it, for
  tests that must not go through the adapter.
"""

from pathlib import Path

from app.database import Database, DatabaseContext
from tests.owned_database import OwnedTestDatabase
from tests.schema_fixtures import INIT_SQL


def make_db(tmp_path: Path) -> OwnedTestDatabase:
    database = OwnedTestDatabase(
        DatabaseContext(database_path=tmp_path / "db.sqlite", init_sql_path=INIT_SQL)
    )
    assert database.initialize()
    return database


def plain_database(tmp_path: Path) -> Database:
    database = Database(DatabaseContext(database_path=tmp_path / "db.sqlite", init_sql_path=INIT_SQL))
    assert database.initialize()
    return database
