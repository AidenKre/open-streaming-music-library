from pydantic import BaseModel, Field
from typing import List, Optional
from .client_track import ClientTrack
from .artist import Artist
from .album import Album


class GetTracksResponse(BaseModel):
    data: List[ClientTrack]
    nextCursor: Optional[str] = None
    # uuids of tracks the server has hard-deleted within the request's
    # time window. Only populated on the first page of an unscoped
    # (no artist_id/album_id) sync — scoped requests cannot speak
    # authoritatively about deletions outside their filter.
    deleted_uuids: List[str] = Field(default_factory=list)


class GetArtistsResponse(BaseModel):
    data: List[Artist]
    nextCursor: Optional[str] = None


class GetAlbumsResponse(BaseModel):
    data: List[Album]
    nextCursor: Optional[str] = None


class GetSearchResponse(BaseModel):
    tracks: List[ClientTrack] = []
    artists: List[Artist] = []
    albums: List[Album] = []


class WarmRequest(BaseModel):
    session_id: Optional[str] = None
    current_index: int = Field(ge=0)
    quality: str
    track_uuids: List[str]


class WarmResponse(BaseModel):
    accepted: bool
    prefetch_queued: int


class QualitySettingResponse(BaseModel):
    quality: str


class SetQualityRequest(BaseModel):
    quality: str


class SetQualityResponse(BaseModel):
    quality: str
    warming: bool
