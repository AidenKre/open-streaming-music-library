"""Reading a file for startup journal recovery, and the content rule that decides
what happens to a leftover file recovery cannot prove by the ownership rules."""

import logging
from dataclasses import dataclass
from typing import Any, Optional

from app.services import audio_identity
from app.services.audio_identity import ExactAudioHash
from app.services.metadata import (
    ProbeUnavailable,
    build_track_metadata,
    ffprobe_for_metadata,
    probe_unavailable_raises,
)

logger = logging.getLogger(__name__)

# How a probe went: it read the file, ffprobe refused it (the file's own answer),
# or nothing is known (timeout, missing tool, unexpected failure).
PROBE_OK = "ok"
PROBE_REFUSED = "refused"
PROBE_UNKNOWN = "unknown"

# What to do with a leftover file.
REDUNDANT = "redundant"
MAKE_TRACK = "make_track"
UNREADABLE = "unreadable"
LEAVE = "leave"

RECOVERY_PROBE_TIMEOUT_S = 30


@dataclass(frozen=True)
class AudioReading:
    probe: str
    metadata: Optional[Any]
    exact: Optional[Any]


def read_audio(path) -> AudioReading:
    """One timed probe of ``path`` and, when it reads as audio, its exact hash."""
    try:
        with probe_unavailable_raises():
            raw = ffprobe_for_metadata(path, timeout=RECOVERY_PROBE_TIMEOUT_S)
        if raw is None:
            return AudioReading(PROBE_REFUSED, None, None)
        metadata = build_track_metadata(raw)
        if metadata is None or metadata.is_empty():
            return AudioReading(PROBE_REFUSED, None, None)
        exact = audio_identity.compute_exact(path, metadata.codec)
        return AudioReading(PROBE_OK, metadata, exact)
    except ProbeUnavailable:
        return AudioReading(PROBE_UNKNOWN, None, None)
    except Exception as e:
        logger.warning("recovery could not read a file: %s", type(e).__name__)
        return AudioReading(PROBE_UNKNOWN, None, None)


def _hashed(reading: AudioReading) -> bool:
    return reading.probe == PROBE_OK and isinstance(reading.exact, ExactAudioHash)


def leftover_verdict(leftover: AudioReading, track: AudioReading) -> str:
    """The content rule. A readable leftover is deleted only as an exact audio
    match of the track's own file, else it becomes a track. One ffprobe refuses
    is deleted only when the track's file hashed (D1); otherwise, and whenever
    the leftover's reading is unknown, it is left alone (D2)."""
    if leftover.probe == PROBE_OK:
        if _hashed(leftover) and _hashed(track) and audio_identity.exact_match(
            leftover.exact, track.exact
        ):
            return REDUNDANT
        return MAKE_TRACK
    if leftover.probe == PROBE_REFUSED and _hashed(track):
        return UNREADABLE
    return LEAVE
