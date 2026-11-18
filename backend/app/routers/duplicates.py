"""Duplicate review API (Phase 8 spec §4): /tracks/duplicates/..."""

from typing import Literal

from pydantic import ValidationError
from fastapi import APIRouter, Depends, Query, Request

from app.core.api_errors import answer_errors
from app.core.bounded_body import bounded_body, validation_error_422
from app.library import Library, current_library
from app.models.duplicates import DuplicatePairPage, DuplicateSummaryOut, PairRequest, PairStatusOut
from app.services import duplicates as duplicate_rules
from app.services.deletion_errors import DeletionError

router = APIRouter(prefix="/tracks/duplicates")


@router.get("/summary", response_model=DuplicateSummaryOut)
def duplicate_summary(request: Request, library: Library = Depends(current_library)):
    fingerprinter = request.app.state.fingerprinter
    return duplicate_rules.summary(library, None if fingerprinter is None else fingerprinter.name)


@router.get("", response_model=DuplicatePairPage)
def list_possible_duplicates(
    status: Literal["open", "dismissed"] = Query("open"),
    after: str | None = Query(None),
    limit: int = Query(25, ge=1, le=100),
    library: Library = Depends(current_library),
):
    return duplicate_rules.list_pairs(library, status, after, limit)


def _set_status(library: Library, raw: bytes, status: str) -> PairStatusOut:
    try:
        body = PairRequest.model_validate_json(raw)
    except ValidationError as exc:
        raise validation_error_422(exc) from exc
    with answer_errors(DeletionError):
        return duplicate_rules.set_status(library, body, status)


@router.post("/dismiss", response_model=PairStatusOut)
def dismiss_pair(
    library: Library = Depends(current_library),
    raw: bytes = Depends(bounded_body(64 * 1024)),
):
    return _set_status(library, raw, "dismissed")


@router.post("/restore", response_model=PairStatusOut)
def restore_pair(
    request: Request,
    library: Library = Depends(current_library),
    raw: bytes = Depends(bounded_body(64 * 1024)),
):
    out = _set_status(library, raw, "open")
    # The restore sent both tracks back to matching: run it now.
    request.app.state.identity_wakeup.notify()
    return out
