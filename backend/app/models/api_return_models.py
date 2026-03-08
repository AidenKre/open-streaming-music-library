from pydantic import BaseModel
from typing import List, Optional
from .client_track import ClientTrack
from .album import Album


class GetTracksResponse(BaseModel):
    data: List[ClientTrack]
    nextCursor: Optional[str] = None


class GetArtistsResponse(BaseModel):
    data: List[str]
    nextCursor: Optional[str] = None


class GetAlbumsResponse(BaseModel):
    data: List[Album]
    nextCursor: Optional[str] = None
