import sqlite3

from fastapi import APIRouter, Depends, Query

from app.core.api_errors import api_error
from app.core.bounded_body import json_body
from app.database.database import HistoryEventConflict
from app.library import Library, current_library
from app.models.history import GetHistoryChangesResponse, PostHistoryRequest

router = APIRouter(prefix="/history")


@router.get("/changes", response_model=GetHistoryChangesResponse)
def get_history_changes(
    after: int = Query(0, ge=0, le=2**63 - 1),
    limit: int = Query(200, ge=1, le=1000),
    library: Library = Depends(current_library),
):
    try:
        events, latest_revision, next_cursor = library.get_history_changes(after, limit)
    except sqlite3.Error as exc:
        raise api_error(
            503,
            "history_unavailable",
            "History is temporarily unavailable. Try again later.",
            retryable=True,
        ) from exc
    return GetHistoryChangesResponse(
        events=events, nextCursor=next_cursor, latestRevision=latest_revision
    )


@router.post("")
def post_history(
    library: Library = Depends(current_library),
    body: PostHistoryRequest = Depends(json_body(PostHistoryRequest, 256 * 1024)),
):
    try:
        acknowledged = library.insert_history_events(body.events)
    except HistoryEventConflict as exc:
        raise api_error(
            409,
            "history_event_conflict",
            "An event with this ID already has different values.",
            retryable=False,
            conflicting_event_uuids=exc.event_uuids,
        ) from exc
    except sqlite3.Error as exc:
        raise api_error(
            503,
            "history_unavailable",
            "History is temporarily unavailable. Try again later.",
            retryable=True,
        ) from exc
    return {"acknowledged": acknowledged}
