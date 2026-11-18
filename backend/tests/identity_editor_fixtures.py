"""Shared setup for the identity-writer edit tests (6.5A.2b), moved out of
``tests/test_identity_editor.py``: a settled track with a real master file,
its identity row read with plain SQL, and a spy for the identity wake-up.

The track builders still come from ``tests/test_track_editor.py``; they move
with that file's helpers."""

import sqlite3

from app.services.track_editor import TrackEditor
from tests.track_editor_fixtures import _add_track, _db, _make_audio

DIGEST = "ef" * 32


def _identity(db, uuid_id):
    conn = sqlite3.connect(db.context.database_path)
    conn.row_factory = sqlite3.Row
    try:
        row = conn.execute("SELECT * FROM track_audio_identity WHERE uuid_id = ?", (uuid_id,)).fetchone()
        return dict(row) if row else None
    finally:
        conn.close()


def _settle(db, uuid_id):
    """The worker's finished state: every layer current, generation 3."""
    conn = sqlite3.connect(db.context.database_path)
    try:
        conn.execute(
            "UPDATE track_audio_identity SET exact_state = 'current', exact_kind = 'packets_sha256', "
            "exact_digest = ?, fp_state = 'current', fp_algorithm = 'chromaprint-2', "
            "match_state = 'current', matcher_version = 'm1', priority = 1, generation = 3 "
            "WHERE uuid_id = ?", (DIGEST, uuid_id))
        conn.commit()
    finally:
        conn.close()
    return _identity(db, uuid_id)


class SpyWakeup:
    """Records the committed generation (seen by a fresh connection) at each notify."""

    def __init__(self, db, uuid_id):
        self.db, self.uuid_id, self.seen = db, uuid_id, []

    def notify(self):
        self.seen.append(_identity(self.db, self.uuid_id)["generation"])


def _editor(library, wakeup=None):
    return TrackEditor(library, library / ".staging", identity_signal=wakeup)


def _world(tmp_path, name="song.m4a"):
    library = tmp_path / "music"
    audio = library / "owner" / "Art" / name
    _make_audio(audio, title="Old", artist="Art")
    db = _db(tmp_path)
    track = _add_track(db, audio, "Old", "Art")
    before = _settle(db, track.uuid_id)
    return library, audio, db, track, before
