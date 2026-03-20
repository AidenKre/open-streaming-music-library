from pydantic import BaseModel
from typing import Optional


class Album(BaseModel):
    id: int
    name: Optional[str] = None
    artist: Optional[str] = None
    artist_id: int
    year: Optional[int] = None
    is_single_grouping: bool = False
