"""BE-TOOLS (reviewer note of BE-TIDY part 2): the runner's error says what
happened without a path or tool output, and the log lines that name a tool
error say it.

``FfmpegError.category``: "not found", "could not start", "timed out",
"killed", "exit <code>", "no output" (``run_ffmpeg``: exit 0 and an empty or
missing output file), "too much output" (``run_capture``). The error's message
and ``stderr`` are unchanged (callers map them as before); ffmpeg's text never
reaches a log line.
"""

from __future__ import annotations

import logging
import subprocess
import threading
import time

import pytest

from app.services import audio_identity, transcoder
from app.services.ffmpeg_runner import (
    CaptureOverflow,
    CaptureTimeout,
    FfmpegError,
    FfmpegProcessRegistry,
    ToolOptions,
    run_capture,
    run_ffmpeg,
)

pytestmark = pytest.mark.integration


def _category(error):
    return getattr(error, "category", None)


def _no_exec(tmp_path):
    tool = tmp_path / "tool"
    tool.write_text("#!/bin/sh\n")
    tool.chmod(0o644)  # exists, cannot be executed: Popen raises PermissionError
    return str(tool)


# --- run_ffmpeg --------------------------------------------------------------------------


def test_run_ffmpeg_tool_not_found(tmp_path):
    with pytest.raises(FfmpegError) as caught:
        run_ffmpeg([str(tmp_path / "missing-tool")], tmp_path / "out", timeout=10)
    assert (str(caught.value), _category(caught.value)) == ("ffmpeg not found", "not found")


def test_run_ffmpeg_tool_that_cannot_start(tmp_path):
    with pytest.raises(FfmpegError) as caught:
        run_ffmpeg([_no_exec(tmp_path)], tmp_path / "out", timeout=10)
    assert _category(caught.value) == "could not start"


def test_run_ffmpeg_non_zero_exit_names_its_code(tmp_path):
    with pytest.raises(FfmpegError) as caught:
        run_ffmpeg(["sh", "-c", "echo 'secret /a/b.flac' >&2; exit 3"], tmp_path / "out", timeout=10)
    assert _category(caught.value) == "exit 3"
    assert caught.value.stderr == "secret /a/b.flac"  # kept for the caller, as before


def test_run_ffmpeg_exit_zero_without_output(tmp_path):
    with pytest.raises(FfmpegError) as caught:
        run_ffmpeg(["sh", "-c", "true"], tmp_path / "out", timeout=10)
    assert _category(caught.value) == "no output"


def test_run_ffmpeg_time_out(tmp_path, monkeypatch):
    class TimingOut(subprocess.Popen):
        def communicate(self, *args, timeout=None, **kwargs):
            if timeout is not None:
                raise subprocess.TimeoutExpired(self.args, timeout)
            return super().communicate(*args, **kwargs)

    monkeypatch.setattr("app.services.ffmpeg_runner.subprocess.Popen", TimingOut)
    with pytest.raises(FfmpegError) as caught:
        run_ffmpeg(["sleep", "30"], tmp_path / "out", timeout=10)
    assert _category(caught.value) == "timed out"


def test_run_ffmpeg_killed_by_a_stop(tmp_path):
    registry = FfmpegProcessRegistry()
    outcome = {}

    def run():
        try:
            run_ffmpeg(["sleep", "30"], tmp_path / "out", timeout=60,
                options=ToolOptions(registry=registry, job_id="j"))
        except FfmpegError as e:
            outcome["error"] = e

    worker = threading.Thread(target=run, daemon=True)
    worker.start()
    deadline = time.monotonic() + 5
    while "j" not in registry._procs and time.monotonic() < deadline:
        time.sleep(0.01)
    assert registry.kill("j")
    worker.join(timeout=10)
    assert _category(outcome["error"]) == "killed"


# --- run_capture -------------------------------------------------------------------------


def test_run_capture_tool_not_found(tmp_path):
    with pytest.raises(FfmpegError) as caught:
        run_capture([str(tmp_path / "missing-tool")], timeout_s=10, max_stdout_bytes=64)
    assert _category(caught.value) == "not found"


def test_run_capture_tool_not_found_at_low_priority(tmp_path):
    with pytest.raises(FfmpegError) as caught:
        run_capture([str(tmp_path / "missing-tool")], timeout_s=10, max_stdout_bytes=64,
            options=ToolOptions(low_priority=True))
    assert _category(caught.value) == "not found"


def test_run_capture_tool_that_cannot_start(tmp_path):
    with pytest.raises(FfmpegError) as caught:
        run_capture([_no_exec(tmp_path)], timeout_s=10, max_stdout_bytes=64)
    assert _category(caught.value) == "could not start"


def test_run_capture_time_out():
    with pytest.raises(CaptureTimeout) as caught:
        run_capture(["sleep", "30"], timeout_s=0.2, max_stdout_bytes=64)
    assert _category(caught.value) == "timed out"


def test_run_capture_too_much_output():
    with pytest.raises(CaptureOverflow) as caught:
        run_capture(["sh", "-c", "printf 0123456789"], timeout_s=10, max_stdout_bytes=4)
    assert _category(caught.value) == "too much output"


# --- the log lines -----------------------------------------------------------------------


@pytest.mark.requires_ffmpeg
def test_a_failed_transcode_logs_the_category_not_the_path(tmp_path, monkeypatch, caplog):
    monkeypatch.setattr(transcoder, "_failures_warned", set())
    source = tmp_path / "Secret Artist" / "Secret Song.flac"
    source.parent.mkdir()
    source.write_bytes(b"not audio")

    with caplog.at_level(logging.DEBUG, logger="app.services.transcoder"):
        result = transcoder.transcode(source, tmp_path / "out.m4a", "aac", 128)

    assert not result.ok and result.stderr  # the caller still has ffmpeg's text
    lines = [r.getMessage() for r in caplog.records if r.name == "app.services.transcoder"]
    assert len(lines) == 1 and lines[0].startswith("transcode to aac failed: FfmpegError (exit ")
    assert lines[0].endswith(")") and "Secret" not in lines[0] and str(tmp_path) not in lines[0]


def test_an_identity_tool_failure_logs_the_category(tmp_path, monkeypatch, caplog):
    path = tmp_path / "a.flac"
    path.write_bytes(b"x")
    monkeypatch.setenv("PATH", str(tmp_path / "no-tools"))

    with caplog.at_level(logging.WARNING, logger="app.services.audio_identity"):
        assert audio_identity.compute_exact(path, "flac").reason == "tool_missing"

    assert [r.getMessage() for r in caplog.records if r.name == "app.services.audio_identity"] == [
        "exact audio hash failed: reason=tool_missing kind=pcm_sha256 codec=flac returncode=None"
        " error=FfmpegError (not found)"
    ]


@pytest.mark.requires_ffmpeg
def test_a_failed_tag_write_logs_the_category_not_the_path_or_tags(tmp_path, caplog):
    from app.services.metadata import TagWriteError, write_metadata_tags

    source = tmp_path / "Secret Artist" / "Secret Song.flac"
    source.parent.mkdir()
    source.write_bytes(b"not audio")

    with caplog.at_level(logging.DEBUG, logger="app.services.metadata"):
        with pytest.raises(TagWriteError):
            write_metadata_tags(source, tmp_path / "out.flac", {"title": "Secret Title"})

    lines = [r.getMessage() for r in caplog.records if r.name == "app.services.metadata"]
    assert len(lines) == 1 and lines[0].startswith("tag write failed: FfmpegError (exit "), lines
    assert lines[0].endswith(")") and "Secret" not in lines[0] and str(tmp_path) not in lines[0]
