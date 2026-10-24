from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest

from app.database.database import Database, DatabaseContext, RevisionConflict, TrackNotFound
from app.models.track import Track
from app.models.track_meta_data import TrackMetaData
from app.services.conversion import (
    ConversionFailed,
    ConversionOrchestrator,
    InsufficientDiskSpace,
    MasterNotFound,
    NoOpConversion,
    reconcile_conversion_jobs,
)
from app.services.encoded_cache import EncodedCache, EncodedCacheContext
from app.services.track_locks import TrackLocks
from app.services.transcoder import TranscodeResult

_INIT_SQL = Path(__file__).parent.parent / "app" / "database" / "init.sql"
_HAS_FFMPEG = shutil.which("ffmpeg") is not None and shutil.which("ffprobe") is not None
requires_ffmpeg = pytest.mark.skipif(not _HAS_FFMPEG, reason="ffmpeg/ffprobe not available")

_ALL_CODECS = frozenset({"aac", "alac", "flac", "mp3"})


def _make_audio(path: Path, codec: str = "flac", **tags) -> None:
    """Generate a tiny real audio file with the given codec/tags via ffmpeg."""
    path.parent.mkdir(parents=True, exist_ok=True)
    codec_flags = {
        "flac": ["-c:a", "flac"],
        "mp3": ["-c:a", "libmp3lame", "-b:a", "192k"],
        "aac": ["-c:a", "aac", "-b:a", "192k"],
    }[codec]
    cmd = [
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
        "-f", "lavfi", "-i", "sine=frequency=440:duration=0.3",
        *codec_flags,
    ]
    for k, v in tags.items():
        cmd += ["-metadata", f"{k}={v}"]
    cmd.append(str(path))
    subprocess.run(cmd, check=True)


def _db(tmp_path: Path) -> Database:
    db = Database(context=DatabaseContext(
        database_path=tmp_path / "database.db", init_sql_path=_INIT_SQL))
    assert db.initialize()
    return db


def _add_track(
    db: Database, file_path: Path, codec: str = "flac", bitrate_kbps: float = 1000.0,
    title: str = "T", artist: str = "Art",
) -> Track:
    meta = TrackMetaData(
        codec=codec, duration=0.3, bitrate_kbps=bitrate_kbps, sample_rate_hz=44100,
        channels=2, title=title, artist=artist,
    )
    track = Track(file_path=file_path, metadata=meta)
    assert db.add_track(track)
    return db.get_track_by_uuid(track.uuid_id)  # fresh revision from the DB


class _FakeCoordinator:
    """Records submit_conversion calls instead of running them, so tests can
    drive the worker function themselves (synchronously, deterministically,
    with real or faked internals as each test needs)."""

    def __init__(self):
        self.submitted = []

    def submit_conversion(self, fn, *args, **kwargs):
        self.submitted.append((fn, args, kwargs))


def _make_orchestrator(tmp_path: Path, available_encoders=None):
    db = _db(tmp_path)
    cache = EncodedCache(
        ctx=EncodedCacheContext(cache_dir=tmp_path / "cache", max_size_bytes=10 * 1024 * 1024)
    )
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
    )
    return db, orchestrator, coordinator


def _run_submitted(coordinator: _FakeCoordinator) -> None:
    fn, args, kwargs = coordinator.submitted[-1]
    fn(*args, **kwargs)


# ── enqueue() validation (no ffmpeg) ────────────────────────────────────────

class TestEnqueueValidation:
    def test_enqueue__unknown_uuid__raises_track_not_found(self, tmp_path):
        _, orch, _ = _make_orchestrator(tmp_path)
        with pytest.raises(TrackNotFound):
            orch.enqueue("no-such-uuid", "aac", 192, None)

    def test_enqueue__stale_base_revision__raises_revision_conflict(self, tmp_path):
        db, orch, _ = _make_orchestrator(tmp_path)
        source = tmp_path / "song.flac"
        source.write_bytes(b"fake")
        track = _add_track(db, source, codec="flac")

        with pytest.raises(RevisionConflict):
            orch.enqueue(track.uuid_id, "aac", 192, track.revision - 1)

    def test_enqueue__missing_master_file__raises_master_not_found(self, tmp_path):
        db, orch, _ = _make_orchestrator(tmp_path)
        source = tmp_path / "song.flac"  # never written to disk
        track = _add_track(db, source, codec="flac")

        with pytest.raises(MasterNotFound):
            orch.enqueue(track.uuid_id, "aac", 192, track.revision)

    def test_enqueue__unsupported_codec__raises_value_error(self, tmp_path):
        db, orch, _ = _make_orchestrator(tmp_path)
        source = tmp_path / "song.flac"
        source.write_bytes(b"fake")
        track = _add_track(db, source, codec="flac")

        with pytest.raises(ValueError):
            orch.enqueue(track.uuid_id, "wav", None, track.revision)

    def test_enqueue__codec_unavailable_on_this_build__raises_value_error(self, tmp_path):
        db, orch, _ = _make_orchestrator(tmp_path, available_encoders=frozenset({"aac"}))
        source = tmp_path / "song.flac"
        source.write_bytes(b"fake")
        track = _add_track(db, source, codec="flac")

        with pytest.raises(ValueError):
            orch.enqueue(track.uuid_id, "mp3", 192, track.revision)

    def test_enqueue__lossy_target_missing_bitrate__raises_value_error(self, tmp_path):
        db, orch, _ = _make_orchestrator(tmp_path)
        source = tmp_path / "song.flac"
        source.write_bytes(b"fake")
        track = _add_track(db, source, codec="flac")

        with pytest.raises(ValueError):
            orch.enqueue(track.uuid_id, "aac", None, track.revision)

    def test_enqueue__lossless_same_codec__raises_no_op_conversion(self, tmp_path):
        db, orch, _ = _make_orchestrator(tmp_path)
        source = tmp_path / "song.flac"
        source.write_bytes(b"fake")
        track = _add_track(db, source, codec="flac")

        with pytest.raises(NoOpConversion):
            orch.enqueue(track.uuid_id, "flac", None, track.revision)

    def test_enqueue__lossy_same_codec__allowed_not_blocked(self, tmp_path):
        db, orch, coordinator = _make_orchestrator(tmp_path)
        source = tmp_path / "song.mp3"
        source.write_bytes(b"fake")
        track = _add_track(db, source, codec="mp3", bitrate_kbps=320.0)

        job_id = orch.enqueue(track.uuid_id, "mp3", 128, track.revision)

        assert db.get_conversion_job(job_id)["status"] == "queued"
        assert len(coordinator.submitted) == 1

    def test_enqueue__insufficient_disk_space__raises(self, tmp_path, monkeypatch):
        db, orch, _ = _make_orchestrator(tmp_path)
        source = tmp_path / "song.flac"
        source.write_bytes(b"x" * 1000)
        track = _add_track(db, source, codec="flac")

        class _TinyDisk:
            free = 1

        monkeypatch.setattr(
            "app.services.conversion.shutil.disk_usage", lambda _path: _TinyDisk()
        )

        with pytest.raises(InsufficientDiskSpace):
            orch.enqueue(track.uuid_id, "aac", 192, track.revision)

    def test_enqueue__valid__persists_queued_job_and_submits(self, tmp_path):
        db, orch, coordinator = _make_orchestrator(tmp_path)
        source = tmp_path / "song.flac"
        source.write_bytes(b"fake")
        track = _add_track(db, source, codec="flac")

        job_id = orch.enqueue(track.uuid_id, "aac", 192, track.revision)

        job = db.get_conversion_job(job_id)
        assert job["status"] == "queued"
        assert job["target_codec"] == "aac"
        assert job["target_container"] == "m4a"
        assert job["target_bitrate"] == 192
        assert len(coordinator.submitted) == 1


# ── cancel() ─────────────────────────────────────────────────────────────────

class TestCancel:
    def test_cancel__queued_job__marks_cancelled_returns_true(self, tmp_path):
        db, orch, _ = _make_orchestrator(tmp_path)
        source = tmp_path / "song.flac"
        source.write_bytes(b"fake")
        track = _add_track(db, source, codec="flac")
        job_id = orch.enqueue(track.uuid_id, "aac", 192, track.revision)

        assert orch.cancel(job_id) is True
        assert db.get_conversion_job(job_id)["status"] == "cancelled"

    def test_cancel__already_terminal__returns_false(self, tmp_path):
        db, orch, _ = _make_orchestrator(tmp_path)
        source = tmp_path / "song.flac"
        source.write_bytes(b"fake")
        track = _add_track(db, source, codec="flac")
        job_id = orch.enqueue(track.uuid_id, "aac", 192, track.revision)
        orch.cancel(job_id)

        assert orch.cancel(job_id) is False

    def test_cancel__running_job__calls_registry_kill(self, tmp_path, monkeypatch):
        db, orch, coordinator = _make_orchestrator(tmp_path)
        source = tmp_path / "song.flac"
        source.write_bytes(b"fake")
        track = _add_track(db, source, codec="flac")
        job_id = orch.enqueue(track.uuid_id, "aac", 192, track.revision)
        db.mark_conversion_job_running(job_id)

        killed = {}
        monkeypatch.setattr(orch._registry, "kill", lambda jid: killed.setdefault("id", jid))

        orch.cancel(job_id)

        assert killed["id"] == job_id
        assert db.get_conversion_job(job_id)["status"] == "cancelled"


# ── worker pipeline: race safety (no ffmpeg) ────────────────────────────────

class TestWorkerRaceSafety:
    def test_worker__cancel_before_running__noops_leaves_source_untouched(self, tmp_path):
        db, orch, coordinator = _make_orchestrator(tmp_path)
        source = tmp_path / "song.flac"
        source.write_bytes(b"fake")
        track = _add_track(db, source, codec="flac")
        job_id = orch.enqueue(track.uuid_id, "aac", 192, track.revision)
        assert orch.cancel(job_id) is True

        _run_submitted(coordinator)  # simulate the pool finally getting to it

        assert db.get_conversion_job(job_id)["status"] == "cancelled"
        assert source.exists()

    def test_worker__cancel_arrives_mid_run__stays_cancelled_not_failed(self, tmp_path, monkeypatch):
        db, orch, coordinator = _make_orchestrator(tmp_path)
        source = tmp_path / "song.flac"
        source.write_bytes(b"fake")
        track = _add_track(db, source, codec="flac")
        job_id = orch.enqueue(track.uuid_id, "aac", 192, track.revision)

        def fake_transcode(*args, **kwargs):
            # Simulate a cancel request landing while this step was "running".
            orch.cancel(job_id)
            return TranscodeResult(ok=True)

        monkeypatch.setattr("app.services.conversion.transcode", fake_transcode)

        _run_submitted(coordinator)

        assert db.get_conversion_job(job_id)["status"] == "cancelled"

    def test_worker__transcode_fails__job_marked_failed_with_stderr(self, tmp_path, monkeypatch):
        db, orch, coordinator = _make_orchestrator(tmp_path)
        source = tmp_path / "song.flac"
        source.write_bytes(b"fake")
        track = _add_track(db, source, codec="flac")
        job_id = orch.enqueue(track.uuid_id, "aac", 192, track.revision)

        monkeypatch.setattr(
            "app.services.conversion.transcode",
            lambda *a, **k: TranscodeResult(ok=False, stderr="boom"),
        )

        _run_submitted(coordinator)

        job = db.get_conversion_job(job_id)
        assert job["status"] == "failed"
        assert "boom" in job["error_text"]
        assert source.exists()  # original untouched


# ── reconcile_conversion_jobs (no ffmpeg) ───────────────────────────────────

class TestReconcileConversionJobs:
    def test_reconcile__orphaned_running_job__flipped_to_failed(self, tmp_path):
        db, orch, _ = _make_orchestrator(tmp_path)
        source = tmp_path / "song.flac"
        source.write_bytes(b"fake")
        track = _add_track(db, source, codec="flac")
        job_id = orch.enqueue(track.uuid_id, "aac", 192, track.revision)
        db.mark_conversion_job_running(job_id)

        reconcile_conversion_jobs(db)

        job = db.get_conversion_job(job_id)
        assert job["status"] == "failed"
        assert "restart" in job["error_text"]

    def test_reconcile__queued_job__left_alone(self, tmp_path):
        db, orch, _ = _make_orchestrator(tmp_path)
        source = tmp_path / "song.flac"
        source.write_bytes(b"fake")
        track = _add_track(db, source, codec="flac")
        job_id = orch.enqueue(track.uuid_id, "aac", 192, track.revision)

        reconcile_conversion_jobs(db)

        assert db.get_conversion_job(job_id)["status"] == "queued"


# ── end-to-end pipeline (real ffmpeg) ────────────────────────────────────────

@requires_ffmpeg
class TestEndToEndConversion:
    def test_flac_to_aac__path_changes__converts_and_updates_db(self, tmp_path):
        db, orch, coordinator = _make_orchestrator(tmp_path)
        source = tmp_path / "song.flac"
        _make_audio(source, codec="flac", title="Original Title")
        track = _add_track(db, source, codec="flac", title="DB Title", artist="DB Artist")

        job_id = orch.enqueue(track.uuid_id, "aac", 192, track.revision)
        _run_submitted(coordinator)

        job = db.get_conversion_job(job_id)
        assert job["status"] == "done"

        updated = db.get_track_by_uuid(track.uuid_id)
        assert updated.metadata.codec == "aac"
        assert str(updated.file_path).endswith(".m4a")
        assert Path(updated.file_path).exists()
        assert not source.exists()
        assert updated.revision > track.revision

    def test_flac_to_alac__lossless_target__mirrors_source_sample_params(self, tmp_path):
        # The one case that exercises SourceAudioParams mirroring end to end
        # (sample_fmt is only mirrored for lossless targets -- see the
        # is_lossless(target_codec) guard in _run_job_inner).
        db, orch, coordinator = _make_orchestrator(tmp_path)
        source = tmp_path / "song.flac"
        _make_audio(source, codec="flac")
        track = _add_track(db, source, codec="flac")

        job_id = orch.enqueue(track.uuid_id, "alac", None, track.revision)
        _run_submitted(coordinator)

        job = db.get_conversion_job(job_id)
        assert job["status"] == "done"
        updated = db.get_track_by_uuid(track.uuid_id)
        assert updated.metadata.codec == "alac"
        assert str(updated.file_path).endswith(".m4a")
        assert Path(updated.file_path).exists()

    def test_mp3_to_mp3_new_bitrate__same_path__replaces_in_place(self, tmp_path):
        db, orch, coordinator = _make_orchestrator(tmp_path)
        source = tmp_path / "song.mp3"
        _make_audio(source, codec="mp3")
        track = _add_track(db, source, codec="mp3", bitrate_kbps=320.0)

        job_id = orch.enqueue(track.uuid_id, "mp3", 128, track.revision)
        _run_submitted(coordinator)

        job = db.get_conversion_job(job_id)
        assert job["status"] == "done"

        updated = db.get_track_by_uuid(track.uuid_id)
        assert updated.metadata.codec == "mp3"
        assert str(updated.file_path) == str(source)
        assert source.exists()

    def test_conversion__bakes_db_authoritative_tags_not_stale_source_tags(self, tmp_path):
        db, orch, coordinator = _make_orchestrator(tmp_path)
        source = tmp_path / "song.flac"
        _make_audio(source, codec="flac", title="Stale File Title")
        track = _add_track(db, source, codec="flac", title="Fresh DB Title", artist="DB Artist")

        job_id = orch.enqueue(track.uuid_id, "aac", 192, track.revision)
        _run_submitted(coordinator)
        assert db.get_conversion_job(job_id)["status"] == "done"

        updated = db.get_track_by_uuid(track.uuid_id)
        probed = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries", "format_tags=title",
             "-of", "default=nw=1:nk=1", str(updated.file_path)],
            capture_output=True, text=True, check=True,
        )
        assert probed.stdout.strip() == "Fresh DB Title"
