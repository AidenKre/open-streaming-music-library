"""Phase 6.5 (spec §2 runner row, review 6.5-U03): ``run_capture`` bounds
stdout, enforces the timeout, kills the whole process group (also through the
registry) and never uses ``preexec_fn``.

These tests run real, short-lived Python child processes (not ffmpeg), so the
pipe, session and signal behavior is the operating system's, not a fake's.
"""

from __future__ import annotations

import errno
import os
import shlex
import shutil
import signal
import subprocess
import sys
import threading
import time

import pytest

from app.services import ffmpeg_runner
from app.services.ffmpeg_runner import (
    CaptureOverflow,
    CaptureResult,
    CaptureTimeout,
    FfmpegError,
    FfmpegProcessRegistry,
    ToolOptions,
    run_capture,
)
from tests.process_state import pid_alive, process_state

PY = sys.executable


def py(code: str) -> list[str]:
    return [PY, "-c", code]


@pytest.fixture
def popen_spy(monkeypatch):
    """Records every Popen ``run_capture`` makes (argv, kwargs, the object)
    while still starting the real process."""
    real_popen = subprocess.Popen
    calls = []

    def spy(cmd, **kwargs):
        proc = real_popen(cmd, **kwargs)
        calls.append({"cmd": list(cmd), "kwargs": kwargs, "proc": proc})
        return proc

    monkeypatch.setattr(ffmpeg_runner.subprocess, "Popen", spy)
    return calls


def _wait_gone(pid: int, deadline_s: float = 5.0) -> bool:
    """True once ``pid`` no longer runs: gone, or a zombie nobody reaps (an
    orphan is reaped by init asynchronously where there is one, so this
    observes with a deadline; it asserts no timing)."""
    end = time.monotonic() + deadline_s
    while time.monotonic() < end:
        if not pid_alive(pid):
            return True
        time.sleep(0.01)
    return False


def _old_pid_alive(pid: int) -> bool:
    """The check both files used before pre-merge D2-02."""
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return True


def test_a_zombie_counts_as_gone_though_signal_zero_still_reaches_it():
    """Pre-merge D2-02: a child that has exited and that nobody reaped (the test
    is its parent and does not reap it yet) is a zombie. ``os.kill(pid, 0)``
    still succeeds on it; ``pid_alive`` must call it gone."""
    read_end, write_end = os.pipe()
    proc = subprocess.Popen(py("pass"), stdout=write_end)
    os.close(write_end)
    try:
        assert os.read(read_end, 1) == b""  # the pipe closes as the child exits
        state = None
        end = time.monotonic() + 5.0
        for _ in range(1_000):  # a 5 ms sleep a pass; a hard cap and the deadline
            state = process_state(proc.pid)
            if (state is not None and state.startswith("Z")) or time.monotonic() > end:
                break
            time.sleep(0.005)
        assert state is not None and state.startswith("Z"), state
        assert _old_pid_alive(proc.pid) is True, "signal 0 reaches a zombie"
        assert pid_alive(proc.pid) is False
    finally:
        os.close(read_end)
        proc.wait()
    assert pid_alive(proc.pid) is False


class _ReadinessClock:
    """Stands in for ``ffmpeg_runner.time``: ``monotonic`` stands still until
    ``ready`` exists, then moves an hour ahead on every read. A timeout
    therefore fires only after the child has written its pid file, however
    slowly the machine starts it, and the next read is past any deadline,
    even one the parent took after the child was ready; nothing waits on
    wall-clock time."""

    def __init__(self, ready):
        self._ready = ready
        self._now = time.monotonic()

    def monotonic(self) -> float:
        if self._ready.exists():
            self._now += 3600.0
        return self._now

    def __getattr__(self, name):
        return getattr(time, name)


def test_the_readiness_clock_passes_a_deadline_taken_after_readiness(tmp_path):
    """A parent stalled past the child's start-up takes its deadline from the
    already-advanced clock; the next read must still be past that deadline."""
    ready = tmp_path / "ready"
    clock = _ReadinessClock(ready)
    early_deadline = clock.monotonic() + 1.0
    ready.write_text("1")

    late_deadline = clock.monotonic() + 1.0  # taken only after the child was ready

    now = clock.monotonic()
    assert now > early_deadline and now > late_deadline


def _spawn_grandchild_then(pid_file, rest: str) -> str:
    """Child code: start a 60 s grandchild in its own group, publish its pid
    atomically (the clock above keys on the file existing), say so on stdout
    (wakes run_capture's select), then run ``rest``."""
    tmp = str(pid_file) + ".tmp"
    return (
        "import os, subprocess, sys, time\n"
        "g = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'])\n"
        f"open({tmp!r}, 'w').write(str(g.pid))\n"
        f"os.replace({tmp!r}, {str(pid_file)!r})\n"
        "print('ready', flush=True)\n"
        f"{rest}\n"
    )


class TestResult:
    @pytest.mark.integration
    def test_returns_exit_code_stdout_and_stderr(self):
        result = run_capture(
            py("import sys; sys.stdout.write('hello'); sys.stderr.write('warn'); sys.exit(3)"),
            timeout_s=10,
            max_stdout_bytes=1024,
        )
        assert isinstance(result, CaptureResult)
        assert result.returncode == 3
        assert result.stdout == b"hello"
        assert "warn" in result.stderr

    @pytest.mark.integration
    def test_stdout_is_bytes_exactly_as_written(self):
        result = run_capture(
            py("import sys; sys.stdout.buffer.write(bytes(range(256)))"),
            timeout_s=10,
            max_stdout_bytes=256,
        )
        assert result.returncode == 0
        assert result.stdout == bytes(range(256))

    @pytest.mark.integration
    def test_undecodable_stderr_is_replaced_not_raised(self):
        result = run_capture(
            py("import sys; sys.stderr.buffer.write(b'bad \\xff\\xfe bytes')"),
            timeout_s=10,
            max_stdout_bytes=16,
        )
        assert result.returncode == 0
        assert "bad" in result.stderr and "bytes" in result.stderr

    def test_missing_binary_raises_ffmpeg_error(self, tmp_path):
        with pytest.raises(FfmpegError) as exc_info:
            run_capture([str(tmp_path / "no-such-tool")], timeout_s=5, max_stdout_bytes=16)
        assert "not found" in str(exc_info.value)
        assert not isinstance(exc_info.value, (CaptureTimeout, CaptureOverflow))


@pytest.mark.integration
class TestProcessSetup:
    def test_own_session_no_stdin_and_never_preexec_fn(self, popen_spy):
        result = run_capture(
            py(
                "import os, sys\n"
                "data = sys.stdin.read()\n"
                "print(os.getpgid(0) == os.getpid(), os.getsid(0) == os.getpid(), len(data))"
            ),
            timeout_s=10,
            max_stdout_bytes=1024,
        )
        assert result.stdout.split() == [b"True", b"True", b"0"]
        (call,) = popen_spy
        kwargs = call["kwargs"]
        assert kwargs.get("start_new_session") is True
        assert kwargs.get("preexec_fn") is None
        assert kwargs.get("stdin") == subprocess.DEVNULL
        assert kwargs.get("stdout") == subprocess.PIPE
        assert kwargs.get("stderr") == subprocess.PIPE

    def test_without_low_priority_the_command_is_run_unchanged(self, popen_spy):
        cmd = py("pass")
        run_capture(cmd, timeout_s=10, max_stdout_bytes=16)
        assert popen_spy[0]["cmd"] == cmd


@pytest.mark.integration
class TestStdoutCap:
    def test_output_exactly_at_the_cap_is_accepted(self):
        result = run_capture(
            py("import sys; sys.stdout.write('x' * 1000)"),
            timeout_s=10,
            max_stdout_bytes=1000,
        )
        assert result.returncode == 0
        assert result.stdout == b"x" * 1000

    def test_one_byte_over_the_cap_raises_overflow(self):
        with pytest.raises(CaptureOverflow):
            run_capture(
                py("import sys; sys.stdout.write('x' * 1001)"),
                timeout_s=10,
                max_stdout_bytes=1000,
            )

    def test_endless_stdout_is_killed_and_reaped(self, popen_spy):
        with pytest.raises(CaptureOverflow):
            run_capture(
                py("import sys\nwhile True:\n    sys.stdout.write('y' * 65536)\n"),
                timeout_s=30,
                max_stdout_bytes=4096,
            )
        proc = popen_spy[0]["proc"]
        assert proc.returncode == -signal.SIGKILL  # killed and reaped, no zombie
        assert proc.stdout.closed and proc.stderr.closed  # no leaked pipe

    def test_a_flood_of_stderr_never_deadlocks_and_is_kept_bounded(self):
        # 4 MiB of stderr is far more than a pipe buffer; a reader that only
        # drains stdout would block the child forever (then time out here).
        result = run_capture(
            py(
                "import sys\n"
                "for _ in range(64):\n    sys.stderr.write('e' * 65536)\n"
                "sys.stdout.write('done')\n"
            ),
            timeout_s=20,
            max_stdout_bytes=64,
        )
        assert result.returncode == 0
        assert result.stdout == b"done"
        assert 0 < len(result.stderr) <= 256 * 1024


@pytest.mark.integration
class TestTimeout:
    def test_timeout_kills_the_whole_process_group(self, tmp_path, popen_spy, monkeypatch):
        pid_file = tmp_path / "grandchild.pid"
        code = _spawn_grandchild_then(pid_file, "time.sleep(60)")
        monkeypatch.setattr(ffmpeg_runner, "time", _ReadinessClock(pid_file))
        started = time.monotonic()
        with pytest.raises(CaptureTimeout):
            run_capture(py(code), timeout_s=1.0, max_stdout_bytes=64)
        assert time.monotonic() - started < 30  # ended by the timeout, not by the child's 60 s

        proc = popen_spy[0]["proc"]
        assert proc.returncode == -signal.SIGKILL  # the child itself: killed and reaped
        assert proc.stdout.closed and proc.stderr.closed
        grandchild = int(pid_file.read_text())
        assert _wait_gone(grandchild), "the grandchild outlived the timeout: no process-group kill"

    def test_timeout_is_a_ffmpeg_error(self):
        with pytest.raises(FfmpegError):
            run_capture(py("import time; time.sleep(60)"), timeout_s=0.3, max_stdout_bytes=64)


@pytest.mark.integration
class TestRegistry:
    def test_registered_while_running_and_discarded_after(self, popen_spy):
        registry = FfmpegProcessRegistry()
        seen = {}
        real_register = registry.register

        def register(job_id, proc):
            seen["job_id"] = job_id
            seen["proc"] = proc
            real_register(job_id, proc)

        registry.register = register
        result = run_capture(
            py("print('ok')"), timeout_s=10, options=ToolOptions(registry=registry, job_id="job-1"), max_stdout_bytes=64
        )
        assert result.returncode == 0
        assert seen["job_id"] == "job-1"
        assert seen["proc"] is popen_spy[0]["proc"]
        assert "job-1" not in registry._procs  # discarded (same check as run_ffmpeg's test)
        assert registry.kill("job-1") is False

    @pytest.mark.parametrize(
        "code, error",
        [
            ("import sys; sys.stdout.write('x' * 200)", CaptureOverflow),
            ("import time; time.sleep(60)", CaptureTimeout),
        ],
    )
    def test_discarded_after_a_failed_run_too(self, code, error):
        registry = FfmpegProcessRegistry()
        with pytest.raises(error):
            run_capture(py(code), timeout_s=0.5,
                options=ToolOptions(registry=registry, job_id="job-x"), max_stdout_bytes=100)
        assert "job-x" not in registry._procs

    def test_registry_kill_from_another_thread_ends_the_run(self, tmp_path, popen_spy):
        registry = FfmpegProcessRegistry()
        registered = threading.Event()
        real_register = registry.register

        def register(job_id, proc):
            real_register(job_id, proc)
            registered.set()

        registry.register = register
        pid_file = tmp_path / "grandchild.pid"
        code = (
            "import subprocess, sys, time\n"
            "g = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'])\n"
            f"open({str(pid_file)!r}, 'w').write(str(g.pid))\n"
            "print('started', flush=True)\n"
            "time.sleep(60)\n"
        )

        def killer():
            assert registered.wait(10)
            end = time.monotonic() + 10
            while (not pid_file.exists() or not pid_file.read_text()) and time.monotonic() < end:
                time.sleep(0.01)
            registry.kill("job-2")

        thread = threading.Thread(target=killer)
        thread.start()
        result = run_capture(py(code), timeout_s=30,
            options=ToolOptions(registry=registry, job_id="job-2"), max_stdout_bytes=64)
        thread.join(10)
        assert result.returncode == -signal.SIGKILL
        assert popen_spy[0]["proc"].returncode == -signal.SIGKILL
        assert _wait_gone(int(pid_file.read_text())), "registry.kill must kill the process group"

    def test_kill_before_register_kills_on_arrival(self):
        registry = FfmpegProcessRegistry()
        registry.kill("job-3")
        started = time.monotonic()
        result = run_capture(
            py("import time; time.sleep(60)"),
            timeout_s=30,
            options=ToolOptions(registry=registry, job_id="job-3"),
            max_stdout_bytes=64,
        )
        assert result.returncode == -signal.SIGKILL
        assert time.monotonic() - started < 10

    def test_registry_without_job_id_is_not_used(self):
        registry = FfmpegProcessRegistry()
        registry.register = lambda job_id, proc: pytest.fail("registered without a job id")
        result = run_capture(py("print('ok')"), timeout_s=10,
            options=ToolOptions(registry=registry), max_stdout_bytes=64)
        assert result.returncode == 0


@pytest.fixture(scope="module")
def ionice_home(tmp_path_factory):
    """One fake ionice script for the module: the first start of a newly
    written program is slow on macOS (about 0.2 s, a security check), so each
    test sets the script's mode in a data file instead of writing a new one."""
    home = tmp_path_factory.mktemp("ionice")
    ionice = home / "ionice"
    ionice.write_text(
        "#!/bin/sh\n"
        'home=${0%/*}\n'
        'echo "$*" >> "$home/calls"\n'
        'read mode < "$home/mode"\n'
        'if [ "$mode" = refuse ]; then\n'
        '  echo "ionice: ioprio_set failed: Operation not permitted" >&2\n'
        "  exit 1\n"
        "fi\n"
        f'if [ "$mode" = answer-check ] && [ "$2" = {shlex.quote(sys.executable)} ]; then exit 0; fi\n'
        "shift\n"
        'exec "$@"\n'
    )
    ionice.chmod(0o755)
    return home


class TestLowPriority:
    """Spec §2: low priority is a command prefix (``nice -n 10``, plus
    ``ionice -c3`` on Linux), never ``preexec_fn``."""

    @staticmethod
    def _which(*present):
        def which(name):
            return f"/usr/bin/{name}" if name in present else None

        return which

    def _argv(self, monkeypatch, popen_spy, *, platform, present):
        monkeypatch.setattr(ffmpeg_runner.sys, "platform", platform)
        monkeypatch.setattr(ffmpeg_runner.shutil, "which", self._which("ffmpeg", *present))
        # These tests build the prefix only: an ionice that is present can set
        # the priority here (whether it can is checked once, tested below).
        monkeypatch.setattr(ffmpeg_runner, "_ionice_usable", lambda path: True, raising=False)
        # The spy starts the real process, so the fake /usr/bin/ionice path
        # must not be executed: stop at the Popen call.
        def refuse(cmd, **kwargs):
            popen_spy.append({"cmd": list(cmd), "kwargs": kwargs})
            raise FileNotFoundError(cmd[0])

        monkeypatch.setattr(ffmpeg_runner.subprocess, "Popen", refuse)
        with pytest.raises(FfmpegError):
            run_capture(["ffmpeg", "-version"], timeout_s=5, max_stdout_bytes=64,
                options=ToolOptions(low_priority=True))
        assert "preexec_fn" not in popen_spy[-1]["kwargs"] or popen_spy[-1]["kwargs"]["preexec_fn"] is None
        return popen_spy[-1]["cmd"]

    def test_macos_prefixes_nice_only(self, monkeypatch, popen_spy):
        argv = self._argv(monkeypatch, popen_spy, platform="darwin", present=("nice", "ionice"))
        assert argv == ["/usr/bin/nice", "-n", "10", "ffmpeg", "-version"]

    def test_linux_with_ionice_prefixes_both(self, monkeypatch, popen_spy):
        argv = self._argv(monkeypatch, popen_spy, platform="linux", present=("nice", "ionice"))
        assert argv == ["/usr/bin/nice", "-n", "10", "/usr/bin/ionice", "-c3", "ffmpeg", "-version"]

    def test_linux_without_ionice_prefixes_nice_only(self, monkeypatch, popen_spy):
        argv = self._argv(monkeypatch, popen_spy, platform="linux", present=("nice",))
        assert argv == ["/usr/bin/nice", "-n", "10", "ffmpeg", "-version"]

    def test_without_nice_the_command_runs_unprefixed(self, monkeypatch, popen_spy):
        argv = self._argv(monkeypatch, popen_spy, platform="linux", present=("ionice",))
        assert argv == ["/usr/bin/ionice", "-c3", "ffmpeg", "-version"]
        argv = self._argv(monkeypatch, popen_spy, platform="darwin", present=())
        assert argv == ["ffmpeg", "-version"]

    def test_missing_tool_message_names_the_tool_not_the_prefix(self, monkeypatch, popen_spy):
        # With a prefix, ``nice`` itself would start and exit 127; the tool
        # must still be reported as missing, before anything is started.
        monkeypatch.setattr(ffmpeg_runner.shutil, "which", self._which("nice"))
        with pytest.raises(FfmpegError) as exc_info:
            run_capture(["/nonexistent/ffmpeg-xyz"], timeout_s=5, max_stdout_bytes=16,
                options=ToolOptions(low_priority=True))
        assert "ffmpeg-xyz" in str(exc_info.value) and "not found" in str(exc_info.value)
        assert popen_spy == []

    @staticmethod
    def _fake_ionice(home, *, refuse, real_check=True):
        """An ionice that records each call. Refusing, it answers like util-linux
        where the system refuses ioprio_set (some containers): a message and
        exit 1, without starting the command. Otherwise it starts the command;
        with ``real_check=False`` it answers the server's check (the do-nothing
        Python) with exit 0 instead of starting an interpreter for it. The
        script is the module's one ``ionice_home`` script; this sets its mode
        and empties its record."""
        mode = "refuse" if refuse else ("run" if real_check else "answer-check")
        (home / "mode").write_text(mode + "\n")
        calls = home / "calls"
        calls.unlink(missing_ok=True)
        return home / "ionice", calls

    @staticmethod
    def _on_linux_with(monkeypatch, ionice):
        real_which = shutil.which
        monkeypatch.setattr(ffmpeg_runner.sys, "platform", "linux")
        monkeypatch.setattr(ffmpeg_runner.shutil, "which",
                            lambda name: str(ionice) if name == "ionice" else real_which(name))
        monkeypatch.setattr(ffmpeg_runner, "_IONICE_USABLE", {}, raising=False)  # nothing known yet
        # Nor a wait left by another test's unanswered check (the path is shared).
        monkeypatch.setattr(ffmpeg_runner, "_IONICE_RECHECK_AT", {}, raising=False)

    # A tiny real program: what is under test is the argv and how often the
    # check runs, not the tool, so no interpreter is started for it.
    _TOOL = [shutil.which("echo") or "/bin/echo", "ran"]

    @classmethod
    def _low_priority_run(cls):
        return run_capture(list(cls._TOOL), timeout_s=10, max_stdout_bytes=64,
                           options=ToolOptions(low_priority=True))

    @classmethod
    def _ran_the_tool(cls, line):
        return line.endswith(" ".join(cls._TOOL))

    def test_where_the_priority_is_refused_the_tool_runs_without_ionice(self, monkeypatch, ionice_home, caplog):
        ionice, calls = self._fake_ionice(ionice_home, refuse=True)
        self._on_linux_with(monkeypatch, ionice)
        caplog.set_level("INFO", logger=ffmpeg_runner.__name__)

        results = [self._low_priority_run() for _ in range(2)]

        # Not a failed tool (exit 1 read as a decode error), and asked only once.
        assert [(r.returncode, r.stdout) for r in results] == [(0, b"ran\n")] * 2
        assert len(calls.read_text().splitlines()) == 1
        [record] = [r for r in caplog.records if r.name == ffmpeg_runner.__name__]
        assert "ionice" in record.getMessage() and str(ionice_home) not in record.getMessage()

    def test_where_ionice_works_every_low_priority_tool_runs_through_it(self, monkeypatch, ionice_home):
        ionice, calls = self._fake_ionice(ionice_home, refuse=False)
        self._on_linux_with(monkeypatch, ionice)

        results = [self._low_priority_run() for _ in range(2)]

        assert [(r.returncode, r.stdout) for r in results] == [(0, b"ran\n")] * 2
        lines = calls.read_text().splitlines()
        assert len(lines) == 3  # one check, then both runs
        assert all(line.startswith("-c3 ") and self._ran_the_tool(line) for line in lines[1:])

    # The check's own start is ``subprocess.run``; the tool's is ``Popen``. Each
    # case makes the first check end one way, lets later checks start the fake
    # ionice for real (which answers the check without starting an
    # interpreter), and counts the checks.
    _FIRST_CHECK = {
        "timed-out": subprocess.TimeoutExpired(["ionice"], 10),
        "EAGAIN": OSError(errno.EAGAIN, "Resource temporarily unavailable"),
        "EMFILE": OSError(errno.EMFILE, "Too many open files"),
        "ENOENT": FileNotFoundError(errno.ENOENT, "No such file or directory"),
        "EACCES": PermissionError(errno.EACCES, "Permission denied"),
    }

    def _runs_after_a_first_check(self, monkeypatch, ionice_home, caplog, case, at):
        """One low-priority run at each monotonic time in ``at``; the first check
        ends as ``case``, later checks start the working fake, which answers them."""
        ionice, calls = self._fake_ionice(ionice_home, refuse=False, real_check=False)
        self._on_linux_with(monkeypatch, ionice)
        caplog.set_level("INFO", logger=ffmpeg_runner.__name__)
        now = [0.0]
        monkeypatch.setattr(ffmpeg_runner, "_ionice_clock", lambda: now[0], raising=False)
        monkeypatch.setattr(ffmpeg_runner, "_IONICE_RECHECK_AT", {}, raising=False)
        real_run = subprocess.run
        checks = []

        def run(cmd, *args, **kwargs):
            checks.append(now[0])
            if len(checks) == 1:
                raise self._FIRST_CHECK[case]
            return real_run(cmd, *args, **kwargs)

        monkeypatch.setattr(ffmpeg_runner.subprocess, "run", run)
        results = []
        for t in at:
            now[0] = t
            results.append(self._low_priority_run())
        through_ionice = [line for line in calls.read_text().splitlines() if self._ran_the_tool(line)] \
            if calls.exists() else []
        warnings = [r for r in caplog.records if r.name == ffmpeg_runner.__name__]
        return results, checks, len(through_ionice), warnings

    @pytest.mark.parametrize("case", ["timed-out", "EAGAIN", "EMFILE"])
    def test_a_check_that_gave_no_answer_waits_a_minute_before_the_next(self, monkeypatch, ionice_home, caplog, case):
        # 0 s: the check gives no answer, the tool runs without ionice. 30 s and
        # 59.9 s: inside the minute, no check, no ionice. 60 s: checked again, it
        # works. 61 s and an hour later: that definite answer is remembered.
        results, checks, through_ionice, warnings = self._runs_after_a_first_check(
            monkeypatch, ionice_home, caplog, case, at=[0.0, 30.0, 59.9, 60.0, 61.0, 3600.0])

        assert [(r.returncode, r.stdout) for r in results] == [(0, b"ran\n")] * 6
        assert checks == [0.0, 60.0]
        assert through_ionice == 3
        assert warnings == []

    @pytest.mark.parametrize("case", ["ENOENT", "EACCES"])
    def test_an_ionice_that_cannot_be_executed_is_remembered(self, monkeypatch, ionice_home, caplog, case):
        results, checks, through_ionice, warnings = self._runs_after_a_first_check(
            monkeypatch, ionice_home, caplog, case, at=[0.0, 30.0, 61.0, 3600.0])

        assert [(r.returncode, r.stdout) for r in results] == [(0, b"ran\n")] * 4
        assert (checks, through_ionice) == ([0.0], 0)
        [record] = warnings
        assert "ionice" in record.getMessage() and str(ionice_home) not in record.getMessage()

    @pytest.mark.skipif(shutil.which("nice") is None, reason="nice not available")
    @pytest.mark.integration
    def test_real_child_runs_ten_steps_nicer(self):
        parent = os.getpriority(os.PRIO_PROCESS, 0)
        result = run_capture(
            py("import os; print(os.getpriority(os.PRIO_PROCESS, 0))"),
            timeout_s=10,
            max_stdout_bytes=64,
            options=ToolOptions(low_priority=True),
        )
        assert result.returncode == 0
        assert int(result.stdout) == min(19, parent + 10)


class TestReviewFindings:
    """In-piece review (6.5A.2a-review.md) regressions."""

    @pytest.mark.integration
    def test_r1_grandchild_holding_stdout_is_killed_after_the_child_exits(self, tmp_path, monkeypatch):
        # The child exits at once, but a grandchild inherits its stdout and
        # keeps it open: no EOF, so the run times out, and the whole group
        # (the grandchild) must still be killed although the child is reaped.
        pid_file = tmp_path / "grandchild.pid"
        code = _spawn_grandchild_then(pid_file, "pass")
        monkeypatch.setattr(ffmpeg_runner, "time", _ReadinessClock(pid_file))
        with pytest.raises(CaptureTimeout):
            run_capture(py(code), timeout_s=1.0, max_stdout_bytes=64)
        assert _wait_gone(int(pid_file.read_text())), "grandchild outlived the timeout"

    def test_r2_registry_kill_tolerates_a_zombie_group(self, monkeypatch):
        # macOS: killpg on a group whose only member is an unreaped zombie
        # raises PermissionError; the kill must not raise (kill_all must not
        # stop partway).
        registry = FfmpegProcessRegistry()

        class Proc:
            pid = 4242

            def poll(self):
                return None

        registry.register("a", Proc())
        registry.register("b", Proc())
        calls = []

        def killpg(pid, sig):
            calls.append(pid)
            raise PermissionError(1, "Operation not permitted")

        monkeypatch.setattr(ffmpeg_runner.os, "killpg", killpg)
        assert registry.kill("a") is False
        registry.kill_all()
        assert len(calls) == 3
