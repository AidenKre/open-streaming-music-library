"""Shared ffmpeg invocation: one place for timeout, validation, and cleanup.

Both the tag writer and the transcoder used to hand-roll the same
run/validate/unlink-on-failure block — and had already diverged (the
transcoder had no timeout at all, so a hung ffmpeg wedged a transcode
forever, and it discarded stderr). Fixes here land for every caller.
"""

import subprocess
from pathlib import Path


class FfmpegError(Exception):
    """ffmpeg failed: missing binary, non-zero exit, timeout, or empty output.
    ``stderr`` carries the captured diagnostics (may be empty)."""

    def __init__(self, message: str, stderr: str = ""):
        self.stderr = stderr
        super().__init__(message)


def scaled_timeout(source: Path, floor_s: int = 30, cap_s: int = 600) -> int:
    """~1s per MB of ``source`` on top of a floor, capped: large lossless files
    don't trip a fixed timeout, and a hang can't wedge a request forever."""
    try:
        size_mb = source.stat().st_size / (1024 * 1024)
    except OSError:
        size_mb = 0
    return min(cap_s, floor_s + int(size_mb))


def run_ffmpeg(cmd: list[str], output_path: Path, timeout: float) -> None:
    """Run an ffmpeg command that produces ``output_path``.

    Validates the run (zero exit, output exists and is non-empty); on ANY
    failure the partial output is removed and ``FfmpegError`` is raised with
    stderr attached. The caller owns semantic verification (e.g. re-probing).
    """
    try:
        result = subprocess.run(
            cmd,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            check=False,
            timeout=timeout,
        )
    except FileNotFoundError as e:
        raise FfmpegError("ffmpeg not found") from e
    except (OSError, subprocess.TimeoutExpired) as e:
        output_path.unlink(missing_ok=True)
        raise FfmpegError(f"ffmpeg failed: {e}") from e

    if result.returncode != 0 or not output_path.exists() or output_path.stat().st_size == 0:
        output_path.unlink(missing_ok=True)
        stderr = result.stderr.decode("utf-8", errors="replace").strip()
        raise FfmpegError(f"ffmpeg exited {result.returncode}: {stderr}", stderr)
