from pathlib import Path
import subprocess
import json
from app.models.track_meta_data import TrackMetaData

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
    
    

def ffprobe_for_metadata(file_path: Path) -> dict | None:
    try:
        completed_process = subprocess.run(
            [
                "ffprobe",
                "-v", "error",
                "-hide_banner",
                "-show_streams",
                "-show_format",
                "-of", "json",
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
    if json_data is None:
        return None
    format_tags = json_data.get("format", {}).get("tags", {})
    streams = json_data.get("streams", [])

    audio_stream = None
    has_album_art = False

    for stream in streams:
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
    if codec != None:
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
    metadata.track_number = _parse_track_number(format_tags.get("track")) if "track" in format_tags else None
    metadata.disc_number = format_tags.get("disc") if "disc" in format_tags else None

    return metadata


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