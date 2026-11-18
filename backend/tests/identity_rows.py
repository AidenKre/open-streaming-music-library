"""The audio-identity row of a track, read with plain SQL (moved out of
``tests/test_identity_writers.py``), and the digest its tests store."""

from tests.sqlite_helpers import sql_dicts

DIGEST = "ab" * 32


def _identity(db, uuid_id):
    rows = sql_dicts(db, "SELECT * FROM track_audio_identity WHERE uuid_id = ?", (uuid_id,))
    return rows[0] if rows else None
