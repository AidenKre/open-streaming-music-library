import sqlite3

from fastapi import APIRouter, Depends, Query, Request
from pydantic import ValidationError

from app.core.api_errors import api_error
from app.core.bounded_body import bounded_body, validation_error_422
from app.database.database import Database, HistoryEventConflict
from app.models.history import GetHistoryChangesResponse, PostHistoryRequest

router = APIRouter(prefix="/history")


@router.get("/changes", response_model=GetHistoryChangesResponse)
def get_history_changes(
    request: Request,
    after: int = Query(0, ge=0, le=2**63 - 1),
    limit: int = Query(200, ge=1, le=1000),
):
    database: Database = request.app.state.database
    try:
        events, latest_revision, next_cursor = database.get_history_changes(after, limit)
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
def post_history(request: Request, raw: bytes = Depends(bounded_body(256 * 1024))):
    try:
        body = PostHistoryRequest.model_validate_json(raw)
    except ValidationError as exc:
        raise validation_error_422(exc) from exc

    database: Database = request.app.state.database
    try:
        acknowledged = database.insert_history_events(body.events)
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
