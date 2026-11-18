"""Shared seeding for the default-streaming-quality tests, moved out of
``tests/test_default_quality.py``: a user's stored setting, written with plain SQL."""

import sqlite3


def _store_quality(client, value, user_id=None):
    user_id = client.app.state.admin_user_id if user_id is None else user_id
    conn = sqlite3.connect(client.app.state.database.context.database_path)
    try:
        conn.execute(
            "INSERT OR REPLACE INTO user_settings (user_id, key, value) "
            "VALUES (?, 'default_streaming_quality', ?)",
            (user_id, value),
        )
        conn.commit()
    finally:
        conn.close()
