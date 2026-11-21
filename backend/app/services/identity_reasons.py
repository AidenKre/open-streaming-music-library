"""The one failure vocabulary of the audio-identity layers.

The values are stored in ``track_audio_identity.failure_reason`` and must never
contain paths or tool output. This module also maps a failed tool capture to
one of those reasons, so every layer reports the same failure the same way.
"""

import signal
from typing import Optional

from app.services.ffmpeg_runner import (
    TOOL_CANNOT_RUN_EXITS,
    CaptureOverflow,
    CaptureTimeout,
    FfmpegError,
    describe_tool_error,
)

REASON_MASTER_MISSING = "master_missing"
REASON_TOOL_MISSING = "tool_missing"
REASON_TIMEOUT = "timeout"
REASON_DECODE_ERROR = "decode_error"
# A SIGKILL (registry/shutdown kill) is not a decode failure. The worker does
# not count ``killed`` as an attempt while it is stopping (its stop flag is set
# or its kill registry is closed); otherwise it does.
REASON_KILLED = "killed"
REASON_PROBE_ERROR = "probe_error"
REASON_OUTPUT_ERROR = "output_error"
REASON_INTERNAL_ERROR = "internal_error"
# "decoded but too short to print"; compute_fingerprint maps it to too_short.
REASON_EMPTY_FINGERPRINT = "empty_fingerprint"
# No duration from the tool, the track's known duration, nor the decoded
# duration (third source); the stored print needs duration_s > 0, and unknown
# is never 0.
REASON_DURATION_UNKNOWN = "duration_unknown"


class CaptureFailed(Exception):
    """Carries one of the fixed ``REASON_*`` constants (never tool output) and,
    when known, the tool's exit code."""

    def __init__(self, reason: str, returncode: Optional[int] = None):
        super().__init__(reason)
        self.reason = reason
        self.returncode = returncode


def reason_for_exit(returncode: int) -> str:
    """Reason for a non-zero tool exit: a SIGKILL is ``killed``, an exit that
    means the tool could not run is ``tool_missing``, anything else is a decode
    error."""
    if returncode == -signal.SIGKILL:
        return REASON_KILLED
    if returncode in TOOL_CANNOT_RUN_EXITS:
        return REASON_TOOL_MISSING
    return REASON_DECODE_ERROR


def reason_for_capture_exception(e: Exception) -> tuple[str, Optional[str], Optional[int]]:
    """``(reason, error type name or None, returncode or None)`` for an exception
    raised while capturing a tool's output. The type name is given only for
    exceptions the tool runner or Python raised, never for ``CaptureFailed``;
    a runner error's name carries its category (``FfmpegError (not found)``)."""
    if isinstance(e, CaptureFailed):
        return e.reason, None, e.returncode
    if isinstance(e, CaptureTimeout):
        return REASON_TIMEOUT, describe_tool_error(e), None
    if isinstance(e, CaptureOverflow):
        return REASON_OUTPUT_ERROR, describe_tool_error(e), None
    if isinstance(e, FfmpegError):
        return REASON_TOOL_MISSING, describe_tool_error(e), None
    return REASON_INTERNAL_ERROR, type(e).__name__, None


_CONTENT_FAILURES = frozenset(
    {REASON_DECODE_ERROR, REASON_PROBE_ERROR, REASON_OUTPUT_ERROR, REASON_MASTER_MISSING})


# Parsing values already read into memory from the stored row: no I/O, so the same
# row raises the same error at every start (never transient).
_STORED_DATA_FAILURES = (ValueError, KeyError, TypeError)


def is_stored_data_failure(e: BaseException) -> bool:
    """True when ``e`` is a deterministic error in a journal's own stored data;
    False for I/O, database, tool and any unrecognised error."""
    return isinstance(e, _STORED_DATA_FAILURES)


def is_content_failure(reason: Optional[str]) -> bool:
    """True when the reason says the file's own content is at fault; False for a
    failure of the tool or the run, and for None or any unknown reason."""
    return reason in _CONTENT_FAILURES
