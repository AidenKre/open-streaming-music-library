"""Fixtures for the M.2b admin CLI tests.

Safety: every CLI test runs against directories under pytest's ``tmp_path``.
``cli_settings`` builds ``Settings`` with every directory explicit and no
``.env`` file, and ``run_cli`` refuses settings whose directories are not
inside the test's ``tmp_path``. The CLI is always invoked in-process through
``app.cli.main(argv, settings=...)``.
"""

import io
import sqlite3
import time
from dataclasses import dataclass, field
from pathlib import Path

from app.config import Settings
from app.database.database import Database, DatabaseContext
from app.library import Library
from app.models import Track, TrackMetaData
from tests.schema_fixtures import INIT_SQL

ADMIN = "admin"


def cli_settings(tmp_path: Path, **overrides) -> Settings:
    values = dict(
        app_data_dir=tmp_path / "data",
        music_library_dir=tmp_path / "music",
        import_dir=tmp_path / "import",
        user_import_dir=tmp_path / "import-users",
        osml_admin_username=None,
        osml_admin_password=None,
        osml_admin_password_file=None,
        osml_insecure_fast_password_hashing=True,
        enable_file_watcher=False,
    )
    values.update(overrides)
    return Settings(_env_file=None, **values)


def database_file(settings: Settings) -> Path:
    """Where the server keeps its database (the layout ``main.py`` creates)."""
    return settings.app_data_dir / "database" / "database.db"


def open_server_database(settings: Settings) -> Database:
    path = database_file(settings)
    path.parent.mkdir(parents=True, exist_ok=True)
    db = Database(DatabaseContext(database_path=path, init_sql_path=INIT_SQL))
    assert db.initialize()
    return db


def add_user(
    db: Database, username: str, *, master: bool = False, created_at: int = 1_700_000_000
) -> int:
    conn = sqlite3.connect(db.context.database_path)
    try:
        uid = conn.execute(
            "INSERT INTO users (username, username_key, password_hash, is_admin, "
            "is_master_admin, library_folder, created_at) VALUES (?, ?, 'unused', ?, ?, ?, ?)",
            (username, username.lower(), int(master), int(master), username, created_at),
        ).lastrowid
        conn.commit()
        return uid
    finally:
        conn.close()


def add_track(
    db: Database,
    settings: Settings,
    owner_id: int,
    *,
    title: str = "Lucky",
    artist: str = "Radiohead",
    album: str = "OK Computer",
    track_number: int = 1,
    cover_art_id: int | None = None,
    album_artist: str | None = None,
) -> Track:
    user = db.get_user(owner_id)
    source = settings.music_library_dir / user["library_folder"] / artist / album / f"{track_number:02d} {title}.flac"
    source.parent.mkdir(parents=True, exist_ok=True)
    source.write_bytes(b"not really flac " + title.encode())
    track = Track(
        file_path=source,
        metadata=TrackMetaData(
            title=title, artist=artist, album=album, codec="flac",
            duration=1.0, bitrate_kbps=900.0, sample_rate_hz=44100, channels=2,
            track_number=track_number, disc_number=1, album_artist=album_artist,
            has_album_art=cover_art_id is not None, cover_art_id=cover_art_id,
        ),
    )
    assert Library(db, owner_id).add_track(track)
    return track


def sql(db: Database, statement: str, params=()):
    conn = sqlite3.connect(db.context.database_path)
    try:
        rows = conn.execute(statement, params).fetchall()
        conn.commit()
        return rows
    finally:
        conn.close()


@dataclass
class CliResult:
    code: int
    out: str
    err: str
    prompts: list = field(default_factory=list)


def run_cli(settings: Settings, tmp_path: Path, *argv, prompt=None, confirm=None) -> CliResult:
    """``app.cli.main`` in-process, with output captured."""
    for directory in (
        settings.app_data_dir,
        settings.music_library_dir,
        settings.import_dir,
        settings.user_import_dir,
    ):
        assert Path(directory).resolve().is_relative_to(Path(tmp_path).resolve()), directory
    from app.cli import main

    out, err = io.StringIO(), io.StringIO()
    kwargs = {}
    if prompt is not None:
        kwargs["prompt"] = prompt
    if confirm is not None:
        kwargs["confirm"] = confirm
    code = main(list(argv), settings=settings, out=out, err=err, **kwargs)
    return CliResult(code, out.getvalue(), err.getvalue())


def now() -> int:
    return int(time.time())
