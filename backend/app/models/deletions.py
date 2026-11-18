"""Deletion API DTOs (Phase 8 spec §4). The one home for deletion request/response models."""

from typing import Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, StrictInt, model_validator

from app.services.deletion_errors import ITEM_DETAIL_CODES, ITEM_ERROR_CODES

ItemErrorCode = Literal[ITEM_ERROR_CODES]
ItemDetailCode = Literal[ITEM_DETAIL_CODES]
JobStatus = Literal["pending", "running", "succeeded", "partial", "failed"]


def _require_unique_targets(targets: list["DeletionTarget"]) -> None:
    uuids = [target.uuid_id for target in targets]
    if len(set(uuids)) != len(uuids):
        raise ValueError("uuid_id values must be unique")


class DeletionTarget(BaseModel):
    model_config = ConfigDict(extra="forbid")

    uuid_id: UUID
    base_revision: StrictInt = Field(ge=0, le=2**63 - 1)  # SQLite INTEGER range


class DeletionPreviewRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    targets: list[DeletionTarget] = Field(min_length=1, max_length=100)

    @model_validator(mode="after")
    def _unique_targets(self):
        _require_unique_targets(self.targets)
        return self


class DeletionPreviewTarget(BaseModel):
    uuid_id: str
    base_revision: int
    revision: int | None
    title: str | None
    artist: str | None
    album: str | None
    master_exists: bool | None
    master_size: int | None
    unknown: bool
    already_deleted: bool
    missing_master: bool
    conflict: bool
    busy: bool


class DeletionPreviewResponse(BaseModel):
    targets: list[DeletionPreviewTarget]


class DeletionReceiptRequest(BaseModel):
    """The request body the operation receipt hashes for a deletion job."""

    targets: list[DeletionTarget]
    confirmed_count: int


class DeletionJobRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    operation_uuid: UUID
    targets: list[DeletionTarget] = Field(min_length=1, max_length=100)
    confirmed_count: StrictInt

    @model_validator(mode="after")
    def _valid_job(self):
        _require_unique_targets(self.targets)
        if self.confirmed_count != len(self.targets):
            raise ValueError("confirmed_count must equal the number of targets")
        return self

    def receipt_model(self) -> DeletionReceiptRequest:
        """Plan D6: the hashed request, order-normalised. The receipt key is
        owner + operation uuid, so the hashed body carries every target."""
        return DeletionReceiptRequest(
            targets=sorted(self.targets, key=lambda t: (str(t.uuid_id), t.base_revision)),
            confirmed_count=self.confirmed_count,
        )


class DeletionJobItemOut(BaseModel):
    uuid_id: str
    base_revision: int
    status: Literal[
        "pending", "running", "deleted", "already_deleted", "conflict", "busy", "failed"
    ]
    error: ItemErrorCode | None
    tombstone_revision: int | None
    details: list[ItemDetailCode]


class DeletionJobOut(BaseModel):
    operation_uuid: str
    created_at: int
    status: JobStatus
    item_count: int
    items: list[DeletionJobItemOut]


class DeletionJobSummaryOut(BaseModel):
    operation_uuid: str
    created_at: int
    status: JobStatus
    item_count: int
    state_counts: dict[str, int]


class DeletionJobPage(BaseModel):
    jobs: list[DeletionJobSummaryOut]
    next_after: str | None
