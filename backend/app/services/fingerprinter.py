"""Phase 6.5 (spec §4): acoustic fingerprints.

Holds the Fingerprinter protocol and its result types, FpcalcFingerprinter,
``classify``, the stored blob format (little-endian uint32 sub-fingerprints),
and ``detect_fingerprinter`` (startup backend selection). No DB access: the
identity worker stores what this module computes.

The ``REASON_*`` failure vocabulary lives in ``app.services.identity_reasons``
(shared with ``audio_identity``) and is re-exported here.
"""

from __future__ import annotations

import json
import logging
import math
import os
import re
import shutil
import struct
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol, runtime_checkable

from app.config import Settings
from app.core.operator_log import operator_logger
from app.services.duplicate_detection import MatcherParams, coarse_diversity
from app.services.ffmpeg_runner import NO_OPTIONS, ToolOptions, run_capture
from app.services.media_input import fpcalc_input_args
from app.services.identity_reasons import (
    CaptureFailed,
    reason_for_capture_exception,
    reason_for_exit,
    REASON_DECODE_ERROR,
    REASON_EMPTY_FINGERPRINT,
    REASON_INTERNAL_ERROR,
    REASON_KILLED,
    REASON_MASTER_MISSING,
    REASON_OUTPUT_ERROR,
    REASON_PROBE_ERROR,
    REASON_TIMEOUT,
    REASON_TOOL_MISSING,
)

logger = logging.getLogger(__name__)

# Spec 4.1: only the first 120 s are fingerprinted.
FINGERPRINT_SECONDS = 120
# Upper bound on items in one print: 16 items/s (about twice the nominal
# ~8.1/s), so a stored blob is at most 7680 bytes.
MAX_FINGERPRINT_ITEMS = FINGERPRINT_SECONDS * 16


@dataclass(frozen=True)
class RawFingerprint:
    """uint32 sub-fingerprints from the first FINGERPRINT_SECONDS; duration_s is the
    decoded full-track duration reported by the tool (> 0), or None when the
    tool did not know it (it prints 0)."""

    items: tuple[int, ...]
    duration_s: float | None


@dataclass(frozen=True)
class FingerprintFailure:
    """A failed fingerprint run; reason is one of the fixed REASON_* values."""

    reason: str


def pack_fingerprint(items) -> bytes:
    """Pack items as little-endian uint32s; ValueError if out of range or too many."""
    items = tuple(items)
    if len(items) > MAX_FINGERPRINT_ITEMS:
        raise ValueError(f"too many fingerprint items: {len(items)}")
    try:
        return struct.pack(f"<{len(items)}I", *items)
    except struct.error as exc:
        raise ValueError(f"fingerprint item out of uint32 range: {exc}") from exc


def unpack_fingerprint(blob: bytes) -> tuple[int, ...]:
    """Inverse of pack_fingerprint; ValueError on a bad length or too many items."""
    if len(blob) % 4:
        raise ValueError(f"fingerprint blob length {len(blob)} is not a multiple of 4")
    n = len(blob) // 4
    if n > MAX_FINGERPRINT_ITEMS:
        raise ValueError(f"too many fingerprint items: {n}")
    return struct.unpack(f"<{n}I", blob)


FP_TOO_SHORT = "too_short"
FP_LOW_INFORMATION = "low_information"
FP_CURRENT = "current"


def classify(raw: RawFingerprint, params: MatcherParams) -> str:
    """Classify a print: too_short, then low_information, else current.

    Both thresholds are strict (below). An unknown diversity (empty print) is
    too short, never treated as 0.
    """
    if len(raw.items) < params.min_items:
        return FP_TOO_SHORT
    diversity = coarse_diversity(raw.items)
    if diversity is None:
        return FP_TOO_SHORT
    if diversity < params.min_diversity:
        return FP_LOW_INFORMATION
    return FP_CURRENT


@runtime_checkable
class Fingerprinter(Protocol):
    """A fingerprint backend: turns an audio file into a RawFingerprint or a failure."""

    name: str
    algorithm: str
    tool_version: str

    def fingerprint(self, path: Path, *, max_seconds: int = FINGERPRINT_SECONDS,
                    options: ToolOptions = NO_OPTIONS) -> RawFingerprint | FingerprintFailure: ...


# Widest JSON print: MAX_FINGERPRINT_ITEMS items of 10 digits plus ", ", and
# room for the duration and keys. Well under 256 KiB.
FPCALC_ALGORITHM = 2
FPCALC_MAX_STDOUT_BYTES = MAX_FINGERPRINT_ITEMS * 12 + 1024


def _parse(stdout: bytes) -> RawFingerprint:
    """Parse fpcalc -raw -json output.

    Raises CaptureFailed(output_error) for any malformed output, or
    CaptureFailed(empty_fingerprint) for a clean but empty print.
    """
    try:
        data = json.loads(stdout.decode("utf-8"))
        raw_items = data["fingerprint"]
        duration = data["duration"]
    except (ValueError, TypeError, KeyError, RecursionError):  # deep nesting recurses
        raise CaptureFailed(REASON_OUTPUT_ERROR) from None
    if not isinstance(raw_items, list):
        raise CaptureFailed(REASON_OUTPUT_ERROR)
    if len(raw_items) > MAX_FINGERPRINT_ITEMS:
        raise CaptureFailed(REASON_OUTPUT_ERROR)
    items = []
    for v in raw_items:
        if type(v) is not int or not -(2**31) <= v <= 2**32 - 1:
            raise CaptureFailed(REASON_OUTPUT_ERROR)
        items.append(v & 0xFFFFFFFF)
    if type(duration) not in (int, float):
        raise CaptureFailed(REASON_OUTPUT_ERROR)
    try:
        duration = float(duration)  # a huge JSON int raises OverflowError
    except OverflowError:
        raise CaptureFailed(REASON_OUTPUT_ERROR) from None
    if not math.isfinite(duration) or duration < 0:
        raise CaptureFailed(REASON_OUTPUT_ERROR)
    duration_s = duration if duration > 0 else None  # 0 (or -0.0) means unknown
    if not items:
        raise CaptureFailed(REASON_EMPTY_FINGERPRINT)
    return RawFingerprint(items=tuple(items), duration_s=duration_s)


_EMPTY_FINGERPRINT_STDERR = ["ERROR: Empty fingerprint"]


def _exit_reason(returncode: int, stderr: str) -> str:
    """Reason for a non-zero exit. stderr is only matched against fixed text."""
    reason = reason_for_exit(returncode)
    if reason != REASON_DECODE_ERROR:
        return reason
    lines = [ln.strip() for ln in stderr.splitlines()]
    if [ln for ln in lines if ln.startswith("ERROR:")] == _EMPTY_FINGERPRINT_STDERR:
        return REASON_EMPTY_FINGERPRINT
    return REASON_DECODE_ERROR


class FpcalcFingerprinter:
    """Chromaprint via the fpcalc executable (`fpcalc -raw -json -length N SRC`)."""

    name = "fpcalc"
    # fpcalc numbers algorithms from 1; 2 is its default, passed explicitly so
    # the stored label is a guarantee, not an assumption.
    algorithm = f"chromaprint-{FPCALC_ALGORITHM}"

    def __init__(self, executable: str, tool_version: str, *, timeout_s: float):
        self.executable = executable
        self.tool_version = tool_version
        self.timeout_s = timeout_s

    def fingerprint(self, path, *, max_seconds=FINGERPRINT_SECONDS, options=NO_OPTIONS):
        """Never raises; returns a RawFingerprint or a FingerprintFailure.

        Failure reasons: master_missing, tool_missing, timeout, killed,
        decode_error, empty_fingerprint, output_error, internal_error.
        ``max_seconds`` must be in 1..FINGERPRINT_SECONDS (the item cap is sized
        for it); otherwise internal_error without running anything.
        """
        reason = None
        returncode = None
        error_type = None
        try:
            if not 1 <= max_seconds <= FINGERPRINT_SECONDS:
                reason = REASON_INTERNAL_ERROR
            elif not Path(path).is_file():
                reason = REASON_MASTER_MISSING
            else:
                # Absolute so a file named "-length.flac" is never read as an option.
                cmd = [self.executable, "-raw", "-json", "-algorithm", str(FPCALC_ALGORITHM), "-length", str(max_seconds),
                       *fpcalc_input_args(options.input_format), str(Path(path).absolute())]
                result = run_capture(
                    cmd,
                    timeout_s=self.timeout_s,
                    max_stdout_bytes=FPCALC_MAX_STDOUT_BYTES,
                    options=options,
                )
                returncode = result.returncode
                if returncode != 0:
                    reason = _exit_reason(returncode, result.stderr)
                else:
                    return _parse(result.stdout)
        except Exception as e:
            reason, error_type, _ = reason_for_capture_exception(e)
        # Fixed reason and the exception TYPE only: never the path or tool output.
        logger.warning(
            "fingerprint failed: reason=%s backend=fpcalc returncode=%s error=%s",
            reason, returncode, error_type,
        )
        return FingerprintFailure(reason)


# Spec 4.1: minimum supported fpcalc (Chromaprint) version.
MIN_FPCALC_VERSION = (1, 5)

_VERSION_TIMEOUT_S = 10
_VERSION_MAX_STDOUT_BYTES = 16 * 1024
_VERSION_RE = re.compile(r"fpcalc version (\d+\.\d+(?:\.\d+)?)")


def probe_fpcalc_version(executable: str) -> str | None:
    """Return the numeric fpcalc version (e.g. "1.6.2"), or None if unknown.

    Never raises. Only the matched numeric part is kept, so no tool output is
    ever stored.
    """
    try:
        result = run_capture(
            [executable, "-version"],
            timeout_s=_VERSION_TIMEOUT_S,
            max_stdout_bytes=_VERSION_MAX_STDOUT_BYTES,
        )
        if result.returncode != 0:
            return None
        lines = result.stdout.decode("utf-8", errors="replace").splitlines()
        match = _VERSION_RE.match(lines[0]) if lines else None
        return match.group(1) if match else None
    except Exception as e:
        logger.debug("fpcalc version probe failed: error=%s", type(e).__name__)
        return None


def fpcalc_version_supported(version: str) -> bool:
    """True if ``version`` (major.minor[.patch], digits only) is >= MIN_FPCALC_VERSION."""
    parts = version.split(".")
    if len(parts) < 2 or not all(p.isascii() and p.isdigit() for p in parts):
        return False
    return tuple(int(p) for p in parts) >= MIN_FPCALC_VERSION


def detect_fingerprinter(settings: Settings) -> Fingerprinter | None:
    """Pick the fingerprint backend once at startup; None means no fingerprinting.

    Order: "off" -> None; "ffmpeg" -> None (that backend is not built; no fallback);
    "auto"/"fpcalc" -> FPCALC_PATH if set (no PATH fallback), else fpcalc on
    PATH, then the version must be readable and >= MIN_FPCALC_VERSION. The
    result is logged, never the executable path. The app's startup
    stores it on ``app.state.fingerprinter``.
    """
    mode = settings.audio_fingerprint_backend
    if mode == "off":
        logger.info("audio fingerprinting is off")
        return None
    if mode == "ffmpeg":
        logger.warning("the ffmpeg fingerprint backend is not supported in this build; fingerprinting disabled")
        return None

    configured = settings.fpcalc_path
    if configured is not None:
        try:
            executable = configured.is_file() and os.access(configured, os.X_OK)
        except OSError:  # e.g. PermissionError under an unreadable directory
            executable = False
        if not executable:
            logger.warning("FPCALC_PATH is set but is not an executable file; fingerprinting disabled")
            return None
        exe = str(configured.absolute())
    else:
        found = shutil.which("fpcalc")
        exe = os.path.abspath(found) if found else None  # which() may return a relative path
        if exe is None:
            if mode == "auto":
                operator_logger.info("fingerprinting unavailable: fpcalc not found")
            else:
                logger.warning("fpcalc not found; fingerprinting disabled")
            return None

    version = probe_fpcalc_version(exe)
    if version is None:
        logger.warning("could not read the fpcalc version; fingerprinting disabled")
        return None
    if not fpcalc_version_supported(version):
        logger.warning(
            "fpcalc %s is older than the supported minimum %s; fingerprinting disabled",
            version, ".".join(map(str, MIN_FPCALC_VERSION)),
        )
        return None
    fingerprinter = FpcalcFingerprinter(exe, version, timeout_s=settings.fpcalc_timeout_s)
    logger.info("fingerprinter: %s %s (%s)", fingerprinter.name, version, fingerprinter.algorithm)
    return fingerprinter
