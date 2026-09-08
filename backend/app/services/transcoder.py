"""Audio transcoding via ffmpeg subprocess.

General-purpose codec conversion, plus the AAC/m4a preset used by the
streaming quality path. The "original" quality preset bypasses transcoding
entirely.
"""

import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import FrozenSet, Optional

from app.services.ffmpeg_runner import FfmpegError, run_ffmpeg, scaled_timeout


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
    """Source audio params to mirror onto the ffmpeg command so a lossless
    target doesn't silently pick up ffmpeg's own defaults instead of the
    source's actual sample format/rate/channel layout.

    ``bits_per_raw_sample`` is informational only (there's no independent
    ffmpeg output flag for it — ``sample_fmt`` is the flag that actually
    carries bit depth); it's carried here for a caller that wants to reason
    about or log it.
    """

    sample_fmt: Optional[str] = None
    bits_per_raw_sample: Optional[int] = None
    sample_rate_hz: Optional[int] = None
    channels: Optional[int] = None


# target_codec -> (ffmpeg encoder/container flags, needs an explicit -b:a).
_CODEC_FLAGS: dict[str, tuple[list[str], bool]] = {
    "aac": (["-c:a", "aac", "-f", "mp4", "-movflags", "+faststart"], True),
    "alac": (["-c:a", "alac", "-f", "mp4", "-movflags", "+faststart"], False),
    "flac": (["-c:a", "flac", "-f", "flac"], False),
    "mp3": (["-c:a", "libmp3lame", "-f", "mp3"], True),
}

# ffmpeg encoder name (as printed by `ffmpeg -encoders`) -> the codec name we
# key everything else by. libmp3lame/alac are build-dependent.
_ENCODER_NAME_TO_CODEC: dict[str, str] = {
    "aac": "aac",
    "alac": "alac",
    "flac": "flac",
    "libmp3lame": "mp3",
}


def _source_param_flags(params: SourceAudioParams) -> list[str]:
    flags: list[str] = []
    if params.sample_fmt:
        flags += ["-sample_fmt", params.sample_fmt]
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
) -> TranscodeResult:
    """Transcode ``source`` to ``target_codec``, writing ``dest``.

    Writes to a temp file first and atomically renames onto ``dest`` so a
    partial output is never visible. ``strip_video`` should be True for the
    streaming path (which never wants embedded cover art in the response) and
    False for conversion (which must carry cover art through).
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
    cmd.extend(codec_flags)
    if needs_bitrate:
        cmd.extend(["-b:a", f"{bitrate_kbps}k"])
    if source_params is not None:
        cmd.extend(_source_param_flags(source_params))
    cmd.append(str(tmp_path))

    try:
        # Shared runner: size-scaled timeout + stderr diagnostics.
        run_ffmpeg(cmd, tmp_path, timeout=scaled_timeout(source))
    except FfmpegError as e:
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
