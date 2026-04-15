"""Audio transcoding via ffmpeg subprocess.

Encodes input audio files to AAC inside an m4a container at a target bitrate.
The "original" quality preset bypasses transcoding entirely.
"""

import concurrent.futures
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Optional


# Quality presets. The "original" preset means do not transcode.
ORIGINAL_QUALITY = "original"
QUALITY_BITRATES_KBPS: dict[str, int] = {
    "320": 320,
    "256": 256,
    "192": 192,
    "128": 128,
}


def is_valid_quality(quality: Optional[str]) -> bool:
    if quality is None:
        return True
    if quality == ORIGINAL_QUALITY:
        return True
    return quality in QUALITY_BITRATES_KBPS


def normalize_quality(quality: Optional[str]) -> str:
    """Return canonical name. None or 'original' both map to ORIGINAL_QUALITY."""
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
        result = subprocess.run(
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
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            check=False,
        )
    except FileNotFoundError:
        return False
    except OSError:
        if tmp_path.exists():
            tmp_path.unlink(missing_ok=True)
        return False

    if result.returncode != 0 or not tmp_path.exists() or tmp_path.stat().st_size == 0:
        if tmp_path.exists():
            tmp_path.unlink(missing_ok=True)
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
