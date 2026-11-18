"""Shared ffmpeg invocation: one place for timeout, validation, and cleanup.

Both the tag writer and the transcoder used to hand-roll the same
run/validate/unlink-on-failure block — and had already diverged (the
transcoder had no timeout at all, so a hung ffmpeg wedged a transcode
forever, and it discarded stderr). Fixes here land for every caller.

Runs via ``Popen`` (not the simpler blocking ``subprocess.run``) so a caller
that passes ``registry``/``job_id`` can cancel a running invocation from
another thread — this is what Phase 2's conversion cancellation is built on.
Every other caller (the tag writer, the streaming transcoder) omits those
two arguments and sees identical externally-observable behavior to before.

``run_capture`` is the sibling for commands whose stdout IS the result
(``-f hash -``, ``fpcalc -json``): bounded stdout capture, a hard timeout and
the same process-group kill/registry semantics.
"""

import os
import re
import selectors
import shutil
import signal
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Optional


# Exit codes `nice` returns when it cannot exec the tool: 126 not executable, 127 not found.
TOOL_CANNOT_RUN_EXITS = frozenset({126, 127})


class FfmpegError(Exception):
    """ffmpeg failed: missing binary, non-zero exit, timeout, or empty output.
    ``stderr`` carries the captured diagnostics (may be empty)."""

    def __init__(self, message: str, stderr: str = ""):
        self.stderr = stderr
        super().__init__(message)


def _kill_group(proc: subprocess.Popen) -> bool:
    # A process already reaped (whose pid may have been reused) is never
    # signalled. pgid == pid because the child is started with
    # start_new_session=True.
    if proc.poll() is not None:
        return False
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        # PermissionError: on macOS a group whose only member is an unreaped
        # zombie refuses the signal.
        return False
    return True


class FfmpegProcessRegistry:
    """``job_id -> Popen`` so a running ffmpeg subprocess can be killed from
    another thread. Unlike ``KeyedLocks``' never-delete pattern, entries here
    ARE removed once the process finishes — job ids are unbounded over time,
    unlike the bounded uuid/quality key space ``KeyedLocks`` was designed for.
    """

    def __init__(self) -> None:
        self._procs: dict[Any, subprocess.Popen] = {}
        # Jobs killed while no process was registered (between two ffmpeg
        # steps, or before the first one started): any process registered
        # for them later is killed on arrival. Cleared via forget().
        self._killed: set[Any] = set()
        self._guard = threading.Lock()
        self._closed = False

    @property
    def closed(self) -> bool:
        return self._closed

    def register(self, job_id: Any, proc: subprocess.Popen) -> None:
        with self._guard:
            self._procs[job_id] = proc
            if self._closed or job_id in self._killed:
                self._kill_locked(proc)

    def discard(self, job_id: Any) -> None:
        with self._guard:
            self._procs.pop(job_id, None)

    def forget(self, job_id: Any) -> None:
        """Drop all state for a finished job (its kill flag included)."""
        with self._guard:
            self._procs.pop(job_id, None)
            self._killed.discard(job_id)

    def kill(self, job_id: Any) -> bool:
        """Kill ``job_id``'s running ffmpeg process group, and any it starts
        later until ``forget(job_id)``. Returns whether a live process was
        killed right now."""
        with self._guard:
            self._killed.add(job_id)
            proc = self._procs.get(job_id)
            if proc is None:
                return False
            return self._kill_locked(proc)

    def kill_all(self) -> None:
        with self._guard:
            self._kill_all_locked()

    def close(self) -> None:
        """Kill everything registered and any process registered afterwards."""
        with self._guard:
            self._closed = True
            self._kill_all_locked()

    def _kill_all_locked(self) -> None:
        for job_id, proc in self._procs.items():
            self._killed.add(job_id)
            self._kill_locked(proc)

    @staticmethod
    def _kill_locked(proc: subprocess.Popen) -> bool:
        return _kill_group(proc)


def kill_orphaned_ffmpeg(work_dir: Path) -> list[int]:
    """Startup: SIGKILL any ffmpeg still writing into ``work_dir``; returns
    the pids killed.

    ``run_ffmpeg`` starts each ffmpeg in its own session so a cancel can kill
    its process group -- which also means a hard-killed server (SIGKILL, OOM
    kill) leaves them running, burning CPU on temps the startup sweep is
    about to delete. A process matches only if its binary is ffmpeg AND its
    command line names a path inside ``work_dir``, so nothing else is
    touched. Must run before this server starts any ffmpeg of its own there.
    Best-effort: returns [] where processes can't be listed.
    """
    # Absolute prefixes only, and only at the start of the command line or an
    # argument (after whitespace, "=" or a "file:"-style colon), so another
    # server's path that merely contains ours never matches.
    prefixes = {str(work_dir.absolute()) + os.sep, str(work_dir.resolve()) + os.sep}
    matcher = re.compile(
        r"(?:^|(?<=[\s=:]))(?:" + "|".join(re.escape(p) for p in prefixes) + ")"
    )
    killed = []
    for pid, argv0, cmdline in _list_processes():
        if pid == os.getpid() or not os.path.basename(argv0).startswith("ffmpeg"):
            continue
        if not matcher.search(cmdline):
            continue
        try:
            # Our ffmpegs lead their own process group (start_new_session).
            if os.getpgid(pid) == pid:
                os.killpg(pid, signal.SIGKILL)
            else:
                os.kill(pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            continue
        killed.append(pid)
    return killed


def _list_processes() -> list[tuple[int, str, str]]:
    """``(pid, argv[0], full command line)`` for every visible process."""
    proc_root = Path("/proc")
    if proc_root.is_dir():  # Linux: no external tools needed (slim images lack ps)
        procs = []
        for entry in proc_root.iterdir():
            if not entry.name.isdigit():
                continue
            try:
                raw = (entry / "cmdline").read_bytes()
            except OSError:
                continue
            args = [a.decode("utf-8", errors="replace") for a in raw.split(b"\0") if a]
            if args:
                procs.append((int(entry.name), args[0], " ".join(args)))
        return procs
    try:
        result = subprocess.run(
            ["ps", "-axww", "-o", "pid=,args="],
            capture_output=True, text=True, timeout=10, check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return []
    procs = []
    for line in result.stdout.splitlines():
        pid_str, _, cmdline = line.strip().partition(" ")
        cmdline = cmdline.strip()
        if pid_str.isdigit() and cmdline:
            # ps joins argv with spaces, so argv[0] is only recoverable up to
            # its first space -- fine for an ffmpeg binary path.
            procs.append((int(pid_str), cmdline.split(" ", 1)[0], cmdline))
    return procs


def scaled_timeout(source: Path, floor_s: int = 30, cap_s: int = 600) -> int:
    """~1s per MB of ``source`` on top of a floor, capped: large lossless files
    don't trip a fixed timeout, and a hang can't wedge a request forever."""
    try:
        size_mb = source.stat().st_size / (1024 * 1024)
    except OSError:
        size_mb = 0
    return min(cap_s, floor_s + int(size_mb))


def run_ffmpeg(
    cmd: list[str],
    output_path: Path,
    timeout: float,
    registry: Optional[FfmpegProcessRegistry] = None,
    job_id: Optional[Any] = None,
) -> None:
    """Run an ffmpeg command that produces ``output_path``.

    Validates the run (zero exit, output exists and is non-empty); on ANY
    failure the partial output is removed and ``FfmpegError`` is raised with
    stderr attached. The caller owns semantic verification (e.g. re-probing).

    When both ``registry`` and ``job_id`` are given, the process is
    registered for the duration of the call so ``registry.kill(job_id)`` from
    another thread can interrupt it — a killed process surfaces as a non-zero
    exit here, same code path as any other ffmpeg failure.
    """
    try:
        # start_new_session=True makes this process its own process-group
        # leader, so a cancel can kill the whole group, not just ffmpeg
        # itself (relevant if ffmpeg forks helpers).
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
    except FileNotFoundError as e:
        raise FfmpegError("ffmpeg not found") from e
    except OSError as e:
        raise FfmpegError(f"ffmpeg failed: {e}") from e

    if registry is not None and job_id is not None:
        registry.register(job_id, proc)
    try:
        try:
            _, stderr_bytes = proc.communicate(timeout=timeout)
        except subprocess.TimeoutExpired as e:
            # Popen.communicate(timeout=...), unlike subprocess.run, does NOT
            # kill the child on timeout -- that must be done explicitly, or
            # the process leaks and the temp file may still be mid-write.
            proc.kill()
            proc.communicate()
            output_path.unlink(missing_ok=True)
            raise FfmpegError(f"ffmpeg failed: {e}") from e
        except BaseException:
            proc.kill()
            proc.wait()
            output_path.unlink(missing_ok=True)
            raise
    finally:
        if registry is not None and job_id is not None:
            registry.discard(job_id)

    if proc.returncode != 0 or not output_path.exists() or output_path.stat().st_size == 0:
        output_path.unlink(missing_ok=True)
        stderr = (stderr_bytes or b"").decode("utf-8", errors="replace").strip()
        raise FfmpegError(f"ffmpeg exited {proc.returncode}: {stderr}", stderr)


@dataclass(frozen=True)
class CaptureResult:
    """A finished ``run_capture`` process: exit status (negative = killed by
    that signal), captured stdout bytes and (bounded) stderr text."""

    returncode: int
    stdout: bytes
    stderr: str


class CaptureTimeout(FfmpegError):
    """``run_capture``: the process outlived ``timeout_s`` and was killed."""


class CaptureOverflow(FfmpegError):
    """``run_capture``: stdout exceeded ``max_stdout_bytes``; the process was killed."""


_STDERR_KEEP_BYTES = 64 * 1024
_READ_CHUNK = 64 * 1024


def _low_priority_prefix() -> list[str]:
    """``nice -n 10`` (plus ``ionice -c3`` on Linux) for whichever tools
    exist. A command prefix, never ``preexec_fn`` (unsafe in a multithreaded
    server)."""
    prefix: list[str] = []
    nice = shutil.which("nice")
    if nice:
        prefix += [nice, "-n", "10"]
    if sys.platform.startswith("linux"):
        ionice = shutil.which("ionice")
        if ionice:
            prefix += [ionice, "-c3"]
    return prefix


def run_capture(
    cmd: list[str],
    *,
    timeout_s: float,
    registry: Optional[FfmpegProcessRegistry] = None,
    job_id: Optional[Any] = None,
    max_stdout_bytes: int,
    low_priority: bool = False,
) -> CaptureResult:
    """Run ``cmd`` and capture its stdout (bounded) and stderr (first 64 KiB).

    stdout and stderr are drained concurrently on one thread, so a child that
    floods either pipe cannot deadlock. Raises ``CaptureOverflow`` if stdout
    exceeds ``max_stdout_bytes`` and ``CaptureTimeout`` if the process outlives
    ``timeout_s``; in both cases (and on any other exception) the process
    group is SIGKILLed and reaped and both pipes are closed. A non-zero or
    signal exit is RETURNED in ``CaptureResult.returncode``, not raised.

    ``registry``/``job_id`` behave as in ``run_ffmpeg``: ``registry.kill`` from
    another thread kills the group and the run returns with ``-SIGKILL``.

    ``low_priority`` prefixes the command with ``nice -n 10`` (and ``ionice
    -c3`` on Linux) when those tools exist. The target tool is resolved first,
    so a missing tool is reported as "not found" rather than as ``nice``
    exiting 127.
    """
    argv = cmd
    if low_priority:
        prefix = _low_priority_prefix()
        if prefix:
            if shutil.which(cmd[0]) is None:
                raise FfmpegError(f"{os.path.basename(cmd[0])} not found")
            argv = prefix + cmd
    try:
        proc = subprocess.Popen(
            argv,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
    except FileNotFoundError as e:
        raise FfmpegError(f"{os.path.basename(cmd[0])} not found") from e
    except OSError as e:
        raise FfmpegError(f"{os.path.basename(cmd[0])} failed to start: {e.strerror or type(e).__name__}") from e

    deadline = time.monotonic() + timeout_s
    use_registry = registry is not None and job_id is not None
    out_chunks: list[bytes] = []
    out_total = 0
    err_chunks: list[bytes] = []
    err_kept = 0
    sel = selectors.DefaultSelector()
    finished = False
    try:
        if use_registry:
            registry.register(job_id, proc)
        for pipe in (proc.stdout, proc.stderr):
            os.set_blocking(pipe.fileno(), False)
            sel.register(pipe, selectors.EVENT_READ)
        while sel.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise CaptureTimeout(f"{os.path.basename(cmd[0])} timed out after {timeout_s}s")
            for key, _ in sel.select(remaining):
                try:
                    data = os.read(key.fd, _READ_CHUNK)
                except BlockingIOError:
                    continue
                if not data:
                    sel.unregister(key.fileobj)
                    continue
                if key.fileobj is proc.stdout:
                    out_total += len(data)
                    if out_total > max_stdout_bytes:
                        raise CaptureOverflow(
                            f"{os.path.basename(cmd[0])} stdout exceeded {max_stdout_bytes} bytes"
                        )
                    out_chunks.append(data)
                elif err_kept < _STDERR_KEEP_BYTES:
                    keep = data[: _STDERR_KEEP_BYTES - err_kept]
                    err_chunks.append(keep)
                    err_kept += len(keep)
        try:
            proc.wait(timeout=max(0.0, deadline - time.monotonic()))
        except subprocess.TimeoutExpired as e:
            raise CaptureTimeout(f"{os.path.basename(cmd[0])} timed out after {timeout_s}s") from e
        finished = True
        return CaptureResult(
            returncode=proc.returncode,
            stdout=b"".join(out_chunks),
            stderr=b"".join(err_chunks).decode("utf-8", errors="replace"),
        )
    finally:
        try:
            if not finished:
                # Abnormal exit: also kill any grandchild still holding the
                # group (even if the leader already exited and was reaped;
                # the pgid cannot be reused while a member exists).
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except (ProcessLookupError, PermissionError):
                    pass
            _kill_group(proc)
            proc.wait()
        finally:
            sel.close()
            for pipe in (proc.stdout, proc.stderr):
                if pipe is not None:
                    pipe.close()
            if use_registry:
                registry.discard(job_id)
