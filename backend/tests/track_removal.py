"""Test set-up and read-back for removed tracks: take a track out of the catalog
without a deletion job, and read which tombstones an owner holds.

The server deletes a track only through a deletion job
(``Database.commit_track_deletion``), which needs the job, its journal row and
the track's files. A test that only needs "this track is gone and has left its
tombstone" calls ``delete_track`` here. It runs the product's own
``_delete_track_in`` (the catalog statements of a committed deletion: the
tombstone, the search rows, an album and artist left empty) in a transaction of
its own, and touches no file. The product has no such method.
"""

import sqlite3
from typing import Optional

from app.database.database import TrackAlreadyDeleted, TrackNotFound
from app.library import Library


def _database_and_owner(target, owner_id: Optional[int]):
    """``target`` is a ``Library`` (its owner) or a ``Database`` (``owner_id``,
    or the test adapter's own owner when none is given)."""
    if isinstance(target, Library):
        if owner_id is not None:
            raise TypeError("a Library names its owner; owner_id cannot be passed")
        return target.unbound_database, target.owner_id
    return target, target.owner_id if owner_id is None else owner_id


def tombstone_uuids(target, *, owner_id: Optional[int] = None) -> list[str]:
    """The ids of the tracks the owner holds a tombstone for, read with plain
    SQL (clients learn of a deletion through ``get_changes``; the product has
    no other reader). ``target`` as for ``delete_track``."""
    database, owner_id = _database_and_owner(target, owner_id)
    conn = sqlite3.connect(database.context.database_path)
    try:
        return [row[0] for row in conn.execute(
            "SELECT uuid_id FROM track_tombstones WHERE owner_id = ? ORDER BY revision, uuid_id",
            (owner_id,),
        )]
    finally:
        conn.close()


def delete_track(target, uuid_id: str, *, owner_id: Optional[int] = None, timeout: float = 5) -> bool:
    """``target`` is a ``Library`` (its owner's track) or a ``Database``
    (``owner_id``, or the test adapter's own owner when none is given).

    True when the track was removed. False when that owner has no such live
    track (unknown, another user's, already deleted), or the database is busy
    (locked by another connection past ``timeout``). Anything else raises, a
    broken statement included."""
    database, owner_id = _database_and_owner(target, owner_id)
    try:
        with database._connection(commit=True, timeout=timeout, immediate=True) as conn:
            database._delete_track_in(conn, uuid_id, owner_id=owner_id)
    except (TrackNotFound, TrackAlreadyDeleted):
        return False
    except sqlite3.OperationalError as e:
        # The primary code (the low byte): the extended busy and locked codes count too.
        if (e.sqlite_errorcode & 0xFF) in (sqlite3.SQLITE_BUSY, sqlite3.SQLITE_LOCKED):
            return False
        raise
    return True
