from __future__ import annotations

import signal
import subprocess
import threading
import time
from pathlib import Path
from typing import Optional
from unittest.mock import MagicMock, patch

import pytest

from app.services.ffmpeg_runner import (
    FfmpegError,
    FfmpegProcessRegistry,
    kill_orphaned_ffmpeg,
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
        fake_proc.poll.return_value = None  # still running
        registry.register("job-1", fake_proc)

        with patch("app.services.ffmpeg_runner.os.killpg") as killpg:
            assert registry.kill("job-1") is True

        # pgid == pid (start_new_session=True): no getpgid round-trip.
        killpg.assert_called_once_with(555, signal.SIGKILL)

    def test_kill__nothing_registered__returns_false(self):
        registry = FfmpegProcessRegistry()
        assert registry.kill("missing") is False

    def test_kill__process_already_reaped__never_signalled(self):
        registry = FfmpegProcessRegistry()
        fake_proc = MagicMock(pid=555)
        fake_proc.poll.return_value = 0  # exited and reaped; pid may be reused
        registry.register("job-1", fake_proc)

        with patch("app.services.ffmpeg_runner.os.killpg") as killpg:
            assert registry.kill("job-1") is False

        killpg.assert_not_called()

    def test_kill__process_group_gone__returns_false(self):
        registry = FfmpegProcessRegistry()
        fake_proc = MagicMock(pid=555)
        fake_proc.poll.return_value = None
        registry.register("job-1", fake_proc)

        with patch(
            "app.services.ffmpeg_runner.os.killpg", side_effect=ProcessLookupError
        ):
            assert registry.kill("job-1") is False

    def test_discard__removes_entry(self):
        registry = FfmpegProcessRegistry()
        registry.register("job-1", MagicMock())

        registry.discard("job-1")

        assert registry.kill("job-1") is False

    def test_kill_before_register__later_register_kills_on_arrival(self):
        registry = FfmpegProcessRegistry()
        assert registry.kill("job-1") is False  # nothing running yet

        fake_proc = MagicMock(pid=777)
        fake_proc.poll.return_value = None
        with patch("app.services.ffmpeg_runner.os.killpg") as killpg:
            registry.register("job-1", fake_proc)

        killpg.assert_called_once_with(777, signal.SIGKILL)

    def test_kill_flag__survives_discard__cleared_by_forget(self):
        registry = FfmpegProcessRegistry()
        registry.kill("job-1")
        registry.discard("job-1")  # end of one ffmpeg step: flag must persist

        with patch("app.services.ffmpeg_runner.os.killpg") as killpg:
            proc = MagicMock(pid=1)
            proc.poll.return_value = None
            registry.register("job-1", proc)
            assert killpg.call_count == 1

            registry.forget("job-1")
            proc2 = MagicMock(pid=2)
            proc2.poll.return_value = None
            registry.register("job-1", proc2)
            assert killpg.call_count == 1  # flag gone: not killed

    def test_kill_flag__is_per_job(self):
        registry = FfmpegProcessRegistry()
        registry.kill("job-1")

        with patch("app.services.ffmpeg_runner.os.killpg") as killpg:
            proc = MagicMock(pid=3)
            proc.poll.return_value = None
            registry.register("job-2", proc)

        killpg.assert_not_called()


def _wait_for(predicate, timeout=5.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.01)
    return False


_SLEEP = ["sleep", "30"]


class TestFfmpegProcessRegistryRealProcesses:
    """Real child processes (``sleep``/``sh``) through run_ffmpeg: the
    command is never inspected, only run, validated and registered."""

    def test_kill__running_process__dies_and_run_ffmpeg_raises(self, tmp_path):
        registry = FfmpegProcessRegistry()
        output = tmp_path / "out.bin"
        outcome = {}

        def run():
            try:
                run_ffmpeg(_SLEEP, output, timeout=60, registry=registry, job_id="job-1")
                outcome["result"] = "returned"
            except BaseException as e:  # noqa: BLE001 - recorded for the assert
                outcome["result"] = e

        worker = threading.Thread(target=run)
        started = time.monotonic()
        worker.start()
        assert _wait_for(lambda: "job-1" in registry._procs)
        proc = registry._procs["job-1"]

        assert registry.kill("job-1") is True
        worker.join(timeout=10)

        assert not worker.is_alive()
        assert time.monotonic() - started < 10
        assert isinstance(outcome["result"], FfmpegError)
        assert proc.poll() == -signal.SIGKILL
        assert "job-1" not in registry._procs
        assert not output.exists()

    def test_kill_before_register__run_ffmpeg_killed_immediately(self, tmp_path):
        registry = FfmpegProcessRegistry()
        registry.kill("job-1")
        started = time.monotonic()

        with pytest.raises(FfmpegError):
            run_ffmpeg(_SLEEP, tmp_path / "out.bin", timeout=60, registry=registry, job_id="job-1")

        assert time.monotonic() - started < 5
        assert "job-1" not in registry._procs

    def test_forget__clears_flag__next_run_succeeds(self, tmp_path):
        registry = FfmpegProcessRegistry()
        registry.kill("job-1")
        registry.forget("job-1")
        output = tmp_path / "out.bin"

        run_ffmpeg(
            ["sh", "-c", f"printf data > '{output}'"], output, timeout=10,
            registry=registry, job_id="job-1",
        )

        assert output.read_bytes() == b"data"

    @pytest.mark.parametrize("exc_type", [RuntimeError, KeyboardInterrupt])
    def test_non_timeout_exception_in_communicate__child_killed_and_reaped(
        self, tmp_path, exc_type
    ):
        registry = FfmpegProcessRegistry()
        output = tmp_path / "out.bin"
        output.write_bytes(b"partial")
        spawned = []

        class RaisingPopen(subprocess.Popen):
            raised = False

            def __init__(self, *args, **kwargs):
                super().__init__(*args, **kwargs)
                spawned.append(self)

            def communicate(self, *args, **kwargs):
                if not RaisingPopen.raised:
                    RaisingPopen.raised = True
                    raise exc_type("interrupted mid-communicate")
                return super().communicate(*args, **kwargs)

        with patch("app.services.ffmpeg_runner.subprocess.Popen", RaisingPopen):
            with pytest.raises(exc_type):
                run_ffmpeg(_SLEEP, output, timeout=60, registry=registry, job_id="job-1")

        (proc,) = spawned
        assert proc.returncode is not None  # reaped, not leaked
        assert proc.returncode == -signal.SIGKILL
        assert "job-1" not in registry._procs
        assert not output.exists()


class TestScaledTimeout:
    def test_scaled_timeout__missing_file__returns_floor(self, tmp_path):
        assert scaled_timeout(tmp_path / "nope.flac") == 30

    def test_scaled_timeout__large_file__capped(self):
        big = MagicMock()
        big.stat.return_value.st_size = 700 * 1024 * 1024
        assert scaled_timeout(big) == 600


# ── kill_orphaned_ffmpeg (real processes) ───────────────────────────────────


def _spawn_fake(binary: Path, target: Path) -> subprocess.Popen:
    """A long-lived process whose argv[0] is ``binary`` and whose command line
    names ``target`` -- like an orphaned conversion ffmpeg. ``binary`` is a
    symlink to /bin/sh; the trailing ``; :`` stops sh from exec-ing sleep
    (which would replace the matching command line)."""
    return subprocess.Popen(
        [str(binary), "-c", "sleep 30; :", str(target)],
        start_new_session=True,
    )


def _wait_dead(proc: subprocess.Popen, timeout: float = 5.0) -> bool:
    try:
        proc.wait(timeout=timeout)
        return True
    except subprocess.TimeoutExpired:
        return False


class TestKillOrphanedFfmpeg:
    @pytest.fixture
    def fake_ffmpeg(self, tmp_path):
        binary = tmp_path / "bin" / "ffmpeg"
        binary.parent.mkdir()
        binary.symlink_to("/bin/sh")
        return binary

    def test_kills_ffmpeg_writing_into_work_dir(self, tmp_path, fake_ffmpeg):
        staging = tmp_path / "music dir" / ".staging"  # space: real libraries have them
        staging.mkdir(parents=True)
        proc = _spawn_fake(fake_ffmpeg, staging / "u.1.convert.m4a.partial")
        try:
            time.sleep(0.2)
            killed = kill_orphaned_ffmpeg(staging)
            assert proc.pid in killed
            assert _wait_dead(proc)
            assert proc.returncode == -signal.SIGKILL
        finally:
            proc.kill()
            proc.wait()

    def test_leaves_unrelated_processes_alone(self, tmp_path, fake_ffmpeg):
        staging = tmp_path / ".staging"
        staging.mkdir()
        elsewhere = tmp_path / "workspace" / "x.m4a"  # an ffmpeg, but not ours
        not_ffmpeg = tmp_path / "bin" / "sh-alias"  # names staging, but not ffmpeg
        not_ffmpeg.symlink_to("/bin/sh")
        procs = [
            _spawn_fake(fake_ffmpeg, elsewhere),
            _spawn_fake(not_ffmpeg, staging / "u.1.convert.m4a"),
            # A sibling directory that merely shares the prefix.
            _spawn_fake(fake_ffmpeg, tmp_path / ".staging-old" / "u.1.convert.m4a"),
        ]
        try:
            time.sleep(0.2)
            assert kill_orphaned_ffmpeg(staging) == []
            assert all(p.poll() is None for p in procs)
        finally:
            for p in procs:
                p.kill()
                p.wait()
