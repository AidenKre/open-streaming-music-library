"""A track's stored path and the folded forms stored with it, for tests that
write ``tracks`` rows with plain SQL.

The product writes ``file_path``, ``file_path_fold`` and ``file_folder_fold``
in one statement (``app.database.database.track_path_values``); a test that
writes a row by hand does the same through these helpers, so its database is
one the product could have made. ``stale_path_rows`` is the check over a whole
database: every row's stored folds are the folds of its path.
"""

import sqlite3

from app.database.database import track_path_values
from tests.sqlite_helpers import database_path

# The columns every write of a track's path sets together, in the order of
# ``path_values``; for a hand-written INSERT or UPDATE.
PATH_COLUMNS = "file_path, file_path_fold, file_folder_fold"
PATH_MARKS = "?, ?, ?"
SET_PATH = "file_path = ?, file_path_fold = ?, file_folder_fold = ?"

UNIQUE_PATH_INDEX = "idx_tracks_file_path_fold"


def path_values(path) -> tuple:
    """The values of ``PATH_COLUMNS`` for ``path``."""
    return track_path_values(path)


def set_track_path(target, uuid_id: str, path) -> None:
    """Point a track's row at ``path`` with plain SQL, on its own connection."""
    conn = sqlite3.connect(database_path(target))
    try:
        conn.execute(f"UPDATE tracks SET {SET_PATH} WHERE uuid_id = ?",
                     (*path_values(path), uuid_id))
        conn.commit()
    finally:
        conn.close()


def allow_two_tracks_on_one_path(target) -> None:
    """Drop the unique index on the folded path, so a test can plant the state
    the database now refuses (two rows naming one file) and show what the code
    that meets it does."""
    conn = sqlite3.connect(database_path(target))
    try:
        conn.execute(f"DROP INDEX {UNIQUE_PATH_INDEX}")
        conn.commit()
    finally:
        conn.close()


def stale_path_rows(target) -> list[tuple]:
    """Every track whose stored folded forms are not the ones of its path, as
    (uuid_id, file_path, stored columns...). Empty for a consistent database."""
    conn = sqlite3.connect(database_path(target))
    try:
        rows = conn.execute(f"SELECT uuid_id, {PATH_COLUMNS} FROM tracks").fetchall()
    finally:
        conn.close()
    return [row for row in rows if tuple(row[1:]) != path_values(row[1])]
