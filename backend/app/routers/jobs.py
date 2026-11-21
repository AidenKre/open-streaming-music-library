"""``/jobs``: master conversions, the one job type."""

import sqlite3
from typing import List, Optional

from fastapi import APIRouter, Depends, HTTPException, Query, Request

from app.core.api_errors import api_error
from app.core.bounded_body import JSON_BODY_LIMIT, json_body
from app.database import (
    ConversionJobActive,
    RevisionConflict,
    TrackNotFound,
    TrackPendingDeletion,
)
from app.library import Library, current_library
from app.models import DeleteJobResponse, GetJobsResponse, JobResponse
from app.services.conversion import (
    ConversionJobStatus,
    ConversionOrchestrator,
    ConversionRequestInvalid,
    InsufficientDiskSpace,
    MasterNotFound,
    NoOpConversion,
    PendingRecovery,
    TargetPathTaken,
)
from app.services.deletion_errors import track_pending_deletion_error
from app.services.job_request import PostJobRequest

router = APIRouter()


def _job_to_response(job: dict) -> JobResponse:
    return JobResponse(
        job_id=job["id"],
        uuid_id=job["uuid_id"],
        target_codec=job["target_codec"],
        target_container=job["target_container"],
        target_bitrate=job["target_bitrate"],
        status=job["status"],
        error_text=job["error_text"],
        created_at=job["created_at"],
        updated_at=job["updated_at"],
    )


@router.post("/jobs", response_model=JobResponse)
def post_job(
    http_request: Request,
    library: Library = Depends(current_library),
    request: PostJobRequest = Depends(json_body(PostJobRequest, JSON_BODY_LIMIT)),
):
    """Create an async job. Only ``type="conversion"`` exists today (the
    generic ``/jobs`` resource is forward-looking per the doc so future
    bulk job types add zero endpoints). Upload work is not a ``/jobs`` type:
    since Phase 7 it lives under ``/tracks/uploads/...`` on the shared job
    runtime. Non-idempotent (mints a job)
    -> single-attempt; an orphaned job from a timed-out-but-succeeded POST is
    recovered via ``GET /jobs``."""
    orchestrator: ConversionOrchestrator = http_request.app.state.conversion_orchestrator

    try:
        job_id = orchestrator.enqueue(
            library,
            uuid_id=request.uuid_id,
            target_codec=request.params.target_codec,
            target_bitrate_kbps=request.params.target_bitrate_kbps,
            base_revision=request.base_revision,
        )
    except TrackNotFound:
        raise HTTPException(status_code=404, detail="Track not found")
    except TrackPendingDeletion:
        raise track_pending_deletion_error(409)
    except MasterNotFound:
        raise HTTPException(status_code=404, detail="Master file not found")
    except RevisionConflict as e:
        raise HTTPException(
            status_code=409,
            detail={
                "error": "revision_conflict",
                "current_revision": e.current_revision,
            },
        )
    except ConversionJobActive as e:
        raise HTTPException(
            status_code=409, detail={"error": "job_active", "job_id": e.job_id}
        )
    except TargetPathTaken:
        raise HTTPException(status_code=409, detail={"error": "target_exists"})
    except PendingRecovery as e:
        detail = {"error": "pending_recovery"}
        if e.message is not None:
            detail["message"] = e.message
        raise HTTPException(status_code=409, detail=detail)
    except NoOpConversion:
        raise HTTPException(
            status_code=422,
            detail="Target codec is the same lossless codec as the source",
        )
    except ConversionRequestInvalid as e:
        raise HTTPException(status_code=422, detail=str(e))
    except InsufficientDiskSpace as e:
        raise api_error(
            507, e.code, e.message, retryable=True, needed=e.needed
        )
    except sqlite3.OperationalError as e:
        if "locked" in str(e).lower():
            raise HTTPException(status_code=503, detail="Database busy, retry")
        raise

    job = library.get_conversion_job(job_id)
    return _job_to_response(job)


@router.get("/jobs", response_model=GetJobsResponse)
def get_jobs(
    uuid_id: Optional[str] = None,
    status: Optional[str] = None,
    type: Optional[str] = None,
    batch_id: Optional[str] = None,
    cursor: int = Query(0, ge=0),
    limit: int = Query(50, ge=1, le=200),
    library: Library = Depends(current_library),
):
    """Filtered, cursored job collection -- replaces both a global and a
    per-uuid conversion list (the per-uuid variant is just ``?uuid_id=``).
    ``cursor``/``nextCursor`` are job ids (ascending), mirroring
    ``GET /changes``' int-cursor convention. ``status`` takes one status or a
    comma-separated list (``queued,running``). ``type`` only accepts
    ``"conversion"`` today (the only job type that exists)."""
    # TODO(bulk-jobs): a grouped-by-batch_id list shape for bulk conversion
    # progress. Uploads never appear here (they are /tracks/uploads, Phase 7).
    if type is not None and type != "conversion":
        raise HTTPException(status_code=422, detail=f"unsupported job type: {type}")
    statuses: Optional[List[str]] = None
    if status is not None:
        statuses = [s.strip() for s in status.split(",") if s.strip()]
        valid = {s.value for s in ConversionJobStatus}
        unknown = [s for s in statuses if s not in valid]
        if unknown or not statuses:
            raise HTTPException(
                status_code=422, detail=f"unsupported job status: {status}"
            )

    try:
        jobs, next_cursor = library.list_conversion_jobs(
            uuid_id=uuid_id, statuses=statuses, batch_id=batch_id,
            after_id=cursor, limit=limit,
        )
    except sqlite3.OperationalError as e:
        if "locked" in str(e).lower():
            raise HTTPException(status_code=503, detail="Database busy, retry")
        raise
    return GetJobsResponse(
        data=[_job_to_response(job) for job in jobs], nextCursor=next_cursor
    )


@router.delete("/jobs/{job_id}", response_model=DeleteJobResponse)
def delete_job(job_id: int, request: Request, library: Library = Depends(current_library)):
    """Cancel a queued or running job. Idempotent: a no-op (``cancelled:
    false``) for an already-terminal or unknown job_id, never a 404 -- the
    doc frames DELETE as remove-pending-work, not resource deletion."""
    orchestrator: ConversionOrchestrator = request.app.state.conversion_orchestrator
    cancelled = orchestrator.cancel(library, job_id)
    return DeleteJobResponse(cancelled=cancelled)
