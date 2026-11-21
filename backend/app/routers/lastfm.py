import uuid

from fastapi import APIRouter, Depends, Request, Response
from pydantic import BaseModel, ConfigDict, field_validator

from app.core.api_errors import answer_errors
from app.core.bounded_body import json_body
from app.library import Library, current_library
from app.services.lastfm_errors import LastfmError

LASTFM_BODY_LIMIT = 4096

router = APIRouter(prefix="/settings/integrations/lastfm")


class LastfmEmptyRequest(BaseModel):
    pass


class LastfmEnableRequest(BaseModel):
    model_config = ConfigDict(strict=True)

    connection_id: str


class LastfmNowPlayingRequest(BaseModel):
    model_config = ConfigDict(strict=True)

    track_uuid: str

    @field_validator("track_uuid")
    @classmethod
    def _must_be_uuid(cls, value: str) -> str:
        try:
            uuid.UUID(value)
        except ValueError:
            raise ValueError("must be a UUID") from None
        return value


@router.get("")
def get_lastfm_status(request: Request, library: Library = Depends(current_library)):
    return request.app.state.lastfm_accounts.status(library)


@router.post("/connect")
def connect_lastfm(
    request: Request,
    library: Library = Depends(current_library),
    _empty: LastfmEmptyRequest = Depends(json_body(LastfmEmptyRequest, LASTFM_BODY_LIMIT)),
):
    with answer_errors(LastfmError, keep_cause=False):
        return request.app.state.lastfm_accounts.connect(library)


@router.post("/complete")
def complete_lastfm(
    request: Request,
    library: Library = Depends(current_library),
    _empty: LastfmEmptyRequest = Depends(json_body(LastfmEmptyRequest, LASTFM_BODY_LIMIT)),
):
    with answer_errors(LastfmError, keep_cause=False):
        return request.app.state.lastfm_accounts.complete(library)


@router.post("/enable")
def enable_lastfm(
    request: Request,
    library: Library = Depends(current_library),
    body: LastfmEnableRequest = Depends(json_body(LastfmEnableRequest, LASTFM_BODY_LIMIT)),
):
    with answer_errors(LastfmError, keep_cause=False):
        return request.app.state.lastfm_accounts.enable(library, body.connection_id)


@router.post("/now-playing", status_code=202)
def lastfm_now_playing(
    request: Request,
    library: Library = Depends(current_library),
    body: LastfmNowPlayingRequest = Depends(
        json_body(LastfmNowPlayingRequest, LASTFM_BODY_LIMIT)
    ),
):
    with answer_errors(LastfmError, keep_cause=False):
        request.app.state.lastfm_accounts.now_playing(library, str(uuid.UUID(body.track_uuid)))
    return Response(status_code=202)


@router.delete("", status_code=204)
def disconnect_lastfm(request: Request, library: Library = Depends(current_library)):
    request.app.state.lastfm_accounts.disconnect(library)
    return Response(status_code=204)
