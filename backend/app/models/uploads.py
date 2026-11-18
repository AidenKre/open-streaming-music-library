"""Upload API DTOs (Phase 7 spec §4). The one home for upload request/response models."""

import re
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, StrictBool, StrictInt, field_validator, model_validator

from app.models.api_return_models import UploadLimitsInfo
from app.services.track_edit import EditableFields

_SHA256 = re.compile(r"[0-9a-fA-F]{64}")


class AllocationItem(BaseModel):
    model_config = ConfigDict(extra="forbid")

    item_uuid: UUID
    filename: str = Field(min_length=1, max_length=255)
    byte_length: int = Field(ge=1)
    sha256: str

    @field_validator("sha256")
    @classmethod
    def _digest(cls, value: str) -> str:
        if _SHA256.fullmatch(value) is None:
            raise ValueError("sha256 must be 64 hex characters")
        return value.lower()


class AllocationRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    batch_uuid: UUID
    label: str | None = Field(default=None, max_length=200)
    items: list[AllocationItem] = Field(min_length=1)

    @model_validator(mode="after")
    def _absent_label_is_null_label(self):
        # An allocation has no "clear label" meaning, so label absent and
        # label null are the same request: keep null out of the fields-set so
        # exclude_unset dumps (the receipt hash) match, and a retry may differ.
        if self.label is None:
            self.__pydantic_fields_set__.discard("label")
        return self

    @model_validator(mode="after")
    def _unique_items(self):
        uuids = [item.item_uuid for item in self.items]
        if len(set(uuids)) != len(uuids):
            raise ValueError("item_uuid values must be unique")
        return self


class RetryRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    expected_review_version: StrictInt = Field(ge=0)


class UploadItemError(BaseModel):
    code: str
    message: str | None
    retryable: bool | None


class DuplicateCoverageOut(BaseModel):
    subject_state: str
    library_pending: int
    library_failed: int
    library_not_comparable: int


class DuplicateTrackSummary(BaseModel):
    title: str | None
    artist: str | None
    album: str | None
    codec: str | None
    bitrate_kbps: float | None
    sample_rate_hz: int | None
    duration_s: float | None


class DuplicateStagedSummary(BaseModel):
    filename: str
    batch_uuid: str
    batch_created_at: int | None


class DuplicateMatchOut(BaseModel):
    subject_kind: str
    track_uuid: str | None
    item_uuid: str | None
    kind: str
    band: str
    score: float | None
    available: bool
    track: DuplicateTrackSummary | None
    staged_item: DuplicateStagedSummary | None


class DuplicateCheckOut(BaseModel):
    version: int
    status: str
    no_duplicates_found: bool
    exact: DuplicateCoverageOut | None
    fingerprint: DuplicateCoverageOut | None
    matches: list[DuplicateMatchOut]


class UploadItemOut(BaseModel):
    item_uuid: str
    batch_uuid: str
    parent_item_uuid: str | None
    filename: str
    selection_index: int
    member_order_key: str
    state: str
    kind: str | None
    skipped_members: int | None
    expected_bytes: int | None
    expected_sha256: str | None
    received_bytes: int
    review_version: int
    error: UploadItemError | None
    created_at: int
    updated_at: int
    detected_metadata: dict | None
    tag_write_supported: bool | None
    duplicate_check: DuplicateCheckOut | None
    result_track_uuid: str | None
    result_revision: int | None
    duplicate_kind: str | None
    conflict_matches: list[DuplicateMatchOut] | None


class UploadBatchOut(BaseModel):
    batch_uuid: str
    label: str | None
    created_at: int
    updated_at: int
    item_count: int
    state_counts: dict[str, int]
    items_path: str


class AllocationResponse(BaseModel):
    batch: UploadBatchOut
    items: list[UploadItemOut]
    limits: UploadLimitsInfo


class UploadBatchPage(BaseModel):
    batches: list[UploadBatchOut]
    next_after: str | None


class UploadItemPage(BaseModel):
    items: list[UploadItemOut]
    next_after: str | None


class StagedEdits(EditableFields):
    model_config = ConfigDict(extra="forbid")


class AcknowledgedDuplicates(BaseModel):
    model_config = ConfigDict(extra="forbid")

    library_tracks: frozenset[UUID]
    staged_items: frozenset[UUID]


class CommitRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    operation_uuid: UUID
    base_review_version: StrictInt = Field(ge=0)
    edits: StagedEdits
    write_tags: StrictBool
    acknowledged_duplicates: AcknowledgedDuplicates


class CommitOperation(BaseModel):
    """The receipt's hashed model: binds the path item to the request."""

    item_uuid: UUID
    request: CommitRequest


class ResolveDuplicateRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    operation_uuid: UUID
    expected_review_version: StrictInt = Field(ge=0)
    existing_track_uuid: UUID


class ResolveDuplicateOperation(BaseModel):
    """The receipt's hashed model: binds the path item to the request."""

    item_uuid: UUID
    request: ResolveDuplicateRequest
