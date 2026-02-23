import json
from contextlib import asynccontextmanager
from dataclasses import asdict
from pathlib import Path
from typing import Any, Dict, List, Optional, cast

from fastapi import FastAPI, HTTPException, Query, Request
from fastapi.responses import StreamingResponse

from app.config import settings
from app.database import Database, DatabaseContext, OrderParameter, SearchParameter
from app.models import (
    ClientTrack,
    GetArtistsResponse,
    GetTracksResponse,
    Track,
    track_meta_data,
)
from app.services import (
    FileWatcher,
    Ingestor,
    IngestorContext,
    Organizer,
    OrganizerContext,
)


@asynccontextmanager
async def lifespan(app: FastAPI):
    startup_event()
    yield
    shutdown_event()


# TODO: Implement locking so that only one uvicorn worker runs startup sequence. Use fasteners with a locking file.
# TODO: Dependency inject depends on get_database into api endpoints (and make the new function needed for this)
app = FastAPI(lifespan=lifespan)


def startup_event():
    # Set app.state classes to be None
    app.state.database = None
    app.state.organizer = None
    app.state.ingestor = None
    app.state.file_watcher = None

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

    if settings.enable_file_watcher:
        organizer_context = OrganizerContext(
            music_library_dir=settings.music_library_dir,
            should_organize_files=True,
            should_copy_files=False,
            add_to_database=app.state.database.add_track,
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


@app.get("/tracks", response_model=GetTracksResponse)
def get_tracks(
    cursor: Optional[str] = None,
    limit: int = Query(500, ge=1, le=1000),
    offset: int = Query(0, ge=0),
    newer_than: Optional[int] = None,
):
    database: Database = cast(Database, app.state.database)

    search_parameters: List[SearchParameter]
    order_parameters: List[OrderParameter]
    if not cursor:
        order_parameters = [
            OrderParameter(column="artist", isAscending=True),
            OrderParameter(column="album", isAscending=True),
            OrderParameter(column="disc_number", isAscending=True),
            OrderParameter(column="track_number", isAscending=True),
        ]
        search_parameters = []
        if newer_than:
            search_parameters = [
                SearchParameter(
                    column="last_updated", operator=">", value=str(newer_than)
                )
            ]
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

        cursor_dict: Dict[str, List[Any]] = decoded

        if not cursor_dict:
            raise HTTPException(
                status_code=400, detail="Cursor could not be decoded for json"
            )

        valid_cursor_keys = ["order_parameters", "search_parameters"]
        valid_cursor_keys = sorted(valid_cursor_keys)
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

    remaining_track_count = database.get_tracks_count(
        search_parameters=search_parameters
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
        limit=limit,
        offset=offset,
    )

    client_track_list = [ClientTrack.from_track(track=track) for track in gotten_tracks]
    if len(client_track_list) == remaining_track_count:
        nextCursor = None
    else:
        last_track: ClientTrack = client_track_list[-1]
        new_search_parameters: List[SearchParameter] = []
        for param in search_parameters:
            # TODO: Fix this shit code... I am lazy
            if param.column == "artist" and param.operator == ">":
                continue
            elif param.column == "album" and param.operator == ">":
                continue
            elif param.column == "disc_number" and param.operator == ">":
                continue
            elif param.column == "track_number" and param.operator == ">":
                continue

            new_param = param

            new_search_parameters.append(new_param)

        cursor_filters = []
        if last_track.metadata.artist:
            cursor_filters.append(
                SearchParameter(
                    column="artist", operator=">", value=last_track.metadata.artist
                )
            )

        if last_track.metadata.album:
            cursor_filters.append(
                SearchParameter(
                    column="album", operator=">", value=last_track.metadata.album
                )
            )

        if last_track.metadata.disc_number:
            cursor_filters.append(
                SearchParameter(
                    column="disc_number",
                    operator=">",
                    value=str(last_track.metadata.disc_number),
                )
            )

        if last_track.metadata.track_number:
            cursor_filters.append(
                SearchParameter(
                    column="track_number",
                    operator=">",
                    value=str(last_track.metadata.track_number),
                )
            )

        new_search_parameters.extend(cursor_filters)

        nextCursor = json.dumps(
            {
                "order_parameters": [asdict(param) for param in order_parameters],
                "search_parameters": [asdict(param) for param in new_search_parameters],
            }
        )
        print(nextCursor)

    return GetTracksResponse(data=client_track_list, nextCursor=nextCursor)


@app.get("/tracks/{uuid_id}/stream")
def stream_track(uuid_id: str, request: Request):
    CHUNK_SIZE = 1024 * 1024
    search_parameters = [SearchParameter(column="uuid_id", operator="=", value=uuid_id)]
    track_list: List[Track] = app.state.database.get_tracks(
        search_parameters=search_parameters
    )
    if len(track_list) <= 0:
        raise HTTPException(
            status_code=404, detail=f"Could not find track with uuid: {uuid_id}"
        )
    track: Track = track_list[0]
    file_path = track.file_path
    if not file_path.exists():
        raise HTTPException(
            status_code=404,
            detail=f"file path for the track is now dead. Path: {file_path}",
        )
    file_size = file_path.stat().st_size
    range_header = request.headers.get("range")

    if not range_header:

        def iterfile():
            with file_path.open("rb") as f:
                while chunk := f.read(CHUNK_SIZE):
                    yield chunk

        return StreamingResponse(
            iterfile(),
            media_type=f"audio/{track.metadata.codec}",
            headers={"Accept-ranges": "bytes", "Content-length": str(file_size)},
        )

    try:
        units, rng = range_header.split("=")
        if units.strip().lower() != "bytes":
            raise HTTPException(
                status_code=422,
                detail=f"range must be in bytes. Instead {units} was used",
            )

        start_s, end_s = (rng.split("-") + [""])[:2]
        start = int(start_s) if start_s else 0
        end = int(end_s) if end_s else file_size - 1
    except Exception:
        raise HTTPException(
            status_code=416, detail=f"Invalid Range Header: {range_header}"
        )

    if start < 0 or end >= file_size or start > end:
        raise HTTPException(
            status_code=416, detail=f"Range not satisfiable: {range_header}"
        )

    content_length = end - start + 1

    def iter_range():
        with file_path.open("rb") as f:
            f.seek(start)
            remaining_bytes = content_length
            while remaining_bytes:
                chunk = f.read(min(CHUNK_SIZE, remaining_bytes))
                remaining_bytes -= len(chunk)
                yield chunk

    return StreamingResponse(
        iter_range(),
        status_code=206,
        media_type=f"audio/{track.metadata.codec}",
        headers={
            "Accept-ranges": "bytes",
            "Content-range": f"bytes {start}-{end}/{file_size}",
            "Content-length": str(content_length),
        },
    )


@app.get("/artists", response_model=GetArtistsResponse)
def get_artists(
    limit: int = Query(100, ge=1, le=500),
    offset: int = Query(0, ge=0),
    cursor: Optional[str] = None,
):
    artist_count = app.state.database.get_artists_count()
    if not artist_count:
        raise HTTPException(
            status_code=500, detail="Server was unable to get count of all artists"
        )

    if artist_count <= 0:
        return GetArtistsResponse(data=[], nextCursor=None)

    if cursor:
        try:
            limit_s, offset_s = cursor.split("-")
            limit = int(limit_s)
            offset = int(offset_s)
        except Exception:
            raise HTTPException(status_code=422, detail="Cursor format was invalid")

    if offset >= artist_count:
        return GetArtistsResponse(data=[], nextCursor=None)

    returned_artists: List[str] = app.state.database.get_artists(
        limit=limit, offset=offset
    )

    if limit + offset >= artist_count:
        nextCursor = None
    else:
        nextCursor = f"{limit}-{limit + offset}"

    return GetArtistsResponse(data=returned_artists, nextCursor=nextCursor)


@app.get("/artists/{artist}/albums", response_model=GetArtistsResponse)
def get_artist_album(
    artist: str,
    limit: int = Query(500, ge=1, le=1000),
    offset: int = Query(0, ge=0),
    cursor: Optional[str] = None,
):
    album_count = app.state.database.get_artist_albums_count(artist=artist)
    if album_count is None:
        raise HTTPException(status_code=500, detail="Unable to get count")

    if cursor:
        try:
            limit_s, offset_s = cursor.split("-")
            limit = int(limit_s)
            offset = int(offset_s)
        except Exception:
            raise HTTPException(status_code=422, detail="Cursor format was invalid")

    if offset >= album_count or album_count == 0:
        return GetArtistsResponse(data=[], nextCursor=None)

    returned_albums: List[str] = app.state.database.get_artist_albums(
        artist=artist, limit=limit, offset=offset
    )

    if limit + offset >= album_count:
        nextCursor = None
    else:
        nextCursor = f"{limit}-{offset + limit}"
    return GetArtistsResponse(data=returned_albums, nextCursor=nextCursor)


@app.get("/")
def read_root():
    return {"message": "Hello, World!"}
