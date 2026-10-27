"""Audio transcoding via ffmpeg subprocess.

General-purpose codec conversion, plus the AAC/m4a preset used by the
streaming quality path. The "original" quality preset bypasses transcoding
entirely.
"""

import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Any, FrozenSet, Optional

from app.services.ffmpeg_runner import (
    FfmpegError,
    FfmpegProcessRegistry,
    run_ffmpeg,
    scaled_timeout,
)


# Quality presets. The "original" preset means do not transcode.
ORIGINAL_QUALITY = "original"
QUALITY_BITRATES_KBPS: dict[str, int] = {
    "320": 320,
    "256": 256,
    "192": 192,
    "128": 128,
}


def normalize_quality(quality: Optional[str]) -> str:
    """Return canonical name. None or 'original' both map to ORIGINAL_QUALITY.

    Raises ValueError for any other unrecognized preset.
    """
    if quality is None or quality == ORIGINAL_QUALITY:
        return ORIGINAL_QUALITY
    if quality not in QUALITY_BITRATES_KBPS:
        raise ValueError(f"unknown quality preset: {quality}")
    return quality


@dataclass(frozen=True)
class TranscodeResult:
    ok: bool
    stderr: str = ""


@dataclass(frozen=True)
class SourceAudioParams:
    """Source audio params mirrored onto the ffmpeg command so a lossless
    target keeps the source's bit depth/rate/channel layout instead of
    ffmpeg's defaults.

    ``bits_per_sample`` is the source's effective integer bit depth (e.g. 24
    for a 24-bit FLAC stored as s32), or None when it has none (float PCM,
    unknown) -- then ffmpeg picks the encoder's default format.
    """

    bits_per_sample: Optional[int] = None
    sample_rate_hz: Optional[int] = None
    channels: Optional[int] = None


# target_codec -> (ffmpeg encoder/container flags, needs an explicit -b:a).
_CODEC_FLAGS: dict[str, tuple[list[str], bool]] = {
    "aac": (["-c:a", "aac", "-f", "mp4", "-movflags", "+faststart"], True),
    "alac": (["-c:a", "alac", "-f", "mp4", "-movflags", "+faststart"], False),
    "flac": (["-c:a", "flac", "-f", "flac"], False),
    "mp3": (["-c:a", "libmp3lame", "-f", "mp3"], True),
}

# Encoders accept only specific sample formats (flac: packed s16/s32, alac:
# planar s16p/s32p), so bit depth maps to the encoder's own format rather
# than copying the source's sample_fmt verbatim. s32 still records a 24-bit
# source as 24-bit (ffmpeg carries bits_per_raw_sample through).
_LOSSLESS_SAMPLE_FMTS: dict[str, tuple[str, str]] = {
    "flac": ("s16", "s32"),
    "alac": ("s16p", "s32p"),
}

# Carry cover art as-is: without an explicit copy ffmpeg re-encodes the
# picture with the muxer's default video encoder (h264 for mp4, which then
# fails to mux; PNG for flac/mp3).
_ART_FLAGS: dict[str, list[str]] = {
    "aac": ["-c:v", "copy", "-disposition:v:0", "attached_pic"],
    "alac": ["-c:v", "copy", "-disposition:v:0", "attached_pic"],
    "flac": ["-c:v", "copy"],
    "mp3": ["-c:v", "copy", "-id3v2_version", "3"],
}

# Codecs transcode() can actually produce. Deliberately narrower than
# media_types.CODEC_TO_EXT, which also has wav/pcm_* entries for passthrough
# MIME lookups — WAV is source-only, never a conversion target.
SUPPORTED_TARGET_CODECS: FrozenSet[str] = frozenset(_CODEC_FLAGS.keys())

# ffmpeg encoder name (as printed by `ffmpeg -encoders`) -> the codec name we
# key everything else by. libmp3lame/alac are build-dependent.
_ENCODER_NAME_TO_CODEC: dict[str, str] = {
    "aac": "aac",
    "alac": "alac",
    "flac": "flac",
    "libmp3lame": "mp3",
}


def _source_param_flags(params: SourceAudioParams, target_codec: str) -> list[str]:
    flags: list[str] = []
    fmts = _LOSSLESS_SAMPLE_FMTS.get(target_codec)
    if fmts is not None and params.bits_per_sample:
        flags += ["-sample_fmt", fmts[0] if params.bits_per_sample <= 16 else fmts[1]]
    if params.sample_rate_hz:
        flags += ["-ar", str(params.sample_rate_hz)]
    if params.channels:
        flags += ["-ac", str(params.channels)]
    return flags


def transcode(
    source: Path,
    dest: Path,
    target_codec: str,
    bitrate_kbps: Optional[int] = None,
    source_params: Optional[SourceAudioParams] = None,
    strip_video: bool = False,
    registry: Optional[FfmpegProcessRegistry] = None,
    job_id: Optional[Any] = None,
) -> TranscodeResult:
    """Transcode ``source`` to ``target_codec``, writing ``dest``.

    Writes to a temp file first and atomically renames onto ``dest`` so a
    partial output is never visible. ``strip_video`` should be True for the
    streaming path (which never wants embedded cover art in the response) and
    False for conversion (which must carry cover art through). ``registry``/
    ``job_id`` (both required together) let a conversion job be cancelled
    mid-transcode — see ``FfmpegProcessRegistry``.
    """
    if target_codec not in _CODEC_FLAGS:
        raise ValueError(f"unsupported target codec: {target_codec}")
    codec_flags, needs_bitrate = _CODEC_FLAGS[target_codec]
    if needs_bitrate and bitrate_kbps is None:
        raise ValueError(f"{target_codec} requires bitrate_kbps")

    dest.parent.mkdir(parents=True, exist_ok=True)
    # Write to a temp file first so partial outputs are never visible.
    tmp_path = dest.with_suffix(dest.suffix + ".partial")

    cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", str(source)]
    if strip_video:
        cmd.append("-vn")
    else:
        cmd.extend(_ART_FLAGS[target_codec])
    cmd.extend(codec_flags)
    if needs_bitrate:
        cmd.extend(["-b:a", f"{bitrate_kbps}k"])
    if source_params is not None:
        cmd.extend(_source_param_flags(source_params, target_codec))
    cmd.append(str(tmp_path))

    try:
        # Shared runner: size-scaled timeout + stderr diagnostics.
        run_ffmpeg(
            cmd, tmp_path, timeout=scaled_timeout(source),
            registry=registry, job_id=job_id,
        )
    except FfmpegError as e:
        print(f"transcode of {source} to {target_codec} failed: {e.stderr[-500:]}")
        return TranscodeResult(ok=False, stderr=e.stderr)

    tmp_path.replace(dest)
    return TranscodeResult(ok=True)


def transcode_to_aac_m4a(
    source_path: Path,
    destination_path: Path,
    bitrate_kbps: int,
) -> bool:
    """Transcode source to AAC m4a at target bitrate. Returns True on success."""
    return transcode(
        source_path, destination_path, "aac", bitrate_kbps, strip_video=True
    ).ok


def probe_available_encoders() -> FrozenSet[str]:
    """Query ffmpeg's compiled-in encoders once at startup.

    Used later to gate advertised conversion targets against what this build
    can actually produce (libmp3lame/alac availability is build-dependent).
    Never raises — a probe failure just means an empty result, not a crash.
    """
    try:
        result = subprocess.run(
            ["ffmpeg", "-hide_banner", "-encoders"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired):
        return frozenset()

    if result.returncode != 0:
        return frozenset()

    available: set[str] = set()
    for line in result.stdout.decode("utf-8", errors="replace").splitlines():
        parts = line.split()
        if len(parts) < 2:
            continue
        codec = _ENCODER_NAME_TO_CODEC.get(parts[1])
        if codec:
            available.add(codec)
    return frozenset(available)
