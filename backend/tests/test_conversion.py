from __future__ import annotations

import json
import os
import sqlite3
import subprocess
import threading
from pathlib import Path

import pytest

from app.core.media_types import CODEC_TO_EXT
from app.library import Library
from tests.conversion_fixtures import (
    _add_track,
    _assert_track_untouched,
    _ffmpeg,
    _lib,
    _make_audio,
    _make_orchestrator,
    _root,
    _run_submitted,
    _staging_files,
)
from tests.crash import Crash
from tests.owned_database import add_test_user
from tests.sqlite_helpers import sql_dicts, sql_exec, sql_rows
from app.database.database import (
    ConversionJobActive,
    Database,
    RevisionConflict,
    TrackNotFound,
)
from app.models.track import Track
from app.models.track_meta_data import TrackMetaData
from app.services import master_replace
from app.services import conversion as conversion_module
from app.services.conversion import (
    TRACK_CHANGED_ERROR,
    InsufficientDiskSpace,
    MasterNotFound,
    NoOpConversion,
    TargetPathTaken,
    reconcile_conversion_jobs,
)
from app.services.storage_ledger import StorageLedger
from app.services.track_editor import reconcile_journal
from app.services.transcoder import TranscodeResult, transcode
from tests.tool_call_capture import bound_to
from tests.track_paths import allow_two_tracks_on_one_path, set_track_path

# Registered marker (plan D16): tests/conftest.py skips without ffmpeg/ffprobe.
requires_ffmpeg = pytest.mark.requires_ffmpeg


# ── fixture builders (real ffmpeg) ──────────────────────────────────────────

def _make_placeholder(path: Path, data: bytes = b"placeholder-not-audio") -> None:
    """Stand-in master for a case that must end before any media read (no ffmpeg)."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)


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

def _second_owner(db: Database) -> int:
    """A user other than the adapter's default owner."""
    with db._connection(commit=True) as conn:
        return conn.execute(
            "INSERT INTO users (username, username_key, password_hash, library_folder, "
            "created_at) VALUES ('other', 'other', 'h', 'other', 0)"
        ).lastrowid


# ── enqueue() validation (no ffmpeg) ────────────────────────────────────────

class TestEnqueueValidation:
    def test_enqueue__unknown_uuid__raises_track_not_found(self, tmp_path):
        _, orch, _ = _make_orchestrator(tmp_path)
        with pytest.raises(TrackNotFound):
            orch.enqueue(_lib(orch), "no-such-uuid", "aac", 192, None)

    def test_enqueue__stale_base_revision__raises_revision_conflict(self, tmp_path):
        db, orch, _ = _make_orchestrator(tmp_path)
        source = _root(tmp_path) / "song.flac"
        source.write_bytes(b"fake")
        track = _add_track(db, source, codec="flac")

        with pytest.raises(RevisionConflict):
            orch.enqueue(_lib(orch), track.uuid_id, "aac", 192, track.revision - 1)

    def test_enqueue__missing_master_file__raises_master_not_found(self, tmp_path):
        db, orch, _ = _make_orchestrator(tmp_path)
        source = _root(tmp_path) / "song.flac"  # never written to disk
        track = _add_track(db, source, codec="flac")

        with pytest.raises(MasterNotFound):
            orch.enqueue(_lib(orch), track.uuid_id, "aac", 192, track.revision)

    def test_enqueue__unsupported_codec__raises_value_error(self, tmp_path):
        db, orch, _ = _make_orchestrator(tmp_path)
        source = _root(tmp_path) / "song.flac"
        source.write_bytes(b"fake")
        track = _add_track(db, source, codec="flac")

        with pytest.raises(ValueError):
            orch.enqueue(_lib(orch), track.uuid_id, "wav", None, track.revision)

    def test_enqueue__codec_unavailable_on_this_build__raises_value_error(self, tmp_path):
        db, orch, _ = _make_orchestrator(tmp_path, available_encoders=frozenset({"aac"}))
        source = _root(tmp_path) / "song.flac"
        source.write_bytes(b"fake")
        track = _add_track(db, source, codec="flac")

        with pytest.raises(ValueError):
            orch.enqueue(_lib(orch), track.uuid_id, "mp3", 192, track.revision)

    def test_enqueue__lossy_target_missing_bitrate__raises_value_error(self, tmp_path):
        db, orch, _ = _make_orchestrator(tmp_path)
        source = _root(tmp_path) / "song.flac"
        source.write_bytes(b"fake")
        track = _add_track(db, source, codec="flac")

        with pytest.raises(ValueError):
            orch.enqueue(_lib(orch), track.uuid_id, "aac", None, track.revision)

    def test_enqueue__lossless_same_codec__raises_no_op_conversion(self, tmp_path):
        db, orch, _ = _make_orchestrator(tmp_path)
        source = _root(tmp_path) / "song.flac"
        source.write_bytes(b"fake")
        track = _add_track(db, source, codec="flac")

        with pytest.raises(NoOpConversion):
            orch.enqueue(_lib(orch), track.uuid_id, "flac", None, track.revision)

    def test_enqueue__lossy_same_codec__allowed_not_blocked(self, tmp_path):
        db, orch, coordinator = _make_orchestrator(tmp_path)
        source = _root(tmp_path) / "song.mp3"
        source.write_bytes(b"fake")
        track = _add_track(db, source, codec="mp3", bitrate_kbps=320.0)

        job_id = orch.enqueue(_lib(orch), track.uuid_id, "mp3", 128, track.revision)

        assert db.get_conversion_job(job_id)["status"] == "queued"
        assert len(coordinator.submitted) == 1

    def test_enqueue__insufficient_disk_space__raises(self, tmp_path, monkeypatch):
        db, orch, _ = _make_orchestrator(tmp_path)
        source = _root(tmp_path) / "song.flac"
        source.write_bytes(b"x" * 1000)
        track = _add_track(db, source, codec="flac")

        class _TinyDisk:
            free = 1

        orch.storage_ledger = StorageLedger(
            db, path=tmp_path, floor_bytes=0, boot_id="test-boot",
            disk_usage=lambda _path: _TinyDisk(),
        )

        with pytest.raises(InsufficientDiskSpace):
            orch.enqueue(_lib(orch), track.uuid_id, "aac", 192, track.revision)

    def test_enqueue__valid__persists_queued_job_and_submits(self, tmp_path):
        db, orch, coordinator = _make_orchestrator(tmp_path)
        source = _root(tmp_path) / "song.flac"
        source.write_bytes(b"fake")
        track = _add_track(db, source, codec="flac")

        job_id = orch.enqueue(_lib(orch), track.uuid_id, "aac", 192, track.revision)

        job = db.get_conversion_job(job_id)
        assert job["status"] == "queued"
        assert job["target_codec"] == "aac"
        assert job["target_container"] == "m4a"
        assert job["target_bitrate"] == 192
        assert job["base_revision"] == track.revision
        assert len(coordinator.submitted) == 1

    def test_enqueue__job_belongs_to_the_tracks_owner(self, tmp_path):
        db, orch, _ = _make_orchestrator(tmp_path)
        source = _root(tmp_path) / "song.flac"
        source.write_bytes(b"fake")
        other = _second_owner(db)
        added = Track(file_path=source, metadata=TrackMetaData(
            codec="flac", duration=0.3, bitrate_kbps=1000.0, sample_rate_hz=44100,
            channels=2, title="T", artist="Art",
        ))
        assert db.add_track(added, owner_id=other)
        track = db.get_track_by_uuid(added.uuid_id, owner_id=other)

        job_id = orch.enqueue(Library(db, other), track.uuid_id, "aac", 192, track.revision)

        assert db.get_conversion_job(job_id, owner_id=other)["owner_id"] == other

    def test_enqueue__job_already_active__raises_conversion_job_active(self, tmp_path):
        db, orch, coordinator = _make_orchestrator(tmp_path)
        source = _root(tmp_path) / "song.flac"
        source.write_bytes(b"fake")
        track = _add_track(db, source, codec="flac")
        first = orch.enqueue(_lib(orch), track.uuid_id, "aac", 192, track.revision)

        with pytest.raises(ConversionJobActive) as exc_info:
            orch.enqueue(_lib(orch), track.uuid_id, "mp3", 320, track.revision)

        assert exc_info.value.job_id == first
        assert len(coordinator.submitted) == 1

    def test_enqueue__target_path_taken__raises_before_persisting(self, tmp_path):
        db, orch, coordinator = _make_orchestrator(tmp_path)
        source = _root(tmp_path) / "Song.mp3"
        source.write_bytes(b"fake")
        (_root(tmp_path) / "Song.m4a").write_bytes(b"someone else")
        track = _add_track(db, source, codec="mp3", bitrate_kbps=320.0)

        with pytest.raises(TargetPathTaken):
            orch.enqueue(_lib(orch), track.uuid_id, "aac", 192, track.revision)

        assert coordinator.submitted == []
        assert db.list_conversion_jobs()[0] == []


# ── cancel() ─────────────────────────────────────────────────────────────────

class TestCancel:
    def test_cancel__queued_job__marks_cancelled_returns_true(self, tmp_path):
        db, orch, _ = _make_orchestrator(tmp_path)
        source = _root(tmp_path) / "song.flac"
        source.write_bytes(b"fake")
        track = _add_track(db, source, codec="flac")
        job_id = orch.enqueue(_lib(orch), track.uuid_id, "aac", 192, track.revision)

        assert orch.cancel(_lib(orch), job_id) is True
        assert db.get_conversion_job(job_id)["status"] == "cancelled"

    def test_cancel__already_terminal__returns_false(self, tmp_path):
        db, orch, _ = _make_orchestrator(tmp_path)
        source = _root(tmp_path) / "song.flac"
        source.write_bytes(b"fake")
        track = _add_track(db, source, codec="flac")
        job_id = orch.enqueue(_lib(orch), track.uuid_id, "aac", 192, track.revision)
        orch.cancel(_lib(orch), job_id)

        assert orch.cancel(_lib(orch), job_id) is False

    def test_cancel__running_job__calls_registry_kill(self, tmp_path, monkeypatch):
        db, orch, coordinator = _make_orchestrator(tmp_path)
        source = _root(tmp_path) / "song.flac"
        source.write_bytes(b"fake")
        track = _add_track(db, source, codec="flac")
        job_id = orch.enqueue(_lib(orch), track.uuid_id, "aac", 192, track.revision)
        db.mark_conversion_job_running(job_id)

        killed = {}
        monkeypatch.setattr(orch._registry, "kill", lambda jid: killed.setdefault("id", jid))

        orch.cancel(_lib(orch), job_id)

        assert killed["id"] == job_id
        assert db.get_conversion_job(job_id)["status"] == "cancelled"


# ── worker pipeline: race safety (no ffmpeg) ────────────────────────────────

class TestWorkerRaceSafety:
    def test_worker__cancel_before_running__noops_leaves_source_untouched(self, tmp_path):
        db, orch, coordinator = _make_orchestrator(tmp_path)
        source = _root(tmp_path) / "song.flac"
        source.write_bytes(b"fake")
        track = _add_track(db, source, codec="flac")
        job_id = orch.enqueue(_lib(orch), track.uuid_id, "aac", 192, track.revision)
        assert orch.cancel(_lib(orch), job_id) is True

        _run_submitted(coordinator)  # simulate the pool finally getting to it

        assert db.get_conversion_job(job_id)["status"] == "cancelled"
        assert source.exists()

    def test_worker__cancel_arrives_mid_run__stays_cancelled_not_failed(self, tmp_path, monkeypatch):
        db, orch, coordinator = _make_orchestrator(tmp_path)
        source = _root(tmp_path) / "song.flac"
        source.write_bytes(b"fake")
        track = _add_track(db, source, codec="flac")
        job_id = orch.enqueue(_lib(orch), track.uuid_id, "aac", 192, track.revision)

        @bound_to(transcode)
        def fake_transcode(src, dest, *args, **kwargs):
            # Simulate a cancel request landing while this step was "running"
            # (the transcode had already produced its temp).
            dest.write_bytes(b"partial-transcode")
            orch.cancel(_lib(orch), job_id)
            return TranscodeResult(ok=True)

        monkeypatch.setattr("app.services.conversion.transcode", fake_transcode)

        _run_submitted(coordinator)

        assert db.get_conversion_job(job_id)["status"] == "cancelled"
        assert _staging_files(tmp_path) == []
        _assert_track_untouched(db, track, source, b"fake")
        assert not (_root(tmp_path) / "song.m4a").exists()
        assert db.list_journal_entries() == []

    def test_worker__transcode_fails__job_marked_failed_with_stderr(self, tmp_path, monkeypatch):
        db, orch, coordinator = _make_orchestrator(tmp_path)
        source = _root(tmp_path) / "song.flac"
        source.write_bytes(b"fake")
        track = _add_track(db, source, codec="flac")
        job_id = orch.enqueue(_lib(orch), track.uuid_id, "aac", 192, track.revision)

        monkeypatch.setattr(
            "app.services.conversion.transcode",
            bound_to(transcode)(lambda *a, **k: TranscodeResult(ok=False, stderr="boom")),
        )

        _run_submitted(coordinator)

        job = db.get_conversion_job(job_id)
        assert job["status"] == "failed"
        # 7-fix-r0 F0-1: ffmpeg stderr names files; it goes to the log only.
        assert job["error_text"] == "transcode failed"
        assert source.exists()  # original untouched

    def test_worker__revision_bumped_between_enqueue_and_run__fails_track_changed(
        self, tmp_path, monkeypatch
    ):
        db, orch, coordinator = _make_orchestrator(tmp_path)
        source = _root(tmp_path) / "song.flac"
        source.write_bytes(b"fake")
        track = _add_track(db, source, codec="flac")
        job_id = orch.enqueue(_lib(orch), track.uuid_id, "aac", 192, track.revision)
        db.apply_track_metadata_edit(track.uuid_id, {"title": "Edited"}, track.revision)
        edited = db.get_track_by_uuid(track.uuid_id)

        transcoded = []
        monkeypatch.setattr(
            "app.services.conversion.transcode",
            bound_to(transcode)(lambda *a, **k: transcoded.append(a) or TranscodeResult(ok=True)),
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
        source = _root(tmp_path) / "Song.mp3"
        source.write_bytes(b"fake")
        track = _add_track(db, source, codec="mp3", bitrate_kbps=320.0)
        job_id = orch.enqueue(_lib(orch), track.uuid_id, "aac", 192, track.revision)
        squatter = _root(tmp_path) / "Song.m4a"
        squatter.write_bytes(b"someone else")
        transcoded = []
        monkeypatch.setattr(
            "app.services.conversion.transcode",
            bound_to(transcode)(lambda *a, **k: transcoded.append(a) or TranscodeResult(ok=True)),
        )

        _run_submitted(coordinator)

        assert db.get_conversion_job(job_id)["status"] == "failed"
        assert transcoded == []
        assert squatter.read_bytes() == b"someone else"
        _assert_track_untouched(db, track, source, b"fake")


class TestRunTimeRefusals:
    """Other-issues row 48 (b): the request refusals that enqueue() answers with
    a named error, raised instead while the job runs (the track or the folder
    changed after the job was queued). These pin today's end state."""

    def test_a_job_whose_track_became_the_same_lossless_codec_fails_without_touching_it(
        self, tmp_path, monkeypatch
    ):
        db, orch, coordinator = _make_orchestrator(tmp_path)
        source = _root(tmp_path) / "song.flac"
        source.write_bytes(b"fake")
        track = _add_track(db, source, codec="flac")
        job_id = orch.enqueue(_lib(orch), track.uuid_id, "alac", None, track.revision)
        with db._connection(commit=True) as conn:  # no revision bump
            conn.execute(
                "UPDATE trackmetadata SET codec = 'alac' WHERE uuid_id = ?", (track.uuid_id,)
            )
        transcoded = []
        monkeypatch.setattr(
            "app.services.conversion.transcode",
            bound_to(transcode)(lambda *a, **k: transcoded.append(a) or TranscodeResult(ok=True)),
        )

        _run_submitted(coordinator)

        job = db.get_conversion_job(job_id)
        assert (job["status"], job["error_text"]) == ("failed", "conversion failed (NoOpConversion)")
        assert transcoded == []
        assert source.read_bytes() == b"fake"
        assert db.list_journal_entries() == []

    def test_a_job_whose_encoder_went_away_fails_with_the_readable_refusal(
        self, tmp_path, monkeypatch
    ):
        """Refactor BE-TIDY row 6: the run-time re-check turns a refused
        request into the job's failure text (ConversionRequestInvalid)."""
        db, orch, coordinator = _make_orchestrator(tmp_path)
        source = _root(tmp_path) / "song.flac"
        source.write_bytes(b"fake")
        track = _add_track(db, source, codec="flac")
        job_id = orch.enqueue(_lib(orch), track.uuid_id, "mp3", 320, track.revision)
        orch.available_encoders = frozenset({"aac"})
        monkeypatch.setattr(
            "app.services.conversion.transcode", bound_to(transcode)(lambda *a, **k: TranscodeResult(ok=True))
        )

        _run_submitted(coordinator)

        job = db.get_conversion_job(job_id)
        assert (job["status"], job["error_text"]) == (
            "failed", "unsupported or unavailable target codec: mp3"
        )
        assert source.read_bytes() == b"fake"

    def test_a_job_whose_target_path_became_taken_fails_with_its_generic_text(
        self, tmp_path, monkeypatch
    ):
        db, orch, coordinator = _make_orchestrator(tmp_path)
        source = _root(tmp_path) / "song.flac"
        source.write_bytes(b"fake")
        track = _add_track(db, source, codec="flac")
        job_id = orch.enqueue(_lib(orch), track.uuid_id, "mp3", 320, track.revision)
        squatter = _root(tmp_path) / "song.mp3"
        squatter.write_bytes(b"someone else")
        monkeypatch.setattr(
            "app.services.conversion.transcode",
            bound_to(transcode)(lambda *a, **k: TranscodeResult(ok=True)),
        )

        _run_submitted(coordinator)

        job = db.get_conversion_job(job_id)
        assert (job["status"], job["error_text"]) == ("failed", "conversion failed (TargetPathTaken)")
        assert squatter.read_bytes() == b"someone else"
        assert source.read_bytes() == b"fake"
        assert db.list_journal_entries() == []
        assert _staging_files(tmp_path) == []


# ── reconcile_conversion_jobs / resume_queued (no ffmpeg) ───────────────────

class TestReconcileConversionJobs:
    def test_reconcile__orphaned_running_job__flipped_to_failed(self, tmp_path):
        db, orch, _ = _make_orchestrator(tmp_path)
        source = _root(tmp_path) / "song.flac"
        source.write_bytes(b"fake")
        track = _add_track(db, source, codec="flac")
        job_id = orch.enqueue(_lib(orch), track.uuid_id, "aac", 192, track.revision)
        db.mark_conversion_job_running(job_id)

        reconcile_conversion_jobs(db, tmp_path / ".staging")

        job = db.get_conversion_job(job_id)
        assert job["status"] == "failed"
        assert job["error_text"] == "interrupted by restart"

    def test_reconcile__queued_and_done_jobs__left_alone(self, tmp_path):
        db, _, _ = _make_orchestrator(tmp_path)
        track_a = _add_track(db, _root(tmp_path) / "a.flac", codec="flac")
        track_b = _add_track(db, _root(tmp_path) / "b.flac", codec="flac")
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
        tracks = [_add_track(db, _root(tmp_path) / f"{n}.flac", codec="flac") for n in "abc"]
        q1 = db.insert_conversion_job(tracks[0].uuid_id, "aac", "m4a", 192,
                                      base_revision=tracks[0].revision)
        q2 = db.insert_conversion_job(tracks[1].uuid_id, "mp3", "mp3", 320,
                                      base_revision=tracks[1].revision)
        running = db.insert_conversion_job(tracks[2].uuid_id, "aac", "m4a", 192)
        db.mark_conversion_job_running(running)

        orch.resume_queued()

        assert [args for _, args, _ in coordinator.submitted] == [(q1,), (q2,)]
        assert all(fn == orch._run_job for fn, _, _ in coordinator.submitted)

    def test_resume_queued__skips_a_user_being_deleted(self, tmp_path):
        """Review r1 m-R1-09: a user left ``deleting`` by a refused boot resume
        gets no conversion written into their half-deleted folder."""
        db, orch, coordinator = _make_orchestrator(tmp_path)
        sam = add_test_user(db, "sam")
        mine = _add_track(db, _root(tmp_path) / "a.flac", codec="flac")
        theirs = Track(file_path=tmp_path / "sam" / "b.flac", metadata=TrackMetaData(
            codec="flac", duration=1.0, title="B", artist="Art"))
        assert db.add_track(theirs, owner_id=sam)
        kept = db.insert_conversion_job(mine.uuid_id, "aac", "m4a", 192)
        Library(db, sam).insert_conversion_job(theirs.uuid_id, "aac", "m4a", 192)
        db.mark_user_deleting(sam, 1)

        orch.resume_queued()

        assert [args for _, args, _ in coordinator.submitted] == [(kept,)]

    def test_resume_queued__resumed_job_runs_and_validates(self, tmp_path, monkeypatch):
        # A queued job resubmitted after a restart re-runs every enqueue check:
        # here its master vanished while the server was down.
        db, orch, coordinator = _make_orchestrator(tmp_path)
        source = _root(tmp_path) / "song.flac"
        track = _add_track(db, source, codec="flac")
        job_id = db.insert_conversion_job(track.uuid_id, "aac", "m4a", 192,
                                          base_revision=track.revision)

        orch.resume_queued()
        _run_submitted(coordinator)

        job = db.get_conversion_job(job_id)
        assert job["status"] == "failed"

    def test_resume_queued__track_revision_moved__fails_track_changed(self, tmp_path):
        db, orch, coordinator = _make_orchestrator(tmp_path)
        source = _root(tmp_path) / "song.flac"
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
        source = _root(tmp_path) / "song.flac"
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
        source = _root(tmp_path) / "song.flac"
        _make_audio(source, codec="flac", title="Original Title")
        track = _add_track(db, source, codec="flac", title="DB Title", artist="DB Artist")

        job_id = orch.enqueue(_lib(orch), track.uuid_id, "aac", 192, track.revision)
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
        source = _root(tmp_path) / "song.flac"
        _make_hires_flac(source)
        track = _add_track(db, source, codec="flac", sample_rate_hz=96000)

        job_id = orch.enqueue(_lib(orch), track.uuid_id, "alac", None, track.revision)
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
        source = _root(tmp_path) / "song.mp3"
        _make_audio(source, codec="mp3")
        track = _add_track(db, source, codec="mp3", bitrate_kbps=192.0)

        job_id = orch.enqueue(_lib(orch), track.uuid_id, "mp3", 128, track.revision)
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
        source = _root(tmp_path) / "song.flac"
        _make_audio(source, codec="flac", title="Stale File Title")
        track = _add_track(db, source, codec="flac", title="Fresh DB Title", artist="DB Artist")

        job_id = orch.enqueue(_lib(orch), track.uuid_id, "aac", 192, track.revision)
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
        source = _root(tmp_path) / "song.flac"
        _make_hires_flac(source, cover=_make_cover(tmp_path / "art" / "cover.jpg"))
        track = _add_track(db, source, codec="flac", sample_rate_hz=96000, has_album_art=True)

        job_id = orch.enqueue(_lib(orch), track.uuid_id, target, bitrate, track.revision)
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
        source = _root(tmp_path) / "song.mp3"
        _make_audio(source, codec="mp3")
        track = _add_track(db, source, codec="mp3", bitrate_kbps=192.0)

        job_id = orch.enqueue(_lib(orch), track.uuid_id, "flac", None, track.revision)
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
        source = _root(tmp_path) / "song.m4a"
        _make_alac_from(hires, source)
        assert int(_audio_stream(_probe(source))["bits_per_raw_sample"]) == 24
        track = _add_track(db, source, codec="alac", sample_rate_hz=96000)

        job_id = orch.enqueue(_lib(orch), track.uuid_id, "flac", None, track.revision)
        _run_submitted(coordinator)

        assert db.get_conversion_job(job_id)["status"] == "done"
        stream = _assert_db_matches_probe(db, track.uuid_id)
        assert stream["codec_name"] == "flac"
        assert int(stream["bits_per_raw_sample"]) == 24
        assert int(stream["sample_rate"]) == 96000

    def test_surround_96k_flac_to_mp3__stores_resampled_downmixed_probed_values(self, tmp_path):
        db, orch, coordinator = _make_orchestrator(tmp_path)
        source = _root(tmp_path) / "song.flac"
        _make_hires_flac(source, layout="5.1")
        assert _audio_stream(_probe(source))["channels"] == 6
        track = _add_track(db, source, codec="flac", sample_rate_hz=96000, channels=6)

        job_id = orch.enqueue(_lib(orch), track.uuid_id, "mp3", 320, track.revision)
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
        source = _root(tmp_path) / "song.wav"
        _make_wav(source, pcm_codec)
        track = _add_track(db, source, codec=pcm_codec, bitrate_kbps=1536.0,
                           sample_rate_hz=48000)

        job_id = orch.enqueue(_lib(orch), track.uuid_id, target, None, track.revision)
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
        source = _root(tmp_path) / "song.wav"
        _make_wav(source, "pcm_s16le")
        track = _add_track(db, source, codec="pcm_s16le", bitrate_kbps=1536.0,
                           sample_rate_hz=48000)

        job_id = orch.enqueue(_lib(orch), track.uuid_id, target, bitrate, track.revision)
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
        source = _root(tmp_path) / "song.mp3"
        _make_mp3_with_jpeg(source, _make_cover(tmp_path / "art" / "cover.jpg"))
        src_pics = _attached_pics(_probe(source))
        assert [p["codec_name"] for p in src_pics] == ["mjpeg"]
        track = _add_track(db, source, codec="mp3", bitrate_kbps=192.0, has_album_art=True)

        job_id = orch.enqueue(_lib(orch), track.uuid_id, target, bitrate, track.revision)
        _run_submitted(coordinator)

        job = db.get_conversion_job(job_id)
        assert job["status"] == "done", job
        updated = db.get_track_by_uuid(track.uuid_id)
        assert Path(updated.file_path) == _root(tmp_path) / f"song.{ext}"
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
        source = _root(tmp_path) / "song.m4a"
        _make_aac_m4a_with_png(source, _make_cover(tmp_path / "art" / "cover.png"))
        src_pics = _attached_pics(_probe(source))
        assert [p["codec_name"] for p in src_pics] == ["png"]
        track = _add_track(db, source, codec="aac", bitrate_kbps=192.0, has_album_art=True)

        job_id = orch.enqueue(_lib(orch), track.uuid_id, target, bitrate, track.revision)
        _run_submitted(coordinator)

        job = db.get_conversion_job(job_id)
        assert job["status"] == "done", job
        updated = db.get_track_by_uuid(track.uuid_id)
        dest = _root(tmp_path) / f"song.{ext}"
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
        source = _root(tmp_path) / "song.flac"
        _make_audio(source, codec="flac")
        track = _add_track(db, source, codec="flac")
        target, bitrate, dest = "aac", 192, _root(tmp_path) / "song.m4a"
    elif case == "mp3_to_mp3":  # same-path branch
        source = _root(tmp_path) / "song.mp3"
        _make_audio(source, codec="mp3")
        track = _add_track(db, source, codec="mp3", bitrate_kbps=192.0)
        target, bitrate, dest = "mp3", 128, source
    elif case == "alac_to_aac":  # same-path branch (.m4a -> .m4a)
        hires = tmp_path / "work" / "hires.flac"
        _make_hires_flac(hires, duration=0.5)
        source = _root(tmp_path) / "song.m4a"
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
        job_id = orch.enqueue(_lib(orch), track.uuid_id, target, bitrate, track.revision)
        real_probe = conversion_module._probe_intrinsic_fields

        def probe_then_cancel(path, target_codec):
            assert orch.cancel(_lib(orch), job_id) is True
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
        job_id = orch.enqueue(_lib(orch), track.uuid_id, target, bitrate, track.revision)
        real_complete = db.complete_conversion_job
        calls = []

        def cancel_then_complete(*args, **kwargs):
            calls.append(kwargs)
            assert orch.cancel(_lib(orch), job_id) is True
            return real_complete(*args, **kwargs)

        monkeypatch.setattr(db, "complete_conversion_job", cancel_then_complete)

        _run_submitted(coordinator)

        assert len(calls) == 1
        self._assert_cancelled_cleanly(tmp_path, db, track, source, dest, original, job_id)

    def test_cancel_after_move_before_commit__path_change_reverted(self, tmp_path, monkeypatch):
        db, orch, coordinator, track, source, dest, original, target, bitrate = (
            _cancel_race_setup(tmp_path, "flac_to_aac")
        )
        job_id = orch.enqueue(_lib(orch), track.uuid_id, target, bitrate, track.revision)
        real_move = master_replace.move_file

        def move_then_cancel(*args, **kwargs):
            moved = real_move(*args, **kwargs)
            assert dest.exists()
            assert orch.cancel(_lib(orch), job_id) is True
            return moved

        monkeypatch.setattr(master_replace, "move_file", move_then_cancel)

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
        source = _root(tmp_path) / "song.flac"
        _make_audio(source, codec="flac")
        track = _add_track(db, source, codec="flac")

        job_a = orch.enqueue(_lib(orch), track.uuid_id, "aac", 256, track.revision)
        fn_a, args_a, kwargs_a = coordinator.submitted[-1]

        real_transcode = conversion_module.transcode
        a_entered = threading.Event()
        release_a = threading.Event()
        dests: dict[int, Path] = {}
        a_wait_timed_out = []

        def gated_transcode(src, dest, *args, **kwargs):
            jid = kwargs["options"].job_id
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
            assert orch.cancel(_lib(orch), job_a) is True

            # Re-POST right away: allowed, A is no longer queued/running.
            pre_b = db.get_track_by_uuid(track.uuid_id)
            job_b = orch.enqueue(_lib(orch), track.uuid_id, "aac", 192, pre_b.revision)
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
        assert Path(updated.file_path) == _root(tmp_path) / "song.m4a"
        assert updated.revision == pre_b.revision + 1
        assert sorted(p.name for p in _root(tmp_path).glob("*.m4a")) == ["song.m4a"]
        assert not source.exists()
        assert _audio_stream(_probe(_root(tmp_path) / "song.m4a"))["codec_name"] == "aac"
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
        source = _root(tmp_path) / "song.mp3"
        _make_audio(source, codec="mp3")
        track = _add_track(db, source, codec="mp3", bitrate_kbps=192.0)
        job_id = orch.enqueue(_lib(orch), track.uuid_id, "mp3", 128, track.revision)
        return db, orch, coordinator, track, source, source.read_bytes(), job_id

    def test_commit_raises__no_journal_row_master_untouched(self, tmp_path, monkeypatch):
        db, orch, coordinator, track, source, original, job_id = self._setup(tmp_path)

        def boom(*args, **kwargs):
            raise sqlite3.OperationalError("disk I/O error")

        monkeypatch.setattr(db, "complete_conversion_job", boom)

        _run_submitted(coordinator)

        job = db.get_conversion_job(job_id)
        assert job["status"] == "failed"
        # 7-fix-r0 F0-1: an unexpected error is stored by type name only.
        assert job["error_text"] == "conversion failed (OperationalError)"
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

        def crash_at_the_tagged_temp(src, dst, *args, **kwargs):
            # The process dies at the swap (a refused swap is another case: it
            # is undone); recovery's later replace goes through.
            if ".tagged." in str(src) and not failed:
                failed.append(src)
                raise Crash()
            return real_replace(src, dst, *args, **kwargs)

        monkeypatch.setattr(conversion_module.os, "replace", crash_at_the_tagged_temp)

        with pytest.raises(Crash):
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


class TestPendingRecovery:
    """A same-path replace that failed in-process and could not be undone
    leaves its journal row + temp for the next startup to finish. Until then a
    new conversion of that track must not run: it would either clobber the
    journal-owned temp or have reconcile later overwrite its result with the
    older one."""

    def _leave_pending_replace(self, tmp_path, monkeypatch):
        db, orch, coordinator, track, source, original, job_id = (
            TestSamePathJournaling()._setup(tmp_path)
        )
        with monkeypatch.context() as m:
            _fail_tagged_replace(m)
            _refuse_undo(m, db)
            _run_submitted(coordinator)
        [entry] = db.list_journal_entries()
        return db, orch, coordinator, track, source, Path(entry["temp_path"])

    @requires_ffmpeg
    def test_enqueue__journal_row_outstanding__raises_pending_recovery(
        self, tmp_path, monkeypatch
    ):
        db, orch, coordinator, track, source, owned_temp = self._leave_pending_replace(
            tmp_path, monkeypatch
        )
        current = db.get_track_by_uuid(track.uuid_id)
        submitted = len(coordinator.submitted)

        with pytest.raises(conversion_module.PendingRecovery):
            orch.enqueue(_lib(orch), track.uuid_id, "mp3", 320, current.revision)

        assert len(coordinator.submitted) == submitted
        assert owned_temp.exists()

    def test_queued_job__journal_row_appears__fails_without_touching_owned_temp(
        self, tmp_path, monkeypatch
    ):
        db, orch, coordinator = _make_orchestrator(tmp_path)
        source = _root(tmp_path) / "song.mp3"
        _make_placeholder(source)
        track = _add_track(db, source, codec="mp3", bitrate_kbps=192.0)
        job_id = orch.enqueue(_lib(orch), track.uuid_id, "mp3", 128, track.revision)
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

    @requires_ffmpeg
    def test_queued_job__a_row_runtime_can_finish_appears__is_settled_and_the_job_converts(
        self, tmp_path
    ):
        """The fence in the job run (sign-off OPEN-6.5-05): a row the running server
        can finish (here an in-place row whose replace already happened) is finished
        under the track lock, and the conversion goes on instead of refusing."""
        db, orch, coordinator = _make_orchestrator(tmp_path)
        source = _root(tmp_path) / "song.flac"
        _make_audio(source)
        track = _add_track(db, source)
        job_id = orch.enqueue(_lib(orch), track.uuid_id, "aac", 192, track.revision)
        db.insert_journal_entry("inplace", track.uuid_id, old_path=str(source))

        _run_submitted(coordinator)

        assert db.get_conversion_job(job_id)["status"] == "done"
        assert db.list_journal_entries() == []
        assert source.with_suffix(".m4a").exists()

    @requires_ffmpeg
    def test_temp_names_are_job_scoped(self, tmp_path, monkeypatch):
        db, orch, coordinator = _make_orchestrator(tmp_path)
        source = _root(tmp_path) / "song.flac"
        _make_audio(source)
        track = _add_track(db, source)
        job_id = orch.enqueue(_lib(orch), track.uuid_id, "aac", 192, track.revision)
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
        source = _root(tmp_path) / "song.flac"
        source.write_bytes(b"x")
        track = _add_track(db, source)
        job_id = orch.enqueue(_lib(orch), track.uuid_id, "aac", 192, track.revision)

        def busy(_job_id, **_kwargs):
            raise sqlite3.OperationalError("database is locked")

        monkeypatch.setattr(db, "mark_conversion_job_running", busy)
        _run_submitted(coordinator)

        job = db.get_conversion_job(job_id)
        assert job["status"] == "failed"
        # 7-fix-r0 F0-1: an unexpected error is stored by type name only.
        assert job["error_text"] == "conversion failed (OperationalError)"
        # No longer "active": the track can be converted again.
        assert orch.enqueue(_lib(orch), track.uuid_id, "aac", 192, track.revision) != job_id

    @pytest.mark.integration
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

    @pytest.mark.integration
    def test_shutdown__a_conversion_that_starts_its_ffmpeg_afterwards_is_killed(
        self, tmp_path, monkeypatch
    ):
        """U06-B-01: a running job between two ffmpeg steps when the server
        stops has nothing registered to kill; the process it starts afterwards
        is killed on arrival instead of outliving the server."""
        from app.services.ffmpeg_runner import FfmpegError, run_ffmpeg

        db, orch, coordinator = _make_orchestrator(tmp_path)
        source = _root(tmp_path) / "song.mp3"
        source.write_bytes(b"x")
        track = _add_track(db, source, codec="mp3", bitrate_kbps=320.0)
        job_id = orch.enqueue(_lib(orch), track.uuid_id, "aac", 192, track.revision)
        errors: list[str] = []

        @bound_to(transcode)
        def transcode_starting_a_process(src, dest, *args, options, **kwargs):
            # The stop arrives while the job runs but has no process; then the
            # real transcode's step: one ffmpeg process run through the job's
            # registry (a sleep stands in for ffmpeg).
            orch.shutdown()
            try:
                run_ffmpeg(["sleep", "30"], dest, timeout=5, options=options)
            except FfmpegError as e:
                errors.append(str(e))
            return TranscodeResult(ok=False)

        monkeypatch.setattr(conversion_module, "transcode", transcode_starting_a_process)
        _run_submitted(coordinator)

        # Killed on arrival (SIGKILL), not ended by run_ffmpeg's own timeout.
        assert len(errors) == 1 and errors[0].startswith("ffmpeg exited -9"), errors
        assert db.get_conversion_job(job_id)["status"] == "failed"
        assert source.read_bytes() == b"x"

    def test_shutdown__a_queued_job_taken_afterwards_stays_queued(self, tmp_path, monkeypatch):
        """U06-B-01 (review r1): a queued job a pool thread takes after the
        stop does not start (it would only be killed and stored as failed);
        it stays queued, and the next start resumes it."""
        db, orch, coordinator = _make_orchestrator(tmp_path)
        source = _root(tmp_path) / "song.mp3"
        source.write_bytes(b"x")
        track = _add_track(db, source, codec="mp3", bitrate_kbps=320.0)
        job_id = orch.enqueue(_lib(orch), track.uuid_id, "aac", 192, track.revision)
        started: list[Path] = []

        @bound_to(transcode)
        def transcode_spy(src, dest, *args, **kwargs):
            started.append(dest)
            return TranscodeResult(ok=False)

        monkeypatch.setattr(conversion_module, "transcode", transcode_spy)
        orch.shutdown()
        _run_submitted(coordinator)

        assert started == []
        assert db.get_conversion_job(job_id)["status"] == "queued"
        assert source.read_bytes() == b"x"


# ── path-change crash windows (real ffmpeg) ─────────────────────────────────


@requires_ffmpeg
class TestPathChangeCrashWindows:
    """At each crash point, startup's reconcile_journal is run against the
    exact on-disk + DB state the crash would leave (inside the hook, before
    any in-process cleanup can run), and the resulting state is recorded."""

    def _setup(self, tmp_path):
        db, orch, coordinator = _make_orchestrator(tmp_path)
        source = _root(tmp_path) / "song.flac"
        _make_audio(source, codec="flac")
        track = _add_track(db, source, codec="flac")
        job_id = orch.enqueue(_lib(orch), track.uuid_id, "aac", 192, track.revision)
        return db, orch, coordinator, track, source, _root(tmp_path) / "song.m4a", job_id

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
            raise Crash()

        monkeypatch.setattr(master_replace, "move_file", crash_before_move)

        with pytest.raises(Crash):
            _run_submitted(coordinator)

        self._assert_reverted(snap, track, source, original)
        reconcile_conversion_jobs(db, tmp_path / ".staging")
        assert db.get_conversion_job(job_id)["status"] == "failed"
        assert _staging_files(tmp_path) == []

    def test_crash_after_move_before_commit__new_copy_dropped(self, tmp_path, monkeypatch):
        db, orch, coordinator, track, source, dest, job_id = self._setup(tmp_path)
        original = source.read_bytes()
        real_move = master_replace.move_file
        snap = {}

        def move_then_crash(*args, **kwargs):
            assert real_move(*args, **kwargs)
            assert dest.exists()
            reconcile_journal(db, tmp_path)
            snap.update(self._snapshot(db, track, source, dest))
            raise Crash()

        monkeypatch.setattr(master_replace, "move_file", move_then_crash)

        with pytest.raises(Crash):
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
            raise Crash()

        monkeypatch.setattr(db, "complete_conversion_job", commit_then_crash)

        with pytest.raises(Crash):
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
        source = _root(tmp_path) / "song.flac"
        _make_audio(source, codec="flac")
        track = _add_track(db, source, codec="flac")
        original = source.read_bytes()
        job_id = orch.enqueue(_lib(orch), track.uuid_id, "aac", 192, track.revision)
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
        assert not (_root(tmp_path) / "song.m4a").exists()
        assert db.list_journal_entries() == []
        assert _staging_files(tmp_path) == []


# ── case handling (real ffmpeg) ─────────────────────────────────────────────

@requires_ffmpeg
class TestExtensionCase:
    def test_uppercase_mp3_reencode__converts(self, tmp_path):
        db, orch, coordinator = _make_orchestrator(tmp_path)
        source = _root(tmp_path) / "Song.MP3"
        _make_audio(source, codec="mp3")
        track = _add_track(db, source, codec="mp3", bitrate_kbps=192.0)

        job_id = orch.enqueue(_lib(orch), track.uuid_id, "mp3", 128, track.revision)
        _run_submitted(coordinator)

        assert db.get_conversion_job(job_id)["status"] == "done"
        updated = db.get_track_by_uuid(track.uuid_id)
        if _is_case_insensitive_fs(tmp_path):
            assert str(updated.file_path) == str(source)  # replaced in place
        audio = [p for p in _root(tmp_path).iterdir() if p.suffix.lower() == ".mp3"]
        assert len(audio) == 1  # never two copies of the master
        stream = _audio_stream(_probe(Path(updated.file_path)))
        assert int(stream["bit_rate"]) / 1000 == pytest.approx(128, abs=8)
        assert db.list_journal_entries() == []

    def test_uppercase_m4a_alac_to_aac__same_path_on_case_insensitive_fs(self, tmp_path):
        db, orch, coordinator = _make_orchestrator(tmp_path)
        hires = tmp_path / "work" / "hires.flac"
        _make_hires_flac(hires, duration=0.5)
        source = _root(tmp_path) / "Song.M4A"
        _make_alac_from(hires, source)
        track = _add_track(db, source, codec="alac", sample_rate_hz=96000)
        case_insensitive = _is_case_insensitive_fs(tmp_path)

        job_id = orch.enqueue(_lib(orch), track.uuid_id, "aac", 192, track.revision)
        _run_submitted(coordinator)

        assert db.get_conversion_job(job_id)["status"] == "done"
        updated = db.get_track_by_uuid(track.uuid_id)
        if case_insensitive:
            assert str(updated.file_path) == str(source)
        else:
            assert str(updated.file_path) == str(_root(tmp_path) / "Song.m4a")
            assert not source.exists()
        m4as = [p for p in _root(tmp_path).iterdir() if p.suffix.lower() == ".m4a"]
        assert len(m4as) == 1
        assert _audio_stream(_probe(Path(updated.file_path)))["codec_name"] == "aac"
        assert db.list_journal_entries() == []
        assert _staging_files(tmp_path) == []


# ── Phase M: per-user roots and path containment (real ffmpeg) ──────────────

class TestOwnerRootContainment:
    def _spy_transcode(self, monkeypatch):
        calls = []

        @bound_to(transcode)
        def spy(*a, **k):
            calls.append(a)
            return TranscodeResult(ok=False, stderr="must not run")

        monkeypatch.setattr(conversion_module, "transcode", spy)
        return calls

    def _assert_refused(self, tmp_path, db, orch, track, job_id, master, original, calls):
        job = db.get_conversion_job(job_id)
        assert job["status"] == "failed"
        # 7-fix-r0 F0-1: the refusal is stored without either path.
        assert "outside" in job["error_text"], job["error_text"]
        assert str(tmp_path) not in job["error_text"]
        assert calls == []  # never reached the encoder
        assert master.read_bytes() == original
        after = db.get_track_by_uuid(track.uuid_id)
        assert after.revision == track.revision
        assert str(after.file_path) == str(track.file_path)
        assert after.metadata.codec == track.metadata.codec
        assert _staging_files(tmp_path) == []
        assert db.list_journal_entries() == []
        assert list(_root(tmp_path).iterdir()) == [] or all(
            p.is_symlink() for p in _root(tmp_path).iterdir()
        )

    def test_relocate_of_master_in_another_users_folder_is_refused(
        self, tmp_path, monkeypatch
    ):
        db, orch, coordinator = _make_orchestrator(tmp_path)
        source = tmp_path / "sam" / "Art" / "x.flac"
        _make_placeholder(source)
        track = _add_track(db, source, codec="flac")
        original = source.read_bytes()
        job_id = orch.enqueue(_lib(orch), track.uuid_id, "aac", 192, track.revision)
        calls = self._spy_transcode(monkeypatch)

        _run_submitted(coordinator)

        self._assert_refused(tmp_path, db, orch, track, job_id, source, original, calls)
        assert not (tmp_path / "sam" / "Art" / "x.m4a").exists()

    def test_inplace_conversion_of_master_resolving_outside_root_is_refused(
        self, tmp_path, monkeypatch
    ):
        db, orch, coordinator = _make_orchestrator(tmp_path)
        outside = tmp_path / "outside"
        _make_placeholder(outside / "x.m4a")
        (_root(tmp_path) / "Art").symlink_to(outside, target_is_directory=True)
        source = _root(tmp_path) / "Art" / "x.m4a"
        track = _add_track(db, source, codec="aac", bitrate_kbps=192.0)
        original = (outside / "x.m4a").read_bytes()
        job_id = orch.enqueue(_lib(orch), track.uuid_id, "aac", 128, track.revision)
        calls = self._spy_transcode(monkeypatch)

        _run_submitted(coordinator)

        self._assert_refused(
            tmp_path, db, orch, track, job_id, outside / "x.m4a", original, calls
        )
        assert sorted(p.name for p in outside.iterdir()) == ["x.m4a"]

    @requires_ffmpeg
    def test_second_users_relocate_conversion_lands_under_their_root(self, tmp_path):
        db, orch, coordinator = _make_orchestrator(tmp_path)
        sam = add_test_user(db, "sam")
        source = tmp_path / "sam" / "Art" / "x.flac"
        _make_audio(source, codec="flac")
        track = Track(file_path=source, metadata=TrackMetaData(
            codec="flac", duration=0.3, bitrate_kbps=1000.0, sample_rate_hz=44100,
            channels=2, title="T", artist="Art"))
        assert db.add_track(track, owner_id=sam)
        revision = db.get_track_by_uuid(track.uuid_id, owner_id=sam).revision
        lib = Library(db, sam, root=tmp_path / "sam")

        job_id = orch.enqueue(lib, track.uuid_id, "aac", 192, revision)
        _run_submitted(coordinator)

        assert db.get_conversion_job(job_id, owner_id=sam)["status"] == "done"
        new_path = tmp_path / "sam" / "Art" / "x.m4a"
        assert new_path.exists()
        assert not source.exists()
        updated = db.get_track_by_uuid(track.uuid_id, owner_id=sam)
        assert str(updated.file_path) == str(new_path)
        assert updated.metadata.codec == "aac"
        assert list(_root(tmp_path).iterdir()) == []
        assert _staging_files(tmp_path) == []


# ── cache eviction (real ffmpeg) ────────────────────────────────────────────

class TestCacheEviction:
    @requires_ffmpeg
    def test_successful_conversion__evicts_both_caches(self, tmp_path, monkeypatch):
        db, orch, coordinator = _make_orchestrator(tmp_path)
        source = _root(tmp_path) / "song.flac"
        _make_audio(source, codec="flac")
        track = _add_track(db, source, codec="flac")
        evicted = {"cache": [], "default": []}
        monkeypatch.setattr(orch.cache, "remove_all_for_uuid", evicted["cache"].append)
        monkeypatch.setattr(orch.default_cache, "remove_all_for_uuid", evicted["default"].append)

        job_id = orch.enqueue(_lib(orch), track.uuid_id, "aac", 192, track.revision)
        _run_submitted(coordinator)

        assert db.get_conversion_job(job_id)["status"] == "done"
        assert track.uuid_id in evicted["cache"]
        assert track.uuid_id in evicted["default"]

    def test_failed_conversion__does_not_evict(self, tmp_path, monkeypatch):
        db, orch, coordinator = _make_orchestrator(tmp_path)
        source = _root(tmp_path) / "song.flac"
        _make_placeholder(source)
        track = _add_track(db, source, codec="flac")
        # Both caches the orchestrator evicts through (evict_track_caches).
        evicted = {"cache": [], "default": []}
        monkeypatch.setattr(orch.cache, "remove_all_for_uuid", evicted["cache"].append)
        monkeypatch.setattr(orch.default_cache, "remove_all_for_uuid", evicted["default"].append)
        monkeypatch.setattr(
            "app.services.conversion.transcode",
            bound_to(transcode)(lambda *a, **k: TranscodeResult(ok=False, stderr="boom")),
        )

        job_id = orch.enqueue(_lib(orch), track.uuid_id, "aac", 192, track.revision)
        _run_submitted(coordinator)

        job = db.get_conversion_job(job_id)
        assert (job["status"], job["error_text"]) == ("failed", "transcode failed")
        assert evicted == {"cache": [], "default": []}

    @requires_ffmpeg
    def test_no_default_cache__converts_without_error(self, tmp_path, monkeypatch):
        db, orch, coordinator = _make_orchestrator(tmp_path, default_cache=None)
        source = _root(tmp_path) / "song.flac"
        _make_audio(source, codec="flac")
        track = _add_track(db, source, codec="flac")
        evicted = []
        monkeypatch.setattr(orch.cache, "remove_all_for_uuid", evicted.append)

        job_id = orch.enqueue(_lib(orch), track.uuid_id, "aac", 192, track.revision)
        _run_submitted(coordinator)

        assert db.get_conversion_job(job_id)["status"] == "done"
        assert track.uuid_id in evicted


# ── tag bake (real ffmpeg) ──────────────────────────────────────────────────

@requires_ffmpeg
class TestTagBake:
    def test_null_db_column__file_tag_preserved(self, tmp_path):
        db, orch, coordinator = _make_orchestrator(tmp_path)
        source = _root(tmp_path) / "song.flac"
        _make_audio(source, codec="flac", track="7", genre="FileGenre")
        track = _add_track(db, source, codec="flac", track_number=None, genre=None)

        orch.enqueue(_lib(orch), track.uuid_id, "aac", 192, track.revision)
        _run_submitted(coordinator)

        updated = db.get_track_by_uuid(track.uuid_id)
        probe = _probe(Path(updated.file_path))
        assert (_tag(probe, "track") or "").split("/")[0] == "7"
        assert _tag(probe, "genre") == "FileGenre"

    def test_non_null_db_column__overrides_file_tag(self, tmp_path):
        db, orch, coordinator = _make_orchestrator(tmp_path)
        source = _root(tmp_path) / "song.flac"
        _make_audio(source, codec="flac", track="7", genre="FileGenre")
        track = _add_track(db, source, codec="flac", track_number=3, genre="DbGenre")

        orch.enqueue(_lib(orch), track.uuid_id, "mp3", 192, track.revision)
        _run_submitted(coordinator)

        updated = db.get_track_by_uuid(track.uuid_id)
        probe = _probe(Path(updated.file_path))
        assert (_tag(probe, "track") or "").split("/")[0] == "3"
        assert _tag(probe, "genre") == "DbGenre"


# ── U06-B-06: a same-file conversion whose final swap is refused ────────────
#
# The owner (2026-11-18): "just make the conversion fail and say to convert
# again". One attempt. A refused swap is undone in one transaction: the catalog
# row reads as before the conversion (at a new revision), the journal row and the
# staged copy go, and the job fails with a sentence that says so. Only when that
# undo cannot be made does the state stay what a crash at that instant leaves:
# the job is failed with the sentence that says the next start finishes it, its
# journal row and staged file are kept, the running server does not put the file
# in place (Phase 6.5's rule stands), and the next start puts it in place, bumps
# the track's revision and marks the job done, or ends it failed with a true
# sentence when the swap can never happen.

SWAP_REFUSED_TEXT = (
    "The converted file could not replace the original, so the original was kept. "
    "Convert it again."
)
SWAP_PENDING_TEXT = (
    "The converted file could not replace the original. The server finishes it at its next start."
)
SWAP_LOST_TEXT = "The converted file was lost, so the original was kept. Convert it again."
# Existing wording until the owner's sentence (bug-fix-common: neutral existing text).
SWAP_UNPROVEN_TEXT = "could not place the converted master"


def _fail_tagged_replace(monkeypatch, times=1, *, after=False):
    """``os.replace`` of a staged converted file raises ``times`` times, then
    works. ``after``: the rename happens and the error is reported all the same."""
    real_replace = os.replace
    failures = []

    def replace(src, dst, *args, **kwargs):
        if ".tagged." in str(src) and len(failures) < times:
            failures.append(Path(src))
            if after:
                real_replace(src, dst, *args, **kwargs)
            raise OSError("simulated rename failure")
        return real_replace(src, dst, *args, **kwargs)

    monkeypatch.setattr(conversion_module.os, "replace", replace)
    return failures


def _refuse_undo(monkeypatch, db):
    """The database refuses the transaction that takes the conversion back."""
    def busy(*args, **kwargs):
        raise sqlite3.OperationalError("database is locked")

    monkeypatch.setattr(db, "undo_inplace_conversion", busy)


def _catalog_row(db, uuid_id):
    """Every stored column of the track but its revision and change time."""
    [track] = sql_dicts(db, "SELECT * FROM tracks WHERE uuid_id = ?", (uuid_id,))
    [meta] = sql_dicts(db, "SELECT * FROM trackmetadata WHERE uuid_id = ?", (uuid_id,))
    for name in ("revision", "last_updated"):
        track.pop(name)
    return track, meta


def _start(db, tmp_path):
    """The next start's recovery, in main.py's order."""
    reconcile_journal(db, tmp_path)
    reconcile_conversion_jobs(db, tmp_path / ".staging")


@pytest.mark.requires_ffmpeg
class TestSameFileSwapRefused:
    def _setup(self, tmp_path):
        db, orch, coordinator, track, source, original, job_id = (
            TestSamePathJournaling()._setup(tmp_path)
        )
        return db, orch, coordinator, track, source, original, job_id

    def _not_undone(self, tmp_path, monkeypatch):
        """The swap was refused and the undo's transaction too: the row and the
        staged copy are kept, as after a crash at that instant."""
        db, orch, coordinator, track, source, original, job_id = self._setup(tmp_path)
        with monkeypatch.context() as m:  # the faults end with the job
            failures = _fail_tagged_replace(m)
            _refuse_undo(m, db)
            _run_submitted(coordinator)
        assert len(failures) == 1
        [entry] = db.list_journal_entries()
        return db, orch, track, source, original, job_id, entry

    def test_a_refused_swap_fails_the_job_and_keeps_the_original(self, tmp_path, monkeypatch):
        db, orch, coordinator, track, source, original, job_id = self._setup(tmp_path)
        before = _catalog_row(db, track.uuid_id)
        seen = []
        real_undo = db.undo_inplace_conversion

        def undo(*args, **kwargs):
            # What a client that syncs in this instant reads: the committed row.
            seen.append(db.get_track_by_uuid(track.uuid_id))
            return real_undo(*args, **kwargs)

        monkeypatch.setattr(db, "undo_inplace_conversion", undo)
        failures = _fail_tagged_replace(monkeypatch)

        _run_submitted(coordinator)

        assert len(failures) == 1  # one attempt, no retry
        job = db.get_conversion_job(job_id)
        assert (job["status"], job["error_text"]) == ("failed", SWAP_REFUSED_TEXT)
        assert source.read_bytes() == original
        assert _catalog_row(db, track.uuid_id) == before
        assert db.list_journal_entries() == [] and _staging_files(tmp_path) == []
        assert sql_rows(db, "SELECT COUNT(*) FROM storage_reservations") == [(0,)]
        # A client that read the committed row reads the track again.
        [committed] = seen
        assert committed.metadata.bitrate_kbps == pytest.approx(128, abs=8)
        assert track.revision < committed.revision < db.get_track_by_uuid(track.uuid_id).revision

    def test_after_a_refused_swap_the_next_start_changes_nothing(self, tmp_path, monkeypatch):
        db, orch, coordinator, track, source, original, job_id = self._setup(tmp_path)
        with monkeypatch.context() as m:
            _fail_tagged_replace(m)
            _run_submitted(coordinator)
        undone = db.get_track_by_uuid(track.uuid_id)

        _start(db, tmp_path)

        assert source.read_bytes() == original
        assert db.get_track_by_uuid(track.uuid_id) == undone
        job = db.get_conversion_job(job_id)
        assert (job["status"], job["error_text"]) == ("failed", SWAP_REFUSED_TEXT)

    def test_after_a_refused_swap_the_track_is_edited_and_converted_again(
        self, tmp_path, monkeypatch
    ):
        """"Convert it again." is true: nothing of the failed job is in the way."""
        from app.services.track_edit import WriteMode
        from app.services.track_editor import TrackEditor

        db, orch, coordinator, track, source, original, job_id = self._setup(tmp_path)
        with monkeypatch.context() as m:
            _fail_tagged_replace(m)
            _run_submitted(coordinator)

        current = db.get_track_by_uuid(track.uuid_id)
        revision, _ = TrackEditor(tmp_path, tmp_path / ".staging").apply_edit(
            _lib(orch), track.uuid_id, {"title": "Edited"}, current.revision,
            WriteMode.db_and_master,
        )
        again = orch.enqueue(_lib(orch), track.uuid_id, "mp3", 128, revision)
        _run_submitted(coordinator)

        job = db.get_conversion_job(again)
        assert (job["status"], job["error_text"]) == ("done", None)
        assert db.get_track_by_uuid(track.uuid_id).metadata.bitrate_kbps == pytest.approx(128, abs=8)
        assert db.list_journal_entries() == [] and _staging_files(tmp_path) == []

    def test_a_refused_swap_leaves_the_identity_marked_for_a_new_hash(self, tmp_path, monkeypatch):
        """The undo does not put the old digest back as current (it restores no
        identity): the worker hashes the unchanged file again."""
        db, orch, coordinator, track, source, original, job_id = self._setup(tmp_path)
        sql_exec(
            db, "UPDATE track_audio_identity SET exact_state = 'current', "
            "exact_kind = 'packets_sha256', exact_digest = 'old', match_state = 'current' "
            "WHERE uuid_id = ?", (track.uuid_id,))
        generation = db.get_audio_identity(track.uuid_id, owner_id=db.owner_id)["generation"]
        notified = []
        orch.identity_signal = type("Signal", (), {"notify": lambda self: notified.append(
            db.list_journal_entries())})()
        _fail_tagged_replace(monkeypatch)

        _run_submitted(coordinator)

        row = db.get_audio_identity(track.uuid_id, owner_id=db.owner_id)
        assert (row["exact_state"], row["exact_digest"], row["match_state"]) == (
            "pending", None, "pending")
        assert row["generation"] > generation
        assert notified == [[]]  # woken once, after the journal row went (the worker skips a journaled track)

    def test_a_refused_swap_that_cannot_be_undone_fails_the_job_until_the_next_start(
        self, tmp_path, monkeypatch
    ):
        from app.services.track_edit import WriteMode
        from app.services.track_editor import MasterWriteError, TrackEditor

        db, orch, track, source, original, job_id, entry = self._not_undone(
            tmp_path, monkeypatch)

        job = db.get_conversion_job(job_id)
        assert (job["status"], job["error_text"]) == ("failed", SWAP_PENDING_TEXT)
        assert entry["intent"] == "convert" and Path(entry["temp_path"]).is_file()
        assert source.read_bytes() == original
        current = db.get_track_by_uuid(track.uuid_id)
        # Like any kept row: the track's edits and conversions wait for it.
        with pytest.raises(MasterWriteError):
            TrackEditor(tmp_path, tmp_path / ".staging").apply_edit(
                _lib(orch), track.uuid_id, {"title": "Edited"}, current.revision,
                WriteMode.db_and_master,
            )
        with pytest.raises(conversion_module.PendingRecovery):
            orch.enqueue(_lib(orch), track.uuid_id, "mp3", 128, current.revision)

    def test_an_undo_that_answers_nothing_was_undone_keeps_the_row_and_the_staged_copy(
        self, tmp_path, monkeypatch
    ):
        """Review (errors and ownership) finding 2: "nothing was undone" (None) is
        treated like a refused undo, not like an undo."""
        db, orch, coordinator, track, source, original, job_id = self._setup(tmp_path)
        with monkeypatch.context() as m:
            _fail_tagged_replace(m)
            m.setattr(db, "undo_inplace_conversion", lambda *args, **kwargs: None)
            _run_submitted(coordinator)

        job = db.get_conversion_job(job_id)
        assert (job["status"], job["error_text"]) == ("failed", SWAP_PENDING_TEXT)
        [entry] = db.list_journal_entries()
        staged = Path(entry["temp_path"]).read_bytes()
        assert source.read_bytes() == original

        _start(db, tmp_path)

        job = db.get_conversion_job(job_id)
        assert (job["status"], job["error_text"]) == ("done", None)
        assert source.read_bytes() == staged

    def test_a_swap_that_reports_an_error_after_it_happened_is_not_undone(
        self, tmp_path, monkeypatch
    ):
        """The staged copy is gone, so the rename may have happened: nothing is
        taken back, and the next start reads the file and says done."""
        db, orch, coordinator, track, source, original, job_id = self._setup(tmp_path)
        with monkeypatch.context() as m:
            _fail_tagged_replace(m, after=True)
            _run_submitted(coordinator)

        job = db.get_conversion_job(job_id)
        assert (job["status"], job["error_text"]) == ("failed", SWAP_PENDING_TEXT)
        assert source.read_bytes() != original
        assert len(db.list_journal_entries()) == 1
        assert db.get_track_by_uuid(track.uuid_id).metadata.bitrate_kbps == pytest.approx(128, abs=8)

        _start(db, tmp_path)

        job = db.get_conversion_job(job_id)
        assert (job["status"], job["error_text"]) == ("done", None)
        assert source.read_bytes() != original
        assert db.list_journal_entries() == []

    def test_the_running_server_never_puts_the_file_in_place(self, tmp_path, monkeypatch):
        """Phase 6.5's rule stands: the idle pass leaves the row to the next start,
        also when its staged file has gone missing meanwhile."""
        from app.services.track_editor import finish_kept_journal_rows

        db, orch, track, source, original, job_id, entry = self._not_undone(
            tmp_path, monkeypatch)
        committed = db.get_track_by_uuid(track.uuid_id)

        assert finish_kept_journal_rows(db, tmp_path, orch.track_locks) == 0
        Path(entry["temp_path"]).unlink()
        assert finish_kept_journal_rows(db, tmp_path, orch.track_locks) == 0

        assert source.read_bytes() == original
        assert len(db.list_journal_entries()) == 1
        job = db.get_conversion_job(job_id)
        assert (job["status"], job["error_text"]) == ("failed", SWAP_PENDING_TEXT)
        assert db.get_track_by_uuid(track.uuid_id).revision == committed.revision

    def test_the_next_start_puts_it_in_place_bumps_the_revision_and_marks_it_done(
        self, tmp_path, monkeypatch
    ):
        db, orch, track, source, original, job_id, entry = self._not_undone(
            tmp_path, monkeypatch)
        staged = Path(entry["temp_path"]).read_bytes()
        committed = db.get_track_by_uuid(track.uuid_id)

        _start(db, tmp_path)

        assert source.read_bytes() == staged
        job = db.get_conversion_job(job_id)
        assert (job["status"], job["error_text"]) == ("done", None)
        assert db.list_journal_entries() == [] and _staging_files(tmp_path) == []
        # Finding 10: apps learn that the audio changed.
        assert db.get_track_by_uuid(track.uuid_id).revision > committed.revision

    def test_a_lost_staged_file_ends_the_job_failed_with_the_database_back_in_line(
        self, tmp_path, monkeypatch
    ):
        db, orch, track, source, original, job_id, entry = self._not_undone(
            tmp_path, monkeypatch)
        Path(entry["temp_path"]).unlink()  # deleted outside the app
        committed = db.get_track_by_uuid(track.uuid_id)
        assert committed.metadata.bitrate_kbps == pytest.approx(128, abs=8)

        _start(db, tmp_path)

        assert source.read_bytes() == original
        job = db.get_conversion_job(job_id)
        assert (job["status"], job["error_text"]) == ("failed", SWAP_LOST_TEXT)
        after = db.get_track_by_uuid(track.uuid_id)
        assert after.metadata.bitrate_kbps == pytest.approx(192, abs=8)  # the file's own
        assert after.revision > committed.revision
        assert db.list_journal_entries() == []

    def test_another_track_at_the_path_ends_the_job_failed_and_keeps_it(
        self, tmp_path, monkeypatch
    ):
        db, orch, track, source, original, job_id, entry = self._not_undone(
            tmp_path, monkeypatch)
        source.unlink()  # A's master vanished outside the app; an import placed B there
        source.write_bytes(b"track B's only copy")
        # Two rows naming one file: the state the unique index now refuses.
        allow_two_tracks_on_one_path(db)
        _add_track(db, source, codec="mp3", bitrate_kbps=192.0, title="B")

        _start(db, tmp_path)

        assert source.read_bytes() == b"track B's only copy"
        job = db.get_conversion_job(job_id)
        assert (job["status"], job["error_text"]) == ("failed", SWAP_UNPROVEN_TEXT)
        assert Path(entry["temp_path"]).is_file()  # kept as evidence
        assert len(db.list_journal_entries()) == 1

    def test_a_track_that_moved_on_ends_the_job_failed(self, tmp_path, monkeypatch):
        db, orch, track, source, original, job_id, entry = self._not_undone(
            tmp_path, monkeypatch)
        other = source.with_name("other.mp3")
        other.write_bytes(original)
        set_track_path(db, track.uuid_id, other)

        _start(db, tmp_path)

        # Phase 8's startup settle (OPEN-6.5-05, rule b): the old path's copy has the
        # track's own audio, so it is removed as redundant; the track's file stays.
        assert other.read_bytes() == original
        assert not source.exists() or source.read_bytes() == original
        job = db.get_conversion_job(job_id)
        assert (job["status"], job["error_text"]) == ("failed", TRACK_CHANGED_ERROR)
        assert db.list_journal_entries() == []

    @pytest.mark.parametrize("crash_at", ["replace", "undo", "failed_mark", "after_failed"])
    def test_a_crash_before_the_undo_ends_like_a_crash_before_the_swap(
        self, tmp_path, monkeypatch, crash_at
    ):
        """A crash at the swap itself (between the commit and the rename), after
        the refused swap and before its undo, or on the way of an undo that was
        refused: the next start puts the converted file in place, and the job is
        done."""
        db, orch, coordinator, track, source, original, job_id = self._setup(tmp_path)

        def crash(*args, **kwargs):
            raise Crash()

        with monkeypatch.context() as m:  # the faults end with the crashed process
            if crash_at == "replace":
                real_replace = os.replace
                m.setattr(conversion_module.os, "replace", lambda src, dst, *a, **k: (
                    crash() if ".tagged." in str(src) else real_replace(src, dst, *a, **k)))
            else:
                _fail_tagged_replace(m)
                if crash_at == "undo":
                    m.setattr(db, "undo_inplace_conversion", crash)
                else:
                    _refuse_undo(m, db)
            if crash_at == "failed_mark":
                m.setattr(db, "mark_conversion_job_failed", crash)
            if crash_at == "after_failed":
                _run_submitted(coordinator)
            else:
                with pytest.raises(Crash):
                    _run_submitted(coordinator)
        [entry] = db.list_journal_entries()
        staged = Path(entry["temp_path"]).read_bytes()
        committed = db.get_track_by_uuid(track.uuid_id)
        assert source.read_bytes() == original

        _start(db, tmp_path)

        assert source.read_bytes() == staged
        job = db.get_conversion_job(job_id)
        assert (job["status"], job["error_text"]) == ("done", None)
        assert db.list_journal_entries() == [] and _staging_files(tmp_path) == []
        assert db.get_track_by_uuid(track.uuid_id).revision > committed.revision

    @pytest.mark.parametrize("crash_at", ["flush", "unlink"])
    def test_a_crash_after_the_undo_ends_undone_at_the_next_start(
        self, tmp_path, monkeypatch, crash_at
    ):
        """The undo committed and the process died before the staged copy went:
        the next start removes the copy nobody owns and changes nothing else."""
        db, orch, coordinator, track, source, original, job_id = self._setup(tmp_path)
        before = _catalog_row(db, track.uuid_id)

        def crash(*args, **kwargs):
            raise Crash()

        with monkeypatch.context() as m:
            _fail_tagged_replace(m)
            if crash_at == "flush":
                real_flush, calls = db.make_durable, []
                m.setattr(db, "make_durable", lambda *a, **k: (
                    crash() if calls else (calls.append(1), real_flush(*a, **k))[1]))
            else:
                real_unlink = Path.unlink
                m.setattr(Path, "unlink", lambda self, *a, **k: (
                    crash() if ".tagged." in self.name and self.exists()
                    else real_unlink(self, *a, **k)))
            with pytest.raises(Crash):
                _run_submitted(coordinator)
        assert len(_staging_files(tmp_path)) == 1 and db.list_journal_entries() == []

        _start(db, tmp_path)

        assert source.read_bytes() == original
        assert _catalog_row(db, track.uuid_id) == before
        job = db.get_conversion_job(job_id)
        assert (job["status"], job["error_text"]) == ("failed", SWAP_REFUSED_TEXT)
        assert _staging_files(tmp_path) == []

    def test_a_staged_copy_that_cannot_be_removed_waits_for_the_next_start(
        self, tmp_path, monkeypatch
    ):
        db, orch, coordinator, track, source, original, job_id = self._setup(tmp_path)
        before = _catalog_row(db, track.uuid_id)
        real_unlink = Path.unlink

        def unlink(self, *args, **kwargs):
            if ".tagged." in self.name and self.exists():
                raise OSError(13, "Permission denied")
            return real_unlink(self, *args, **kwargs)

        with monkeypatch.context() as m:
            _fail_tagged_replace(m)
            m.setattr(Path, "unlink", unlink)
            _run_submitted(coordinator)

        job = db.get_conversion_job(job_id)
        assert (job["status"], job["error_text"]) == ("failed", SWAP_REFUSED_TEXT)
        assert _catalog_row(db, track.uuid_id) == before and db.list_journal_entries() == []
        assert sql_rows(db, "SELECT COUNT(*) FROM storage_reservations") == [(0,)]
        assert len(_staging_files(tmp_path)) == 1

        _start(db, tmp_path)

        assert _staging_files(tmp_path) == [] and source.read_bytes() == original

    def test_no_sequence_of_requests_converts_the_track_twice(self, tmp_path, monkeypatch):
        """While the row exists a Retry is refused; after the next start finished the
        swap, a Retry of the same target is refused because the track already has
        that format. The track was transcoded exactly once."""
        db, orch, coordinator, track, source, original, job_id = self._setup(tmp_path)
        transcodes = []
        real_transcode = conversion_module.transcode
        monkeypatch.setattr(conversion_module, "transcode",
                            lambda *a, **k: transcodes.append(1) or real_transcode(*a, **k))
        with monkeypatch.context() as m:
            _fail_tagged_replace(m)
            _refuse_undo(m, db)
            _run_submitted(coordinator)
        submitted = len(coordinator.submitted)

        current = db.get_track_by_uuid(track.uuid_id)
        with pytest.raises(conversion_module.PendingRecovery):
            orch.enqueue(_lib(orch), track.uuid_id, "mp3", 128, current.revision)
        _start(db, tmp_path)
        current = db.get_track_by_uuid(track.uuid_id)
        with pytest.raises(ValueError, match="already in this format"):
            orch.enqueue(_lib(orch), track.uuid_id, "mp3", 128, current.revision)

        assert len(coordinator.submitted) == submitted
        assert transcodes == [1]
        assert db.get_conversion_job(job_id)["status"] == "done"


@pytest.mark.requires_ffmpeg
class TestSameFileSwapStartupRecheck:
    """Review of the retry-only branch, findings 1 to 3: the next start ends in a
    true state also after a crash between its own writes, a track that moved on
    after its staged file was lost, or a master that is gone."""

    def _not_undone(self, tmp_path, monkeypatch):
        return TestSameFileSwapRefused()._not_undone(tmp_path, monkeypatch)

    def test_a_crash_after_the_lost_refresh_still_ends_lost(self, tmp_path, monkeypatch):
        db, orch, track, source, original, job_id, entry = self._not_undone(
            tmp_path, monkeypatch)
        Path(entry["temp_path"]).unlink()

        def crash(*args, **kwargs):
            raise Crash()

        with monkeypatch.context() as m:
            m.setattr(db, "delete_journal_entry", crash)
            with pytest.raises(Crash):
                reconcile_journal(db, tmp_path)
        assert len(db.list_journal_entries()) == 1  # refreshed, settled, row kept

        _start(db, tmp_path)

        assert source.read_bytes() == original
        job = db.get_conversion_job(job_id)
        assert (job["status"], job["error_text"]) == ("failed", SWAP_LOST_TEXT)
        assert db.list_journal_entries() == []

    def test_a_lost_staged_file_of_a_track_that_moved_on_ends_track_changed(
        self, tmp_path, monkeypatch
    ):
        db, orch, track, source, original, job_id, entry = self._not_undone(
            tmp_path, monkeypatch)
        Path(entry["temp_path"]).unlink()
        other = source.with_name("other.mp3")
        other.write_bytes(original)
        set_track_path(db, track.uuid_id, other)

        _start(db, tmp_path)

        job = db.get_conversion_job(job_id)
        assert (job["status"], job["error_text"]) == ("failed", TRACK_CHANGED_ERROR)
        assert db.list_journal_entries() == []
        # Phase 8's startup settle (OPEN-6.5-05, rule b): the old path's copy has the
        # track's own audio, so it is removed as redundant; the track's file stays.
        assert other.read_bytes() == original
        assert not source.exists() or source.read_bytes() == original

    def test_a_lost_staged_file_and_a_missing_master_end_the_job(self, tmp_path, monkeypatch):
        db, orch, track, source, original, job_id, entry = self._not_undone(
            tmp_path, monkeypatch)
        Path(entry["temp_path"]).unlink()
        source.unlink()

        _start(db, tmp_path)

        job = db.get_conversion_job(job_id)
        assert (job["status"], job["error_text"]) == ("failed", SWAP_UNPROVEN_TEXT)
        # Phase 8's startup settle (OPEN-6.5-05): a row with no copy and no track
        # file goes (on Phase 7 it is kept); the job's sentence is the same.
        assert db.list_journal_entries() == []


@pytest.mark.requires_ffmpeg
class TestSameFileSwapPhase8:
    """Phase 8's startup settles journal rows through ``journal_settle``; its
    deletion answers busy while a journal row exists."""

    def _not_undone(self, tmp_path, monkeypatch):
        return TestSameFileSwapRefused()._not_undone(tmp_path, monkeypatch)

    def test_a_deletion_of_the_track_is_busy_while_the_row_is_kept(self, tmp_path, monkeypatch):
        db, orch, track, source, original, job_id, entry = self._not_undone(
            tmp_path, monkeypatch)

        assert db.read_deletion_target(track.uuid_id, owner_id=db.owner_id)["busy"] is True

        _start(db, tmp_path)
        assert db.read_deletion_target(track.uuid_id, owner_id=db.owner_id)["busy"] is False

    def test_a_staged_copy_that_is_no_regular_file_ends_lost_with_the_old_columns(
        self, tmp_path, monkeypatch
    ):
        """D9: the replace never happened; the track is read again from its file."""
        db, orch, track, source, original, job_id, entry = self._not_undone(
            tmp_path, monkeypatch)
        staged = Path(entry["temp_path"])
        elsewhere = staged.with_name("elsewhere.mp3")
        elsewhere.write_bytes(staged.read_bytes())
        staged.unlink()
        staged.symlink_to(elsewhere)
        committed = db.get_track_by_uuid(track.uuid_id)

        _start(db, tmp_path)

        assert source.read_bytes() == original
        job = db.get_conversion_job(job_id)
        assert (job["status"], job["error_text"]) == ("failed", SWAP_LOST_TEXT)
        after = db.get_track_by_uuid(track.uuid_id)
        assert after.metadata.bitrate_kbps == pytest.approx(192, abs=8)
        assert after.revision > committed.revision

    @pytest.mark.parametrize("case", ["at_its_own_path", "recorded_elsewhere"])
    def test_a_missing_track_file_gets_the_converted_copy_and_ends_done(
        self, tmp_path, monkeypatch, case
    ):
        """At its own path the copy is put in place (the redo); recorded elsewhere,
        the converted copy is adopted as the track's file."""
        db, orch, track, source, original, job_id, entry = self._not_undone(
            tmp_path, monkeypatch)
        converted = Path(entry["temp_path"]).read_bytes()
        if case == "at_its_own_path":
            source.unlink()
        else:
            set_track_path(db, track.uuid_id, source.with_name("moved.mp3"))

        _start(db, tmp_path)

        job = db.get_conversion_job(job_id)
        assert (job["status"], job["error_text"]) == ("done", None)
        after = db.get_track_by_uuid(track.uuid_id)
        assert Path(after.file_path).read_bytes() == converted
        assert db.list_journal_entries() == []


@pytest.mark.requires_ffmpeg
class TestSameFileSwapPhase8Recheck:
    """Review of the Phase 8 cascade, findings 1 and 2."""

    def _not_undone(self, tmp_path, monkeypatch):
        return TestSameFileSwapRefused()._not_undone(tmp_path, monkeypatch)

    @pytest.mark.parametrize("crash_at", ["settle_swapped_conversion_job", "delete_journal_entry"])
    def test_a_stop_after_adopting_the_converted_copy_still_ends_done(
        self, tmp_path, monkeypatch, crash_at
    ):
        """The adopted copy is the track's file: a rerun never calls that "moved on"."""
        db, orch, track, source, original, job_id, entry = self._not_undone(
            tmp_path, monkeypatch)
        converted = Path(entry["temp_path"]).read_bytes()
        set_track_path(db, track.uuid_id, source.with_name("moved.mp3"))

        def crash(*args, **kwargs):
            raise Crash()

        with monkeypatch.context() as m:
            m.setattr(db, crash_at, crash)
            with pytest.raises(Crash):
                reconcile_journal(db, tmp_path)
        _start(db, tmp_path)

        job = db.get_conversion_job(job_id)
        assert (job["status"], job["error_text"]) == ("done", None)
        assert Path(db.get_track_by_uuid(track.uuid_id).file_path).read_bytes() == converted
        assert db.list_journal_entries() == []

    def test_an_unreadable_master_with_a_lost_staged_file_ends_the_job(
        self, tmp_path, monkeypatch
    ):
        """ffprobe refuses the file for good: D9 (the columns become unknown), the job
        ends and the row goes, so the track is not busy for good."""
        db, orch, track, source, original, job_id, entry = self._not_undone(
            tmp_path, monkeypatch)
        Path(entry["temp_path"]).unlink()
        source.write_bytes(b"not audio at all")

        _start(db, tmp_path)

        job = db.get_conversion_job(job_id)
        assert (job["status"], job["error_text"]) == ("failed", SWAP_UNPROVEN_TEXT)
        assert db.list_journal_entries() == []
        assert db.get_track_by_uuid(track.uuid_id).metadata.codec is None
        assert db.read_deletion_target(track.uuid_id, owner_id=db.owner_id)["busy"] is False


class TestAlreadyInTheTargetFormat:
    """A conversion to the format the track already has is refused: lossless by the
    existing same-codec rule, lossy (same codec, the same preset) by U06-B-06's."""

    def _track(self, tmp_path, codec, bitrate):
        db, orch, _ = _make_orchestrator(tmp_path)
        ext = {"mp3": "mp3", "aac": "m4a", "flac": "flac", "alac": "m4a"}[codec]
        source = _root(tmp_path) / f"song.{ext}"
        source.write_bytes(b"x")
        return db, orch, _add_track(db, source, codec=codec, bitrate_kbps=bitrate)

    @pytest.mark.parametrize("codec, bitrate, target, target_bitrate", [
        ("mp3", 128.0, "mp3", 128), ("mp3", 131.4, "mp3", 128), ("aac", 256.0, "aac", 256),
        # Review finding 6: ffmpeg's AAC can land far below its preset (256k -> 193.8).
        ("aac", 193.8, "aac", 256),
        ("mp3", 128.0, "mp3", 320),   # a higher bitrate of the same lossy codec gains nothing
    ])
    def test_a_lossy_track_already_at_the_target_is_refused(
        self, tmp_path, codec, bitrate, target, target_bitrate
    ):
        db, orch, track = self._track(tmp_path, codec, bitrate)
        with pytest.raises(ValueError, match="already in this format"):
            orch.enqueue(_lib(orch), track.uuid_id, target, target_bitrate, track.revision)

    @pytest.mark.parametrize("codec, target", [("flac", "flac"), ("alac", "alac")])
    def test_a_lossless_track_already_at_the_target_is_refused(self, tmp_path, codec, target):
        db, orch, track = self._track(tmp_path, codec, 1000.0)
        with pytest.raises(NoOpConversion):
            orch.enqueue(_lib(orch), track.uuid_id, target, None, track.revision)

    @pytest.mark.parametrize("codec, bitrate, target, target_bitrate", [
        ("mp3", 320.0, "mp3", 128),   # a real change of bitrate
        ("mp3", None, "mp3", 128),    # unknown bitrate: not known to be the same
        ("aac", 256.0, "mp3", 256),   # another codec
    ])
    def test_other_lossy_requests_are_accepted(
        self, tmp_path, codec, bitrate, target, target_bitrate
    ):
        db, orch, track = self._track(tmp_path, codec, bitrate)
        assert orch.enqueue(_lib(orch), track.uuid_id, target, target_bitrate, track.revision)


class TestSwapJobTransitions:
    """The job and track writes of U06-B-06, for the job's owner only."""

    def _job(self, tmp_path, status):
        db, orch, _ = _make_orchestrator(tmp_path)
        source = _root(tmp_path) / "song.mp3"
        source.write_bytes(b"x")
        track = _add_track(db, source, codec="mp3", bitrate_kbps=320.0)
        job_id = orch.enqueue(_lib(orch), track.uuid_id, "aac", 192, track.revision)
        sql_exec(db, "UPDATE conversion_jobs SET status = ?, error_text = 'why' WHERE id = ?",
             (status, job_id))
        return db, orch, track, job_id

    @pytest.mark.parametrize("status, moved", [
        ("done", True), ("queued", False), ("running", False), ("cancelled", False),
        ("failed", False),
    ])
    def test_failed_after_commit_moves_only_a_done_job(self, tmp_path, status, moved):
        db, orch, track, job_id = self._job(tmp_path, status)

        assert db.mark_conversion_job_failed(job_id, "the reason", after_commit=True) is moved

        job = db.get_conversion_job(job_id)
        assert (job["status"], job["error_text"]) == (
            ("failed", "the reason") if moved else (status, "why"))

    @pytest.mark.parametrize("status, moved", [
        ("failed", True), ("done", True), ("queued", False), ("running", False),
        ("cancelled", False),
    ])
    @pytest.mark.parametrize("outcome", ["done", "failed"])
    def test_settle_moves_only_a_failed_or_done_job_of_that_track(
        self, tmp_path, status, moved, outcome
    ):
        db, orch, track, job_id = self._job(tmp_path, status)
        text = None if outcome == "done" else "the final reason"

        assert db.settle_swapped_conversion_job(job_id, "another-track", error_text=text) is False
        assert db.settle_swapped_conversion_job(job_id, track.uuid_id, error_text=text) is moved

        job = db.get_conversion_job(job_id)
        assert (job["status"], job["error_text"]) == ((outcome, text) if moved else (status, "why"))

    def test_bump_track_revision_advances_the_revision(self, tmp_path):
        db, orch, track, job_id = self._job(tmp_path, "done")
        revision = db.get_track_by_uuid(track.uuid_id).revision

        assert db.bump_track_revision(track.uuid_id) == revision + 1
        assert db.get_track_by_uuid(track.uuid_id).revision == revision + 1

    def _committed(self, tmp_path):
        """A same-file conversion as its commit leaves it: the job done, the
        catalog row describing the converted audio, the journal row written."""
        db, orch, _ = _make_orchestrator(tmp_path)
        source = _root(tmp_path) / "song.mp3"
        source.write_bytes(b"x")
        track = _add_track(db, source, codec="mp3", bitrate_kbps=320.0)
        before = _catalog_row(db, track.uuid_id)
        job_id = orch.enqueue(_lib(orch), track.uuid_id, "mp3", 128, track.revision)
        assert db.mark_conversion_job_running(job_id)
        revision, journal_id = db.complete_conversion_job(
            job_id, track.uuid_id, "mp3", 128.0, 22050, 1,
            inplace_journal=(str(source), str(tmp_path / ".staging" / "x.tagged.mp3")),
        )
        assert _catalog_row(db, track.uuid_id) != before
        return db, track, job_id, journal_id, revision, before

    @staticmethod
    def _undo(db, uuid_id, job_id, journal_id, **owner):
        before = dict(codec="mp3", bitrate_kbps=320.0, sample_rate_hz=44100, channels=2)
        if owner:  # another owner's call, past the test adapter's default
            return Database.undo_inplace_conversion(
                db, job_id, uuid_id, journal_id, "the reason", **before, **owner)
        return db.undo_inplace_conversion(job_id, uuid_id, journal_id, "the reason", **before)

    @staticmethod
    def _state(db, uuid_id, job_id):
        job = db.get_conversion_job(job_id)
        return (
            _catalog_row(db, uuid_id), db.get_track_by_uuid(uuid_id).revision,
            len(sql_rows(db, "SELECT id FROM edit_journal")), (job["status"], job["error_text"]),
        )

    def test_the_undo_puts_the_row_back_removes_the_journal_row_and_fails_the_job(self, tmp_path):
        db, track, job_id, journal_id, revision, before = self._committed(tmp_path)

        assert self._undo(db, track.uuid_id, job_id, journal_id) == revision + 1

        assert self._state(db, track.uuid_id, job_id) == (
            before, revision + 1, 0, ("failed", "the reason"))

    @pytest.mark.parametrize("status", ["queued", "running", "failed", "cancelled"])
    def test_the_undo_moves_only_a_done_job(self, tmp_path, status):
        db, track, job_id, journal_id, revision, before = self._committed(tmp_path)
        sql_exec(db, "UPDATE conversion_jobs SET status = ?, error_text = 'why' WHERE id = ?",
                 (status, job_id))
        committed = self._state(db, track.uuid_id, job_id)

        assert self._undo(db, track.uuid_id, job_id, journal_id) is None

        assert self._state(db, track.uuid_id, job_id) == committed

    @pytest.mark.parametrize("case", [
        "row_gone", "another_row", "another_track",
        # Review (errors and ownership) finding 1: a row that exists but is not
        # this conversion's own is never deleted in its place.
        "another_tracks_row", "another_owners_row", "not_a_convert_row",
    ])
    def test_the_undo_needs_the_conversions_own_journal_row(self, tmp_path, case):
        db, track, job_id, journal_id, revision, before = self._committed(tmp_path)
        uuid_id = track.uuid_id
        if case == "row_gone":
            db.delete_journal_entry(journal_id)
        elif case == "another_row":
            journal_id += 1
        elif case == "another_track":
            uuid_id = "another-track"
        elif case == "not_a_convert_row":
            journal_id = db.insert_journal_entry(
                "inplace", track.uuid_id, old_path=str(track.file_path), temp_path="edit")
        else:
            owner = db.owner_id if case == "another_tracks_row" else _second_owner(db)
            other = _root(tmp_path) / "other.mp3"
            other.write_bytes(b"y")
            added = Track(file_path=other, metadata=TrackMetaData(
                codec="mp3", duration=0.3, bitrate_kbps=320.0, sample_rate_hz=44100,
                channels=2, title="Other", artist="Art",
            ))
            assert db.add_track(added, owner_id=owner)
            journal_id = db.insert_journal_entry(
                "convert", added.uuid_id, old_path=str(other), temp_path="staged",
                owner_id=owner)
        committed = self._state(db, track.uuid_id, job_id)

        assert self._undo(db, uuid_id, job_id, journal_id) is None

        assert self._state(db, track.uuid_id, job_id) == committed

    def test_an_undo_that_fails_halfway_changes_nothing(self, tmp_path):
        db, track, job_id, journal_id, revision, before = self._committed(tmp_path)
        committed = self._state(db, track.uuid_id, job_id)
        sql_exec(db, "CREATE TRIGGER refuse_failed BEFORE UPDATE OF status ON conversion_jobs "
                     "BEGIN SELECT RAISE(ABORT, 'refused'); END")

        with pytest.raises(sqlite3.IntegrityError):
            self._undo(db, track.uuid_id, job_id, journal_id)

        assert self._state(db, track.uuid_id, job_id) == committed

    def test_another_owner_can_undo_nothing(self, tmp_path):
        db, track, job_id, journal_id, revision, before = self._committed(tmp_path)
        committed = self._state(db, track.uuid_id, job_id)

        assert self._undo(
            db, track.uuid_id, job_id, journal_id, owner_id=_second_owner(db)) is None

        assert self._state(db, track.uuid_id, job_id) == committed

    def test_another_owner_can_move_nothing(self, tmp_path):
        db, orch, track, job_id = self._job(tmp_path, "done")
        other = _second_owner(db)
        revision = db.get_track_by_uuid(track.uuid_id).revision

        assert Database.mark_conversion_job_failed(
            db, job_id, "x", owner_id=other, after_commit=True) is False
        assert Database.settle_swapped_conversion_job(
            db, job_id, track.uuid_id, owner_id=other) is False
        assert Database.bump_track_revision(db, track.uuid_id, owner_id=other) is None
        assert db.get_conversion_job(job_id)["status"] == "done"
        assert db.get_track_by_uuid(track.uuid_id).revision == revision


def test_start_up_and_the_job_use_the_same_track_changed_text():
    """Pre-merge D1-02: the start-up copy of the sentence (not imported, to avoid
    an import cycle) must stay the job's own."""
    from app.services import journal_recovery

    assert journal_recovery.TRACK_CHANGED_TEXT == conversion_module.TRACK_CHANGED_ERROR
