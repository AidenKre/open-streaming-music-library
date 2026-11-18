"""The one rule that says whether a database error means "the database was
busy": SQLite's busy/locked answers. Shared by the audio identity worker and
the deletion worker (sign-off DEV-8-17 item 4)."""

import sqlite3


def is_sqlite_busy(exc) -> bool:
    """True only for a SQLite ``OperationalError`` whose message says the
    database (or a table) is locked or busy; any other error is not busy."""
    return isinstance(exc, sqlite3.OperationalError) and any(
        word in str(exc).lower() for word in ("locked", "busy")
    )
