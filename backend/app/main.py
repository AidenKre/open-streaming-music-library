import json
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any, Dict, List, Optional

from fastapi import FastAPI, HTTPException, Query, Request
from fastapi.responses import StreamingResponse

from app.config import settings
from app.database import Database, DatabaseContext
from app.models import ClientTrack, GetArtistsResponse, GetTracksResponse, Track
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
    total_track_count = app.state.database.get_tracks_count()
    if total_track_count is None:
        raise HTTPException(
            status_code=500, detail="Could not find a total track count"
        )
    if not cursor:
        order_parameters = {"artist": "ASC", "album": "ASC", "track_number": "ASC"}
        search_parameters = {}
        if newer_than:
            search_parameters["last_updated"] = newer_than
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

        if total_track_count == 0 or offset >= total_track_count:
            return GetTracksResponse(data=[], nextCursor=None)

        valid_cursor_keys = ["order_parameters", "search_parameters", "limit", "offset"]
        valid_cursor_keys = sorted(valid_cursor_keys)
        if sorted(cursor_dict.keys()) != valid_cursor_keys:
            raise HTTPException(
                status_code=400, detail="Invalid dictionary keys for the cursor_dict"
            )
        order_parameters = cursor_dict["order_parameters"]
        search_parameters = cursor_dict["search_parameters"]
        limit = cursor_dict["limit"]
        offset = cursor_dict["offset"]

    gotten_tracks = app.state.database.get_tracks(
        search_parameters=search_parameters,
        order_parameters=order_parameters,
        limit=limit,
        offset=offset,
    )

    client_track_list = [ClientTrack.from_track(track=track) for track in gotten_tracks]
    if offset + limit >= total_track_count:
        nextCursor = None
    else:
        nextCursor = json.dumps(
            {
                "order_parameters": order_parameters,
                "search_parameters": search_parameters,
                "limit": limit,
                "offset": offset + limit,
            }
        )

    return GetTracksResponse(data=client_track_list, nextCursor=nextCursor)


@app.get("/tracks/{uuid_id}/stream")
def stream_track(uuid_id: str, request: Request):
    CHUNK_SIZE = 1024 * 1024
    search_parameters = {"uuid_id": uuid_id}
    track_list: List[Track] = []
    track_list = app.state.database.get_tracks(search_parameters=search_parameters)
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
            return HTTPException(
                status_code=422,
                detail=f"range must be in bytes. Instead {units} was used",
            )

        start_s, end_s = (rng.split("-") + [""])[:2]
        start = int(start_s) if start_s else 0
        end = int(end_s) if end_s else file_size - 1
    except Exception:
        return HTTPException(
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
