from pathlib import Path

from pydantic import BaseModel


class CoverArt(BaseModel):
    id: int
    sha256: str
    phash: str
    phash_prefix: str
    file_path: Path