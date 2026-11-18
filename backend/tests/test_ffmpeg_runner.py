from __future__ import annotations

import os
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
    ToolOptions,
    run_ffmpeg,
    scaled_timeout,
)
from tests.process_state import pid_alive


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

    def test_run_ffmpeg__timeout__kills_process_group_reaps_and_raises(self, tmp_path):
        # BE-TOOLS (A.7): the whole group (pgid == pid), no longer the leader only.
        output = tmp_path / "out.m4a"
        output.write_bytes(b"partial")  # simulate a partial write mid-encode
        fake = _fake_popen_factory(
            communicate_effect=subprocess.TimeoutExpired(cmd="ffmpeg", timeout=5)
        )
        reaped = {}

        class ReapTrackingFakePopen(fake):
            def communicate(self, timeout=None):
                result = super().communicate(timeout=timeout)
                reaped["after_kill"] = killpg.call_count == 1
                return result

        with patch("app.services.ffmpeg_runner.os.killpg") as killpg, \
                patch("app.services.ffmpeg_runner.subprocess.Popen", ReapTrackingFakePopen):
            with pytest.raises(FfmpegError):
                run_ffmpeg(["ffmpeg", "-i", "src"], output, timeout=5)
        killpg.assert_called_once_with(4242, signal.SIGKILL)
        assert reaped["after_kill"] is True
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
            run_ffmpeg(["ffmpeg", "-i", "src"], output, timeout=5,
                options=ToolOptions(registry=registry, job_id="job-1"))

        assert seen_during_run["registered"] is True
        assert "job-1" not in registry._procs

    def test_run_ffmpeg__low_priority__refused_never_ignored(self, tmp_path):
        with patch("app.services.ffmpeg_runner.subprocess.Popen") as popen:
            with pytest.raises(ValueError):
                run_ffmpeg(["ffmpeg"], tmp_path / "out", timeout=5, options=ToolOptions(low_priority=True))
        popen.assert_not_called()

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


@pytest.mark.integration
class TestFfmpegProcessRegistryRealProcesses:
    """Real child processes (``sleep``/``sh``) through run_ffmpeg: the
    command is never inspected, only run, validated and registered."""

    def test_kill__running_process__dies_and_run_ffmpeg_raises(self, tmp_path):
        registry = FfmpegProcessRegistry()
        output = tmp_path / "out.bin"
        outcome = {}

        def run():
            try:
                run_ffmpeg(_SLEEP, output, timeout=60, options=ToolOptions(registry=registry, job_id="job-1"))
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
            run_ffmpeg(_SLEEP, tmp_path / "out.bin", timeout=60, options=ToolOptions(registry=registry, job_id="job-1"))

        assert time.monotonic() - started < 5
        assert "job-1" not in registry._procs

    def test_forget__clears_flag__next_run_succeeds(self, tmp_path):
        registry = FfmpegProcessRegistry()
        registry.kill("job-1")
        registry.forget("job-1")
        output = tmp_path / "out.bin"

        run_ffmpeg(
            ["sh", "-c", f"printf data > '{output}'"], output, timeout=10,
            options=ToolOptions(registry=registry, job_id="job-1"),
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
                run_ffmpeg(_SLEEP, output, timeout=60, options=ToolOptions(registry=registry, job_id="job-1"))

        (proc,) = spawned
        assert proc.returncode is not None  # reaped, not leaked
        assert proc.returncode == -signal.SIGKILL
        assert "job-1" not in registry._procs
        assert not output.exists()


# ── BE-TOOLS (A.7, approved): every way run_ffmpeg ends a process ends its group ──


def _wait_gone(pid: int, deadline_s: float = 5.0) -> bool:
    """True once ``pid`` no longer runs: gone, or a zombie nobody reaps (an
    orphan is reaped by init asynchronously where there is one, so this
    observes with a deadline; it asserts no timing)."""
    return _wait_for(lambda: not pid_alive(pid), deadline_s)


class _ToolWithChild:
    """A fake tool: ``sh`` starts a child (``sleep``) in its own process group,
    writes the child's pid to a file, then sleeps itself. ``child_keeps_stderr``
    leaves the child holding the stderr pipe run_ffmpeg reads."""

    def __init__(self, tmp_path: Path, *, child_keeps_stderr: bool = False):
        self.pid_file = tmp_path / "child.pid"
        redirect = "</dev/null >/dev/null" + ("" if child_keeps_stderr else " 2>/dev/null")
        script = tmp_path / "tool.sh"
        script.write_text(
            f"sleep 300 {redirect} &\n"
            f'echo $! > "$1.part" && mv "$1.part" "$1"\n'
            "exec sleep 300\n"
        )
        self.cmd = ["sh", str(script), str(self.pid_file)]

    def ready(self) -> bool:
        return self.pid_file.exists()

    def child_pid(self) -> int:
        return int(self.pid_file.read_text())

    def cleanup(self, *, seen_gone: bool = False) -> None:
        # A pid already seen gone may belong to another process by now: never signal it.
        if self.pid_file.exists() and not seen_gone:
            try:
                os.kill(self.child_pid(), signal.SIGKILL)
            except ProcessLookupError:
                pass


def _popen_failing_once_ready(tool: _ToolWithChild, error: BaseException, spawned: list):
    """A real Popen whose first bounded ``communicate`` raises ``error`` once
    the tool's child exists: a time-out (or another failure while reading the
    output) at a known moment, without waiting on the clock."""

    class FailingOnce(subprocess.Popen):
        failed = False

        def __init__(self, *args, **kwargs):
            super().__init__(*args, **kwargs)
            spawned.append(self)

        def communicate(self, *args, **kwargs):
            if not FailingOnce.failed:
                FailingOnce.failed = True
                assert _wait_for(tool.ready), "the fake tool never started its child"
                raise error
            return super().communicate(*args, **kwargs)

    return FailingOnce


@pytest.mark.integration
class TestRunFfmpegEndsTheWholeGroup:
    def _run(self, tmp_path, tool, error):
        spawned: list[subprocess.Popen] = []
        output = tmp_path / "out.bin"
        outcome = {}

        def run():
            try:
                with patch("app.services.ffmpeg_runner.subprocess.Popen",
                           _popen_failing_once_ready(tool, error, spawned)):
                    run_ffmpeg(tool.cmd, output, timeout=60)
                outcome["result"] = "returned"
            except BaseException as e:  # noqa: BLE001 - recorded for the assert
                outcome["result"] = e

        worker = threading.Thread(target=run, daemon=True)
        worker.start()
        child_gone = False
        try:
            worker.join(timeout=10)
            returned = not worker.is_alive()
            child = tool.child_pid() if tool.ready() else None
            child_gone = child is not None and _wait_gone(child)
        finally:
            tool.cleanup(seen_gone=child_gone)
            worker.join(timeout=10)
        return outcome.get("result"), spawned, returned, child_gone

    def test_a_time_out_kills_the_tool_and_the_child_it_started(self, tmp_path):
        tool = _ToolWithChild(tmp_path)

        result, [proc], returned, child_gone = self._run(
            tmp_path, tool, subprocess.TimeoutExpired(cmd="tool", timeout=60))

        assert returned
        assert isinstance(result, FfmpegError)
        assert proc.returncode == -signal.SIGKILL
        assert child_gone, "the tool's child outlived the time-out"

    def test_a_time_out_returns_even_when_the_child_holds_the_output_pipe(self, tmp_path):
        tool = _ToolWithChild(tmp_path, child_keeps_stderr=True)

        result, [proc], returned, child_gone = self._run(
            tmp_path, tool, subprocess.TimeoutExpired(cmd="tool", timeout=60))

        assert returned, "run_ffmpeg waited on the child after the time-out"
        assert isinstance(result, FfmpegError)
        assert child_gone

    @pytest.mark.parametrize("exc_type", [RuntimeError, KeyboardInterrupt])
    def test_a_failure_while_reading_the_output_kills_the_child_too(self, tmp_path, exc_type):
        tool = _ToolWithChild(tmp_path)

        result, [proc], returned, child_gone = self._run(tmp_path, tool, exc_type("interrupted"))

        assert returned
        assert isinstance(result, exc_type)
        assert proc.returncode == -signal.SIGKILL
        assert child_gone, "the tool's child outlived the failure"

    def test_a_stop_through_the_registry_kills_the_child_too(self, tmp_path):
        """Already true before BE-TOOLS (the registry kills the group); kept as a guard."""
        tool = _ToolWithChild(tmp_path)
        registry = FfmpegProcessRegistry()
        outcome = {}

        def run():
            try:
                run_ffmpeg(tool.cmd, tmp_path / "out.bin", timeout=60,
                    options=ToolOptions(registry=registry, job_id="job-1"))
            except BaseException as e:  # noqa: BLE001 - recorded for the assert
                outcome["result"] = e

        worker = threading.Thread(target=run, daemon=True)
        worker.start()
        child_gone = False
        try:
            assert _wait_for(tool.ready)
            assert registry.kill("job-1") is True
            worker.join(timeout=10)
            assert not worker.is_alive()
            assert isinstance(outcome["result"], FfmpegError)
            child_gone = _wait_gone(tool.child_pid())
            assert child_gone
        finally:
            tool.cleanup(seen_gone=child_gone)


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


@pytest.mark.integration
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


# ── 7A.1a review R1: match the dir only as a path argument, never a substring ──

class TestKillOrphanedFfmpegMatching:
    """Stubbed process list: the matcher must name a pid only when an argument
    *starts* with the work dir's absolute path, so another server's library
    whose path merely ends the same way is never touched."""

    def _killed(self, monkeypatch, work_dir, cmdlines):
        import app.services.ffmpeg_runner as runner

        procs = [(800000 + i, "/usr/bin/ffmpeg", c) for i, c in enumerate(cmdlines)]
        sent = []
        monkeypatch.setattr(runner, "_list_processes", lambda: procs)
        monkeypatch.setattr(runner.os, "getpgid", lambda pid: pid)
        monkeypatch.setattr(runner.os, "killpg", lambda pid, sig: sent.append(pid))
        monkeypatch.setattr(runner.os, "kill", lambda pid, sig: sent.append(pid))
        return runner.kill_orphaned_ffmpeg(work_dir), sent

    def test_a_relative_work_dir_never_matches_another_library(self, tmp_path, monkeypatch):
        monkeypatch.chdir(tmp_path)
        (tmp_path / "music" / ".uploads").mkdir(parents=True)
        ours = tmp_path / "music" / ".uploads" / "b" / "work.flac"

        killed, sent = self._killed(monkeypatch, Path("music/.uploads"), [
            "ffmpeg -i x -y /srv/other/music/.uploads/a.flac",
            f"ffmpeg -i x -y {ours}",
        ])

        assert killed == [800001] and sent == [800001]

    def test_an_absolute_work_dir_never_matches_a_longer_path(self, tmp_path, monkeypatch):
        uploads = tmp_path / "music dir" / ".uploads"  # space: real libraries have them
        uploads.mkdir(parents=True)

        killed, _ = self._killed(monkeypatch, uploads, [
            f"ffmpeg -i x -y /srv{uploads}/a.flac",        # another root ending the same way
            f"ffmpeg -i x -y {uploads}-old/a.flac",         # sibling sharing the prefix
            f"ffmpeg -i {uploads}/in.flac -y out.flac",     # ours (input side)
            f"ffmpeg -i x -f flac file:{uploads}/o.flac",   # ours (protocol prefix)
        ])

        assert killed == [800002, 800003]
