"""Streaming preparation: warming the encoded cache ahead of playback, and the
default streaming quality setting."""

from fastapi import APIRouter, Depends, HTTPException, Request

from app.core.bounded_body import JSON_BODY_LIMIT, json_body
from app.library import Library, current_library
from app.models import (
    QualitySettingResponse,
    SetQualityRequest,
    SetQualityResponse,
    WarmRequest,
    WarmResponse,
)
from app.services import EncoderCoordinator, normalize_quality
from app.services.encoder_coordinator import PrefetchOutcome
from app.services.transcoder import resolve_default_quality

router = APIRouter()


_WARM_MAX_UUIDS = 500


@router.post("/tracks/warm", response_model=WarmResponse)
def warm_tracks(
    http_request: Request,
    library: Library = Depends(current_library),
    request: WarmRequest = Depends(json_body(WarmRequest, JSON_BODY_LIMIT)),
):
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

    coordinator: EncoderCoordinator = http_request.app.state.encoder_coordinator
    window = (
        request.count if request.count is not None
        else http_request.app.state.settings.prefetch_lookahead
    )
    start = request.current_index
    end = min(start + window, len(request.track_uuids))
    queued = 0
    skipped = 0
    # Foreign and unknown uuids are dropped uncounted, so ALREADY_CACHED can't
    # reveal another user's streaming.
    for uuid_id in library.filter_owned_track_uuids(
        request.track_uuids[start:end]
    ):
        outcome = coordinator.enqueue_prefetch(uuid_id, quality_canonical)
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


@router.get("/settings/quality", response_model=QualitySettingResponse)
def get_quality_setting(request: Request, library: Library = Depends(current_library)):
    return QualitySettingResponse(
        quality=resolve_default_quality(
            library.get_user_setting("default_streaming_quality"),
            request.app.state.settings.default_streaming_quality,
        )
    )


@router.put("/settings/quality", response_model=SetQualityResponse)
def set_quality_setting(
    http_request: Request,
    library: Library = Depends(current_library),
    request: SetQualityRequest = Depends(json_body(SetQualityRequest, JSON_BODY_LIMIT)),
):
    try:
        quality_canonical = normalize_quality(request.quality)
    except ValueError:
        raise HTTPException(
            status_code=422,
            detail=f"Unsupported quality preset: {request.quality}",
        )

    # EncoderCoordinator.default_quality is the master admin's; any other
    # caller only changes their own user_settings row (spec 6.1).
    is_master_admin = library.owner_id == http_request.app.state.admin_user_id

    try:
        if is_master_admin:
            coordinator: EncoderCoordinator = http_request.app.state.encoder_coordinator
            _, warming = coordinator.persist_and_set_default_quality(
                quality_canonical,
                lambda q: library.set_user_setting("default_streaming_quality", q),
                read_stored=lambda: library.get_user_setting("default_streaming_quality"),
            )
        else:
            library.set_user_setting("default_streaming_quality", quality_canonical)
            warming = False
    except Exception:
        raise HTTPException(
            status_code=500,
            detail="Failed to persist default quality setting",
        )

    return SetQualityResponse(quality=quality_canonical, warming=warming)
