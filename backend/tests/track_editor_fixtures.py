"""Shared setup of the tag-editor tests, moved out of ``tests/test_track_editor.py``:
a test database, the test owner's library, a tiny real AAC file made by ffmpeg,
and a catalog row for it."""

import subprocess
from pathlib import Path

from app.database.database import Database, DatabaseContext
from app.library import Library
from app.models.track import Track
from app.models.track_meta_data import TrackMetaData
from tests.owned_database import OwnedTestDatabase

_INIT_SQL = Path(__file__).parent.parent / "app" / "database" / "init.sql"


def _make_audio(path: Path, **tags) -> None:
    """Generate a tiny real AAC/m4a file with the given tags via ffmpeg."""
    path.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
        "-f", "lavfi", "-i", "sine=frequency=440:duration=0.3",
        "-c:a", "aac",
    ]
    for k, v in tags.items():
        cmd += ["-metadata", f"{k}={v}"]
    cmd.append(str(path))
    subprocess.run(cmd, check=True)


def _lib(db: Database) -> Library:
    """The test owner's Library (request-path services take one per call)."""
    root = db.context.database_path.parent / "music" / "owner"
    return Library(db, db.owner_id, root=root)


def _db(tmp_path: Path) -> Database:
    db = OwnedTestDatabase(context=DatabaseContext(
        database_path=tmp_path / "database.db", init_sql_path=_INIT_SQL))
    assert db.initialize()
    return db


def _add_track(db: Database, file_path: Path, title, artist, album=None) -> Track:
    meta = TrackMetaData(
        codec="aac", duration=1.0, bitrate_kbps=128.0, sample_rate_hz=44100,
        channels=2, title=title, artist=artist, album=album,
    )
    track = Track(file_path=file_path, metadata=meta)
    assert db.add_track(track)
    return track
