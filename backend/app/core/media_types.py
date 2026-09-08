from typing import FrozenSet

AUDIO_EXTENSIONS: FrozenSet[str] = frozenset({
    ".mp3",
    ".wav",
    ".flac",
    ".m4a",
})

ARCHIVE_EXTENSIONS: FrozenSet[str] = frozenset({
    ".zip",
    ".rar",
    ".tar",
    ".tar.gz",
})

# Codec (ffprobe codec_name) -> file extension used when a master is written
# in that codec (conversion targets + passthrough).
CODEC_TO_EXT: dict[str, str] = {
    "aac": "m4a",
    "alac": "m4a",
    "flac": "flac",
    "mp3": "mp3",
    "wav": "wav",
    "pcm_s16le": "wav",
    "pcm_s24le": "wav",
    "pcm_f32le": "wav",
}

# Codec -> MIME type, for picking a streaming response's media_type on
# passthrough (no transcode happened, so the codec is whatever the source is).
CODEC_MIME: dict[str, str] = {
    "aac": "audio/mp4",
    "alac": "audio/mp4",
    "mp3": "audio/mpeg",
    "flac": "audio/flac",
    "wav": "audio/wav",
    "pcm_s16le": "audio/wav",
    "pcm_s24le": "audio/wav",
    "pcm_f32le": "audio/wav",
}

# MIME type -> bare extension, for the X-Audio-Extension response header.
MIME_EXTENSION: dict[str, str] = {
    "audio/mp4": "m4a",
    "audio/mpeg": "mp3",
    "audio/flac": "flac",
    "audio/x-flac": "flac",
    "audio/ogg": "ogg",
    "audio/aac": "aac",
    "audio/wav": "wav",
    "audio/x-wav": "wav",
}

LOSSLESS_CODECS: FrozenSet[str] = frozenset({
    "flac",
    "alac",
    "wav",
    "pcm_s16le",
    "pcm_s24le",
    "pcm_f32le",
})

LOSSY_CODECS: FrozenSet[str] = frozenset({
    "aac",
    "mp3",
})


def is_lossless(codec: str) -> bool:
    return codec in LOSSLESS_CODECS


def is_lossy(codec: str) -> bool:
    return codec in LOSSY_CODECS
