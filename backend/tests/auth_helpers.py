"""Test-only session creation: a live ``auth_sessions`` row for a user that a
test created directly (``add_test_user``), without an argon2 login.

Production creates sessions only through register and login (in their own
transactions); this helper writes the same row shape with the same tokens.
"""

import sqlite3
import time

from app.auth.sessions import SessionTokens, new_session_tokens


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
