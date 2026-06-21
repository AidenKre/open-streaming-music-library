import json
import subprocess
from pathlib import Path

from app.models.track_meta_data import TrackMetaData


class TagWriteError(Exception):
    """Raised when writing tags to a master file fails (ffmpeg non-zero exit,
    timeout, or the re-probe verification did not confirm the change)."""


def is_wav(file_path: Path) -> bool:
    """WAV master tagging is out of scope in Phase 1 (RIFF tag support is too
    lossy), so the orchestration degrades a ``db_and_master`` WAV edit to
    DB-only. Keyed off the extension — cheap and good enough for the gate."""
    return file_path.suffix.lower() == ".wav"


def write_metadata_tags(source: Path, dest: Path, tags: dict[str, str | None]) -> None:
    """Copy ``source`` to ``dest`` with ``tags`` applied, audio bytes untouched.

    ``tags`` maps ffmpeg metadata keys to values; ``None`` (or "") clears the
    tag. Uses ``-map 0 -c copy -map_metadata 0`` so every stream — including the
    attached-pic cover-art stream — and all unedited tags are preserved; only
    the named tags are overwritten. Because the audio bytes are unchanged, the
    ``(uuid, quality)``-keyed encoded cache stays valid across an edit. Verifies
    by re-probing ``dest`` and raises ``TagWriteError`` on any failure.
    """
    cmd = [
        "ffmpeg",
        "-hide_banner",
        "-loglevel", "error",
        "-y",
        "-i", str(source),
        "-map", "0",
        "-c", "copy",
        "-map_metadata", "0",
    ]
    for key, value in tags.items():
        cmd += ["-metadata", f"{key}={value if value is not None else ''}"]
    cmd.append(str(dest))

    # ~1s per MB on top of a 30s floor so large lossless files don't trip a
    # fixed timeout; capped so a hang can't wedge a request forever.
    try:
        size_mb = source.stat().st_size / (1024 * 1024)
    except OSError:
        size_mb = 0
    timeout = min(600, 30 + int(size_mb))

    try:
        result = subprocess.run(
            cmd,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            check=False,
            timeout=timeout,
        )
    except FileNotFoundError as e:
        raise TagWriteError("ffmpeg not found") from e
    except (OSError, subprocess.TimeoutExpired) as e:
        dest.unlink(missing_ok=True)
        raise TagWriteError(f"ffmpeg failed: {e}") from e

    if result.returncode != 0 or not dest.exists() or dest.stat().st_size == 0:
        dest.unlink(missing_ok=True)
        stderr = result.stderr.decode("utf-8", errors="replace").strip()
        raise TagWriteError(f"ffmpeg exited {result.returncode}: {stderr}")

    # Verify the output is still a probe-able audio file (catches a silently
    # corrupt remux). Field-level verification is intentionally light — ffmpeg
    # normalizes some tag spellings, so we confirm probe-ability, not equality.
    if ffprobe_for_metadata(dest) is None:
        dest.unlink(missing_ok=True)
        raise TagWriteError("re-probe of written file failed")

# TODO: Handle non printable characters in metadata (remember the UniBe@t thingy where there were windows /r/n invisible characters...)
# TODO: possible search database to see if artist/album already exists? and match capitalization? might be confusing...


def get_track_metadata(file_path: Path) -> TrackMetaData | None:
    json_data = ffprobe_for_metadata(file_path)
    if json_data is None:
        return None
    metadata = build_track_metadata(json_data)
    if metadata is None:
        return None
    if metadata.is_empty():
        return None
    return metadata


def get_audio_bitrate_kbps(path: Path) -> int | None:
    """Return the audio stream's bitrate in kbps, or None on failure.

    Issues a targeted ffprobe query for only the bit_rate field — lighter than
    the full metadata probe. Returns None when ffprobe is unavailable, the file
    has no audio stream, or the value cannot be parsed. Callers should treat
    None as "unknown" and proceed conservatively (e.g. allow transcoding).
    """
    try:
        result = subprocess.run(
            [
                "ffprobe",
                "-v", "quiet",
                "-select_streams", "a:0",
                "-show_entries", "stream=bit_rate",
                "-of", "default=noprint_wrappers=1:nokey=1",
                str(path),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
        )
    except (FileNotFoundError, OSError):
        return None

    raw = result.stdout.decode("utf-8", errors="replace").strip()
    if not raw or raw == "N/A":
        return None
    try:
        return int(raw) // 1000
    except ValueError:
        return None


def ffprobe_for_metadata(file_path: Path) -> dict | None:
    try:
        completed_process = subprocess.run(
            [
                "ffprobe",
                "-v",
                "error",
                "-hide_banner",
                "-show_streams",
                "-show_format",
                "-of",
                "json",
                str(file_path),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            check=False,
        )
    except FileNotFoundError:
        print("ffprobe not found")
        return None
    except OSError:
        return None

    if completed_process.returncode != 0:
        return None

    try:
        return json.loads(completed_process.stdout or "{}")
    except json.JSONDecodeError:
        return None


def build_track_metadata(json_data: dict) -> TrackMetaData | None:
    raw_format_tags = json_data.get("format", {}).get("tags", {})
    format_tags = {k.lower(): v for k, v in raw_format_tags.items()}
    streams = json_data.get("streams", {})

    audio_stream = None
    has_album_art = False

    for raw_stream in streams:
        stream = {k.lower(): v for k, v in raw_stream.items()}
        stream_type = stream.get("codec_type")
        if stream_type == "audio":
            audio_stream = stream
            continue

        if stream.get("disposition", {}).get("attached_pic") == 1:
            has_album_art = True
            continue

    if audio_stream is None:
        return None

    metadata = TrackMetaData()

    codec = audio_stream.get("codec_name", None)
    if codec:
        codec = str(codec)

    metadata.codec = codec
    metadata.duration = float(audio_stream.get("duration", 0.0))
    metadata.bitrate_kbps = float(audio_stream.get("bit_rate", 0.0)) / 1000.0
    metadata.sample_rate_hz = int(audio_stream.get("sample_rate", 0))
    metadata.channels = int(audio_stream.get("channels", 0))

    metadata.has_album_art = has_album_art

    if metadata.is_empty():
        return None

    metadata.title = format_tags.get("title")
    metadata.artist = format_tags.get("artist")
    metadata.album = format_tags.get("album")
    metadata.album_artist = format_tags.get("album_artist")
    date_val = format_tags.get("date") if "date" in format_tags else None
    metadata.date = date_val
    metadata.year = _parse_year(date_val)

    metadata.genre = format_tags.get("genre")
    metadata.track_number = (
        _parse_track_number(format_tags.get("track"))
        if "track" in format_tags
        else None
    )
    metadata.disc_number = (
        _parse_track_number(format_tags.get("disc")) if "disc" in format_tags else None
    )

    return metadata


def extract_cover_art_bytes(file_path: Path) -> bytes | None:
    """Extract embedded cover art from an audio file using ffmpeg."""
    try:
        result = subprocess.run(
            [
                "ffmpeg",
                "-i", str(file_path),
                "-an",
                "-vcodec", "copy",
                "-f", "image2pipe",
                "-",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=30,
        )
    except FileNotFoundError:
        print("ffmpeg not found")
        return None
    except (OSError, subprocess.TimeoutExpired):
        return None

    if result.returncode != 0 or not result.stdout:
        return None

    return result.stdout


def _parse_year(date_val: object) -> int | None:
    """
    Best-effort year extraction from ffprobe date tags.
    Common values: "2021", "2021-06-01", sometimes numeric.
    """
    if date_val is None:
        return None
    if isinstance(date_val, int):
        return date_val
    if not isinstance(date_val, str):
        return None
    if not date_val.strip():
        return None
    try:
        return int(date_val.split("-")[0])
    except (ValueError, TypeError):
        return None


def _parse_track_number(track_val: object) -> int | None:
    """
    Best-effort parsing from ffprobe track tags.
    Common values: "1", "1/12", sometimes numeric.
    """
    if track_val is None:
        return None
    if isinstance(track_val, int):
        return track_val
    if not isinstance(track_val, str):
        return None
    if not track_val.strip():
        return None
    try:
        return int(track_val.split("/")[0])
    except (ValueError, TypeError):
        return None
