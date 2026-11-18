"""7-fix-r0 F0-1: a conversion job's ``error_text`` is read by clients
(``GET /jobs``) and never carries a server path (SC-22 "no paths"). The server
log keeps the detail."""

import errno
import logging

import pytest

import app.services.conversion as conv_mod
import tests.test_conversion as conv
from app.services.metadata import TagWriteError
from app.services.transcoder import TranscodeResult

requires_ffmpeg = pytest.mark.requires_ffmpeg


def _assert_pathless(text, tmp_path):
    assert text, "a failed job names a reason"
    assert str(tmp_path) not in text, text
    assert "song." not in text, text  # no file name either


def _flac_job(tmp_path):
    db, orch, coordinator = conv._make_orchestrator(tmp_path)
    source = conv._root(tmp_path) / "song.flac"
    conv._make_audio(source, codec="flac")
    track = conv._add_track(db, source, codec="flac")
    job_id = orch.enqueue(conv._lib(orch), track.uuid_id, "aac", 192, track.revision)
    return db, orch, coordinator, source, job_id


@requires_ffmpeg
def test_ffmpeg_stderr_naming_the_source_is_not_stored(tmp_path, monkeypatch, caplog):
    db, orch, coordinator, source, job_id = _flac_job(tmp_path)
    stderr = f"{source}: Invalid data found when processing input"
    monkeypatch.setattr(
        conv_mod, "transcode", lambda *a, **k: TranscodeResult(ok=False, stderr=stderr))

    with caplog.at_level(logging.INFO):
        conv._run_submitted(coordinator)

    job = db.get_conversion_job(job_id)
    assert job["status"] == "failed"
    _assert_pathless(job["error_text"], tmp_path)
    assert stderr in caplog.text  # the operator still sees it


@requires_ffmpeg
def test_a_tag_write_failure_naming_a_path_is_not_stored(tmp_path, monkeypatch):
    db, orch, coordinator, source, job_id = _flac_job(tmp_path)

    def failing_writer(src, dest, *a, **k):
        raise TagWriteError(f"ffmpeg exited 1: {dest}: Permission denied")

    monkeypatch.setattr(conv_mod, "write_metadata_tags", failing_writer)

    conv._run_submitted(coordinator)

    job = db.get_conversion_job(job_id)
    assert job["status"] == "failed"
    _assert_pathless(job["error_text"], tmp_path)


@requires_ffmpeg
def test_a_failed_placement_does_not_store_the_destination(tmp_path, monkeypatch):
    db, orch, coordinator, source, job_id = _flac_job(tmp_path)
    monkeypatch.setattr(conv_mod, "move_file", lambda **k: False)

    conv._run_submitted(coordinator)

    job = db.get_conversion_job(job_id)
    assert job["status"] == "failed"
    _assert_pathless(job["error_text"], tmp_path)
    assert source.exists()


@requires_ffmpeg
def test_a_failed_post_conversion_probe_does_not_store_the_temp_path(tmp_path, monkeypatch):
    db, orch, coordinator, source, job_id = _flac_job(tmp_path)
    real_probe = conv_mod.ffprobe_for_metadata

    def probe(path, *a, **k):
        return None if ".tagged." in str(path) else real_probe(path, *a, **k)

    monkeypatch.setattr(conv_mod, "ffprobe_for_metadata", probe)

    conv._run_submitted(coordinator)

    job = db.get_conversion_job(job_id)
    assert job["status"] == "failed"
    _assert_pathless(job["error_text"], tmp_path)


@requires_ffmpeg
def test_an_unexpected_os_error_naming_a_path_is_not_stored(tmp_path, monkeypatch):
    db, orch, coordinator, source, job_id = _flac_job(tmp_path)

    def boom(*a, **k):
        raise OSError(errno.EACCES, "Permission denied", str(source))

    monkeypatch.setattr(db, "complete_conversion_job", boom)

    conv._run_submitted(coordinator)

    job = db.get_conversion_job(job_id)
    assert job["status"] == "failed"
    _assert_pathless(job["error_text"], tmp_path)
    assert source.exists()


def test_a_master_outside_its_owners_root_is_refused_without_paths(tmp_path):
    db, orch, coordinator = conv._make_orchestrator(tmp_path)
    outside = tmp_path / "elsewhere" / "song.flac"
    outside.parent.mkdir()
    outside.write_bytes(b"x")
    track = conv._add_track(db, outside, codec="flac")
    job_id = orch.enqueue(conv._lib(orch), track.uuid_id, "aac", 192, track.revision)

    conv._run_submitted(coordinator)

    job = db.get_conversion_job(job_id)
    assert job["status"] == "failed"
    _assert_pathless(job["error_text"], tmp_path)
