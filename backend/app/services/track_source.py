"""The single way to open a track's audio (Phase 8 spec §5, SC-16i, SC-16j)."""

import logging
from dataclasses import dataclass
from pathlib import Path
from typing import BinaryIO, Optional

from fastapi import HTTPException

from app.database import ANY_OWNER
from app.models import Track
from app.services.deletion_errors import track_pending_deletion_error
from app.services.encoder_coordinator import EncodeResult, SourceUnavailable

logger = logging.getLogger(__name__)


class TrackSourceError(Exception):
    """A refusal to open a track; ``http()`` is what the route raises.

    No message carries a filesystem path (SC-22)."""

    def __init__(self, status: int, detail: str):
        super().__init__(detail)
        self.status = status
        self.detail = detail

    def http(self) -> HTTPException:
        return HTTPException(status_code=self.status, detail=self.detail)


class TrackGone(TrackSourceError):
    """Unknown, foreign or tombstoned: answers exactly like an unknown uuid."""

    def __init__(self, uuid_id: str):
        super().__init__(404, f"Could not find track with uuid: {uuid_id}")


class StreamTrackPendingDeletion(TrackSourceError):
    def __init__(self):
        super().__init__(410, "This track is being deleted.")

    def http(self) -> HTTPException:
        return track_pending_deletion_error(self.status)


@dataclass(frozen=True)
class OpenedTrackSource:
    file: BinaryIO
    encode: EncodeResult
    track: Track  # the pre-open row; response headers come from it


def _after_row_read(track) -> None:
    """Test seam: runs right after the pre-open row read, before the encode / open."""


def _open_source(path: Path) -> BinaryIO:
    return Path(path).open("rb")


def _read_live_row(library, uuid_id: str) -> Track:
    track = library.get_track_by_uuid(uuid_id)
    if track is None:
        raise TrackGone(uuid_id)
    if library.is_pending_deletion(uuid_id):
        raise StreamTrackPendingDeletion()
    return track


def _changed(library, uuid_id: str, track: Track, token) -> bool:
    """Re-read the row: raises if gone or pending; True when the master moved.

    Compares the file path and the cache generation, never ``revision``, so a
    DB-only edit does not trigger a retry."""
    current = _read_live_row(library, uuid_id)
    return current.file_path != track.file_path or token.moved()


def _attempt(
    library, uuid_id: str, quality: str, coordinator, *, final: bool
) -> Optional[OpenedTrackSource]:
    """One full open. None means the master changed underneath it: retry."""
    # Captured before the row is read (SC-16j): an eviction after this point
    # makes the encode's insert drop instead of caching a replaced master.
    token = coordinator.capture_generation(uuid_id, quality, owner_id=library.owner_id)
    track = _read_live_row(library, uuid_id)
    _after_row_read(track)
    # None = unknown; a real 0 is kept so the header can report it.
    source_bitrate = (
        int(track.metadata.bitrate_kbps)
        if track.metadata.bitrate_kbps is not None else None
    )

    def failed(error: TrackSourceError) -> Optional[OpenedTrackSource]:
        # Re-read first: a gone or pending track answers 404/410, not 500.
        if _changed(library, uuid_id, track, token) and not final:
            return None
        raise error

    try:
        result = coordinator.encode_for_stream(
            uuid_id,
            quality,
            source_bitrate_kbps=source_bitrate,
            source_path=track.file_path,
            owner_id=track.owner_id,
            generation=token,
        )
    except SourceUnavailable:
        # Row exists but its source file is gone: 404 so clients drop it
        # instead of retrying a permanently-missing file as if it were transient.
        return failed(
            TrackSourceError(404, f"Source file for track {uuid_id} is no longer available")
        )
    if result is None:
        return failed(
            TrackSourceError(500, f"Unable to encode track {uuid_id} at quality {quality}")
        )

    # Open eagerly (before the response starts) so the file descriptor pins the
    # inode. EncodedCache pruning and default-quality changes may unlink the
    # path after we validate it but before a lazy generator would open it; on
    # Unix the open handle keeps the data readable even after unlink, so
    # streaming survives concurrent cache eviction.
    try:
        f = _open_source(result.path)
    except OSError as exc:
        # Never the path (SC-22): only the exception type. Only proof of
        # absence of the master itself is "gone"; a missing encoded cache file
        # is just a prune, and any other open error may be transient.
        logger.warning("track file could not be opened: %s", type(exc).__name__)
        if isinstance(exc, (FileNotFoundError, NotADirectoryError)) and not result.transcoded:
            return failed(TrackSourceError(404, "The track's file is no longer available"))
        return failed(TrackSourceError(503, "The track's file could not be opened right now"))

    try:
        changed = _changed(library, uuid_id, track, token)
    except BaseException:
        f.close()
        raise
    if changed:
        f.close()
        if final:
            raise TrackSourceError(404, "The track's file is no longer available")
        return None
    return OpenedTrackSource(file=f, encode=result, track=track)


def open_track_source(library, uuid_id: str, quality: str, *, coordinator) -> OpenedTrackSource:
    # At most two attempts: one retry when the master changed mid-open.
    opened = _attempt(library, uuid_id, quality, coordinator, final=False)
    if opened is None:
        opened = _attempt(library, uuid_id, quality, coordinator, final=True)
    return opened


def _live_track_any_owner(database, uuid_id: str) -> Optional[Track]:
    """The track row for a uuid across owners, or None when absent or pending deletion."""
    track = database.get_track_by_uuid(uuid_id, owner_id=ANY_OWNER)
    if track is None or database.is_pending_deletion(uuid_id, owner_id=track.owner_id):
        return None
    return track


def live_track_owner(database, uuid_id: str) -> Optional[int]:
    """Background encoder owner lookup, answered only for a live track.

    Queued prefetch / warm work skips a uuid that is no longer live at task
    start (plan D11 / O7); there is no cancel API."""
    track = _live_track_any_owner(database, uuid_id)
    return track.owner_id if track is not None else None


def live_source_path(database, uuid_id: str) -> Optional[Path]:
    """Background encoder source lookup, answered only for a live track."""
    track = _live_track_any_owner(database, uuid_id)
    return track.file_path if track is not None else None
