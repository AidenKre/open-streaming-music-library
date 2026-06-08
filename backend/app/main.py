import json
import os
from contextlib import asynccontextmanager
from dataclasses import asdict
from pathlib import Path
from typing import Any, Dict, List, Optional, cast

from fastapi import FastAPI, HTTPException, Query, Request
from fastapi.responses import FileResponse, StreamingResponse

from app.config import settings
from app.database import (
    AlbumOrderParameter,
    AlbumRowFilterParameter,
    ArtistOrderParameter,
    ArtistRowFilterParameter,
    Database,
    DatabaseContext,
    OrderParameter,
    RowFilterParameter,
    SearchEntityType,
    SearchParameter,
)
from app.models import (
    Album,
    ClientTrack,
    GetAlbumsResponse,
    GetArtistsResponse,
    GetSearchResponse,
    GetTracksResponse,
    WarmRequest,
    WarmResponse,
    QualitySettingResponse,
    SetQualityRequest,
    SetQualityResponse,
    Track,
)
from app.services import (
    CoverArtContext,
    CoverArtManager,
    EncodedCache,
    EncodedCacheContext,
    EncoderCoordinator,
    FileWatcher,
    Ingestor,
    IngestorContext,
    Organizer,
    OrganizerContext,
    ORIGINAL_QUALITY,
    normalize_quality,
)
from app.services.encoder_coordinator import EncodeResult


@asynccontextmanager
async def lifespan(_app: FastAPI):
    startup_event()
    yield
    shutdown_event()


# TODO: Implement locking so that only one uvicorn worker runs startup sequence. Use fasteners with a locking file.
# TODO: Dependency inject depends on get_database into api endpoints (and make the new function needed for this)
app = FastAPI(lifespan=lifespan)


def _resolve_track_source_path(database: Database, uuid_id: str) -> Optional[Path]:
    rows = database.get_tracks(
        search_parameters=[SearchParameter(column="uuid_id", operator="=", value=uuid_id)]
    )
    if not rows:
        return None
    return rows[0].file_path


def startup_event():
    # Set app.state classes to be None
    app.state.database = None
    app.state.cover_art_manager = None
    app.state.organizer = None
    app.state.ingestor = None
    app.state.file_watcher = None
    app.state.encoded_cache = None
    app.state.default_cache = None
    app.state.encoder_coordinator = None

    settings.app_data_dir.mkdir(parents=True, exist_ok=True)
    settings.music_library_dir.mkdir(parents=True, exist_ok=True)
    settings.import_dir.mkdir(parents=True, exist_ok=True)

    print(f"app data dir: {settings.app_data_dir}")

    # Set up database
    database_path = settings.app_data_dir / "database" / "database.db"
    database_path.parent.mkdir(parents=True, exist_ok=True)
    init_sql_path = Path(__file__).parent / "database" / "init.sql"
    database_context = DatabaseContext(
        database_path=database_path, init_sql_path=init_sql_path
    )
    database = Database(context=database_context)
    db_intialized = database.initialize()
    print(f"Database initialized: {db_intialized}")
    app.state.database = database

    # Set up cover art manager
    cover_art_dir = settings.app_data_dir / "cover_art"
    cover_art_dir.mkdir(parents=True, exist_ok=True)
    cover_art_context = CoverArtContext(
        cover_art_dir=cover_art_dir, database=database
    )
    cover_art_manager = CoverArtManager(ctx=cover_art_context)
    app.state.cover_art_manager = cover_art_manager

    # Backfill cover_art_id for tracks ingested before cover art support
    cover_art_manager.backfill_cover_art()

    # Set up the encoded-track cache + coordinator used by the streaming endpoint.
    encoded_cache_dir = settings.app_data_dir / "encoded_cache"
    encoded_cache_dir.mkdir(parents=True, exist_ok=True)
    max_cache_bytes = int(settings.encoded_cache_size_gb * 1024 * 1024 * 1024)
    encoded_cache = EncodedCache(
        ctx=EncodedCacheContext(
            cache_dir=encoded_cache_dir,
            max_size_bytes=max_cache_bytes,
        )
    )
    # Unlimited cache for the server's default streaming quality — these files
    # are never evicted by on-demand traffic.
    default_cache_dir = settings.app_data_dir / "default_cache"
    default_cache_dir.mkdir(parents=True, exist_ok=True)
    default_cache = EncodedCache(
        ctx=EncodedCacheContext(
            cache_dir=default_cache_dir,
            max_size_bytes=0,  # unlimited
        )
    )
    # Resolve the startup default quality. Bad persisted/env values must not
    # leak into EncoderCoordinator — fall through persisted → env → ORIGINAL.
    persisted_quality = database.get_setting("default_streaming_quality")
    default_quality = ORIGINAL_QUALITY
    for candidate, source_label in (
        (persisted_quality, "persisted"),
        (settings.default_streaming_quality, "env/config"),
    ):
        if candidate is None:
            continue
        try:
            default_quality = normalize_quality(candidate)
            break
        except ValueError:
            print(
                f"Invalid {source_label} default_streaming_quality "
                f"{candidate!r}; falling back."
            )
    else:
        print(
            f"No valid default_streaming_quality configured; using "
            f"{ORIGINAL_QUALITY!r}."
        )

    app.state.encoded_cache = encoded_cache
    app.state.default_cache = default_cache
    encoder_coordinator = EncoderCoordinator(
        cache=encoded_cache,
        source_lookup=lambda uuid_id: _resolve_track_source_path(database, uuid_id),
        workers=max(1, settings.encoded_cache_prefetch_workers),
        default_cache=default_cache,
        default_quality=default_quality,
        all_uuids_fn=lambda: database.get_all_track_uuids(),
    )
    app.state.encoder_coordinator = encoder_coordinator
    encoder_coordinator.startup()

    if settings.enable_file_watcher:
        organizer_context = OrganizerContext(
            music_library_dir=settings.music_library_dir,
            should_organize_files=True,
            should_copy_files=False,
            add_to_database=app.state.database.add_track,
            add_cover_art=cover_art_manager.add_album_art_with_status,
            remove_cover_art=cover_art_manager.remove_album_art,
        )

        organizer = Organizer(ctx=organizer_context)
        app.state.organizer = organizer
        workspace_dir = settings.app_data_dir / "workspace"
        workspace_dir.mkdir(parents=True, exist_ok=True)
        ingestor_context = IngestorContext(
            workspace_dir=workspace_dir,
            organize_function=app.state.organizer.organize_file,
        )

        ingestor = Ingestor(ctx=ingestor_context)
        app.state.ingestor = ingestor

        file_watcher = FileWatcher(
            import_dir=settings.import_dir, on_file=app.state.ingestor.ingest_file
        )

        file_watcher.start_file_watcher()
        app.state.file_watcher = file_watcher


def shutdown_event():
    watcher = getattr(app.state, "file_watcher", None)
    if watcher:
        watcher.stop_file_watcher()
    coordinator = getattr(app.state, "encoder_coordinator", None)
    if coordinator:
        coordinator.shutdown()


@app.get("/tracks", response_model=GetTracksResponse)
def get_tracks(
    cursor: Optional[str] = None,
    limit: int = Query(500, ge=1, le=1000),
    offset: int = Query(0, ge=0),
    artist_id: Optional[int] = None,
    album_id: Optional[int] = None,
    newer_than: Optional[int] = None,
    older_than: Optional[int] = None,
):
    database: Database = cast(Database, app.state.database)

    # Capture the original (uncursored) request shape so we can decide
    # whether this call is an unscoped sync — only unscoped, first-page
    # requests are allowed to return tombstones (see Issue #8 for why
    # scoped requests are non-authoritative).
    is_first_page = not cursor
    request_is_scoped = artist_id is not None or album_id is not None
    tombstone_newer_than = newer_than
    tombstone_older_than = older_than

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
        if newer_than:
            search_parameters.append(
                SearchParameter(
                    column="last_updated", operator=">", value=str(newer_than)
                )
            )
        if older_than:
            search_parameters.append(
                SearchParameter(
                    column="last_updated", operator="<=", value=str(older_than)
                )
            )

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

    remaining_track_count = database.get_tracks_count(
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

    # Tombstones piggyback on the unscoped, first-page response so the client
    # only has to make one call per sync. Scoped (artist/album) requests must
    # not return them because they cannot tell whether a tombstone belongs to
    # the scope; subsequent cursor pages skip them to avoid duplicate work.
    deleted_uuids: List[str] = []
    if is_first_page and not request_is_scoped:
        deleted_uuids = database.get_track_tombstones(
            newer_than=tombstone_newer_than,
            older_than=tombstone_older_than,
        )

    if remaining_track_count == 0 or offset >= remaining_track_count:
        return GetTracksResponse(
            data=[], nextCursor=None, deleted_uuids=deleted_uuids
        )

    gotten_tracks = database.get_tracks(
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
            # Linked to allowed track columns in database.py.
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
        deleted_uuids=deleted_uuids,
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


@app.get("/cover_art/{cover_art_id}")
def get_cover_art(cover_art_id: int):
    manager: CoverArtManager = app.state.cover_art_manager
    path = manager.get_album_art(cover_art_id)
    if path is None or not path.exists():
        raise HTTPException(status_code=404, detail="Cover art not found")
    media_type = _IMAGE_MIME.get(path.suffix.lower(), "image/jpeg")
    return FileResponse(
        path,
        media_type=media_type,
        headers={"Cache-Control": "public, max-age=31536000, immutable"},
    )


_MIME_EXTENSION: dict[str, str] = {
    "audio/mp4": "m4a",
    "audio/mpeg": "mp3",
    "audio/flac": "flac",
    "audio/x-flac": "flac",
    "audio/ogg": "ogg",
    "audio/aac": "aac",
    "audio/wav": "wav",
    "audio/x-wav": "wav",
}

_CODEC_MIME: dict[str, str] = {
    "aac": "audio/mp4",
    "alac": "audio/mp4",
    "mp3": "audio/mpeg",
    "flac": "audio/flac",
    "wav": "audio/wav",
    "pcm_s16le": "audio/wav",
    "pcm_s24le": "audio/wav",
    "pcm_f32le": "audio/wav",
}


def _parse_byte_range(range_header: str, file_size: int) -> tuple[int, int]:
    """Parse a single HTTP byte range and return ``(start, end)`` inclusive.

    Supports the three single-range forms from RFC 7233:
      ``bytes=start-end`` — explicit window
      ``bytes=start-``    — from ``start`` to EOF
      ``bytes=-N``        — the last ``N`` bytes (suffix range)

    Anything else — multi-range requests, malformed values, ranges entirely
    past EOF — raises 416. We treat 416 as the right answer for "could not
    parse" too: returning a 200 with the whole file would silently mask a
    bad client header.
    """
    if "," in range_header:
        # Multi-range responses require multipart/byteranges; we only serve
        # single ranges, so reject explicitly rather than serving the first.
        raise HTTPException(
            status_code=416,
            detail=f"Multi-range requests are not supported: {range_header}",
        )

    if "=" not in range_header:
        raise HTTPException(
            status_code=416, detail=f"Invalid Range Header: {range_header}"
        )

    units, _, rng = range_header.partition("=")
    if units.strip().lower() != "bytes":
        raise HTTPException(
            status_code=422,
            detail=f"range must be in bytes. Instead {units} was used",
        )

    rng = rng.strip()
    # Exactly one "-" separator; partition guarantees that. The earlier
    # split("-") accepted "1-2-3" by silently dropping the tail.
    if rng.count("-") != 1:
        raise HTTPException(
            status_code=416, detail=f"Invalid Range Header: {range_header}"
        )
    start_s, end_s = rng.split("-")

    try:
        if not start_s and not end_s:
            # "bytes=-" — malformed.
            raise ValueError("empty range")
        if not start_s:
            # Suffix range: last N bytes.
            suffix_len = int(end_s)
            if suffix_len <= 0:
                raise ValueError("non-positive suffix length")
            if suffix_len >= file_size:
                start = 0
            else:
                start = file_size - suffix_len
            end = file_size - 1
        else:
            start = int(start_s)
            if start < 0:
                raise ValueError("negative start")
            end = int(end_s) if end_s else file_size - 1
            if end < 0:
                raise ValueError("negative end")
    except ValueError:
        raise HTTPException(
            status_code=416, detail=f"Invalid Range Header: {range_header}"
        )

    if start >= file_size or end >= file_size or start > end:
        raise HTTPException(
            status_code=416, detail=f"Range not satisfiable: {range_header}"
        )

    return start, end


@app.get("/tracks/{uuid_id}/stream")
def stream_track(uuid_id: str, request: Request, quality: Optional[str] = None):
    CHUNK_SIZE = 1024 * 1024
    try:
        quality_canonical = normalize_quality(quality)
    except ValueError:
        raise HTTPException(
            status_code=422,
            detail=f"Unsupported quality preset: {quality}",
        )

    search_parameters = [SearchParameter(column="uuid_id", operator="=", value=uuid_id)]
    track_list: List[Track] = app.state.database.get_tracks(
        search_parameters=search_parameters
    )
    if len(track_list) <= 0:
        raise HTTPException(
            status_code=404, detail=f"Could not find track with uuid: {uuid_id}"
        )
    track: Track = track_list[0]
    source_bitrate = int(track.metadata.bitrate_kbps or 0) or None

    coordinator: EncoderCoordinator = app.state.encoder_coordinator
    encode_result: Optional[EncodeResult] = coordinator.encode_for_stream(
        uuid_id, quality_canonical, source_bitrate_kbps=source_bitrate
    )
    if encode_result is None:
        raise HTTPException(
            status_code=500,
            detail=f"Unable to encode track {uuid_id} at quality {quality_canonical}",
        )
    file_path = encode_result.path

    # Use audio/mp4 only when we actually transcoded; for passthrough (including
    # ORIGINAL_QUALITY and bitrate-based passthrough) use the source codec's type
    # so the MIME header always matches what is actually being served.
    if encode_result.transcoded:
        media_type = "audio/mp4"
    else:
        media_type = _CODEC_MIME.get(
            track.metadata.codec or "", f"audio/{track.metadata.codec or 'octet-stream'}"
        )

    extra_headers = {
        "X-Audio-Bitrate-Kbps": str(encode_result.bitrate_kbps),
        "X-Audio-Extension": _MIME_EXTENSION.get(media_type, "audio"),
    }

    # Open the cache file eagerly (before returning the StreamingResponse) so
    # the active file descriptor pins the inode. EncodedCache pruning and
    # default-quality changes may unlink the path after we validate it but
    # before a lazy generator would otherwise open it; on Unix the open
    # handle keeps the data readable even after unlink, so streaming
    # survives concurrent cache eviction.
    try:
        f = file_path.open("rb")
    except FileNotFoundError:
        raise HTTPException(
            status_code=404,
            detail=f"file path for the track is now dead. Path: {file_path}",
        )

    try:
        file_size = os.fstat(f.fileno()).st_size
        range_header = request.headers.get("range")

        if not range_header:

            def iterfile(handle):
                try:
                    while chunk := handle.read(CHUNK_SIZE):
                        yield chunk
                finally:
                    handle.close()

            response = StreamingResponse(
                iterfile(f),
                media_type=media_type,
                headers={
                    "Accept-ranges": "bytes",
                    "Content-length": str(file_size),
                    **extra_headers,
                },
            )
            f = None  # ownership transferred to the generator
            return response

        start, end = _parse_byte_range(range_header, file_size)
        content_length = end - start + 1
        f.seek(start)

        def iter_range(handle, remaining_bytes):
            try:
                while remaining_bytes:
                    chunk = handle.read(min(CHUNK_SIZE, remaining_bytes))
                    if not chunk:
                        break
                    remaining_bytes -= len(chunk)
                    yield chunk
            finally:
                handle.close()

        response = StreamingResponse(
            iter_range(f, content_length),
            status_code=206,
            media_type=media_type,
            headers={
                "Accept-ranges": "bytes",
                "Content-range": f"bytes {start}-{end}/{file_size}",
                "Content-length": str(content_length),
                **extra_headers,
            },
        )
        f = None  # ownership transferred to the generator
        return response
    finally:
        if f is not None:
            f.close()


@app.get("/artists", response_model=GetArtistsResponse)
def get_artists(
    cursor: Optional[str] = None,
    limit: int = Query(100, ge=1, le=500),
    offset: int = Query(0, ge=0),
):
    database: Database = cast(Database, app.state.database)

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

    remaining_count = database.get_artists_count(
        order_parameters=order_parameters,
        row_filter_parameters=row_filter_parameters,
    )
    if remaining_count is None:
        raise HTTPException(
            status_code=500, detail="Unable to get count of remaining artists"
        )

    if remaining_count == 0 or offset >= remaining_count:
        return GetArtistsResponse(data=[], nextCursor=None)

    returned_artists = database.get_artists(
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


@app.get("/albums", response_model=GetAlbumsResponse)
def get_albums(
    cursor: Optional[str] = None,
    limit: int = Query(500, ge=1, le=1000),
    offset: int = Query(0, ge=0),
    artist_id: Optional[int] = None,
):
    database: Database = cast(Database, app.state.database)

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

    remaining_count = database.get_albums_count(
        artist_id=artist_id,
        order_parameters=order_parameters,
        row_filter_parameters=row_filter_parameters,
    )
    if remaining_count is None:
        raise HTTPException(status_code=500, detail="Unable to get count")

    if remaining_count == 0 or offset >= remaining_count:
        return GetAlbumsResponse(data=[], nextCursor=None)

    returned_albums: List[Album] | None = database.get_albums(
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


@app.get("/search", response_model=GetSearchResponse)
def search(
    q: str = Query(..., min_length=1),
    types: str = Query("tracks,artists,albums"),
    limit: int = Query(10, ge=1, le=50),
):
    database: Database = cast(Database, app.state.database)

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

    results = database.get_search_results(
        query=q,
        return_types=return_types,
        limit_per_type=limit,
    )

    return GetSearchResponse(
        tracks=[ClientTrack.from_track(t) for t in results.tracks],
        artists=results.artists,
        albums=results.albums,
    )


_WARM_MAX_UUIDS = 500


@app.post("/tracks/warm", response_model=WarmResponse)
def warm_tracks(request: WarmRequest):
    if len(request.track_uuids) > _WARM_MAX_UUIDS:
        raise HTTPException(
            status_code=422,
            detail=f"Too many track_uuids: max {_WARM_MAX_UUIDS}",
        )
    try:
        quality_canonical = normalize_quality(request.quality)
    except ValueError:
        raise HTTPException(
            status_code=422,
            detail=f"Unsupported quality preset: {request.quality}",
        )

    coordinator: EncoderCoordinator = app.state.encoder_coordinator
    lookahead = settings.prefetch_lookahead
    start = request.current_index
    end = min(start + lookahead, len(request.track_uuids))
    prefetch_count = 0
    for i in range(start, end):
        if coordinator.enqueue_prefetch(request.track_uuids[i], quality_canonical):
            prefetch_count += 1

    return WarmResponse(accepted=True, prefetch_queued=prefetch_count)


@app.get("/settings/quality", response_model=QualitySettingResponse)
def get_quality_setting():
    coordinator: EncoderCoordinator = app.state.encoder_coordinator
    return QualitySettingResponse(quality=coordinator.default_quality)


@app.put("/settings/quality", response_model=SetQualityResponse)
def set_quality_setting(request: SetQualityRequest):
    try:
        quality_canonical = normalize_quality(request.quality)
    except ValueError:
        raise HTTPException(
            status_code=422,
            detail=f"Unsupported quality preset: {request.quality}",
        )

    coordinator: EncoderCoordinator = app.state.encoder_coordinator
    database: Database = cast(Database, app.state.database)

    try:
        _, warming = coordinator.persist_and_set_default_quality(
            quality_canonical,
            lambda q: database.set_setting("default_streaming_quality", q),
        )
    except Exception:
        raise HTTPException(
            status_code=500,
            detail="Failed to persist default quality setting",
        )

    return SetQualityResponse(quality=quality_canonical, warming=warming)


@app.get("/")
def read_root():
    return {"message": "Healthy"}
