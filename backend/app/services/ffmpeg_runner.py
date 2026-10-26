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
"""

import os
import signal
import subprocess
import threading
from pathlib import Path
from typing import Any, Optional


class FfmpegError(Exception):
    """ffmpeg failed: missing binary, non-zero exit, timeout, or empty output.
    ``stderr`` carries the captured diagnostics (may be empty)."""

    def __init__(self, message: str, stderr: str = ""):
        self.stderr = stderr
        super().__init__(message)


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

    def register(self, job_id: Any, proc: subprocess.Popen) -> None:
        with self._guard:
            self._procs[job_id] = proc
            if job_id in self._killed:
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
            for job_id, proc in self._procs.items():
                self._killed.add(job_id)
                self._kill_locked(proc)

    @staticmethod
    def _kill_locked(proc: subprocess.Popen) -> bool:
        # Checked under the guard so a process already reaped (whose pid may
        # have been reused) is never signalled. pgid == pid because the
        # child is started with start_new_session=True.
        if proc.poll() is not None:
            return False
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            return False
        return True


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
