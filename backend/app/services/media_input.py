"""The one place that builds the input arguments of media processes run on
staged upload bytes (review r1 7-R1-18). FFmpeg auto-probes its input, so an
uploaded playlist-style file could make it open a second file or a URL: the
upload probe is limited to the allow-listed demuxers and the ``file`` protocol,
and every later process forces the demuxer the probe detected. ``None`` means a
library file and adds nothing."""

import json

# The demuxers of the allow-listed upload containers (mov also reads mp4/m4a).
UPLOAD_DEMUXERS = ("flac", "mp3", "wav", "mov")

UPLOAD_PROBE_ARGS = ["-protocol_whitelist", "file", "-format_whitelist", ",".join(UPLOAD_DEMUXERS)]


def demuxer_for(container: str | None) -> str | None:
    """The demuxer to force for a probed ``format_name`` (``"mov,mp4,m4a,..."`` -> ``"mov"``)."""
    names = (container or "").split(",")
    return next((name for name in names if name in UPLOAD_DEMUXERS), None)


def item_demuxer(database, owner_id: int, item_uuid: str) -> str | None:
    """The demuxer of an upload item's probed container (its owner-scoped
    ``detected_metadata``), or None when the item or the container is unknown."""
    try:
        item = database.get_upload_item(item_uuid, owner_id=owner_id)
        return demuxer_for(json.loads(item["detected_metadata"]).get("container"))
    except (TypeError, ValueError, AttributeError, KeyError):
        return None


def ffmpeg_input_args(input_format: str | None) -> list[str]:
    """Options before ``-i`` of ffmpeg/ffprobe for a forced demuxer."""
    return [] if input_format is None else ["-protocol_whitelist", "file", "-f", input_format]


def fpcalc_input_args(input_format: str | None) -> list[str]:
    """fpcalc has no protocol whitelist; forcing the format is what it offers."""
    return [] if input_format is None else ["-format", input_format]
