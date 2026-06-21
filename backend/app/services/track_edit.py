from __future__ import annotations

from enum import Enum
from typing import Optional

from pydantic import BaseModel, ConfigDict, field_validator

from app.database.database import EDITABLE_METADATA_COLUMNS


# (label, valueType) for each editable column, in display order. valueType is
# the open set consumed by the client's schema-driven Get Info form.
EDITABLE_FIELD_META: dict[str, tuple[str, str]] = {
    "title": ("Title", "text"),
    "artist": ("Artist", "text"),
    "album": ("Album", "text"),
    "album_artist": ("Album Artist", "text"),
    "year": ("Year", "year"),
    "date": ("Date", "text"),
    "genre": ("Genre", "text"),
    "track_number": ("Track Number", "int"),
    "disc_number": ("Disc Number", "int"),
}


class WriteMode(str, Enum):
    """Where a metadata edit is persisted. Phase 1 implements ``db_only``; the
    master-file path (``db_and_master``) lands in slice 4 and returns 501 until
    then. The value is part of the request shape now so the API doesn't change
    between slices."""

    db_only = "db_only"
    db_and_master = "db_and_master"


class TrackPatchRequest(BaseModel):
    """Partial track metadata edit. Only the fields present in the request body
    are changed; an explicit ``null`` clears that field. ``extra='forbid'`` makes
    a non-allowlisted field a 422 (advertised set == accepted set), so the edit
    allowlist is enforced by the schema itself."""

    model_config = ConfigDict(extra="forbid")

    base_revision: int
    write_mode: WriteMode = WriteMode.db_only

    title: Optional[str] = None
    artist: Optional[str] = None
    album: Optional[str] = None
    album_artist: Optional[str] = None
    year: Optional[int] = None
    date: Optional[str] = None
    genre: Optional[str] = None
    track_number: Optional[int] = None
    disc_number: Optional[int] = None

    @field_validator("year")
    @classmethod
    def _year_in_range(cls, v: Optional[int]) -> Optional[int]:
        if v is not None and not (0 <= v <= 9999):
            raise ValueError("year must be between 0 and 9999")
        return v

    @field_validator("track_number", "disc_number")
    @classmethod
    def _non_negative(cls, v: Optional[int]) -> Optional[int]:
        if v is not None and v < 0:
            raise ValueError("must be non-negative")
        return v

    def edit_fields(self) -> dict:
        """The present subset of editable columns (preserving an explicit
        ``None`` so 'clear' is distinguishable from 'untouched'). ``base_revision``
        and ``write_mode`` are control fields, not columns, so they are excluded."""
        return {
            col: getattr(self, col)
            for col in EDITABLE_METADATA_COLUMNS
            if col in self.model_fields_set
        }
