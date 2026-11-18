"""Deletion API (Phase 8 spec §4): /tracks/deletions/..."""

import logging
import time
from contextlib import contextmanager
from uuid import UUID

from fastapi import APIRouter, Depends, Query, Request
from fastapi.responses import JSONResponse
from pydantic import ValidationError

from app.core.bounded_body import bounded_body, validation_error_422
from app.library import Library, current_library
from app.models.deletions import (
    DeletionJobOut,
    DeletionJobPage,
    DeletionJobRequest,
    DeletionPreviewRequest,
    DeletionPreviewResponse,
)
from app.services import deletions as deletion_rules
from app.services.deletion_errors import DeletionError, library_delete_disabled

DELETION_BODY_LIMIT = 64 * 1024

router = APIRouter(prefix="/tracks/deletions")


def deletion_clock() -> int:
    return int(time.time())


@contextmanager
def _api_errors():
    """Service calls run inside this: DeletionError becomes the SC-22 HTTP error."""
    try:
        yield
    except DeletionError as exc:
        raise exc.to_http() from exc


logger = logging.getLogger(__name__)


def _wake_deletion_worker(request: Request) -> None:
    """8A.3c sets app.state.deletion_worker; job creation tells it there is work."""
    worker = getattr(request.app.state, "deletion_worker", None)
    if worker is not None:
        try:
            worker.wake()
        except Exception as exc:
            # The job is already committed; a failed wake never fails the request.
            logger.warning("deletion worker wake failed: %s", type(exc).__name__)


def require_library_delete_enabled(request: Request) -> None:
    """The operator switch: answers before any database access or body read."""
    if not request.app.state.settings.library_delete_enabled:
        raise library_delete_disabled().to_http()


@router.post(
    "/preview",
    dependencies=[Depends(require_library_delete_enabled)],
    response_model=DeletionPreviewResponse,
)
def preview_deletion(
    library: Library = Depends(current_library),
    raw: bytes = Depends(bounded_body(DELETION_BODY_LIMIT)),
):
    try:
        body = DeletionPreviewRequest.model_validate_json(raw)
    except ValidationError as exc:
        raise validation_error_422(exc) from exc
    return deletion_rules.preview(library, body)


@router.post("", dependencies=[Depends(require_library_delete_enabled)])
def create_deletion(
    request: Request,
    library: Library = Depends(current_library),
    raw: bytes = Depends(bounded_body(DELETION_BODY_LIMIT)),
    now: int = Depends(deletion_clock),
):
    try:
        body = DeletionJobRequest.model_validate_json(raw)
    except ValidationError as exc:
        raise validation_error_422(exc) from exc
    with _api_errors():
        created, job = deletion_rules.create_job(library, body, now=now)
    if created:
        _wake_deletion_worker(request)
    return JSONResponse(job.model_dump(mode="json"), status_code=202)


@router.get("/{operation_uuid:uuid}", response_model=DeletionJobOut)
def get_deletion_job(
    operation_uuid: UUID,
    library: Library = Depends(current_library),
):
    """Readable with the switch off, so accepted jobs stay inspectable."""
    with _api_errors():
        return deletion_rules.get_job(library, str(operation_uuid))


@router.get("", response_model=DeletionJobPage)
def list_deletions(
    after: str | None = Query(None),
    limit: int = Query(25, ge=1, le=100),
    library: Library = Depends(current_library),
):
    """Keyset page of the caller's jobs; readable with the switch off."""
    return deletion_rules.list_jobs(library, after, limit)
