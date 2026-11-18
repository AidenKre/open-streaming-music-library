"""Phase 6.5 (SC-25): the audio identity model. Spec §3 exact audio hash."""

from __future__ import annotations

import hashlib
import json
import logging
import math
import re
import time
import os
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING, Any, Mapping, Optional

from app.core.media_types import is_lossless, is_lossy
from app.services.ffmpeg_runner import (
    NO_OPTIONS,
    ToolOptions,
    run_capture,
    scaled_timeout,
)
from app.services.media_input import ffmpeg_input_args
from app.services.identity_reasons import (
    CaptureFailed,
    reason_for_capture_exception,
    reason_for_exit,
    REASON_DECODE_ERROR,
    REASON_DURATION_UNKNOWN,
    REASON_EMPTY_FINGERPRINT,
    REASON_INTERNAL_ERROR,
    REASON_KILLED,
    REASON_MASTER_MISSING,
    REASON_OUTPUT_ERROR,
    REASON_PROBE_ERROR,
    REASON_TIMEOUT,
    REASON_TOOL_MISSING,
)

if TYPE_CHECKING:
    from app.services.duplicate_detection import MatcherParams
    from app.services.fingerprinter import Fingerprinter

logger = logging.getLogger(__name__)

KIND_PCM = "pcm_sha256"
KIND_PCM_FLOAT = "pcm_float_sha256"
KIND_PACKETS = "packets_sha256"

EXACT_KINDS = frozenset({KIND_PCM, KIND_PCM_FLOAT, KIND_PACKETS})
PCM_KINDS = frozenset({KIND_PCM, KIND_PCM_FLOAT})

# Float PCM is checked before the integer lossless set: pcm_f32le
# is also in LOSSLESS_CODECS, and pcm_f64le is in neither set.
FLOAT_PCM_CODECS = frozenset({"pcm_f32le", "pcm_f64le"})

PROBE_TIMEOUT_S = 30
PROBE_MAX_STDOUT_BYTES = 64 * 1024
HASH_MAX_STDOUT_BYTES = 4 * 1024
# ffmpeg's exit when the decode error rate passes -max_error_rate (check_strict_decode).
FFMPEG_ERROR_RATE_EXCEEDED_EXIT = 69
DECODE_PROGRESS_MAX_STDOUT_BYTES = 1024 * 1024
# Bump when the duration rule in compute_fingerprint changes, so prints that ended duration_unknown are retried.
FINGERPRINT_DURATION_RULE = "tool>track>decoded-1"

_SHA256_RE = re.compile(r"SHA256=([0-9a-fA-F]{64})")


@dataclass(frozen=True)
class ExactAudioHash:
    kind: str
    digest: str
    sample_rate_hz: Optional[int]
    channels: Optional[int]
    bits_per_sample: Optional[int]


@dataclass(frozen=True)
class ExactUnavailable:
    state: str
    reason: Optional[str]


def _positive_int(value: Any) -> Optional[int]:
    """Robust int parse ("44100", 44100, "N/A", 0, None); non-positive or
    unparseable is None (unknown is not zero)."""
    if isinstance(value, bool):
        return None
    try:
        n = int(str(value).strip())
    except (TypeError, ValueError):
        return None
    return n if n > 0 else None


def _probe(path: Path, options: ToolOptions) -> tuple[Optional[int], Optional[int], Optional[int]]:
    cmd = [
        "ffprobe", "-v", "error", "-select_streams", "a:0",
        "-show_entries", "stream=sample_rate,channels,bits_per_raw_sample,bits_per_sample",
        "-of", "json", *ffmpeg_input_args(options.input_format), str(path),
    ]
    result = run_capture(
        cmd, timeout_s=PROBE_TIMEOUT_S, max_stdout_bytes=PROBE_MAX_STDOUT_BYTES, options=options
    )
    if result.returncode != 0:
        raise CaptureFailed(reason_for_exit(result.returncode), result.returncode)
    try:
        streams = json.loads(result.stdout.decode("utf-8", errors="replace")).get("streams")
        stream = streams[0]
        if not isinstance(stream, dict):
            raise TypeError
    except (ValueError, AttributeError, TypeError, IndexError, KeyError):
        raise CaptureFailed(REASON_PROBE_ERROR) from None
    bits = _positive_int(stream.get("bits_per_raw_sample")) or _positive_int(stream.get("bits_per_sample"))
    return _positive_int(stream.get("sample_rate")), _positive_int(stream.get("channels")), bits


_EMPTY_SHA256 = hashlib.sha256(b"").hexdigest()


def compute_exact(
    path: Path,
    codec_hint: Optional[str],
    *,
    options: ToolOptions = NO_OPTIONS,
) -> ExactAudioHash | ExactUnavailable:
    """SHA-256 of the decoded audio (spec §3), or why that is unavailable.

    The kind comes from ``codec_hint`` alone, float first: ``pcm_f32le`` /
    ``pcm_f64le`` -> ``pcm_float_sha256`` (decoded as f64), then the integer
    lossless set -> ``pcm_sha256`` (decoded as s32), then the lossy set ->
    ``packets_sha256`` (stream copy). Anything else is ``unsupported`` and no
    process runs.

    Never raises (except ``BaseException`` such as ``KeyboardInterrupt``): a
    failure is returned as ``ExactUnavailable("failed", <fixed reason>)``,
    which callers treat as "exact layer pending", never an import failure.
    Reasons are fixed constants; paths, stderr and exception messages are
    never logged or returned.
    """
    if codec_hint in FLOAT_PCM_CODECS:
        kind, ffmpeg_codec = KIND_PCM_FLOAT, "pcm_f64le"
    elif codec_hint is not None and is_lossless(codec_hint):
        kind, ffmpeg_codec = KIND_PCM, "pcm_s32le"
    elif codec_hint is not None and is_lossy(codec_hint):
        kind, ffmpeg_codec = KIND_PACKETS, "copy"
    else:
        return ExactUnavailable("unsupported", None)

    returncode: Optional[int] = None
    error_type: Optional[str] = None
    try:
        if not path.is_file():
            raise CaptureFailed(REASON_MASTER_MISSING)
        rate, channels, bits = _probe(path, options)
        if kind == KIND_PACKETS:
            bits = None
        elif rate is None or channels is None:
            raise CaptureFailed(REASON_PROBE_ERROR)
        result = run_capture(
            ["ffmpeg", "-v", "error", *ffmpeg_input_args(options.input_format), "-i", str(path),
             "-map", "0:a:0", "-c:a", ffmpeg_codec, "-f", "hash", "-hash", "sha256", "-"],
            timeout_s=scaled_timeout(path),
            max_stdout_bytes=HASH_MAX_STDOUT_BYTES,
            options=options,
        )
        if result.returncode != 0:
            raise CaptureFailed(reason_for_exit(result.returncode), result.returncode)
        match = _SHA256_RE.fullmatch(result.stdout.decode("ascii", errors="replace").strip())
        if match is None:
            raise CaptureFailed(REASON_OUTPUT_ERROR, result.returncode)
        digest = match.group(1).lower()
        if digest == _EMPTY_SHA256:
            # No audio: nothing to hash, never an identity.
            raise CaptureFailed(REASON_DECODE_ERROR, result.returncode)
        return ExactAudioHash(kind, digest, rate, channels, bits)
    except Exception as e:
        reason, error_type, returncode = reason_for_capture_exception(e)
    logger.warning(
        "exact audio hash failed: reason=%s kind=%s codec=%s returncode=%s error=%s",
        reason, kind, codec_hint, returncode, error_type,
    )
    return ExactUnavailable("failed", reason)


def check_strict_decode(
    path: Path,
    *,
    options: ToolOptions = NO_OPTIONS,
    audio_end: Optional[int] = None,
) -> Optional[str]:
    """Decode the first audio stream once in strict mode, before a lossless
    conversion: None when it decodes cleanly, else one fixed ``REASON_*``
    (``decode_error`` means damaged audio).

    A default decode conceals damaged FLAC frames and exits 0 (so the exact
    hash does not notice); ``-err_detect crccheck+explode -max_error_rate 0``
    verifies the frame CRCs and exits 69 when any decode error occurred
    (ffmpeg 9.0.2). Only exit 69 means damaged audio. ``-xerror`` is not used:
    it also fails healthy files (a WAV written to a pipe). Any other non-zero
    exit (input not opened, a signal, a crash) is ``internal_error``, except
    ``killed`` and ``tool_missing``. Never raises (except ``BaseException``);
    paths, stderr and exception messages are never logged or returned.
    With ``audio_end``, only bytes ``[0, audio_end)`` of the file are decoded
    (ffmpeg's ``subfile`` protocol; see :func:`audio_end_without_trailer`), and
    a clean decode must also be as long as the FLAC STREAMINFO announces (when
    it states its total samples and rate): shorter means frames are missing
    (``decode_error``), no usable progress report is ``output_error``.
    """
    returncode: Optional[int] = None
    error_type: Optional[str] = None
    try:
        if not path.is_file():
            raise CaptureFailed(REASON_MASTER_MISSING)
        if audio_end is None:
            source, progress, max_stdout = str(path), [], HASH_MAX_STDOUT_BYTES
        else:
            source = f"subfile,,start,0,end,{audio_end},,:file:{path.resolve()}"
            progress = ["-progress", "pipe:1", "-nostats"]
            max_stdout = DECODE_PROGRESS_MAX_STDOUT_BYTES
        result = run_capture(
            ["ffmpeg", "-v", "error", "-nostdin", "-err_detect", "crccheck+explode",
             "-max_error_rate", "0", *progress, "-i", source, "-map", "0:a:0",
             "-f", "null", "-"],
            timeout_s=scaled_timeout(path),
            max_stdout_bytes=max_stdout,
            options=options,
        )
        if result.returncode == 0:
            if audio_end is not None:
                announced = _flac_streaminfo_length(path)
                if announced is not None:
                    total, rate = announced
                    out_us = _progress_end_out_time_us(result.stdout)
                    if out_us is None:
                        raise CaptureFailed(REASON_OUTPUT_ERROR, result.returncode)
                    if round(out_us * rate / 1_000_000) != total:
                        raise CaptureFailed(REASON_DECODE_ERROR, result.returncode)
            return None
        if result.returncode == FFMPEG_ERROR_RATE_EXCEEDED_EXIT:
            raise CaptureFailed(REASON_DECODE_ERROR, result.returncode)
        reason = reason_for_exit(result.returncode)
        if reason == REASON_DECODE_ERROR:
            reason = REASON_INTERNAL_ERROR
        raise CaptureFailed(reason, result.returncode)
    except Exception as e:
        reason, error_type, returncode = reason_for_capture_exception(e)
    logger.warning(
        "strict decode failed: reason=%s returncode=%s error=%s",
        reason, returncode, error_type,
    )
    return reason


def _flac_streaminfo_length(path: Path) -> Optional[tuple[int, int]]:
    """``(total_samples, sample_rate)`` from the FLAC STREAMINFO in the file's
    first 42 bytes, or None when there is none or it does not state both."""
    try:
        with path.open("rb") as f:
            head = f.read(42)
    except OSError:
        return None
    if (
        len(head) != 42 or head[:4] != b"fLaC" or head[4] & 0x7F != 0
        or int.from_bytes(head[5:8], "big") != 34
    ):
        return None
    packed = int.from_bytes(head[8 + 10:8 + 18], "big")
    rate = packed >> 44
    total = packed & ((1 << 36) - 1)
    return (total, rate) if total > 0 and rate > 0 else None


def _progress_end_out_time_us(stdout: bytes) -> Optional[int]:
    """The positive ``out_time_us`` of ffmpeg's ``progress=end`` report, else None."""
    out_time: Optional[str] = None
    for line in stdout.decode("utf-8", errors="replace").splitlines():
        key, sep, value = line.strip().partition("=")
        if not sep:
            continue
        if key == "out_time_us":
            out_time = value.strip()
        elif key == "progress":
            if value.strip() == "end":
                if out_time is not None and re.fullmatch(r"[0-9]+", out_time):
                    micros = int(out_time)
                    if micros > 0:
                        return micros
                return None
            out_time = None
    return None


TRAILING_PADDING_MAX_BYTES = 1024 * 1024
APE_TAG_MAX_BYTES = 16 * 1024 * 1024
_ID3V1_SIZE = 128
_APE_FOOTER_SIZE = 32
_APE_VERSIONS = (1000, 2000)
_APE_FLAG_HAS_HEADER = 1 << 31
_APE_FLAG_IS_HEADER = 1 << 29
_TRAILER_MAX_ROUNDS = 8
_PADDING_CHUNK_BYTES = 64 * 1024


def _id3v1_size(f: Any, end: int) -> Optional[int]:
    if end < _ID3V1_SIZE:
        return None
    f.seek(end - _ID3V1_SIZE)
    return _ID3V1_SIZE if f.read(3) == b"TAG" else None


def _apev2_size(f: Any, end: int) -> Optional[int]:
    if end < _APE_FOOTER_SIZE:
        return None
    f.seek(end - _APE_FOOTER_SIZE)
    footer = f.read(_APE_FOOTER_SIZE)
    if len(footer) != _APE_FOOTER_SIZE or not footer.startswith(b"APETAGEX"):
        return None
    version = int.from_bytes(footer[8:12], "little")
    size = int.from_bytes(footer[12:16], "little")
    item_count = int.from_bytes(footer[16:20], "little")
    flags = int.from_bytes(footer[20:24], "little")
    if (
        version not in _APE_VERSIONS or flags & _APE_FLAG_IS_HEADER
        or not _APE_FOOTER_SIZE <= size <= APE_TAG_MAX_BYTES
    ):
        return None
    total = size + _APE_FOOTER_SIZE if flags & _APE_FLAG_HAS_HEADER else size
    if total > end:
        return None
    if flags & _APE_FLAG_HAS_HEADER:
        f.seek(end - total)
        header = f.read(_APE_FOOTER_SIZE)
        if not header.startswith(b"APETAGEX") or header[8:20] != footer[8:20]:
            return None
    f.seek(end - size)
    items = f.read(size - _APE_FOOTER_SIZE)
    if len(items) != size - _APE_FOOTER_SIZE or not _ape_items_parse(items, item_count):
        return None
    return total


def _ape_items_parse(items: bytes, item_count: int) -> bool:
    """Whether ``items`` holds exactly ``item_count`` well-formed APEv2 items:
    value length (LE uint32), flags, a 2..255-byte printable ASCII key ended by
    NUL, then the value."""
    pos = 0
    for _ in range(item_count):
        if pos + 8 > len(items):
            return False
        value_len = int.from_bytes(items[pos:pos + 4], "little")
        key_start = pos + 8
        nul = items.find(b"\0", key_start, key_start + 256)
        if nul < 0:
            return False
        key = items[key_start:nul]
        if not 2 <= len(key) <= 255 or any(b < 0x20 or b > 0x7E for b in key):
            return False
        pos = nul + 1 + value_len
        if pos > len(items):
            return False
    return pos == len(items)


def _zero_padding_size(f: Any, end: int) -> Optional[int]:
    """Length of the trailing run of zero bytes before ``end`` (0 when none),
    or None when the run is longer than ``TRAILING_PADDING_MAX_BYTES``."""
    run = 0
    pos = end
    while pos > 0 and run <= TRAILING_PADDING_MAX_BYTES:
        start = max(0, pos - _PADDING_CHUNK_BYTES)
        f.seek(start)
        chunk = f.read(pos - start)
        stripped = chunk.rstrip(b"\0")
        run += len(chunk) - len(stripped)
        if stripped:
            break
        pos = start
    return run if run <= TRAILING_PADDING_MAX_BYTES else None


def _strip_trailers(path: Path) -> Optional[tuple[int, int]]:
    """``(end, last_zero_run)`` for :func:`audio_end_without_trailer`:
    ``last_zero_run`` is the length of the zero run when the last round that
    removed bytes was a zero-padding strip, else 0. None as that function."""
    last_zero_run = 0
    try:
        with path.open("rb") as f:
            size = os.fstat(f.fileno()).st_size
            end = size
            for _ in range(_TRAILER_MAX_ROUNDS):
                strip = _id3v1_size(f, end) or _apev2_size(f, end)
                zero_run = 0
                if strip is None:
                    strip = _zero_padding_size(f, end)
                    if strip is None:
                        return None
                    zero_run = strip
                if strip == 0:
                    break
                end -= strip
                last_zero_run = zero_run
                if end <= 0:
                    return None
    except OSError:
        return None
    return (end, last_zero_run) if end < size else None


def audio_end_without_trailer(path: Path) -> Optional[int]:
    """Byte length of ``path`` without the trailers it recognises, or None
    when none is recognised, nothing would be left, or the file cannot be read.

    ffmpeg's FLAC reader decodes to the end of the file, so a healthy FLAC with
    bytes after its last frame fails the strict decode. Stripped from the end,
    repeatedly (at most 8 rounds): an ID3v1 tag (the last 128 bytes start with
    ``TAG``), an APEv2 tag (a valid ``APETAGEX`` footer of at most
    ``APE_TAG_MAX_BYTES``, its header present and matching when flagged, and
    its items parsing exactly) and a run of zero padding of at most
    ``TRAILING_PADDING_MAX_BYTES`` (a longer run is not recognised: None).
    Not supported: Lyrics3 (written only by old MP3 taggers, and v1 has no
    length field), Enhanced TAG, and ID3v2 at the end (non-standard for FLAC).
    Reads only the tail in bounded chunks. Never raises.
    """
    stripped = _strip_trailers(path)
    return None if stripped is None else stripped[0]


def audio_end_candidates(path: Path) -> tuple[int, ...]:
    """Candidate audio ends for a strict-decode retry: ``()`` when
    :func:`audio_end_without_trailer` is None, else its value followed by up to
    two larger ends. A healthy last frame can end with a CRC byte 0x00 (or two),
    which reads like zero padding and is stripped with it; so when the last
    stripped trailer was a zero run, ``end + 1`` and ``end + 2`` (never more
    than the zeros stripped) are tried too."""
    stripped = _strip_trailers(path)
    if stripped is None:
        return ()
    end, zero_run = stripped
    return tuple(range(end, end + min(2, zero_run) + 1))


def measure_decoded_duration(
    path: Path,
    *,
    options: ToolOptions = NO_OPTIONS,
) -> Optional[float]:
    """Measure a file's decoded full-track duration in seconds by decoding it once
    (spec 4.1). Used only when the tool and the track's stored duration are unknown
    (e.g. a FLAC written to a pipe has no header duration). Returns None for any
    unusable output (unknown is never 0); raises CaptureFailed or the runner's
    errors for a failed run."""
    result = run_capture(
        ["ffmpeg", "-v", "error", "-nostdin", "-progress", "pipe:1", "-nostats",
         *ffmpeg_input_args(options.input_format), "-i", str(path), "-map", "0:a:0", "-f", "null", "-"],
        timeout_s=scaled_timeout(path),
        max_stdout_bytes=DECODE_PROGRESS_MAX_STDOUT_BYTES,
        options=options,
    )
    if result.returncode != 0:
        raise CaptureFailed(reason_for_exit(result.returncode), result.returncode)
    micros = _progress_end_out_time_us(result.stdout)
    return micros / 1_000_000 if micros is not None else None


@dataclass(frozen=True)
class FingerprintIdentity:
    """A computed, final fingerprint layer: state is current, low_information or
    too_short; items is () and duration_s None when too_short."""

    state: str
    backend: str
    algorithm: str
    duration_s: Optional[float]
    items: tuple[int, ...]


@dataclass(frozen=True)
class FingerprintUnavailable:
    """Not computed this time; the layer stays pending. reason is a fixed REASON_*."""

    reason: str


def compute_fingerprint(
    path: Path,
    fingerprinter: "Fingerprinter",
    *,
    params: "MatcherParams",
    known_duration_s: Optional[float] = None,
    options: ToolOptions = NO_OPTIONS,
) -> FingerprintIdentity | FingerprintUnavailable:
    """Fingerprint one file and classify it. Never raises; an unexpected
    exception becomes REASON_INTERNAL_ERROR (type logged, never message/path)."""
    # Local import: duplicate_detection imports this module at top level and
    # fingerprinter imports duplicate_detection (cycle).
    from app.services.fingerprinter import (
        FINGERPRINT_SECONDS,
        FP_TOO_SHORT,
        FingerprintFailure,
        classify,
    )

    try:
        raw = fingerprinter.fingerprint(path, max_seconds=FINGERPRINT_SECONDS, options=options)
        if isinstance(raw, FingerprintFailure):
            if raw.reason == REASON_EMPTY_FINGERPRINT:
                return FingerprintIdentity(FP_TOO_SHORT, fingerprinter.name, fingerprinter.algorithm, None, ())
            return FingerprintUnavailable(raw.reason)
        state = classify(raw, params)
        if state == FP_TOO_SHORT:
            return FingerprintIdentity(state, fingerprinter.name, fingerprinter.algorithm, None, ())
        duration = raw.duration_s
        if duration is None and known_duration_s is not None and math.isfinite(known_duration_s) \
                and known_duration_s > 0:
            duration = float(known_duration_s)
        if duration is None:
            # Order: tool duration, then the track's known duration, then the
            # decoded duration. Only this last step costs a decode. The value
            # feeds the finder's duration window (fp_duration_tolerance_s /
            # _frac, spec 5) and places the comparator's second search range;
            # source differences of about a second or less (~8 items) are
            # absorbed by the +-fp_max_offset search.
            try:
                measured = measure_decoded_duration(path, options=options)
            except Exception as e:
                reason, error_type, _ = reason_for_capture_exception(e)
                logger.warning("decoded duration failed: reason=%s error=%s", reason, error_type)
                return FingerprintUnavailable(reason)
            if measured is not None and math.isfinite(measured) and measured > 0:
                duration = float(measured)
        if duration is None:
            return FingerprintUnavailable(REASON_DURATION_UNKNOWN)
        return FingerprintIdentity(state, fingerprinter.name, fingerprinter.algorithm, duration, tuple(raw.items))
    except Exception as e:
        logger.warning("compute_fingerprint failed: %s", type(e).__name__)
        return FingerprintUnavailable(REASON_INTERNAL_ERROR)


# Identity-value columns of the SC-25 table only. Lifecycle columns
# (generation, match_state, attempts, priority, stat_*, ...) belong to the
# database writers. The fingerprint value columns are FINGERPRINT_COLUMNS.
IDENTITY_COLUMNS: tuple[str, ...] = (
    "exact_state", "exact_kind", "exact_digest", "sample_rate_hz", "channels",
    "bits_per_sample", "failure_reason", "computed_at", "tool_versions",
)


# Fingerprint-layer value columns, disjoint from IDENTITY_COLUMNS. Written by
# identity_to_columns only for a computed FingerprintIdentity.
FINGERPRINT_COLUMNS: tuple[str, ...] = (
    "fp_state", "fp_algorithm", "fp_backend", "fp_duration_s", "fp_item_count", "fp_data",
)


@dataclass(frozen=True)
class AudioIdentity:
    exact: ExactAudioHash | ExactUnavailable
    tool_versions: Optional[str]
    computed_at: int
    fingerprint: FingerprintIdentity | FingerprintUnavailable | None = None


_tool_versions_cache: Optional[str] = None


_TOOL_VERSIONS_TIMEOUT_S = 10
_TOOL_VERSIONS_MAX_STDOUT_BYTES = 16 * 1024
_FFMPEG_VERSION_RE = re.compile(r"ffmpeg version (\S+)")


def split_tool_versions(versions: Optional[str]) -> tuple[Optional[str], Optional[str]]:
    """``(ffmpeg part, fingerprinter part)`` of a stored/current tool-versions
    string: the text before the first ``"; "`` (or the whole string) and the text
    after it (None when absent). None splits to (None, None). The failed-row
    resets compare each layer's part on its own (SQL mirror: ``Database._TV_*``)."""
    if versions is None:
        return None, None
    head, sep, tail = versions.partition("; ")
    return head, (tail if sep else None)


def tool_versions(*, fingerprinter: Any = None, options: ToolOptions = NO_OPTIONS) -> Optional[str]:
    """``"ffmpeg <ver>"`` from ``ffmpeg -version``, or None; with a
    fingerprinter ``"; <name> <tool_version>"`` is appended (e.g.
    ``"ffmpeg 8.1; fpcalc 1.6.2"``). The ffmpeg part is cached for the process
    on success; a failure (missing tool, non-zero exit, odd output) is None
    overall (a missing tool is not a version change) and not cached. Never
    raises."""
    ffmpeg = _ffmpeg_version(options)
    if ffmpeg is None or fingerprinter is None:
        return ffmpeg
    return f"{ffmpeg}; {fingerprinter.name} {fingerprinter.tool_version}"


def _ffmpeg_version(options: ToolOptions = NO_OPTIONS) -> Optional[str]:
    global _tool_versions_cache
    if _tool_versions_cache is not None:
        return _tool_versions_cache
    try:
        result = run_capture(
            ["ffmpeg", "-version"],
            timeout_s=_TOOL_VERSIONS_TIMEOUT_S,
            max_stdout_bytes=_TOOL_VERSIONS_MAX_STDOUT_BYTES,
            options=options,
        )
        if result.returncode != 0:
            return None
        first_line = result.stdout.decode("utf-8", errors="replace").splitlines()[0]
        match = _FFMPEG_VERSION_RE.match(first_line.strip())
        if match is None:
            return None
    except Exception:
        return None
    _tool_versions_cache = f"ffmpeg {match.group(1)}"
    return _tool_versions_cache


def exact_match(a: Any, b: Any) -> bool:
    """Two exact hashes match only when kind, digest and the kind's equality
    parameters are equal: sample rate and channels (both known) for the PCM
    kinds, nothing for packets. ``bits_per_sample`` is informational. A
    lossy and a lossless hash never match (different kinds)."""
    if not isinstance(a, ExactAudioHash) or not isinstance(b, ExactAudioHash):
        return False
    if a.kind != b.kind or a.digest != b.digest:
        return False
    if a.kind in PCM_KINDS:
        return (
            a.sample_rate_hz is not None and a.sample_rate_hz == b.sample_rate_hz
            and a.channels is not None and a.channels == b.channels
        )
    return True


def compute_identity(
    path: Path,
    codec_hint: Optional[str],
    *,
    fingerprinter: Optional["Fingerprinter"] = None,
    known_duration_s: Optional[float] = None,
    params: Optional["MatcherParams"] = None,
    options: ToolOptions = NO_OPTIONS,
) -> AudioIdentity:
    """The audio identity of ``path``: the exact layer and, when a
    fingerprinter is given, the fingerprint layer (without one the fingerprint
    is None, i.e. not computed). Shared by the worker, the organizer and
    Phase 7, minus storage. Never raises. ``options`` reach every tool run (an
    upload's names its demuxer; a library file's names none)."""
    exact = compute_exact(path, codec_hint, options=options)
    fingerprint = None
    if fingerprinter is not None:
        if params is None:
            # Local import: duplicate_detection imports this module (cycle).
            from app.config import settings
            from app.services.duplicate_detection import MatcherParams

            params = MatcherParams.from_settings(settings)
        fingerprint = compute_fingerprint(
            path, fingerprinter, params=params, known_duration_s=known_duration_s, options=options,
        )
    return AudioIdentity(
        exact=exact,
        tool_versions=tool_versions(fingerprinter=fingerprinter, options=options),
        computed_at=int(time.time()),
        fingerprint=fingerprint,
    )


def fingerprint_to_columns(fp: FingerprintIdentity | FingerprintUnavailable | None) -> dict[str, Any]:
    """The ``FINGERPRINT_COLUMNS`` of a computed ``FingerprintIdentity``; {} for
    None or a ``FingerprintUnavailable`` (the writer decides that state)."""
    if not isinstance(fp, FingerprintIdentity):
        return {}
    from app.services.fingerprinter import pack_fingerprint  # cycle, see compute_fingerprint

    too_short = fp.state == "too_short"
    return {
        "fp_state": fp.state, "fp_algorithm": fp.algorithm, "fp_backend": fp.backend,
        "fp_duration_s": None if too_short else fp.duration_s,
        "fp_item_count": None if too_short else len(fp.items),
        "fp_data": None if too_short else pack_fingerprint(fp.items),
    }


def identity_to_columns(identity: AudioIdentity) -> dict[str, Any]:
    """Serialize to the SC-25 identity-value columns (``IDENTITY_COLUMNS``).
    Lifecycle columns (generation, match_state, attempts, priority, stat_*,
    ...) belong to the database writers; the ``FINGERPRINT_COLUMNS`` keys
    are added only for a computed ``FingerprintIdentity``; with no fingerprint
    or a ``FingerprintUnavailable`` there is no fp key (the writer decides
    pending/unavailable)."""
    exact = identity.exact
    if isinstance(exact, ExactAudioHash):
        columns: dict[str, Any] = {
            "exact_state": "current", "exact_kind": exact.kind, "exact_digest": exact.digest,
            "sample_rate_hz": exact.sample_rate_hz, "channels": exact.channels,
            "bits_per_sample": exact.bits_per_sample, "failure_reason": None,
        }
    else:
        columns = {
            "exact_state": exact.state, "exact_kind": None, "exact_digest": None,
            "sample_rate_hz": None, "channels": None, "bits_per_sample": None,
            "failure_reason": exact.reason,
        }
    columns["computed_at"] = identity.computed_at
    columns["tool_versions"] = identity.tool_versions
    columns.update(fingerprint_to_columns(identity.fingerprint))
    return columns


def identity_from_columns(row: Mapping[str, Any]) -> AudioIdentity:
    """Inverse of ``identity_to_columns``; extra keys are ignored. Raises
    ``ValueError`` for a state that is not a computed identity (``pending``
    is a storage state) or a malformed ``current`` row."""
    state = row["exact_state"]
    exact: ExactAudioHash | ExactUnavailable
    if state == "current":
        if row["exact_kind"] not in EXACT_KINDS or not row["exact_digest"]:
            raise ValueError("malformed current audio identity row")
        exact = ExactAudioHash(
            row["exact_kind"], row["exact_digest"],
            row["sample_rate_hz"], row["channels"], row["bits_per_sample"],
        )
    elif state in ("failed", "unsupported"):
        exact = ExactUnavailable(state, row["failure_reason"])
    else:
        raise ValueError(f"unexpected exact_state {state!r}")
    fingerprint = None
    fp_state = row.get("fp_state")
    if fp_state == "too_short":
        fingerprint = FingerprintIdentity(fp_state, row.get("fp_backend"), row.get("fp_algorithm"), None, ())
    elif fp_state in ("current", "low_information"):
        from app.services.fingerprinter import unpack_fingerprint  # cycle, see compute_fingerprint

        duration = row.get("fp_duration_s")
        if (row.get("fp_data") is None or not row.get("fp_backend") or not row.get("fp_algorithm")
                or duration is None or not duration > 0):
            raise ValueError("malformed fingerprint")
        fingerprint = FingerprintIdentity(
            fp_state, row["fp_backend"], row["fp_algorithm"], duration, unpack_fingerprint(row["fp_data"]),
        )
    return AudioIdentity(
        exact=exact, tool_versions=row["tool_versions"], computed_at=row["computed_at"], fingerprint=fingerprint,
    )


def stat_snapshot(path) -> Optional[tuple[int, int, int]]:
    """``(size, mtime_ns, inode)`` of ``path``, or None when it cannot be read
    (missing or unreadable: unknown, never zero)."""
    try:
        st = os.stat(path)
    except OSError:
        return None
    return (st.st_size, st.st_mtime_ns, st.st_ino)
