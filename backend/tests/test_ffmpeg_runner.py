from __future__ import annotations

import signal
import subprocess
from pathlib import Path
from typing import Optional
from unittest.mock import MagicMock, patch

import pytest

from app.services.ffmpeg_runner import (
    FfmpegError,
    FfmpegProcessRegistry,
    run_ffmpeg,
    scaled_timeout,
)


def _fake_popen_factory(
    *,
    returncode: int = 0,
    stderr: bytes = b"",
    write_output: Optional[Path] = None,
    write_bytes: bytes = b"encoded-bytes",
    communicate_effect: Optional[BaseException] = None,
    pid: int = 4242,
):
    """Builds a fake Popen class mirroring the real one's shape (returncode,
    communicate(), kill(), pid) closely enough for run_ffmpeg's own logic."""

    class FakePopen:
        def __init__(self, cmd, **kwargs):
            self.pid = pid
            self.returncode = returncode
            self.killed = False
            self._communicate_effect = communicate_effect

        def communicate(self, timeout=None):
            if self._communicate_effect is not None:
                effect = self._communicate_effect
                self._communicate_effect = None
                raise effect
            if write_output is not None:
                write_output.write_bytes(write_bytes)
            return (b"", stderr)

        def kill(self):
            self.killed = True

    return FakePopen


class TestRunFfmpeg:
    def test_run_ffmpeg__success__writes_output_no_error(self, tmp_path):
        output = tmp_path / "out.m4a"
        fake = _fake_popen_factory(write_output=output)
        with patch("app.services.ffmpeg_runner.subprocess.Popen", fake):
            run_ffmpeg(["ffmpeg", "-i", "src"], output, timeout=5)
        assert output.exists()

    def test_run_ffmpeg__nonzero_exit__raises_and_cleans_up_output(self, tmp_path):
        output = tmp_path / "out.m4a"
        fake = _fake_popen_factory(returncode=1, stderr=b"boom", write_output=output)
        with patch("app.services.ffmpeg_runner.subprocess.Popen", fake):
            with pytest.raises(FfmpegError) as exc_info:
                run_ffmpeg(["ffmpeg", "-i", "src"], output, timeout=5)
        assert "boom" in exc_info.value.stderr
        assert not output.exists()

    def test_run_ffmpeg__missing_binary__raises_ffmpeg_error(self, tmp_path):
        output = tmp_path / "out.m4a"
        with patch(
            "app.services.ffmpeg_runner.subprocess.Popen", side_effect=FileNotFoundError
        ):
            with pytest.raises(FfmpegError):
                run_ffmpeg(["ffmpeg", "-i", "src"], output, timeout=5)

    def test_run_ffmpeg__empty_output__raises_ffmpeg_error(self, tmp_path):
        output = tmp_path / "out.m4a"
        # returncode 0 but nothing was actually written to output.
        fake = _fake_popen_factory(returncode=0)
        with patch("app.services.ffmpeg_runner.subprocess.Popen", fake):
            with pytest.raises(FfmpegError):
                run_ffmpeg(["ffmpeg", "-i", "src"], output, timeout=5)

    def test_run_ffmpeg__timeout__kills_process_reaps_and_raises(self, tmp_path):
        output = tmp_path / "out.m4a"
        output.write_bytes(b"partial")  # simulate a partial write mid-encode
        fake = _fake_popen_factory(
            communicate_effect=subprocess.TimeoutExpired(cmd="ffmpeg", timeout=5)
        )
        killed_flag = {}

        class KillTrackingFakePopen(fake):
            def kill(self):
                killed_flag["killed"] = True
                super().kill()

        with patch("app.services.ffmpeg_runner.subprocess.Popen", KillTrackingFakePopen):
            with pytest.raises(FfmpegError):
                run_ffmpeg(["ffmpeg", "-i", "src"], output, timeout=5)
        assert killed_flag.get("killed") is True
        assert not output.exists()

    def test_run_ffmpeg__registry_and_job_id__registered_during_run_discarded_after(
        self, tmp_path
    ):
        output = tmp_path / "out.m4a"
        registry = FfmpegProcessRegistry()
        seen_during_run = {}

        fake = _fake_popen_factory(write_output=output)

        class TrackingFakePopen(fake):
            def communicate(self, timeout=None):
                # At this point run_ffmpeg must have already registered us.
                seen_during_run["registered"] = registry._procs.get("job-1") is self
                return super().communicate(timeout=timeout)

        with patch("app.services.ffmpeg_runner.subprocess.Popen", TrackingFakePopen):
            run_ffmpeg(["ffmpeg", "-i", "src"], output, timeout=5, registry=registry, job_id="job-1")

        assert seen_during_run["registered"] is True
        assert "job-1" not in registry._procs

    def test_run_ffmpeg__no_registry_or_job_id__behaves_as_before(self, tmp_path):
        output = tmp_path / "out.m4a"
        fake = _fake_popen_factory(write_output=output)
        with patch("app.services.ffmpeg_runner.subprocess.Popen", fake):
            run_ffmpeg(["ffmpeg", "-i", "src"], output, timeout=5)
        assert output.exists()


class TestFfmpegProcessRegistry:
    def test_kill__process_registered__calls_os_killpg(self):
        registry = FfmpegProcessRegistry()
        fake_proc = MagicMock(pid=555)
        registry.register("job-1", fake_proc)

        with patch(
            "app.services.ffmpeg_runner.os.getpgid", return_value=555
        ) as getpgid, patch("app.services.ffmpeg_runner.os.killpg") as killpg:
            assert registry.kill("job-1") is True

        getpgid.assert_called_once_with(555)
        killpg.assert_called_once_with(555, signal.SIGKILL)

    def test_kill__nothing_registered__returns_false(self):
        registry = FfmpegProcessRegistry()
        assert registry.kill("missing") is False

    def test_kill__process_already_exited__returns_false(self):
        registry = FfmpegProcessRegistry()
        fake_proc = MagicMock(pid=555)
        registry.register("job-1", fake_proc)

        with patch(
            "app.services.ffmpeg_runner.os.getpgid", side_effect=ProcessLookupError
        ):
            assert registry.kill("job-1") is False

    def test_discard__removes_entry(self):
        registry = FfmpegProcessRegistry()
        registry.register("job-1", MagicMock())

        registry.discard("job-1")

        assert registry.kill("job-1") is False


class TestScaledTimeout:
    def test_scaled_timeout__missing_file__returns_floor(self, tmp_path):
        assert scaled_timeout(tmp_path / "nope.flac") == 30

    def test_scaled_timeout__large_file__capped(self):
        big = MagicMock()
        big.stat.return_value.st_size = 700 * 1024 * 1024
        assert scaled_timeout(big) == 600
