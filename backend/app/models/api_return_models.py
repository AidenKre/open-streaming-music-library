from pydantic import BaseModel
from typing import List, Optional
from .client_track import ClientTrack


class GetTracksResponse(BaseModel):
    data: List[ClientTrack]
    nextCursor: Optional[dict] = None


class GetArtistsResponse(BaseModel):
    data: List[str]
    nextCursor: Optional[int] = None
