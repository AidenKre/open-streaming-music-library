from pydantic import BaseModel
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
