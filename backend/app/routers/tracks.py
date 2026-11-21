"""One track: its current state, and the metadata edit."""

import sqlite3
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Request

from app.core.bounded_body import JSON_BODY_LIMIT, json_body
from app.database import (
    EmptyTrackEdit,
    RevisionConflict,
    TrackNotFound,
    TrackPendingDeletion,
)
from app.library import Library, current_library
from app.models import ClientTrack, PatchTrackResponse
from app.services.deletion_errors import track_pending_deletion_error
from app.services.metadata import TagWriteError
from app.services.track_edit import TrackPatchRequest
from app.services.track_editor import MasterSwapPending, MasterWriteError, TrackEditor
from app.services.track_locks import TrackLocks

router = APIRouter()


@router.get("/tracks/{uuid_id:uuid}", response_model=ClientTrack)
def get_track(uuid_id: UUID, library: Library = Depends(current_library)):
    """Authoritative current state of a single track. Lets a client reconcile
    one track to server truth without a watermark-driven `/changes` pull — used
    by edit-conflict "take server" resolution, where the watermark may already
    have advanced past the conflicting revision. 404 if the track is gone."""
    uuid_id = str(uuid_id)
    track = library.get_track_by_uuid(uuid_id)
    if track is None:
        raise HTTPException(status_code=404, detail="Track not found")
    return ClientTrack.from_track(track=track)


@router.patch("/tracks/{uuid_id:uuid}", response_model=PatchTrackResponse)
def patch_track(
    uuid_id: UUID,
    http_request: Request,
    library: Library = Depends(current_library),
    request: TrackPatchRequest = Depends(json_body(TrackPatchRequest, JSON_BODY_LIMIT)),
):
    """Partial track metadata edit. Non-allowlisted fields + type/range are
    rejected by ``TrackPatchRequest`` (422). ``db_only`` writes the DB; the
    confirmation-gated ``db_and_master`` also rewrites the file tags and
    relocates the master when artist/album change (WAV / missing master degrade
    to DB-only with ``master_written=False``). Per-uuid serialized; the DB
    layer's typed conflicts map to HTTP status codes. A track pending deletion
    is refused with 409 ``track_pending_deletion``."""
    uuid_id = str(uuid_id)
    track_editor: TrackEditor = http_request.app.state.track_editor
    track_locks: TrackLocks = http_request.app.state.track_locks

    try:
        with track_locks.lock(uuid_id):
            new_revision, master_written = track_editor.apply_edit(
                library,
                uuid_id=uuid_id,
                fields=request.edit_fields(),
                base_revision=request.base_revision,
                write_mode=request.write_mode,
            )
    except TrackNotFound:
        raise HTTPException(status_code=404, detail="Track not found")
    except TrackPendingDeletion:
        raise track_pending_deletion_error(409)
    except RevisionConflict as e:
        raise HTTPException(
            status_code=409,
            detail={
                "error": "revision_conflict",
                "current_revision": e.current_revision,
            },
        )
    except EmptyTrackEdit:
        raise HTTPException(
            status_code=422,
            detail="Edit would leave the track with no title, artist, "
            "album, or album artist",
        )
    # The edit is committed and its kept journal row finishes the swap; 503 lets
    # the client retry, and the retry with the old base gets the usual revision_conflict.
    except MasterSwapPending as e:
        raise HTTPException(status_code=503, detail=f"Master file write failed: {e}")
    except (TagWriteError, MasterWriteError) as e:
        raise HTTPException(status_code=500, detail=f"Master file write failed: {e}")
    except sqlite3.OperationalError as e:
        if "locked" in str(e).lower():
            raise HTTPException(
                status_code=503, detail="Database busy, retry"
            )
        raise

    return PatchTrackResponse(
        uuid_id=uuid_id, revision=new_revision, master_written=master_written
    )
