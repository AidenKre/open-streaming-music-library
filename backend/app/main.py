import json
import os
import sqlite3
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
    EmptyTrackEdit,
    OrderParameter,
    RevisionConflict,
    RowFilterParameter,
    SearchEntityType,
    SearchParameter,
    TrackNotFound,
)
from app.models import (
    Album,
    AppInfoResponse,
    ChangeEntry,
    ClientTrack,
    EntityInfo,
    FieldDescriptor,
    GetAlbumsResponse,
    GetArtistsResponse,
    GetChangesResponse,
    GetSearchResponse,
    GetTracksResponse,
    PatchTrackResponse,
    WarmRequest,
    WarmResponse,
    QualitySettingResponse,
    SetQualityRequest,
    SetQualityResponse,
    Track,
)
from app.models.edit_fields import EDIT_FIELD_SPECS
from app.services.metadata import TagWriteError
from app.services.track_edit import (
    TrackPatchRequest,
    WriteMode,
)
from app.services.track_editor import (
    MasterWriteError,
    TrackEditor,
    reconcile_journal,
)
from app.services.track_locks import TrackLocks
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
from app.services.encoder_coordinator import (
    EncodeResult,
    PrefetchOutcome,
    SourceUnavailable,
)


@asynccontextmanager
async def lifespan(_app: FastAPI):
    startup_event()
    yield
    shutdown_event()


# TODO: Implement locking so that only one uvicorn worker runs startup sequence. Use fasteners with a locking file.
# TODO: Dependency inject depends on get_database into api endpoints (and make the new function needed for this)
app = FastAPI(lifespan=lifespan)


def _resolve_track_source_path(database: Database, uuid_id: str) -> Optional[Path]:
    track = database.get_track_by_uuid(uuid_id)
    return track.file_path if track is not None else None


def _assert_dirs_non_overlapping(import_dir: Path, library_dir: Path) -> None:
    """Fail startup if import_dir and music_library_dir are the same or one is
    nested in the other — otherwise edit staging (under the library) could be
    re-ingested by the import watcher."""
    a = import_dir.resolve()
    b = library_dir.resolve()
    if a == b or a in b.parents or b in a.parents:
        raise RuntimeError(
            f"import_dir ({a}) and music_library_dir ({b}) must not overlap"
        )


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
    # Per-uuid edit lock. Built once here so slice 4's master-file staging and
    # Phase 2's conversion worker share the identical instance.
    app.state.track_locks = TrackLocks()

    settings.app_data_dir.mkdir(parents=True, exist_ok=True)
    settings.music_library_dir.mkdir(parents=True, exist_ok=True)
    settings.import_dir.mkdir(parents=True, exist_ok=True)

    # The watcher ingests anything dropped in import_dir; edit staging lives
    # under music_library_dir. If those trees overlapped, a staged temp could be
    # re-ingested as a new track. Fail fast rather than corrupt the library.
    _assert_dirs_non_overlapping(settings.import_dir, settings.music_library_dir)

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

    # Master-file edit orchestration. Staging lives under the library so a
    # staged temp is on the same filesystem as its destination (atomic
    # os.replace / rename) yet off the watched import tree.
    staging_dir = settings.music_library_dir / ".staging"
    staging_dir.mkdir(parents=True, exist_ok=True)
    app.state.track_editor = TrackEditor(
        database=database,
        music_library_dir=settings.music_library_dir,
        staging_dir=staging_dir,
    )
    # Finish/revert any edit interrupted by a crash before serving requests.
    reconcile_journal(database, settings.music_library_dir)

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
):
    """Browse tracks in display order (artist/album/disc/track), optionally
    scoped by artist/album, with keyset cursor pagination. Incremental sync
    lives on ``GET /changes`` — this endpoint no longer windows by timestamp
    or returns tombstones."""
    database: Database = cast(Database, app.state.database)

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

    if remaining_track_count == 0 or offset >= remaining_track_count:
        return GetTracksResponse(data=[], nextCursor=None)

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
    )


@app.get("/changes", response_model=GetChangesResponse)
def get_changes(
    after_revision: int = Query(0, ge=0),
    limit: int = Query(500, ge=1, le=1000),
):
    """Revision-based incremental sync. Returns ordered upsert/delete entries
    with ``revision > after_revision``; the client persists the last applied
    entry's revision and pages until ``nextCursor`` is null. ``after_revision=0``
    is a full resync."""
    database: Database = cast(Database, app.state.database)

    try:
        changes, latest_revision, next_cursor = database.get_changes(
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
    try:
        encode_result: Optional[EncodeResult] = coordinator.encode_for_stream(
            uuid_id,
            quality_canonical,
            source_bitrate_kbps=source_bitrate,
            source_path=track.file_path,
        )
    except SourceUnavailable:
        # Track row exists but its source file is gone — 404 so clients drop it
        # instead of retrying a permanently-missing file as if it were transient.
        raise HTTPException(
            status_code=404,
            detail=f"Source file for track {uuid_id} is no longer available",
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

    # For passthrough/original responses, the source's own file extension is
    # a better fallback than the literal string "audio" when the codec is not
    # in [_MIME_EXTENSION] (e.g. opus, vorbis) — that name is what the client
    # would have got had it downloaded the source directly.
    extension = _MIME_EXTENSION.get(media_type)
    if extension is None:
        source_suffix = file_path.suffix.lstrip(".").lower() if not encode_result.transcoded else ""
        extension = source_suffix or "audio"

    extra_headers = {
        "X-Audio-Bitrate-Kbps": str(encode_result.bitrate_kbps),
        "X-Audio-Extension": extension,
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
    window = request.count if request.count is not None else settings.prefetch_lookahead
    start = request.current_index
    end = min(start + window, len(request.track_uuids))
    queued = 0
    skipped = 0
    for i in range(start, end):
        outcome = coordinator.enqueue_prefetch(
            request.track_uuids[i], quality_canonical
        )
        if outcome == PrefetchOutcome.QUEUED:
            queued += 1
        elif outcome in (
            PrefetchOutcome.ALREADY_CACHED,
            PrefetchOutcome.SKIPPED_ORIGINAL,
        ):
            skipped += 1

    return WarmResponse(
        accepted=True, prefetch_queued=queued, prefetch_skipped=skipped
    )


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


@app.get("/app/info", response_model=AppInfoResponse)
def get_app_info():
    """App-level bootstrap: per-entity editable fields + actions. Backed by the
    same edit allowlist that gates PATCH, so advertised == accepted. Cached
    client-side; later phases extend this rather than add endpoints."""
    track_fields = [
        FieldDescriptor(key=spec.key, label=spec.label, valueType=spec.value_type)
        for spec in EDIT_FIELD_SPECS
    ]
    return AppInfoResponse(
        entities={"track": EntityInfo(fields=track_fields, actions=[])}
    )


@app.get("/tracks/{uuid_id}", response_model=ClientTrack)
def get_track(uuid_id: str):
    """Authoritative current state of a single track. Lets a client reconcile
    one track to server truth without a watermark-driven `/changes` pull — used
    by edit-conflict "take server" resolution, where the watermark may already
    have advanced past the conflicting revision. 404 if the track is gone."""
    database: Database = cast(Database, app.state.database)
    track = database.get_track_by_uuid(uuid_id)
    if track is None:
        raise HTTPException(status_code=404, detail="Track not found")
    return ClientTrack.from_track(track=track)


@app.patch("/tracks/{uuid_id}", response_model=PatchTrackResponse)
def patch_track(uuid_id: str, request: TrackPatchRequest):
    """Partial track metadata edit. Non-allowlisted fields + type/range are
    rejected by ``TrackPatchRequest`` (422). ``db_only`` writes the DB; the
    confirmation-gated ``db_and_master`` also rewrites the file tags and
    relocates the master when artist/album change (WAV / missing master degrade
    to DB-only with ``master_written=False``). Per-uuid serialized; the DB
    layer's typed conflicts map to HTTP status codes."""
    track_editor: TrackEditor = app.state.track_editor
    track_locks: TrackLocks = app.state.track_locks

    try:
        with track_locks.lock(uuid_id):
            new_revision, master_written = track_editor.apply_edit(
                uuid_id=uuid_id,
                fields=request.edit_fields(),
                base_revision=request.base_revision,
                write_mode=request.write_mode,
            )
    except TrackNotFound:
        raise HTTPException(status_code=404, detail="Track not found")
    except RevisionConflict as e:
        raise HTTPException(
            status_code=409,
            detail={
                "error": "revision_conflict",
                "current_revision": e.current_revision,
            },
        )
    except EmptyTrackEdit:
        raise HTTPException(
            status_code=422,
            detail="Edit would leave the track with no title, artist, "
            "album, or album artist",
        )
    except (TagWriteError, MasterWriteError) as e:
        raise HTTPException(status_code=500, detail=f"Master file write failed: {e}")
    except sqlite3.OperationalError as e:
        if "locked" in str(e).lower():
            raise HTTPException(
                status_code=503, detail="Database busy, retry"
            )
        raise

    return PatchTrackResponse(
        uuid_id=uuid_id, revision=new_revision, master_written=master_written
    )


@app.get("/")
def read_root():
    return {"message": "Healthy"}
