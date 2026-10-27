from __future__ import annotations

import json
import os
import shutil
import sqlite3
import subprocess
import threading
from pathlib import Path

import pytest

from app.core.media_types import CODEC_TO_EXT
from app.database.database import (
    ConversionJobActive,
    Database,
    DatabaseContext,
    RevisionConflict,
    TrackNotFound,
)
from app.models.track import Track
from app.models.track_meta_data import TrackMetaData
from app.services import conversion as conversion_module
from app.services.conversion import (
    TRACK_CHANGED_ERROR,
    ConversionFailed,
    ConversionOrchestrator,
    InsufficientDiskSpace,
    MasterNotFound,
    NoOpConversion,
    TargetPathTaken,
    reconcile_conversion_jobs,
)
from app.services.encoded_cache import EncodedCache, EncodedCacheContext
from app.services.track_editor import reconcile_journal
from app.services.track_locks import TrackLocks
from app.services.transcoder import TranscodeResult

_INIT_SQL = Path(__file__).parent.parent / "app" / "database" / "init.sql"
_HAS_FFMPEG = shutil.which("ffmpeg") is not None and shutil.which("ffprobe") is not None
requires_ffmpeg = pytest.mark.skipif(not _HAS_FFMPEG, reason="ffmpeg/ffprobe not available")

_ALL_CODECS = frozenset({"aac", "alac", "flac", "mp3"})
_DEFAULT = object()


# ── fixture builders (real ffmpeg) ──────────────────────────────────────────

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


def _make_cover(path: Path) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    _ffmpeg("-f", "lavfi", "-i", "color=c=red:s=32x32:d=1", "-frames:v", "1", str(path))
    return path


def _make_hires_flac(
    path: Path, *, sample_rate: int = 96000, layout: str = "stereo",
    cover: Path | None = None, duration: float = 1.0, **tags,
) -> None:
    """A 24-bit FLAC at ``sample_rate`` with ``layout`` channels and an
    optional embedded JPEG cover (attached_pic)."""
    path.parent.mkdir(parents=True, exist_ok=True)
    cmd = ["-f", "lavfi", "-i", f"sine=frequency=440:sample_rate={sample_rate}:duration={duration}"]
    if cover is not None:
        cmd += ["-i", str(cover)]
    cmd += ["-filter_complex", f"[0:a]aformat=channel_layouts={layout}[a]", "-map", "[a]"]
    if cover is not None:
        cmd += ["-map", "1", "-c:v", "copy", "-disposition:v:0", "attached_pic"]
    cmd += ["-c:a", "flac", "-sample_fmt", "s32", "-bits_per_raw_sample", "24"]
    for k, v in tags.items():
        cmd += ["-metadata", f"{k}={v}"]
    _ffmpeg(*cmd, str(path))


def _make_alac_from(source: Path, dest: Path) -> None:
    """ALAC .m4a carrying ``source``'s bit depth (24-bit -> s32p)."""
    _ffmpeg("-i", str(source), "-map", "0:a", "-c:a", "alac", "-sample_fmt", "s32p", str(dest))


def _probe(path: Path) -> dict:
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", str(path)],
        capture_output=True, text=True, check=True,
    ).stdout
    return json.loads(out)


def _audio_stream(probe: dict) -> dict:
    return next(s for s in probe["streams"] if s["codec_type"] == "audio")


def _attached_pics(probe: dict) -> list[dict]:
    return [
        s for s in probe["streams"]
        if s["codec_type"] == "video" and s.get("disposition", {}).get("attached_pic") == 1
    ]


def _tag(probe: dict, key: str) -> str | None:
    tags = {k.lower(): v for k, v in probe.get("format", {}).get("tags", {}).items()}
    return tags.get(key)


def _is_case_insensitive_fs(directory: Path) -> bool:
    probe = directory / "CaseProbe.TMP"
    probe.write_bytes(b"x")
    try:
        return (directory / "caseprobe.tmp").exists()
    finally:
        probe.unlink()


# ── orchestrator plumbing ───────────────────────────────────────────────────

def _db(tmp_path: Path) -> Database:
    db = Database(context=DatabaseContext(
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
        assert job["base_revision"] == track.revision
        assert len(coordinator.submitted) == 1

    def test_enqueue__job_already_active__raises_conversion_job_active(self, tmp_path):
        db, orch, coordinator = _make_orchestrator(tmp_path)
        source = tmp_path / "song.flac"
        source.write_bytes(b"fake")
        track = _add_track(db, source, codec="flac")
        first = orch.enqueue(track.uuid_id, "aac", 192, track.revision)

        with pytest.raises(ConversionJobActive) as exc_info:
            orch.enqueue(track.uuid_id, "mp3", 320, track.revision)

        assert exc_info.value.job_id == first
        assert len(coordinator.submitted) == 1

    def test_enqueue__target_path_taken__raises_before_persisting(self, tmp_path):
        db, orch, coordinator = _make_orchestrator(tmp_path)
        source = tmp_path / "Song.mp3"
        source.write_bytes(b"fake")
        (tmp_path / "Song.m4a").write_bytes(b"someone else")
        track = _add_track(db, source, codec="mp3", bitrate_kbps=320.0)

        with pytest.raises(TargetPathTaken):
            orch.enqueue(track.uuid_id, "aac", 192, track.revision)

        assert coordinator.submitted == []
        assert db.list_conversion_jobs()[0] == []


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

        def fake_transcode(src, dest, *args, **kwargs):
            # Simulate a cancel request landing while this step was "running"
            # (the transcode had already produced its temp).
            dest.write_bytes(b"partial-transcode")
            orch.cancel(job_id)
            return TranscodeResult(ok=True)

        monkeypatch.setattr("app.services.conversion.transcode", fake_transcode)

        _run_submitted(coordinator)

        assert db.get_conversion_job(job_id)["status"] == "cancelled"
        assert _staging_files(tmp_path) == []
        _assert_track_untouched(db, track, source, b"fake")
        assert not (tmp_path / "song.m4a").exists()
        assert db.list_journal_entries() == []

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

    def test_worker__revision_bumped_between_enqueue_and_run__fails_track_changed(
        self, tmp_path, monkeypatch
    ):
        db, orch, coordinator = _make_orchestrator(tmp_path)
        source = tmp_path / "song.flac"
        source.write_bytes(b"fake")
        track = _add_track(db, source, codec="flac")
        job_id = orch.enqueue(track.uuid_id, "aac", 192, track.revision)
        db.apply_track_metadata_edit(track.uuid_id, {"title": "Edited"}, track.revision)
        edited = db.get_track_by_uuid(track.uuid_id)

        transcoded = []
        monkeypatch.setattr(
            "app.services.conversion.transcode",
            lambda *a, **k: transcoded.append(a) or TranscodeResult(ok=True),
        )

        _run_submitted(coordinator)

        job = db.get_conversion_job(job_id)
        assert job["status"] == "failed"
        assert job["error_text"] == TRACK_CHANGED_ERROR
        assert transcoded == []  # failed fast, before any encode
        _assert_track_untouched(db, edited, source, b"fake")

    def test_worker__target_path_appears_after_enqueue__fails_without_clobbering(
        self, tmp_path, monkeypatch
    ):
        db, orch, coordinator = _make_orchestrator(tmp_path)
        source = tmp_path / "Song.mp3"
        source.write_bytes(b"fake")
        track = _add_track(db, source, codec="mp3", bitrate_kbps=320.0)
        job_id = orch.enqueue(track.uuid_id, "aac", 192, track.revision)
        squatter = tmp_path / "Song.m4a"
        squatter.write_bytes(b"someone else")
        transcoded = []
        monkeypatch.setattr(
            "app.services.conversion.transcode",
            lambda *a, **k: transcoded.append(a) or TranscodeResult(ok=True),
        )

        _run_submitted(coordinator)

        assert db.get_conversion_job(job_id)["status"] == "failed"
        assert transcoded == []
        assert squatter.read_bytes() == b"someone else"
        _assert_track_untouched(db, track, source, b"fake")


# ── reconcile_conversion_jobs / resume_queued (no ffmpeg) ───────────────────

class TestReconcileConversionJobs:
    def test_reconcile__orphaned_running_job__flipped_to_failed(self, tmp_path):
        db, orch, _ = _make_orchestrator(tmp_path)
        source = tmp_path / "song.flac"
        source.write_bytes(b"fake")
        track = _add_track(db, source, codec="flac")
        job_id = orch.enqueue(track.uuid_id, "aac", 192, track.revision)
        db.mark_conversion_job_running(job_id)

        reconcile_conversion_jobs(db, tmp_path / ".staging")

        job = db.get_conversion_job(job_id)
        assert job["status"] == "failed"
        assert job["error_text"] == "interrupted by restart"

    def test_reconcile__queued_and_done_jobs__left_alone(self, tmp_path):
        db, _, _ = _make_orchestrator(tmp_path)
        track_a = _add_track(db, tmp_path / "a.flac", codec="flac")
        track_b = _add_track(db, tmp_path / "b.flac", codec="flac")
        queued = db.insert_conversion_job(track_a.uuid_id, "aac", "m4a", 192)
        done = db.insert_conversion_job(track_b.uuid_id, "aac", "m4a", 192)
        db.mark_conversion_job_running(done)
        db.complete_conversion_job(done, track_b.uuid_id, "aac", 192.0, 44100, 2)

        reconcile_conversion_jobs(db, tmp_path / ".staging")

        assert db.get_conversion_job(queued)["status"] == "queued"
        assert db.get_conversion_job(done)["status"] == "done"

    def test_reconcile__missing_staging_dir__no_error(self, tmp_path):
        db, _, _ = _make_orchestrator(tmp_path)
        reconcile_conversion_jobs(db, tmp_path / "does-not-exist")

    def test_reconcile__sweeps_unowned_conversion_temps_keeps_owned_and_unrelated(self, tmp_path):
        db, _, _ = _make_orchestrator(tmp_path)
        staging = tmp_path / ".staging"
        staging.mkdir()
        orphan_convert = staging / "u1.convert.m4a"
        orphan_tagged = staging / "u1.tagged.m4a"
        owned_tagged = staging / "u2.tagged.mp3"
        editor_temp = staging / "u3.flac"  # Phase 1 editor temp ({uuid}{suffix})
        unrelated = staging / "notes.txt"
        for p in (orphan_convert, orphan_tagged, owned_tagged, editor_temp, unrelated):
            p.write_bytes(b"x")
        db.insert_journal_entry(
            "convert", "u2", old_path=str(tmp_path / "u2.mp3"), temp_path=str(owned_tagged)
        )

        reconcile_conversion_jobs(db, staging)

        assert not orphan_convert.exists()
        assert not orphan_tagged.exists()
        assert owned_tagged.exists()
        assert editor_temp.exists()
        assert unrelated.exists()

    def test_reconcile__kills_orphaned_ffmpeg_before_sweeping(self, tmp_path, monkeypatch):
        db, _, _ = _make_orchestrator(tmp_path)
        staging = tmp_path / ".staging"
        staging.mkdir()
        temp = staging / "u1.7.convert.m4a.partial"
        temp.write_bytes(b"x")
        seen = []

        def fake_kill(work_dir):
            seen.append((work_dir, temp.exists()))
            return []

        monkeypatch.setattr(conversion_module, "kill_orphaned_ffmpeg", fake_kill)
        reconcile_conversion_jobs(db, staging)

        assert seen == [(staging, True)]  # killed while the temp still existed
        assert not temp.exists()


class TestResumeQueued:
    def test_resume_queued__submits_each_queued_job_only(self, tmp_path):
        db, orch, coordinator = _make_orchestrator(tmp_path)
        tracks = [_add_track(db, tmp_path / f"{n}.flac", codec="flac") for n in "abc"]
        q1 = db.insert_conversion_job(tracks[0].uuid_id, "aac", "m4a", 192,
                                      base_revision=tracks[0].revision)
        q2 = db.insert_conversion_job(tracks[1].uuid_id, "mp3", "mp3", 320,
                                      base_revision=tracks[1].revision)
        running = db.insert_conversion_job(tracks[2].uuid_id, "aac", "m4a", 192)
        db.mark_conversion_job_running(running)

        orch.resume_queued()

        assert [args for _, args, _ in coordinator.submitted] == [(q1,), (q2,)]
        assert all(fn == orch._run_job for fn, _, _ in coordinator.submitted)

    def test_resume_queued__resumed_job_runs_and_validates(self, tmp_path, monkeypatch):
        # A queued job resubmitted after a restart re-runs every enqueue check:
        # here its master vanished while the server was down.
        db, orch, coordinator = _make_orchestrator(tmp_path)
        source = tmp_path / "song.flac"
        track = _add_track(db, source, codec="flac")
        job_id = db.insert_conversion_job(track.uuid_id, "aac", "m4a", 192,
                                          base_revision=track.revision)

        orch.resume_queued()
        _run_submitted(coordinator)

        job = db.get_conversion_job(job_id)
        assert job["status"] == "failed"

    def test_resume_queued__track_revision_moved__fails_track_changed(self, tmp_path):
        db, orch, coordinator = _make_orchestrator(tmp_path)
        source = tmp_path / "song.flac"
        source.write_bytes(b"fake")
        track = _add_track(db, source, codec="flac")
        job_id = db.insert_conversion_job(track.uuid_id, "aac", "m4a", 192,
                                          base_revision=track.revision)
        db.apply_track_metadata_edit(track.uuid_id, {"title": "Edited"}, track.revision)

        orch.resume_queued()
        _run_submitted(coordinator)

        job = db.get_conversion_job(job_id)
        assert job["status"] == "failed"
        assert job["error_text"] == TRACK_CHANGED_ERROR
        assert source.read_bytes() == b"fake"


@requires_ffmpeg
class TestResumeQueuedEndToEnd:
    def _setup(self, tmp_path):
        db, orch, coordinator = _make_orchestrator(tmp_path)
        source = tmp_path / "song.flac"
        _make_audio(source, codec="flac")
        track = _add_track(db, source, codec="flac")
        job_id = db.insert_conversion_job(track.uuid_id, "aac", "m4a", 192,
                                          base_revision=track.revision)
        return db, orch, coordinator, track, job_id

    def test_resume_queued__resumed_job_converts(self, tmp_path):
        db, orch, coordinator, track, job_id = self._setup(tmp_path)
        (tmp_path / ".staging").mkdir()  # left behind by the enqueue before the restart

        orch.resume_queued()
        assert len(coordinator.submitted) == 1
        _run_submitted(coordinator)

        assert db.get_conversion_job(job_id)["status"] == "done"
        updated = db.get_track_by_uuid(track.uuid_id)
        assert updated.metadata.codec == "aac"
        assert _audio_stream(_probe(Path(updated.file_path)))["codec_name"] == "aac"

    def test_resume_queued__staging_dir_missing__still_converts(self, tmp_path):
        db, orch, coordinator, track, job_id = self._setup(tmp_path)
        assert not (tmp_path / ".staging").exists()

        orch.resume_queued()
        assert len(coordinator.submitted) == 1
        _run_submitted(coordinator)

        assert db.get_conversion_job(job_id)["status"] == "done"
        updated = db.get_track_by_uuid(track.uuid_id)
        assert updated.metadata.codec == "aac"
        assert _audio_stream(_probe(Path(updated.file_path)))["codec_name"] == "aac"


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
        assert db.list_journal_entries() == []
        assert _staging_files(tmp_path) == []

    def test_flac_to_alac__lossless_target__mirrors_source_sample_params(self, tmp_path):
        # The one case that exercises SourceAudioParams mirroring end to end:
        # a stereo 24-bit/96 kHz source, where ffmpeg's ALAC defaults would
        # otherwise not obviously coincide with the source.
        db, orch, coordinator = _make_orchestrator(tmp_path)
        source = tmp_path / "song.flac"
        _make_hires_flac(source)
        track = _add_track(db, source, codec="flac", sample_rate_hz=96000)

        job_id = orch.enqueue(track.uuid_id, "alac", None, track.revision)
        _run_submitted(coordinator)

        assert db.get_conversion_job(job_id)["status"] == "done"
        updated = db.get_track_by_uuid(track.uuid_id)
        assert updated.metadata.codec == "alac"
        assert str(updated.file_path).endswith(".m4a")
        stream = _audio_stream(_probe(Path(updated.file_path)))
        assert stream["codec_name"] == "alac"
        assert int(stream["bits_per_raw_sample"]) == 24
        assert int(stream["sample_rate"]) == 96000
        assert stream["channels"] == 2

    def test_mp3_to_mp3_new_bitrate__same_path__replaces_in_place(self, tmp_path):
        db, orch, coordinator = _make_orchestrator(tmp_path)
        source = tmp_path / "song.mp3"
        _make_audio(source, codec="mp3")
        track = _add_track(db, source, codec="mp3", bitrate_kbps=192.0)

        job_id = orch.enqueue(track.uuid_id, "mp3", 128, track.revision)
        _run_submitted(coordinator)

        job = db.get_conversion_job(job_id)
        assert job["status"] == "done"

        updated = db.get_track_by_uuid(track.uuid_id)
        assert updated.metadata.codec == "mp3"
        assert str(updated.file_path) == str(source)
        probed_kbps = int(_audio_stream(_probe(source))["bit_rate"]) / 1000
        assert probed_kbps == pytest.approx(128, abs=8)
        assert updated.metadata.bitrate_kbps == pytest.approx(128, abs=8)
        assert updated.metadata.bitrate_kbps != track.metadata.bitrate_kbps
        assert updated.revision > track.revision
        assert db.list_journal_entries() == []
        assert _staging_files(tmp_path) == []

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


def _assert_db_matches_probe(db: Database, uuid_id: str) -> dict:
    updated = db.get_track_by_uuid(uuid_id)
    stream = _audio_stream(_probe(Path(updated.file_path)))
    assert updated.metadata.codec == stream["codec_name"]
    assert updated.metadata.sample_rate_hz == int(stream["sample_rate"])
    assert updated.metadata.channels == stream["channels"]
    return stream


@requires_ffmpeg
class TestRealConversionMatrix:
    @pytest.mark.parametrize("target,bitrate,ext", [
        ("aac", 256, "m4a"),
        ("alac", None, "m4a"),
        ("mp3", 320, "mp3"),
    ])
    def test_hires_flac_with_cover__converts_keeps_art_and_stores_probed_values(
        self, tmp_path, target, bitrate, ext
    ):
        db, orch, coordinator = _make_orchestrator(tmp_path)
        source = tmp_path / "song.flac"
        _make_hires_flac(source, cover=_make_cover(tmp_path / "art" / "cover.jpg"))
        track = _add_track(db, source, codec="flac", sample_rate_hz=96000, has_album_art=True)

        job_id = orch.enqueue(track.uuid_id, target, bitrate, track.revision)
        _run_submitted(coordinator)

        job = db.get_conversion_job(job_id)
        assert job["status"] == "done", job
        updated = db.get_track_by_uuid(track.uuid_id)
        assert Path(updated.file_path).suffix == f".{ext}"
        assert not source.exists()
        stream = _assert_db_matches_probe(db, track.uuid_id)
        assert stream["codec_name"] == target
        if target == "alac":
            assert int(stream["bits_per_raw_sample"]) == 24
            assert int(stream["sample_rate"]) == 96000
            assert stream["channels"] == 2
        pics = _attached_pics(_probe(Path(updated.file_path)))
        assert len(pics) == 1
        assert pics[0]["codec_name"] == "mjpeg"
        assert _staging_files(tmp_path) == []

    def test_mp3_to_flac__lossy_source__16_bit_output(self, tmp_path):
        db, orch, coordinator = _make_orchestrator(tmp_path)
        source = tmp_path / "song.mp3"
        _make_audio(source, codec="mp3")
        track = _add_track(db, source, codec="mp3", bitrate_kbps=192.0)

        job_id = orch.enqueue(track.uuid_id, "flac", None, track.revision)
        _run_submitted(coordinator)

        assert db.get_conversion_job(job_id)["status"] == "done"
        stream = _assert_db_matches_probe(db, track.uuid_id)
        assert stream["codec_name"] == "flac"
        assert stream["sample_fmt"] == "s16"
        assert int(stream.get("bits_per_raw_sample", 16)) == 16
        updated = db.get_track_by_uuid(track.uuid_id)
        assert updated.metadata.bitrate_kbps > 0  # format-level fallback for lossless

    def test_alac_to_flac__keeps_24_bit(self, tmp_path):
        db, orch, coordinator = _make_orchestrator(tmp_path)
        hires = tmp_path / "work" / "hires.flac"
        _make_hires_flac(hires)
        source = tmp_path / "song.m4a"
        _make_alac_from(hires, source)
        assert int(_audio_stream(_probe(source))["bits_per_raw_sample"]) == 24
        track = _add_track(db, source, codec="alac", sample_rate_hz=96000)

        job_id = orch.enqueue(track.uuid_id, "flac", None, track.revision)
        _run_submitted(coordinator)

        assert db.get_conversion_job(job_id)["status"] == "done"
        stream = _assert_db_matches_probe(db, track.uuid_id)
        assert stream["codec_name"] == "flac"
        assert int(stream["bits_per_raw_sample"]) == 24
        assert int(stream["sample_rate"]) == 96000

    def test_surround_96k_flac_to_mp3__stores_resampled_downmixed_probed_values(self, tmp_path):
        db, orch, coordinator = _make_orchestrator(tmp_path)
        source = tmp_path / "song.flac"
        _make_hires_flac(source, layout="5.1")
        assert _audio_stream(_probe(source))["channels"] == 6
        track = _add_track(db, source, codec="flac", sample_rate_hz=96000, channels=6)

        job_id = orch.enqueue(track.uuid_id, "mp3", 320, track.revision)
        _run_submitted(coordinator)

        job = db.get_conversion_job(job_id)
        assert job["status"] == "done", job
        stream = _assert_db_matches_probe(db, track.uuid_id)
        assert int(stream["sample_rate"]) <= 48000
        assert stream["channels"] <= 2


# ── WAV sources (real ffmpeg) ────────────────────────────────────────────────

_INT_FMT_BITS = {"s16": 16, "s16p": 16, "s32": 32, "s32p": 32}


def _make_wav(path: Path, pcm_codec: str) -> None:
    """A tiny stereo 48 kHz WAV in ``pcm_codec`` (pcm_s16le/s24le/f32le)."""
    path.parent.mkdir(parents=True, exist_ok=True)
    _ffmpeg("-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=0.3",
            "-ac", "2", "-c:a", pcm_codec, str(path))


def _effective_bits(stream: dict) -> int:
    raw = str(stream.get("bits_per_raw_sample", ""))
    if raw.isdigit() and int(raw) > 0:
        return int(raw)
    return _INT_FMT_BITS[stream["sample_fmt"]]


@requires_ffmpeg
class TestWavSources:
    @pytest.mark.parametrize("pcm_codec", ["pcm_s16le", "pcm_s24le", "pcm_f32le"])
    @pytest.mark.parametrize("target", ["flac", "alac"])
    def test_wav_to_lossless__keeps_rate_channels_and_bit_depth(
        self, tmp_path, pcm_codec, target
    ):
        db, orch, coordinator = _make_orchestrator(tmp_path)
        source = tmp_path / "song.wav"
        _make_wav(source, pcm_codec)
        track = _add_track(db, source, codec=pcm_codec, bitrate_kbps=1536.0,
                           sample_rate_hz=48000)

        job_id = orch.enqueue(track.uuid_id, target, None, track.revision)
        _run_submitted(coordinator)

        job = db.get_conversion_job(job_id)
        assert job["status"] == "done", job
        updated = db.get_track_by_uuid(track.uuid_id)
        assert Path(updated.file_path).suffix == f".{CODEC_TO_EXT[target]}"
        assert not source.exists()
        stream = _assert_db_matches_probe(db, track.uuid_id)
        assert stream["codec_name"] == target
        assert int(stream["sample_rate"]) == 48000
        assert stream["channels"] == 2
        # Integer output format in every case (flac/alac have no float mode).
        assert stream["sample_fmt"] in _INT_FMT_BITS
        bits = _effective_bits(stream)
        if pcm_codec == "pcm_s16le":
            assert bits == 16
            assert stream["sample_fmt"] in ("s16", "s16p")
        elif pcm_codec == "pcm_s24le":
            assert int(stream["bits_per_raw_sample"]) == 24
        else:  # float source: no integer depth to mirror -> encoder default
            assert bits >= 16
        assert db.list_journal_entries() == []
        assert _staging_files(tmp_path) == []

    @pytest.mark.parametrize("target,bitrate,ext", [("aac", 256, "m4a"), ("mp3", 320, "mp3")])
    def test_wav_s16_to_lossy__converts(self, tmp_path, target, bitrate, ext):
        db, orch, coordinator = _make_orchestrator(tmp_path)
        source = tmp_path / "song.wav"
        _make_wav(source, "pcm_s16le")
        track = _add_track(db, source, codec="pcm_s16le", bitrate_kbps=1536.0,
                           sample_rate_hz=48000)

        job_id = orch.enqueue(track.uuid_id, target, bitrate, track.revision)
        _run_submitted(coordinator)

        job = db.get_conversion_job(job_id)
        assert job["status"] == "done", job
        updated = db.get_track_by_uuid(track.uuid_id)
        assert Path(updated.file_path).suffix == f".{ext}"
        assert not source.exists()
        stream = _assert_db_matches_probe(db, track.uuid_id)
        assert stream["codec_name"] == target
        assert _staging_files(tmp_path) == []


# ── cover art from non-FLAC sources (real ffmpeg) ───────────────────────────

def _make_mp3_with_jpeg(path: Path, cover: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    _ffmpeg("-f", "lavfi", "-i", "sine=frequency=440:duration=0.3", "-i", str(cover),
            "-map", "0:a", "-map", "1", "-c:a", "libmp3lame", "-b:a", "192k",
            "-c:v", "copy", "-id3v2_version", "3", str(path))


def _make_aac_m4a_with_png(path: Path, cover: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    _ffmpeg("-f", "lavfi", "-i", "sine=frequency=440:duration=0.3", "-i", str(cover),
            "-map", "0:a", "-map", "1", "-c:a", "aac", "-b:a", "192k",
            "-c:v", "copy", "-disposition:v:0", "attached_pic", str(path))


@requires_ffmpeg
class TestCoverArtFromNonFlacSources:
    @pytest.mark.parametrize("target,bitrate,ext", [("aac", 192, "m4a"), ("flac", None, "flac")])
    def test_mp3_with_jpeg_cover__art_preserved(self, tmp_path, target, bitrate, ext):
        db, orch, coordinator = _make_orchestrator(tmp_path)
        source = tmp_path / "song.mp3"
        _make_mp3_with_jpeg(source, _make_cover(tmp_path / "art" / "cover.jpg"))
        src_pics = _attached_pics(_probe(source))
        assert [p["codec_name"] for p in src_pics] == ["mjpeg"]
        track = _add_track(db, source, codec="mp3", bitrate_kbps=192.0, has_album_art=True)

        job_id = orch.enqueue(track.uuid_id, target, bitrate, track.revision)
        _run_submitted(coordinator)

        job = db.get_conversion_job(job_id)
        assert job["status"] == "done", job
        updated = db.get_track_by_uuid(track.uuid_id)
        assert Path(updated.file_path) == tmp_path / f"song.{ext}"
        assert not source.exists()  # path change: old master gone
        assert _assert_db_matches_probe(db, track.uuid_id)["codec_name"] == target
        pics = _attached_pics(_probe(Path(updated.file_path)))
        assert len(pics) == 1
        assert pics[0]["codec_name"] == "mjpeg"
        assert db.list_journal_entries() == []
        assert _staging_files(tmp_path) == []

    @pytest.mark.parametrize("target,bitrate,ext", [("mp3", 320, "mp3"), ("alac", None, "m4a")])
    def test_aac_m4a_with_png_cover__art_preserved(self, tmp_path, target, bitrate, ext):
        db, orch, coordinator = _make_orchestrator(tmp_path)
        source = tmp_path / "song.m4a"
        _make_aac_m4a_with_png(source, _make_cover(tmp_path / "art" / "cover.png"))
        src_pics = _attached_pics(_probe(source))
        assert [p["codec_name"] for p in src_pics] == ["png"]
        track = _add_track(db, source, codec="aac", bitrate_kbps=192.0, has_album_art=True)

        job_id = orch.enqueue(track.uuid_id, target, bitrate, track.revision)
        _run_submitted(coordinator)

        job = db.get_conversion_job(job_id)
        assert job["status"] == "done", job
        updated = db.get_track_by_uuid(track.uuid_id)
        dest = tmp_path / f"song.{ext}"
        assert Path(updated.file_path) == dest
        if dest != source:
            assert not source.exists()  # path change: old master gone
        assert _assert_db_matches_probe(db, track.uuid_id)["codec_name"] == target
        pics = _attached_pics(_probe(dest))
        assert len(pics) == 1
        assert pics[0]["codec_name"] == "png"
        assert db.list_journal_entries() == []
        assert _staging_files(tmp_path) == []


# ── cancel races in the tag-bake -> commit window (real ffmpeg) ─────────────

def _cancel_race_setup(tmp_path: Path, case: str):
    """Returns (db, orch, coordinator, track, source, dest, original_bytes, target, bitrate)."""
    db, orch, coordinator = _make_orchestrator(tmp_path)
    if case == "flac_to_aac":  # path-change branch
        source = tmp_path / "song.flac"
        _make_audio(source, codec="flac")
        track = _add_track(db, source, codec="flac")
        target, bitrate, dest = "aac", 192, tmp_path / "song.m4a"
    elif case == "mp3_to_mp3":  # same-path branch
        source = tmp_path / "song.mp3"
        _make_audio(source, codec="mp3")
        track = _add_track(db, source, codec="mp3", bitrate_kbps=192.0)
        target, bitrate, dest = "mp3", 128, source
    elif case == "alac_to_aac":  # same-path branch (.m4a -> .m4a)
        hires = tmp_path / "work" / "hires.flac"
        _make_hires_flac(hires, duration=0.5)
        source = tmp_path / "song.m4a"
        _make_alac_from(hires, source)
        track = _add_track(db, source, codec="alac", sample_rate_hz=96000)
        target, bitrate, dest = "aac", 192, source
    else:
        raise AssertionError(case)
    return db, orch, coordinator, track, source, dest, source.read_bytes(), target, bitrate


_CANCEL_CASES = ["flac_to_aac", "mp3_to_mp3", "alac_to_aac"]


@requires_ffmpeg
class TestCancelRaces:
    def _assert_cancelled_cleanly(self, tmp_path, db, track, source, dest, original, job_id):
        assert db.get_conversion_job(job_id)["status"] == "cancelled"
        _assert_track_untouched(db, track, source, original)
        if dest != source:
            assert not dest.exists()
        assert db.list_journal_entries() == []
        assert _staging_files(tmp_path) == []

    @pytest.mark.parametrize("case", _CANCEL_CASES)
    def test_cancel_after_tag_bake_before_lock__nothing_lands(self, tmp_path, monkeypatch, case):
        db, orch, coordinator, track, source, dest, original, target, bitrate = (
            _cancel_race_setup(tmp_path, case)
        )
        job_id = orch.enqueue(track.uuid_id, target, bitrate, track.revision)
        real_probe = conversion_module._probe_intrinsic_fields

        def probe_then_cancel(path, target_codec):
            assert orch.cancel(job_id) is True
            return real_probe(path, target_codec)

        monkeypatch.setattr(conversion_module, "_probe_intrinsic_fields", probe_then_cancel)

        _run_submitted(coordinator)

        self._assert_cancelled_cleanly(tmp_path, db, track, source, dest, original, job_id)

    @pytest.mark.parametrize("case", _CANCEL_CASES)
    def test_cancel_inside_lock_right_before_commit__commit_refused(
        self, tmp_path, monkeypatch, case
    ):
        # Lands after the in-lock _raise_if_cancelled check passed, so only
        # complete_conversion_job's 'running' condition stands between the
        # cancel and the conversion landing.
        db, orch, coordinator, track, source, dest, original, target, bitrate = (
            _cancel_race_setup(tmp_path, case)
        )
        job_id = orch.enqueue(track.uuid_id, target, bitrate, track.revision)
        real_complete = db.complete_conversion_job
        calls = []

        def cancel_then_complete(*args, **kwargs):
            calls.append(kwargs)
            assert orch.cancel(job_id) is True
            return real_complete(*args, **kwargs)

        monkeypatch.setattr(db, "complete_conversion_job", cancel_then_complete)

        _run_submitted(coordinator)

        assert len(calls) == 1
        self._assert_cancelled_cleanly(tmp_path, db, track, source, dest, original, job_id)

    def test_cancel_after_move_before_commit__path_change_reverted(self, tmp_path, monkeypatch):
        db, orch, coordinator, track, source, dest, original, target, bitrate = (
            _cancel_race_setup(tmp_path, "flac_to_aac")
        )
        job_id = orch.enqueue(track.uuid_id, target, bitrate, track.revision)
        real_move = conversion_module.move_file

        def move_then_cancel(*args, **kwargs):
            moved = real_move(*args, **kwargs)
            assert dest.exists()
            assert orch.cancel(job_id) is True
            return moved

        monkeypatch.setattr(conversion_module, "move_file", move_then_cancel)

        _run_submitted(coordinator)

        self._assert_cancelled_cleanly(tmp_path, db, track, source, dest, original, job_id)


# ── cancel-then-re-POST overlap (real ffmpeg, real threads) ─────────────────

_WAIT_S = 30


@requires_ffmpeg
class TestCancelThenRepostOverlap:
    def test_cancelled_job_still_running__new_job_converts_once(self, tmp_path, monkeypatch):
        # A user cancels job A while its worker is still mid-transcode, then
        # immediately re-POSTs (job B). B must run to completion while A is
        # still alive, and A's eventual wake-up must neither commit nor touch
        # B's temps or B's converted master.
        db, orch, coordinator = _make_orchestrator(tmp_path)
        source = tmp_path / "song.flac"
        _make_audio(source, codec="flac")
        track = _add_track(db, source, codec="flac")

        job_a = orch.enqueue(track.uuid_id, "aac", 256, track.revision)
        fn_a, args_a, kwargs_a = coordinator.submitted[-1]

        real_transcode = conversion_module.transcode
        a_entered = threading.Event()
        release_a = threading.Event()
        dests: dict[int, Path] = {}
        a_wait_timed_out = []

        def gated_transcode(src, dest, *args, **kwargs):
            jid = kwargs.get("job_id")
            dests[jid] = dest
            if jid == job_a:
                a_entered.set()
                if not release_a.wait(timeout=_WAIT_S):
                    a_wait_timed_out.append(True)
            return real_transcode(src, dest, *args, **kwargs)

        monkeypatch.setattr(conversion_module, "transcode", gated_transcode)

        thread_a = threading.Thread(target=fn_a, args=args_a, kwargs=kwargs_a, daemon=True)
        thread_a.start()
        try:
            assert a_entered.wait(timeout=_WAIT_S), "job A never reached transcode"
            assert db.get_conversion_job(job_a)["status"] == "running"
            assert orch.cancel(job_a) is True

            # Re-POST right away: allowed, A is no longer queued/running.
            pre_b = db.get_track_by_uuid(track.uuid_id)
            job_b = orch.enqueue(track.uuid_id, "aac", 192, pre_b.revision)
            assert job_b != job_a
            fn_b, args_b, kwargs_b = coordinator.submitted[-1]
            thread_b = threading.Thread(target=fn_b, args=args_b, kwargs=kwargs_b, daemon=True)
            thread_b.start()
            thread_b.join(timeout=_WAIT_S)
            assert not thread_b.is_alive(), "job B did not finish"
            assert thread_a.is_alive()  # A is still parked in its transcode
            assert db.get_conversion_job(job_b)["status"] == "done", db.get_conversion_job(job_b)
        finally:
            release_a.set()
            thread_a.join(timeout=_WAIT_S)
        assert not thread_a.is_alive(), "job A did not finish after release"
        assert a_wait_timed_out == []

        assert db.get_conversion_job(job_a)["status"] == "cancelled"
        assert db.get_conversion_job(job_b)["status"] == "done"
        updated = db.get_track_by_uuid(track.uuid_id)
        assert updated.metadata.codec == "aac"
        assert Path(updated.file_path) == tmp_path / "song.m4a"
        assert updated.revision == pre_b.revision + 1
        assert sorted(p.name for p in tmp_path.glob("*.m4a")) == ["song.m4a"]
        assert not source.exists()
        assert _audio_stream(_probe(tmp_path / "song.m4a"))["codec_name"] == "aac"
        assert set(dests) == {job_a, job_b}
        assert dests[job_a] != dests[job_b]  # job-scoped temp names
        for jid in (job_a, job_b):
            assert dests[jid].name == f"{track.uuid_id}.{jid}.convert.m4a"
        assert _staging_files(tmp_path) == []
        assert db.list_journal_entries() == []


# ── same-path journaling invariant (real ffmpeg) ────────────────────────────

@requires_ffmpeg
class TestSamePathJournaling:
    def _setup(self, tmp_path):
        db, orch, coordinator = _make_orchestrator(tmp_path)
        source = tmp_path / "song.mp3"
        _make_audio(source, codec="mp3")
        track = _add_track(db, source, codec="mp3", bitrate_kbps=192.0)
        job_id = orch.enqueue(track.uuid_id, "mp3", 128, track.revision)
        return db, orch, coordinator, track, source, source.read_bytes(), job_id

    def test_commit_raises__no_journal_row_master_untouched(self, tmp_path, monkeypatch):
        db, orch, coordinator, track, source, original, job_id = self._setup(tmp_path)

        def boom(*args, **kwargs):
            raise sqlite3.OperationalError("disk I/O error")

        monkeypatch.setattr(db, "complete_conversion_job", boom)

        _run_submitted(coordinator)

        job = db.get_conversion_job(job_id)
        assert job["status"] == "failed"
        assert "disk I/O error" in job["error_text"]
        assert db.list_journal_entries() == []
        assert _staging_files(tmp_path) == []
        _assert_track_untouched(db, track, source, original)

        reconcile_journal(db, tmp_path)

        _assert_track_untouched(db, track, source, original)

    def test_crash_after_commit_before_replace__reconcile_redoes_replace(
        self, tmp_path, monkeypatch
    ):
        db, orch, coordinator, track, source, original, job_id = self._setup(tmp_path)
        real_replace = os.replace
        failed = []

        def replace_fails_once_for_tagged_temp(src, dst, *args, **kwargs):
            if ".tagged." in str(src) and not failed:
                failed.append(src)
                raise OSError("simulated crash before replace")
            return real_replace(src, dst, *args, **kwargs)

        monkeypatch.setattr(conversion_module.os, "replace", replace_fails_once_for_tagged_temp)

        _run_submitted(coordinator)

        assert failed, "the in-place replace was never attempted"
        entries = db.list_journal_entries()
        assert len(entries) == 1
        assert entries[0]["intent"] == "convert"
        assert Path(entries[0]["temp_path"]).exists()  # the journal owns the temp
        assert source.read_bytes() == original  # replace hasn't happened yet
        advanced = db.get_track_by_uuid(track.uuid_id)
        assert advanced.revision > track.revision

        # Startup: the journal sweep must not eat the journal-owned temp.
        reconcile_conversion_jobs(db, tmp_path / ".staging")
        assert Path(entries[0]["temp_path"]).exists()
        reconcile_journal(db, tmp_path)

        assert db.list_journal_entries() == []
        assert _staging_files(tmp_path) == []
        assert source.read_bytes() != original
        stream = _audio_stream(_probe(source))
        assert stream["codec_name"] == advanced.metadata.codec == "mp3"
        assert int(stream["bit_rate"]) / 1000 == pytest.approx(128, abs=8)
        assert advanced.metadata.bitrate_kbps == pytest.approx(128, abs=8)


@requires_ffmpeg
class TestPendingRecovery:
    """A same-path replace that failed in-process leaves its journal row +
    temp for the next startup to finish. Until then a new conversion of that
    track must not run: it would either clobber the journal-owned temp or
    have reconcile later overwrite its result with the older one."""

    def _leave_pending_replace(self, tmp_path, monkeypatch):
        db, orch, coordinator, track, source, original, job_id = (
            TestSamePathJournaling()._setup(tmp_path)
        )
        real_replace = os.replace

        def fail_tagged_replace(src, dst, *args, **kwargs):
            if ".tagged." in str(src):
                raise OSError("simulated replace failure")
            return real_replace(src, dst, *args, **kwargs)

        monkeypatch.setattr(conversion_module.os, "replace", fail_tagged_replace)
        _run_submitted(coordinator)
        monkeypatch.setattr(conversion_module.os, "replace", real_replace)
        [entry] = db.list_journal_entries()
        return db, orch, coordinator, track, source, Path(entry["temp_path"])

    def test_enqueue__journal_row_outstanding__raises_pending_recovery(
        self, tmp_path, monkeypatch
    ):
        db, orch, coordinator, track, source, owned_temp = self._leave_pending_replace(
            tmp_path, monkeypatch
        )
        current = db.get_track_by_uuid(track.uuid_id)
        submitted = len(coordinator.submitted)

        with pytest.raises(conversion_module.PendingRecovery):
            orch.enqueue(track.uuid_id, "mp3", 320, current.revision)

        assert len(coordinator.submitted) == submitted
        assert owned_temp.exists()

    def test_queued_job__journal_row_appears__fails_without_touching_owned_temp(
        self, tmp_path, monkeypatch
    ):
        db, orch, coordinator = _make_orchestrator(tmp_path)
        source = tmp_path / "song.mp3"
        _make_audio(source, codec="mp3")
        track = _add_track(db, source, codec="mp3", bitrate_kbps=192.0)
        job_id = orch.enqueue(track.uuid_id, "mp3", 128, track.revision)
        staging = tmp_path / ".staging"
        staging.mkdir(exist_ok=True)
        # Same name scheme an earlier job (id 999) would have used.
        owned = staging / f"{track.uuid_id}.999.tagged.mp3"
        owned.write_bytes(b"owned")
        db.insert_journal_entry("convert", track.uuid_id, old_path=str(source),
                                temp_path=str(owned))

        _run_submitted(coordinator)

        job = db.get_conversion_job(job_id)
        assert job["status"] == "failed"
        assert "awaiting recovery" in job["error_text"]
        assert owned.read_bytes() == b"owned"

    def test_temp_names_are_job_scoped(self, tmp_path, monkeypatch):
        db, orch, coordinator = _make_orchestrator(tmp_path)
        source = tmp_path / "song.flac"
        _make_audio(source)
        track = _add_track(db, source)
        job_id = orch.enqueue(track.uuid_id, "aac", 192, track.revision)
        seen = []
        real_transcode = conversion_module.transcode

        def spy(src, dest, *args, **kwargs):
            seen.append(dest.name)
            return real_transcode(src, dest, *args, **kwargs)

        monkeypatch.setattr(conversion_module, "transcode", spy)
        _run_submitted(coordinator)

        assert seen == [f"{track.uuid_id}.{job_id}.convert.m4a"]
        assert db.get_conversion_job(job_id)["status"] == "done"


class TestWorkerBookkeepingFailures:
    def test_mark_running_raises__job_failed_not_stuck_queued(self, tmp_path, monkeypatch):
        db, orch, coordinator = _make_orchestrator(tmp_path)
        source = tmp_path / "song.flac"
        source.write_bytes(b"x")
        track = _add_track(db, source)
        job_id = orch.enqueue(track.uuid_id, "aac", 192, track.revision)

        def busy(_job_id):
            raise sqlite3.OperationalError("database is locked")

        monkeypatch.setattr(db, "mark_conversion_job_running", busy)
        _run_submitted(coordinator)

        job = db.get_conversion_job(job_id)
        assert job["status"] == "failed"
        assert "locked" in job["error_text"]
        # No longer "active": the track can be converted again.
        assert orch.enqueue(track.uuid_id, "aac", 192, track.revision) != job_id

    def test_shutdown__kills_running_ffmpeg(self, tmp_path):
        _, orch, _ = _make_orchestrator(tmp_path)
        proc = subprocess.Popen(["sleep", "30"], start_new_session=True)
        try:
            orch._registry.register(7, proc)
            orch.shutdown()
            assert proc.wait(timeout=5) != 0
        finally:
            if proc.poll() is None:
                proc.kill()


# ── path-change crash windows (real ffmpeg) ─────────────────────────────────

class _HardCrash(BaseException):
    """Stands in for the process dying: not an Exception, so _run_job's
    outer handler doesn't catch it."""


@requires_ffmpeg
class TestPathChangeCrashWindows:
    """At each crash point, startup's reconcile_journal is run against the
    exact on-disk + DB state the crash would leave (inside the hook, before
    any in-process cleanup can run), and the resulting state is recorded."""

    def _setup(self, tmp_path):
        db, orch, coordinator = _make_orchestrator(tmp_path)
        source = tmp_path / "song.flac"
        _make_audio(source, codec="flac")
        track = _add_track(db, source, codec="flac")
        job_id = orch.enqueue(track.uuid_id, "aac", 192, track.revision)
        return db, orch, coordinator, track, source, tmp_path / "song.m4a", job_id

    def _snapshot(self, db, track, source, dest):
        current = db.get_track_by_uuid(track.uuid_id)
        return {
            "journal": db.list_journal_entries(),
            "source_bytes": source.read_bytes() if source.exists() else None,
            "dest_exists": dest.exists(),
            "db_path": str(current.file_path),
            "db_codec": current.metadata.codec,
            "db_revision": current.revision,
            "dest_codec": _audio_stream(_probe(dest))["codec_name"] if dest.exists() else None,
        }

    def _assert_reverted(self, snap, track, source, original):
        assert snap["journal"] == []
        assert snap["source_bytes"] == original
        assert snap["dest_exists"] is False
        assert snap["db_path"] == str(source)
        assert snap["db_codec"] == "flac"
        assert snap["db_revision"] == track.revision

    def test_crash_after_journal_insert_before_move__old_master_kept(self, tmp_path, monkeypatch):
        db, orch, coordinator, track, source, dest, job_id = self._setup(tmp_path)
        original = source.read_bytes()
        snap = {}

        def crash_before_move(*args, **kwargs):
            assert len(db.list_journal_entries()) == 1
            reconcile_journal(db, tmp_path)
            snap.update(self._snapshot(db, track, source, dest))
            raise _HardCrash()

        monkeypatch.setattr(conversion_module, "move_file", crash_before_move)

        with pytest.raises(_HardCrash):
            _run_submitted(coordinator)

        self._assert_reverted(snap, track, source, original)
        reconcile_conversion_jobs(db, tmp_path / ".staging")
        assert db.get_conversion_job(job_id)["status"] == "failed"
        assert _staging_files(tmp_path) == []

    def test_crash_after_move_before_commit__new_copy_dropped(self, tmp_path, monkeypatch):
        db, orch, coordinator, track, source, dest, job_id = self._setup(tmp_path)
        original = source.read_bytes()
        real_move = conversion_module.move_file
        snap = {}

        def move_then_crash(*args, **kwargs):
            assert real_move(*args, **kwargs)
            assert dest.exists()
            reconcile_journal(db, tmp_path)
            snap.update(self._snapshot(db, track, source, dest))
            raise _HardCrash()

        monkeypatch.setattr(conversion_module, "move_file", move_then_crash)

        with pytest.raises(_HardCrash):
            _run_submitted(coordinator)

        self._assert_reverted(snap, track, source, original)
        reconcile_conversion_jobs(db, tmp_path / ".staging")
        assert db.get_conversion_job(job_id)["status"] == "failed"

    def test_crash_after_commit_before_source_unlink__new_master_kept(self, tmp_path, monkeypatch):
        db, orch, coordinator, track, source, dest, job_id = self._setup(tmp_path)
        real_complete = db.complete_conversion_job
        snap = {}

        def commit_then_crash(*args, **kwargs):
            result = real_complete(*args, **kwargs)
            assert source.exists() and dest.exists()
            reconcile_journal(db, tmp_path)
            snap.update(self._snapshot(db, track, source, dest))
            raise _HardCrash()

        monkeypatch.setattr(db, "complete_conversion_job", commit_then_crash)

        with pytest.raises(_HardCrash):
            _run_submitted(coordinator)

        assert snap["journal"] == []
        assert snap["source_bytes"] is None  # old master removed
        assert snap["dest_exists"] is True
        assert snap["db_path"] == str(dest)
        assert snap["db_codec"] == snap["dest_codec"] == "aac"
        assert snap["db_revision"] > track.revision
        assert db.get_conversion_job(job_id)["status"] == "done"


# ── revision re-check (real ffmpeg) ─────────────────────────────────────────

@requires_ffmpeg
class TestRevisionRecheck:
    def test_revision_bumped_during_transcode__fails_track_changed_master_untouched(
        self, tmp_path, monkeypatch
    ):
        db, orch, coordinator = _make_orchestrator(tmp_path)
        source = tmp_path / "song.flac"
        _make_audio(source, codec="flac")
        track = _add_track(db, source, codec="flac")
        original = source.read_bytes()
        job_id = orch.enqueue(track.uuid_id, "aac", 192, track.revision)
        real_transcode = conversion_module.transcode

        def edit_then_transcode(*args, **kwargs):
            db.apply_track_metadata_edit(track.uuid_id, {"title": "Edited"}, track.revision)
            return real_transcode(*args, **kwargs)

        monkeypatch.setattr(conversion_module, "transcode", edit_then_transcode)

        _run_submitted(coordinator)

        job = db.get_conversion_job(job_id)
        assert job["status"] == "failed"
        assert job["error_text"] == TRACK_CHANGED_ERROR
        edited = db.get_track_by_uuid(track.uuid_id)
        assert edited.metadata.title == "Edited"
        assert edited.metadata.codec == "flac"
        assert str(edited.file_path) == str(source)
        assert source.read_bytes() == original
        assert not (tmp_path / "song.m4a").exists()
        assert db.list_journal_entries() == []
        assert _staging_files(tmp_path) == []


# ── case handling (real ffmpeg) ─────────────────────────────────────────────

@requires_ffmpeg
class TestExtensionCase:
    def test_uppercase_mp3_reencode__converts(self, tmp_path):
        db, orch, coordinator = _make_orchestrator(tmp_path)
        source = tmp_path / "Song.MP3"
        _make_audio(source, codec="mp3")
        track = _add_track(db, source, codec="mp3", bitrate_kbps=192.0)

        job_id = orch.enqueue(track.uuid_id, "mp3", 128, track.revision)
        _run_submitted(coordinator)

        assert db.get_conversion_job(job_id)["status"] == "done"
        updated = db.get_track_by_uuid(track.uuid_id)
        if _is_case_insensitive_fs(tmp_path):
            assert str(updated.file_path) == str(source)  # replaced in place
        audio = [p for p in tmp_path.iterdir() if p.suffix.lower() == ".mp3"]
        assert len(audio) == 1  # never two copies of the master
        stream = _audio_stream(_probe(Path(updated.file_path)))
        assert int(stream["bit_rate"]) / 1000 == pytest.approx(128, abs=8)
        assert db.list_journal_entries() == []

    def test_uppercase_m4a_alac_to_aac__same_path_on_case_insensitive_fs(self, tmp_path):
        db, orch, coordinator = _make_orchestrator(tmp_path)
        hires = tmp_path / "work" / "hires.flac"
        _make_hires_flac(hires, duration=0.5)
        source = tmp_path / "Song.M4A"
        _make_alac_from(hires, source)
        track = _add_track(db, source, codec="alac", sample_rate_hz=96000)
        case_insensitive = _is_case_insensitive_fs(tmp_path)

        job_id = orch.enqueue(track.uuid_id, "aac", 192, track.revision)
        _run_submitted(coordinator)

        assert db.get_conversion_job(job_id)["status"] == "done"
        updated = db.get_track_by_uuid(track.uuid_id)
        if case_insensitive:
            assert str(updated.file_path) == str(source)
        else:
            assert str(updated.file_path) == str(tmp_path / "Song.m4a")
            assert not source.exists()
        m4as = [p for p in tmp_path.iterdir() if p.suffix.lower() == ".m4a"]
        assert len(m4as) == 1
        assert _audio_stream(_probe(Path(updated.file_path)))["codec_name"] == "aac"
        assert db.list_journal_entries() == []
        assert _staging_files(tmp_path) == []


# ── cache eviction (real ffmpeg) ────────────────────────────────────────────

@requires_ffmpeg
class TestCacheEviction:
    def test_successful_conversion__evicts_both_caches(self, tmp_path, monkeypatch):
        db, orch, coordinator = _make_orchestrator(tmp_path)
        source = tmp_path / "song.flac"
        _make_audio(source, codec="flac")
        track = _add_track(db, source, codec="flac")
        evicted = {"cache": [], "default": []}
        monkeypatch.setattr(orch.cache, "remove_all_for_uuid", evicted["cache"].append)
        monkeypatch.setattr(orch.default_cache, "remove_all_for_uuid", evicted["default"].append)

        job_id = orch.enqueue(track.uuid_id, "aac", 192, track.revision)
        _run_submitted(coordinator)

        assert db.get_conversion_job(job_id)["status"] == "done"
        assert track.uuid_id in evicted["cache"]
        assert track.uuid_id in evicted["default"]

    def test_failed_conversion__does_not_evict(self, tmp_path, monkeypatch):
        db, orch, coordinator = _make_orchestrator(tmp_path)
        source = tmp_path / "song.flac"
        _make_audio(source, codec="flac")
        track = _add_track(db, source, codec="flac")
        evicted = []
        monkeypatch.setattr(orch.cache, "remove_all_for_uuid", evicted.append)
        monkeypatch.setattr(
            "app.services.conversion.transcode",
            lambda *a, **k: TranscodeResult(ok=False, stderr="boom"),
        )

        orch.enqueue(track.uuid_id, "aac", 192, track.revision)
        _run_submitted(coordinator)

        assert evicted == []

    def test_no_default_cache__converts_without_error(self, tmp_path, monkeypatch):
        db, orch, coordinator = _make_orchestrator(tmp_path, default_cache=None)
        source = tmp_path / "song.flac"
        _make_audio(source, codec="flac")
        track = _add_track(db, source, codec="flac")
        evicted = []
        monkeypatch.setattr(orch.cache, "remove_all_for_uuid", evicted.append)

        job_id = orch.enqueue(track.uuid_id, "aac", 192, track.revision)
        _run_submitted(coordinator)

        assert db.get_conversion_job(job_id)["status"] == "done"
        assert track.uuid_id in evicted


# ── tag bake (real ffmpeg) ──────────────────────────────────────────────────

@requires_ffmpeg
class TestTagBake:
    def test_null_db_column__file_tag_preserved(self, tmp_path):
        db, orch, coordinator = _make_orchestrator(tmp_path)
        source = tmp_path / "song.flac"
        _make_audio(source, codec="flac", track="7", genre="FileGenre")
        track = _add_track(db, source, codec="flac", track_number=None, genre=None)

        orch.enqueue(track.uuid_id, "aac", 192, track.revision)
        _run_submitted(coordinator)

        updated = db.get_track_by_uuid(track.uuid_id)
        probe = _probe(Path(updated.file_path))
        assert (_tag(probe, "track") or "").split("/")[0] == "7"
        assert _tag(probe, "genre") == "FileGenre"

    def test_non_null_db_column__overrides_file_tag(self, tmp_path):
        db, orch, coordinator = _make_orchestrator(tmp_path)
        source = tmp_path / "song.flac"
        _make_audio(source, codec="flac", track="7", genre="FileGenre")
        track = _add_track(db, source, codec="flac", track_number=3, genre="DbGenre")

        orch.enqueue(track.uuid_id, "mp3", 192, track.revision)
        _run_submitted(coordinator)

        updated = db.get_track_by_uuid(track.uuid_id)
        probe = _probe(Path(updated.file_path))
        assert (_tag(probe, "track") or "").split("/")[0] == "3"
        assert _tag(probe, "genre") == "DbGenre"
