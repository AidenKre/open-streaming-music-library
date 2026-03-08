from pydantic import BaseModel
from typing import Optional


class Album(BaseModel):
    album: Optional[str] = None
    artist: Optional[str] = None
    year: Optional[int] = None
    isSingleGrouping: bool = False