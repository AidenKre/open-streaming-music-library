from pydantic import BaseModel
from pathlib import Path
from dataclasses import dataclass
from .track_meta_data import TrackMetaData

class Track(BaseModel):
    file_path: Path
    metadata: TrackMetaData
    file_hash: str | None = None