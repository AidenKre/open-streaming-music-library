"""7-fix-r0 F0-1: a conversion job's ``error_text`` is read by clients
(``GET /jobs``) and never carries a server path (SC-22 "no paths").
Other-issues row 61: the conversion's log lines carry none either (no path,
no ffmpeg error text, which names files and tags); the job and the codec say
what failed."""

import errno
import inspect
import logging

import pytest

from app.services import file_ops, master_replace
import app.services.conversion as conv_mod
import tests.conversion_fixtures as conv
from app.services.metadata import TagWriteError, write_metadata_tags
from app.services.transcoder import TranscodeResult, transcode
from tests.tool_call_capture import bound_to

# conversion.py's text for a converted master its move could not place.
PLACEMENT_FAILED = "could not place the converted master"

requires_ffmpeg = pytest.mark.requires_ffmpeg


def _assert_pathless(text, tmp_path):
    assert text, "a failed job names a reason"
    assert str(tmp_path) not in text, text
    assert "song." not in text, text  # no file name either


CONVERSION_LOGGER = "app.services.conversion"


def _assert_log_pathless(caplog, tmp_path):
    lines = [r.getMessage() for r in caplog.records if r.name == CONVERSION_LOGGER]
    assert lines, "the failure is logged"
    for line in lines:
        assert str(tmp_path) not in line, line
        assert "song." not in line, line


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
        conv_mod, "transcode", bound_to(transcode)(lambda *a, **k: TranscodeResult(ok=False, stderr=stderr)))

    with caplog.at_level(logging.INFO):
        conv._run_submitted(coordinator)

    job = db.get_conversion_job(job_id)
    assert job["status"] == "failed"
    _assert_pathless(job["error_text"], tmp_path)
    # Row 61: ffmpeg's text names files and tags; it stays in TranscodeResult.stderr.
    assert stderr not in caplog.text
    _assert_log_pathless(caplog, tmp_path)
    assert f"conversion job {job_id}: transcode to aac failed" in [
        r.getMessage() for r in caplog.records if r.name == CONVERSION_LOGGER
    ]


@requires_ffmpeg
def test_a_tag_write_failure_naming_a_path_is_not_stored(tmp_path, monkeypatch):
    db, orch, coordinator, source, job_id = _flac_job(tmp_path)

    @bound_to(write_metadata_tags)
    def failing_writer(src, dest, *a, **k):
        raise TagWriteError(f"ffmpeg exited 1: {dest}: Permission denied")

    monkeypatch.setattr(conv_mod, "write_metadata_tags", failing_writer)

    conv._run_submitted(coordinator)

    job = db.get_conversion_job(job_id)
    assert job["status"] == "failed"
    _assert_pathless(job["error_text"], tmp_path)


@requires_ffmpeg
def test_a_failed_placement_does_not_store_the_destination(tmp_path, monkeypatch, caplog):
    db, orch, coordinator, source, job_id = _flac_job(tmp_path)
    refused = []

    def refuse(*a, **k):
        inspect.signature(file_ops.move_file).bind(*a, **k)  # the real helper's signature
        refused.append(True)
        return False

    monkeypatch.setattr(master_replace, "move_file", refuse)

    with caplog.at_level(logging.INFO):
        conv._run_submitted(coordinator)

    job = db.get_conversion_job(job_id)
    assert job["status"] == "failed"
    assert refused == [True]
    assert job["error_text"] == PLACEMENT_FAILED  # the refused move's own branch
    _assert_pathless(job["error_text"], tmp_path)
    _assert_log_pathless(caplog, tmp_path)
    assert source.exists()


@requires_ffmpeg
def test_a_failed_post_conversion_probe_does_not_store_the_temp_path(tmp_path, monkeypatch, caplog):
    db, orch, coordinator, source, job_id = _flac_job(tmp_path)
    real_probe = conv_mod.ffprobe_for_metadata

    def probe(path, *a, **k):
        return None if ".tagged." in str(path) else real_probe(path, *a, **k)

    monkeypatch.setattr(conv_mod, "ffprobe_for_metadata", probe)

    with caplog.at_level(logging.INFO):
        conv._run_submitted(coordinator)

    job = db.get_conversion_job(job_id)
    assert job["status"] == "failed"
    _assert_pathless(job["error_text"], tmp_path)
    _assert_log_pathless(caplog, tmp_path)


@requires_ffmpeg
def test_an_unexpected_os_error_naming_a_path_is_not_stored(tmp_path, monkeypatch, caplog):
    db, orch, coordinator, source, job_id = _flac_job(tmp_path)

    def boom(*a, **k):
        raise OSError(errno.EACCES, "Permission denied", str(source))

    monkeypatch.setattr(db, "complete_conversion_job", boom)

    with caplog.at_level(logging.INFO):
        conv._run_submitted(coordinator)

    job = db.get_conversion_job(job_id)
    assert job["status"] == "failed"
    _assert_pathless(job["error_text"], tmp_path)
    _assert_log_pathless(caplog, tmp_path)
    assert "conversion job failed: PermissionError" in caplog.text
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


def test_a_target_path_taken_while_the_job_runs_logs_no_path(tmp_path, monkeypatch, caplog):
    db, orch, coordinator = conv._make_orchestrator(tmp_path)
    source = conv._root(tmp_path) / "song.flac"
    source.write_bytes(b"fake")
    track = conv._add_track(db, source, codec="flac")
    job_id = orch.enqueue(conv._lib(orch), track.uuid_id, "mp3", 320, track.revision)
    (conv._root(tmp_path) / "song.mp3").write_bytes(b"someone else")

    with caplog.at_level(logging.INFO):
        conv._run_submitted(coordinator)

    assert db.get_conversion_job(job_id)["status"] == "failed"
    _assert_log_pathless(caplog, tmp_path)
    assert "conversion job failed: TargetPathTaken" in caplog.text
