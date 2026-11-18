"""Shared setup of the conversion tests, moved out of ``tests/test_conversion.py``:
a tiny real audio file made by ffmpeg, a test database with a catalog row, and
a conversion orchestrator on a fake encoder coordinator whose submitted job a
test runs itself (synchronously)."""

from __future__ import annotations

import subprocess
from pathlib import Path

from app.database.database import Database, DatabaseContext
from app.library import Library
from app.models.track import Track
from app.models.track_meta_data import TrackMetaData
from app.services.conversion import ConversionOrchestrator
from app.services.encoded_cache import EncodedCache, EncodedCacheContext
from app.services.storage_ledger import StorageLedger
from app.services.track_locks import TrackLocks
from tests.owned_database import OwnedTestDatabase

_INIT_SQL = Path(__file__).parent.parent / "app" / "database" / "init.sql"
_ALL_CODECS = frozenset({"aac", "alac", "flac", "mp3"})
_DEFAULT = object()


def _ffmpeg(*args: str) -> None:
    subprocess.run(
        ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *args], check=True
    )


def _make_audio(path: Path, codec: str = "flac", **tags) -> None:
    """Generate a tiny real audio file with the given codec/tags via ffmpeg."""
    path.parent.mkdir(parents=True, exist_ok=True)
    codec_flags = {
        "flac": ["-c:a", "flac"],
        "mp3": ["-c:a", "libmp3lame", "-b:a", "192k"],
        "aac": ["-c:a", "aac", "-b:a", "192k"],
    }[codec]
    cmd = ["-f", "lavfi", "-i", "sine=frequency=440:duration=0.3", *codec_flags]
    for k, v in tags.items():
        cmd += ["-metadata", f"{k}={v}"]
    _ffmpeg(*cmd, str(path))


def _db(tmp_path: Path) -> Database:
    db = OwnedTestDatabase(context=DatabaseContext(
        database_path=tmp_path / "database.db", init_sql_path=_INIT_SQL))
    assert db.initialize()
    return db


def _add_track(
    db: Database, file_path: Path, codec: str = "flac", bitrate_kbps: float = 1000.0,
    title: str = "T", artist: str = "Art", **meta,
) -> Track:
    fields = dict(
        codec=codec, duration=0.3, bitrate_kbps=bitrate_kbps, sample_rate_hz=44100,
        channels=2, title=title, artist=artist,
    )
    fields.update(meta)
    track = Track(file_path=file_path, metadata=TrackMetaData(**fields))
    assert db.add_track(track)
    return db.get_track_by_uuid(track.uuid_id)  # fresh revision from the DB


def _root(tmp_path: Path) -> Path:
    """The test owner's library root (music dir is tmp_path; folder "owner")."""
    return tmp_path / "owner"


def _lib(orch: ConversionOrchestrator) -> Library:
    """The test owner's Library (request-path services take one per call)."""
    return Library(orch.database, orch.database.owner_id, root=_root(orch.music_library_dir))


class _FakeCoordinator:
    """Records submit_conversion calls instead of running them, so tests can
    drive the worker function themselves (synchronously, deterministically,
    with real or faked internals as each test needs)."""

    def __init__(self):
        self.submitted = []

    def submit_conversion(self, fn, *args, **kwargs):
        self.submitted.append((fn, args, kwargs))


def _make_orchestrator(tmp_path: Path, available_encoders=None, default_cache=_DEFAULT):
    db = _db(tmp_path)
    _root(tmp_path).mkdir(exist_ok=True)
    cache = EncodedCache(
        ctx=EncodedCacheContext(cache_dir=tmp_path / "cache", max_size_bytes=10 * 1024 * 1024)
    )
    if default_cache is _DEFAULT:
        default_cache = EncodedCache(
            ctx=EncodedCacheContext(cache_dir=tmp_path / "default_cache", max_size_bytes=0)
        )
    coordinator = _FakeCoordinator()
    orchestrator = ConversionOrchestrator(
        database=db,
        music_library_dir=tmp_path,
        staging_dir=tmp_path / ".staging",
        track_locks=TrackLocks(),
        encoder_coordinator=coordinator,
        cache=cache,
        default_cache=default_cache,
        available_encoders=available_encoders or _ALL_CODECS,
        # 7A.2a check seam: the shared storage ledger replaces the old
        # free-space check (real disk, no floor, a fixed boot id).
        storage_ledger=StorageLedger(db, path=tmp_path, floor_bytes=0, boot_id="test-boot"),
    )
    return db, orchestrator, coordinator


def _run_submitted(coordinator: _FakeCoordinator) -> None:
    fn, args, kwargs = coordinator.submitted[-1]
    fn(*args, **kwargs)


def _staging_files(tmp_path: Path) -> list[str]:
    staging = tmp_path / ".staging"
    return sorted(p.name for p in staging.iterdir()) if staging.is_dir() else []


def _assert_track_untouched(db: Database, before: Track, source: Path, original: bytes) -> None:
    after = db.get_track_by_uuid(before.uuid_id)
    assert after.metadata.codec == before.metadata.codec
    assert str(after.file_path) == str(before.file_path)
    assert after.revision == before.revision
    assert source.read_bytes() == original
