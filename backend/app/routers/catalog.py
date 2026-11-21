"""Reading the catalog: the browse pages (deprecated, kept for other clients),
the change stream the app syncs from, cover art and the audio stream."""

import json
import sqlite3
from dataclasses import asdict
from typing import Any, Dict, List, Optional
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from fastapi.responses import FileResponse

from app.core.byte_range import ranged_file_response
from app.core.media_types import CODEC_MIME, MIME_EXTENSION
from app.database import (
    AlbumOrderParameter,
    AlbumRowFilterParameter,
    ArtistOrderParameter,
    ArtistRowFilterParameter,
    OrderParameter,
    RowFilterParameter,
    SearchEntityType,
    SearchParameter,
)
from app.library import Library, current_library
from app.models import (
    Album,
    ChangeEntry,
    ClientTrack,
    GetAlbumsResponse,
    GetArtistsResponse,
    GetChangesResponse,
    GetSearchResponse,
    GetTracksResponse,
)
from app.services import normalize_quality
from app.services.track_source import TrackSourceError, open_track_source

router = APIRouter()


# Deprecated (the owner's decision of 2026-11-14): no app code calls this route;
# the app keeps its own copy of the library through GET /changes. It stays live
# for other clients.
@router.get("/tracks", response_model=GetTracksResponse, deprecated=True)
def get_tracks(
    cursor: Optional[str] = None,
    limit: int = Query(500, ge=1, le=1000),
    offset: int = Query(0, ge=0),
    artist_id: Optional[int] = None,
    album_id: Optional[int] = None,
    library: Library = Depends(current_library),
):
    """Browse tracks in display order (artist/album/disc/track), optionally
    scoped by artist/album, with keyset cursor pagination. Incremental sync
    lives on ``GET /changes`` — this endpoint no longer windows by timestamp
    or returns tombstones."""

    # ``album_id`` is only meaningful when paired with ``artist_id`` — the
    # query layer rejects album-only filters because album IDs are not
    # globally unique across artists. Reject at the API boundary so the
    # client gets a clear 422 instead of a 500 from a deeper layer.
    if album_id is not None and artist_id is None and not cursor:
        raise HTTPException(
            status_code=422,
            detail="album_id requires artist_id",
        )

    search_parameters: List[SearchParameter]
    order_parameters: List[OrderParameter]
    if not cursor:
        order_parameters = [
            OrderParameter(column="artist", isAscending=True),
            OrderParameter(column="album", isAscending=True),
            OrderParameter(column="disc_number", isAscending=True),
            OrderParameter(column="track_number", isAscending=True),
            OrderParameter(column="uuid_id", isAscending=True),
        ]
        search_parameters = []
        row_filter_parameters = []

    else:
        try:
            decoded = json.loads(cursor)
        except json.JSONDecodeError:
            raise HTTPException(
                status_code=400, detail="Cursor could not be decoded for json"
            )
        if not isinstance(decoded, dict):
            raise HTTPException(
                status_code=400, detail="Cursor did not decode to a dict"
            )

        cursor_dict: Dict[str, Any] = decoded

        if not cursor_dict:
            raise HTTPException(
                status_code=400, detail="Cursor could not be decoded for json"
            )

        valid_cursor_keys = sorted(
            [
                "order_parameters",
                "row_filter_parameters",
                "search_parameters",
                "artist_id",
                "album_id",
            ]
        )
        if sorted(cursor_dict.keys()) != valid_cursor_keys:
            raise HTTPException(
                status_code=400, detail="Invalid dictionary keys for the cursor_dict"
            )

        order_parameters = [
            OrderParameter(**item) for item in cursor_dict["order_parameters"]
        ]
        search_parameters = [
            SearchParameter(**item) for item in cursor_dict["search_parameters"]
        ]
        row_filter_parameters = [
            RowFilterParameter(**item) for item in cursor_dict["row_filter_parameters"]
        ]
        artist_id = cursor_dict["artist_id"]
        album_id = cursor_dict["album_id"]

    remaining_track_count = library.get_tracks_count(
        search_parameters=search_parameters,
        order_parameters=order_parameters,
        row_filter_parameters=row_filter_parameters,
        artist_id=artist_id,
        album_id=album_id,
    )
    if remaining_track_count is None:
        raise HTTPException(
            status_code=500, detail="Unable to get count of remaining tracks"
        )

    if remaining_track_count == 0 or offset >= remaining_track_count:
        return GetTracksResponse(data=[], nextCursor=None)

    gotten_tracks = library.get_tracks(
        search_parameters=search_parameters,
        order_parameters=order_parameters,
        row_filter_parameters=row_filter_parameters,
        artist_id=artist_id,
        album_id=album_id,
        limit=limit,
        offset=offset,
    )

    client_track_list = [ClientTrack.from_track(track=track) for track in gotten_tracks]
    if len(client_track_list) == remaining_track_count:
        nextCursor = None
    else:
        last_track: ClientTrack = client_track_list[-1]

        new_row_filter_parameters: List[RowFilterParameter] = []
        for order_param in order_parameters:
            col = order_param.column
            # Linked to ALLOWED_TRACK_COLUMNS in app/database/browse.py.
            if col in ["uuid_id", "created_at", "last_updated"]:
                raw_value = getattr(last_track, col)
            else:
                raw_value = getattr(last_track.metadata, col)
            value = str(raw_value) if raw_value is not None else None
            new_row_filter_parameters.append(
                RowFilterParameter(column=col, value=value)
            )

        nextCursor = json.dumps(
            {
                "order_parameters": [asdict(param) for param in order_parameters],
                "row_filter_parameters": [
                    asdict(param) for param in new_row_filter_parameters
                ],
                "search_parameters": [asdict(param) for param in search_parameters],
                "artist_id": artist_id,
                "album_id": album_id,
            }
        )

    return GetTracksResponse(
        data=client_track_list,
        nextCursor=nextCursor,
    )


@router.get("/changes", response_model=GetChangesResponse)
def get_changes(
    after_revision: int = Query(0, ge=0),
    limit: int = Query(500, ge=1, le=1000),
    library: Library = Depends(current_library),
):
    """Revision-based incremental sync. Returns ordered upsert/delete entries
    with ``revision > after_revision``; the client persists the last applied
    entry's revision and pages until ``nextCursor`` is null. ``after_revision=0``
    is a full resync."""
    try:
        changes, latest_revision, next_cursor = library.get_changes(
            after_revision=after_revision, limit=limit
        )
    except Exception as e:
        raise HTTPException(
            status_code=500, detail="Failed to fetch changes"
        ) from e

    entries = [
        ChangeEntry(
            type=change.type,
            revision=change.revision,
            uuid_id=change.uuid_id,
            track=(
                ClientTrack.from_track(track=change.track)
                if change.track is not None
                else None
            ),
        )
        for change in changes
    ]

    return GetChangesResponse(
        changes=entries,
        nextCursor=next_cursor,
        latestRevision=latest_revision,
    )


_IMAGE_MIME: dict[str, str] = {
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".png": "image/png",
    ".webp": "image/webp",
    ".gif": "image/gif",
    ".bmp": "image/bmp",
    ".tiff": "image/tiff",
}


@router.get("/cover_art/{cover_art_id}")
def get_cover_art(cover_art_id: int, library: Library = Depends(current_library)):
    # Busy is a retryable 503, as PATCH answers (Phase 10 replaces it with its typed busy answer).
    try:
        art = library.get_owned_cover_art(cover_art_id)
    except sqlite3.OperationalError as e:
        if "locked" in str(e).lower():
            raise HTTPException(status_code=503, detail="Database busy, retry")
        raise
    path = None if art is None else art.file_path
    if path is None or not path.exists():
        raise HTTPException(status_code=404, detail="Cover art not found")
    media_type = _IMAGE_MIME.get(path.suffix.lower(), "image/jpeg")
    return FileResponse(
        path,
        media_type=media_type,
        headers={"Cache-Control": "private, max-age=31536000, immutable"},
    )


@router.get("/tracks/{uuid_id:uuid}/stream")
def stream_track(
    uuid_id: UUID,
    request: Request,
    quality: Optional[str] = None,
    library: Library = Depends(current_library),
):
    uuid_id = str(uuid_id)
    CHUNK_SIZE = 1024 * 1024
    try:
        quality_canonical = normalize_quality(quality)
    except ValueError:
        raise HTTPException(
            status_code=422,
            detail=f"Unsupported quality preset: {quality}",
        )

    try:
        opened = open_track_source(
            library,
            uuid_id,
            quality_canonical,
            coordinator=request.app.state.encoder_coordinator,
        )
    except TrackSourceError as exc:
        raise exc.http()
    track = opened.track
    encode_result = opened.encode
    file_path = encode_result.path

    # Use audio/mp4 only when we actually transcoded; for passthrough (including
    # ORIGINAL_QUALITY and bitrate-based passthrough) use the source codec's type
    # so the MIME header always matches what is actually being served.
    if encode_result.transcoded:
        media_type = "audio/mp4"
    else:
        media_type = CODEC_MIME.get(
            track.metadata.codec or "", f"audio/{track.metadata.codec or 'octet-stream'}"
        )

    # For passthrough/original responses, the source's own file extension is
    # a better fallback than the literal string "audio" when the codec is not
    # in [MIME_EXTENSION] (e.g. opus, vorbis) — that name is what the client
    # would have got had it downloaded the source directly.
    extension = MIME_EXTENSION.get(media_type)
    if extension is None:
        source_suffix = file_path.suffix.lstrip(".").lower() if not encode_result.transcoded else ""
        extension = source_suffix or "audio"

    # Codec + revision of what is actually served, so a client that saves the
    # bytes can record exactly what it has (the revision is read before the
    # encode, so a conversion landing mid-request errs toward "stale").
    # X-Audio-Bitrate-Kbps is omitted when the bitrate is unknown, so the
    # client records "unknown" rather than a fabricated 0.
    extra_headers = {
        **(
            {"X-Audio-Bitrate-Kbps": str(encode_result.bitrate_kbps)}
            if encode_result.bitrate_kbps is not None else {}
        ),
        "X-Audio-Extension": extension,
        "X-Audio-Codec": "aac" if encode_result.transcoded else (track.metadata.codec or ""),
        "X-Track-Revision": str(track.revision),
    }

    return ranged_file_response(
        opened.file,
        media_type=media_type,
        range_header=request.headers.get("range"),
        headers=extra_headers,
        chunk_size=CHUNK_SIZE,
    )


# Deprecated (the owner's decision of 2026-11-14): no app code calls this route;
# the app keeps its own copy of the library through GET /changes. It stays live
# for other clients.
@router.get("/artists", response_model=GetArtistsResponse, deprecated=True)
def get_artists(
    cursor: Optional[str] = None,
    limit: int = Query(100, ge=1, le=500),
    offset: int = Query(0, ge=0),
    library: Library = Depends(current_library),
):
    order_parameters: List[ArtistOrderParameter]
    row_filter_parameters: List[ArtistRowFilterParameter]

    if not cursor:
        order_parameters = [
            ArtistOrderParameter(column="name", isAscending=True),
        ]
        row_filter_parameters = []
    else:
        try:
            decoded = json.loads(cursor)
        except json.JSONDecodeError:
            raise HTTPException(
                status_code=400, detail="Cursor could not be decoded as JSON"
            )
        if not isinstance(decoded, dict):
            raise HTTPException(
                status_code=400, detail="Cursor did not decode to a dict"
            )

        cursor_dict: Dict[str, Any] = decoded
        valid_cursor_keys = sorted(["order_parameters", "row_filter_parameters"])
        if sorted(cursor_dict.keys()) != valid_cursor_keys:
            raise HTTPException(
                status_code=400, detail="Invalid dictionary keys for the cursor"
            )

        order_parameters = [
            ArtistOrderParameter(**item) for item in cursor_dict["order_parameters"]
        ]
        row_filter_parameters = [
            ArtistRowFilterParameter(**item)
            for item in cursor_dict["row_filter_parameters"]
        ]

    remaining_count = library.get_artists_count(
        order_parameters=order_parameters,
        row_filter_parameters=row_filter_parameters,
    )
    if remaining_count is None:
        raise HTTPException(
            status_code=500, detail="Unable to get count of remaining artists"
        )

    if remaining_count == 0 or offset >= remaining_count:
        return GetArtistsResponse(data=[], nextCursor=None)

    returned_artists = library.get_artists(
        order_parameters=order_parameters,
        row_filter_parameters=row_filter_parameters,
        limit=limit,
        offset=offset,
    )

    if returned_artists is None:
        raise HTTPException(
            status_code=500, detail="Unable to fetch artists from the database"
        )

    if len(returned_artists) == remaining_count:
        nextCursor = None
    else:
        last_artist = returned_artists[-1]
        new_row_filter_parameters = [
            ArtistRowFilterParameter(column="name", value=last_artist.name),
        ]

        nextCursor = json.dumps(
            {
                "order_parameters": [asdict(param) for param in order_parameters],
                "row_filter_parameters": [
                    asdict(param) for param in new_row_filter_parameters
                ],
            }
        )

    return GetArtistsResponse(data=returned_artists, nextCursor=nextCursor)


# Deprecated (the owner's decision of 2026-11-14): no app code calls this route;
# the app keeps its own copy of the library through GET /changes. It stays live
# for other clients.
@router.get("/albums", response_model=GetAlbumsResponse, deprecated=True)
def get_albums(
    cursor: Optional[str] = None,
    limit: int = Query(500, ge=1, le=1000),
    offset: int = Query(0, ge=0),
    artist_id: Optional[int] = None,
    library: Library = Depends(current_library),
):
    order_parameters: List[AlbumOrderParameter]
    row_filter_parameters: List[AlbumRowFilterParameter]

    if not cursor:
        if artist_id is not None:
            order_parameters = [
                AlbumOrderParameter(column="year", isAscending=False, nullsLast=True),
                AlbumOrderParameter(column="is_single_grouping", isAscending=True),
                AlbumOrderParameter(column="name", isAscending=True, nullsLast=True),
            ]
        else:
            order_parameters = [
                AlbumOrderParameter(column="artist", isAscending=True, nullsLast=True),
                AlbumOrderParameter(column="year", isAscending=False, nullsLast=True),
                AlbumOrderParameter(column="is_single_grouping", isAscending=True),
                AlbumOrderParameter(column="name", isAscending=True, nullsLast=True),
            ]
        row_filter_parameters = []
    else:
        try:
            decoded = json.loads(cursor)
        except json.JSONDecodeError:
            raise HTTPException(
                status_code=400, detail="Cursor could not be decoded as JSON"
            )
        if not isinstance(decoded, dict):
            raise HTTPException(
                status_code=400, detail="Cursor did not decode to a dict"
            )

        cursor_dict: Dict[str, Any] = decoded
        valid_cursor_keys = sorted(
            ["order_parameters", "row_filter_parameters", "artist_id"]
        )
        if sorted(cursor_dict.keys()) != valid_cursor_keys:
            raise HTTPException(
                status_code=400, detail="Invalid dictionary keys for the cursor"
            )

        order_parameters = [
            AlbumOrderParameter(**item) for item in cursor_dict["order_parameters"]
        ]
        row_filter_parameters = [
            AlbumRowFilterParameter(**item)
            for item in cursor_dict["row_filter_parameters"]
        ]
        artist_id = cursor_dict["artist_id"]

    remaining_count = library.get_albums_count(
        artist_id=artist_id,
        order_parameters=order_parameters,
        row_filter_parameters=row_filter_parameters,
    )
    if remaining_count is None:
        raise HTTPException(status_code=500, detail="Unable to get count")

    if remaining_count == 0 or offset >= remaining_count:
        return GetAlbumsResponse(data=[], nextCursor=None)

    returned_albums: List[Album] | None = library.get_albums(
        artist_id=artist_id,
        order_parameters=order_parameters,
        row_filter_parameters=row_filter_parameters,
        limit=limit,
        offset=offset,
    )

    if returned_albums is None:
        raise HTTPException(
            status_code=500,
            detail="Unable to fetch albums from the backends database",
        )

    if len(returned_albums) == remaining_count:
        nextCursor = None
    else:
        last_album: Album = returned_albums[-1]
        new_row_filter_parameters: List[AlbumRowFilterParameter] = []
        for order_param in order_parameters:
            col = order_param.column
            raw_value: Any
            if col == "name":
                raw_value = last_album.name
            elif col == "artist":
                raw_value = last_album.artist
            elif col == "year":
                raw_value = last_album.year
            elif col == "is_single_grouping":
                raw_value = 1 if last_album.is_single_grouping else 0
            else:
                raw_value = None
            value = str(raw_value) if raw_value is not None else None
            new_row_filter_parameters.append(
                AlbumRowFilterParameter(column=col, value=value)
            )

        nextCursor = json.dumps(
            {
                "order_parameters": [asdict(param) for param in order_parameters],
                "row_filter_parameters": [
                    asdict(param) for param in new_row_filter_parameters
                ],
                "artist_id": artist_id,
            }
        )

    return GetAlbumsResponse(data=returned_albums, nextCursor=nextCursor)


# Deprecated (the owner's decision of 2026-11-14): no app code calls this route;
# the app keeps its own copy of the library through GET /changes. It stays live
# for other clients.
@router.get("/search", response_model=GetSearchResponse, deprecated=True)
def search(
    q: str = Query(..., min_length=1),
    types: str = Query("tracks,artists,albums"),
    limit: int = Query(10, ge=1, le=50),
    library: Library = Depends(current_library),
):
    return_types = SearchEntityType(0)
    for t in types.split(","):
        t = t.strip().lower()
        if t == "tracks":
            return_types |= SearchEntityType.TRACKS
        elif t == "artists":
            return_types |= SearchEntityType.ARTISTS
        elif t == "albums":
            return_types |= SearchEntityType.ALBUMS

    if not return_types:
        raise HTTPException(status_code=400, detail="No valid types specified")

    results = library.get_search_results(
        query=q,
        return_types=return_types,
        limit_per_type=limit,
    )

    return GetSearchResponse(
        tracks=[ClientTrack.from_track(t) for t in results.tracks],
        artists=results.artists,
        albums=results.albums,
    )
