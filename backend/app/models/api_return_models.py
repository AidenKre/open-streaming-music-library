from typing import List, Literal, Optional, Self

from pydantic import BaseModel, Field, model_validator

from .album import Album
from .artist import Artist
from .client_track import ClientTrack


class GetTracksResponse(BaseModel):
    data: List[ClientTrack]
    nextCursor: Optional[str] = None


class ChangeEntry(BaseModel):
    """One ordered entry in the revision-based change stream. ``track`` is set
    for upserts and ``None`` for deletes; ``uuid_id`` identifies the row in
    both cases."""

    type: Literal["upsert", "delete"]
    revision: int
    uuid_id: str
    track: Optional[ClientTrack] = None

    @model_validator(mode="after")
    def validate_track_payload(self) -> Self:
        if self.type == "upsert" and self.track is None:
            raise ValueError("upsert change entries must include track")
        if self.type == "delete" and self.track is not None:
            raise ValueError("delete change entries must not include track")
        return self


class GetChangesResponse(BaseModel):
    changes: List[ChangeEntry]
    # Revision to request next when the raw page filled and the client should
    # probe again; ``None`` once the client has caught up.
    nextCursor: Optional[int] = None
    # Current server revision at query time — informational. The client should
    # persist the last *applied* entry's revision, not this.
    latestRevision: int


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
    # How many uuids (from current_index) to warm. Defaults to the server's
    # prefetch_lookahead window (the queue look-ahead use case). The
    # download-driven path passes the full batch length so every queued
    # download is warmed, not just the first look-ahead window.
    count: Optional[int] = Field(default=None, ge=1)


class WarmResponse(BaseModel):
    accepted: bool
    # Only background encodes that were actually scheduled. Cache hits and
    # ORIGINAL_QUALITY pass-throughs count toward [prefetch_skipped], not
    # this field — previously they were lumped in here, making metrics
    # look like work happened when nothing was scheduled.
    prefetch_queued: int
    prefetch_skipped: int = 0


class FieldDescriptor(BaseModel):
    """One editable field advertised by ``/app/info``. ``valueType`` is an
    intentionally open string set (text/int/year/enum/bool now, ``image`` later
    for cover art) so a new type doesn't force a client refactor."""

    key: str
    label: str
    valueType: str
    editable: bool = True


class EntityInfo(BaseModel):
    fields: List[FieldDescriptor] = []
    # Non-mutation operations (e.g. Phase 2 master-type conversion). Empty in
    # Phase 1.
    actions: List[str] = []


class AppInfoResponse(BaseModel):
    """App-level bootstrap blob. The home for app-global facts so later phases
    extend it (Phase 2 adds a ``conversion`` block) rather than add endpoints.
    Per-entity *live* data stays out of it; this is cached client-side."""

    entities: dict[str, EntityInfo]


class PatchTrackResponse(BaseModel):
    uuid_id: str
    revision: int


class QualitySettingResponse(BaseModel):
    quality: str


class SetQualityRequest(BaseModel):
    quality: str


class SetQualityResponse(BaseModel):
    quality: str
    warming: bool
