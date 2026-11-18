"""Sign-in and ownership helpers for tests.

``create_session``: a live ``auth_sessions`` row for a user that a test created
directly (``add_test_user``), without an argon2 login.

Production creates sessions only through register and login (in their own
transactions); this helper writes the same row shape with the same tokens.
"""

import hashlib
import sqlite3
import time

from app.auth.sessions import SessionTokens, new_session_tokens
from app.models import Track, TrackMetaData


def create_session(database, user_id: int) -> SessionTokens:
    tokens = new_session_tokens()
    conn = sqlite3.connect(database.context.database_path)
    try:
        conn.execute(
            "INSERT INTO auth_sessions (token_hash, media_hash, user_id, created_at) "
            "VALUES (?, ?, ?, ?)",
            (tokens.token_hash, tokens.media_hash, user_id, int(time.time())),
        )
        conn.commit()
    finally:
        conn.close()
    return tokens


def sha256_hex(token: str) -> str:
    """The stored form of a token, computed independently of the product."""
    return hashlib.sha256(token.encode()).hexdigest()


def flac_track(source, title):
    """A track to add for a user: a stand-in file (not real FLAC) and fixed tags."""
    source.parent.mkdir(parents=True, exist_ok=True)
    source.write_bytes(b"not really flac")
    return Track(
        file_path=source,
        metadata=TrackMetaData(
            title=title, artist="Radiohead", album="OK Computer", codec="flac",
            duration=1.0, bitrate_kbps=900.0, sample_rate_hz=44100, channels=2,
            track_number=1, disc_number=1,
        ),
    )
