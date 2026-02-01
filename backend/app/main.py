from pathlib import Path
from typing import Optional

from fastapi import FastAPI, HTTPException, Query

from app.config import settings
from app.database import Database, DatabaseContext
from app.models import ClientTrack, GetArtistsResponse, GetTracksResponse
from app.models.api_return_models import GetArtistsResponse
from app.services import (
    FileWatcher,
    Ingestor,
    IngestorContext,
    Organizer,
    OrganizerContext,
)

# TODO: Implement locking so that only one uvicorn worker runs startup sequence. Use fasteners with a locking file.
app = FastAPI()


@app.on_event("startup")
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


@app.on_event("shutdown")
def shutdown_event():
    watcher = getattr(app.state, "file_watcher", None)
    if watcher:
        watcher.stop_file_watcher()


@app.get("/tracks", response_model=GetTracksResponse)
def get_tracks(
    cursor: Optional[dict] = None,
    limit: int = Query(500, ge=1, le=1000),
    offset: int = Query(0, ge=0),
    older_than: Optional[int] = None,
):
    raise HTTPException(status_code=501)


@app.get("/tracks/{uuid_id}/stream")
def stream_track(uuid_id: str):
    raise HTTPException(status_code=501)


@app.get("/artists", response_model=GetArtistsResponse)
def get_artists(
    limit: int = Query(100, ge=1, le=500),
    offset: int = Query(0, ge=0),
    nextCursor: Optional[int] = None,
):
    raise HTTPException(status_code=501)


@app.get("/artists/{artist}/albums")
def get_artist_album(
    artist: str,
    limit: int = Query(500, ge=1, le=1000),
    offset: int = Query(0, ge=0),
    cursor: Optional[int] = None,
):
    raise HTTPException(status_code=501)


@app.get("/")
def read_root():
    return {"message": "Hello, World!"}
