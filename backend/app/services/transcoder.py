"""Audio transcoding via ffmpeg subprocess.

Encodes input audio files to AAC inside an m4a container at a target bitrate.
The "original" quality preset bypasses transcoding entirely.
"""

import concurrent.futures
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

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
    output_path: Path
    media_type: str


def transcode_to_aac_m4a(
    source_path: Path,
    destination_path: Path,
    bitrate_kbps: int,
) -> bool:
    """Transcode source to AAC m4a at target bitrate. Returns True on success."""
    destination_path.parent.mkdir(parents=True, exist_ok=True)
    # Write to a temp file first so partial outputs are never visible.
    tmp_path = destination_path.with_suffix(destination_path.suffix + ".partial")
    try:
        # Shared runner: size-scaled timeout (this path previously had none,
        # so a hung ffmpeg wedged a transcode forever) + stderr diagnostics.
        run_ffmpeg(
            [
                "ffmpeg",
                "-hide_banner",
                "-loglevel",
                "error",
                "-y",
                "-i",
                str(source_path),
                "-vn",
                "-c:a",
                "aac",
                "-b:a",
                f"{bitrate_kbps}k",
                "-f",
                "mp4",
                "-movflags",
                "+faststart",
                str(tmp_path),
            ],
            tmp_path,
            timeout=scaled_timeout(source_path),
        )
    except FfmpegError as e:
        print(f"transcode of {source_path} failed: {e}")
        return False

    tmp_path.replace(destination_path)
    return True


def transcode_batch(
    items: list[tuple[Path, Path, int]],
    max_concurrent: int = 4,
) -> list[bool]:
    """Run multiple ffmpeg transcodes concurrently.

    Each item is ``(source_path, destination_path, bitrate_kbps)``.  Returns a
    list of booleans in the same order indicating success or failure.
    """
    if not items:
        return []
    results = [False] * len(items)
    with concurrent.futures.ThreadPoolExecutor(max_workers=max_concurrent) as executor:
        futures = {
            executor.submit(transcode_to_aac_m4a, src, dst, br): idx
            for idx, (src, dst, br) in enumerate(items)
        }
        for future in concurrent.futures.as_completed(futures):
            idx = futures[future]
            try:
                results[idx] = future.result()
            except Exception:
                results[idx] = False
    return results
