"""Plain-SQL reads and writes for tests, on their own connection, so an expected
value never comes from the code under test (U02-A-08).

Each variant is named for what it returns; ``target`` is a started
``TestClient`` (its app's database), a database object (its context's path) or
a path. Every call opens one connection, runs one statement, commits and closes.
"""

import sqlite3
from pathlib import Path


def database_path(target) -> Path:
    if hasattr(target, "app"):
        return Path(target.app.state.database.context.database_path)
    if hasattr(target, "context"):
        return Path(target.context.database_path)
    return Path(target)


def sql_rows(target, statement: str, params=()) -> list[tuple]:
    """Every row as a tuple."""
    conn = sqlite3.connect(database_path(target))
    try:
        rows = conn.execute(statement, params).fetchall()
        conn.commit()
        return rows
    finally:
        conn.close()


def sql_dicts(target, statement: str, params=()) -> list[dict]:
    """Every row as a dict of column name to value."""
    conn = sqlite3.connect(database_path(target))
    conn.row_factory = sqlite3.Row
    try:
        rows = [dict(r) for r in conn.execute(statement, params)]
        conn.commit()
        return rows
    finally:
        conn.close()


def sql_exec(target, statement: str, params=()) -> None:
    """Run one statement that returns nothing a test reads."""
    conn = sqlite3.connect(database_path(target))
    try:
        conn.execute(statement, params)
        conn.commit()
    finally:
        conn.close()


def table_count(target, table: str) -> int:
    """The number of rows in ``table`` (a name the test itself writes)."""
    return sql_rows(target, f"SELECT count(*) FROM {table}")[0][0]
