"""Upload API (Phase 7 spec §4): /tracks/uploads/..."""

import time

import anyio.to_thread
from contextlib import contextmanager
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from fastapi.responses import JSONResponse
from starlette.requests import ClientDisconnect
from pydantic import ValidationError

from app.core.byte_range import ranged_file_response
from app.core.bounded_body import bounded_body, validation_error_422
from app.library import Library, current_library
from app.models.uploads import (
    AllocationRequest,
    CommitRequest,
    ResolveDuplicateRequest,
    RetryRequest,
    UploadBatchOut,
    UploadBatchPage,
    UploadItemOut,
    UploadItemPage,
)
from app.services import uploads as upload_rules
from app.services.upload_receipt import ClientGone, receive_content
from app.services.upload_errors import UploadError, range_not_satisfiable
from app.services.upload_limits import effective_upload_limits

router = APIRouter(prefix="/tracks/uploads")


def upload_clock() -> int:
    """Unix seconds for upload rows; tests override it through dependency_overrides."""
    return int(time.time())


@contextmanager
def _api_errors():
    """Every upload route runs its service call inside this: UploadError
    becomes the SC-22 HTTP error."""
    try:
        yield
    except UploadError as exc:
        raise exc.to_http() from exc


@router.post("")
def post_allocation(
    request: Request,
    library: Library = Depends(current_library),
    raw: bytes = Depends(bounded_body(256 * 1024)),
    now: int = Depends(upload_clock),
):
    try:
        body = AllocationRequest.model_validate_json(raw)
    except ValidationError as exc:
        raise validation_error_422(exc) from exc
    limits = effective_upload_limits(request.app.state.settings)
    with _api_errors():
        created, response = upload_rules.allocate(library, limits, body, now=now)
    return JSONResponse(response.model_dump(mode="json"), status_code=201 if created else 200)


@router.post("/items/{item_uuid:uuid}/retry", response_model=UploadItemOut)
def retry_upload_item(
    item_uuid: UUID,
    request: Request,
    library: Library = Depends(current_library),
    raw: bytes = Depends(bounded_body(256 * 1024)),
    now: int = Depends(upload_clock),
):
    try:
        body = RetryRequest.model_validate_json(raw)
    except ValidationError as exc:
        raise validation_error_422(exc) from exc
    with _api_errors():
        item = upload_rules.retry(
            library, str(item_uuid), body.expected_review_version, now=now,
            uploads_root=request.app.state.upload_receipt.uploads_root,
        )
    worker = request.app.state.upload_validation_worker
    if worker is not None and item.state == "validating":
        worker.wake()
    return item


@router.post("/items/{item_uuid:uuid}/commit")
def commit_upload_item(
    item_uuid: UUID,
    request: Request,
    library: Library = Depends(current_library),
    raw: bytes = Depends(bounded_body(256 * 1024)),
    now: int = Depends(upload_clock),
):
    try:
        body = CommitRequest.model_validate_json(raw)
    except ValidationError as exc:
        raise validation_error_422(exc) from exc
    with _api_errors():
        status, item = upload_rules.commit(
            library, body, str(item_uuid), now=now,
            uploads_root=request.app.state.upload_receipt.uploads_root,
        )
    worker = request.app.state.upload_commit_worker
    if worker is not None and status == 202:
        worker.wake()
    return JSONResponse(item.model_dump(mode="json"), status_code=status)


@router.post("/items/{item_uuid:uuid}/resolve-duplicate", response_model=UploadItemOut)
def resolve_upload_duplicate(
    item_uuid: UUID,
    request: Request,
    library: Library = Depends(current_library),
    raw: bytes = Depends(bounded_body(256 * 1024)),
    now: int = Depends(upload_clock),
):
    try:
        body = ResolveDuplicateRequest.model_validate_json(raw)
    except ValidationError as exc:
        raise validation_error_422(exc) from exc
    with _api_errors():
        return upload_rules.resolve_duplicate(
            library, body, str(item_uuid), now=now,
            uploads_root=request.app.state.upload_receipt.uploads_root,
        )


@router.get("/items/{item_uuid:uuid}/preview", name="preview_upload_item")
def preview_upload_item(
    item_uuid: UUID,
    request: Request,
    library: Library = Depends(current_library),
):
    """The owner's own review-ready staged file, with Range support."""
    with _api_errors():
        handle, mime = upload_rules.open_preview(
            library, str(item_uuid), request.app.state.upload_receipt.uploads_root
        )
        try:
            # The helper owns the handle and closes it when it raises.
            return ranged_file_response(
                handle,
                media_type=mime,
                range_header=request.headers.get("range"),
                headers={
                    "X-Content-Type-Options": "nosniff",
                    "Content-Disposition": "attachment",
                    "Cache-Control": "private, no-store",
                },
                chunk_size=1024 * 1024,
            )
        except HTTPException as exc:
            raise range_not_satisfiable(exc.headers) from None


@router.get("/items/{item_uuid:uuid}", response_model=UploadItemOut)
def get_upload_item(item_uuid: UUID, library: Library = Depends(current_library)):
    with _api_errors():
        return upload_rules.get_item(library, str(item_uuid))


@router.get("/{batch_uuid:uuid}", response_model=UploadBatchOut)
def get_upload_batch(batch_uuid: UUID, library: Library = Depends(current_library)):
    with _api_errors():
        return upload_rules.get_batch(library, str(batch_uuid))


@router.get("", response_model=UploadBatchPage)
def list_upload_batches(
    after: str | None = Query(None),
    limit: int = Query(25, ge=1, le=100),
    library: Library = Depends(current_library),
):
    with _api_errors():
        return upload_rules.list_batches(library, after, limit)


@router.get("/{batch_uuid:uuid}/items", response_model=UploadItemPage)
def list_upload_items(
    batch_uuid: UUID,
    after: str | None = Query(None),
    limit: int = Query(25, ge=1, le=100),
    library: Library = Depends(current_library),
):
    with _api_errors():
        return upload_rules.list_items(library, str(batch_uuid), after, limit)


@router.delete("/items/{item_uuid:uuid}", response_model=UploadItemOut)
def cancel_upload_item(
    item_uuid: UUID,
    request: Request,
    library: Library = Depends(current_library),
    now: int = Depends(upload_clock),
):
    with _api_errors():
        return upload_rules.cancel(
            library, str(item_uuid), now=now,
            tokens=request.app.state.upload_cancel_tokens,
            uploads_root=request.app.state.upload_receipt.uploads_root,
        )


async def _body(request: Request):
    """The request body as chunks; a client that goes away mid-body is ClientGone."""
    try:
        async for chunk in request.stream():
            yield chunk
    except ClientDisconnect:
        raise ClientGone() from None


@router.put("/items/{item_uuid:uuid}/content", response_model=UploadItemOut)
async def put_upload_content(
    item_uuid: UUID,
    request: Request,
    library: Library = Depends(current_library),
    now: int = Depends(upload_clock),
):
    """The raw body is read here, as a stream, never through a body parameter."""
    limits = effective_upload_limits(request.app.state.settings)
    with _api_errors():
        row = await receive_content(
            request.app.state.upload_receipt, library, limits, str(item_uuid),
            _body(request),
            declared_length=request.headers.get("content-length"), now=now,
        )
    worker = request.app.state.upload_validation_worker
    if worker is not None and row["state"] == "validating":
        worker.wake()
    return await anyio.to_thread.run_sync(upload_rules.item_out, row, library)
