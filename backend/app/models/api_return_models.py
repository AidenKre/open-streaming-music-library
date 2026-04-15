from pydantic import BaseModel, Field
from typing import List, Optional
from .client_track import ClientTrack
from .artist import Artist
from .album import Album


class GetTracksResponse(BaseModel):
    data: List[ClientTrack]
    nextCursor: Optional[str] = None


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


class QueueSyncRequest(BaseModel):
    session_id: str
    current_index: int = Field(ge=0)
    quality: str
    track_uuids: List[str]


class QueueSyncResponse(BaseModel):
    accepted: bool
    prefetch_queued: int
