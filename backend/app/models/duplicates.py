"""Duplicate review API DTOs (Phase 8 spec §4)."""

from typing import Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict


class DuplicatePairTrack(BaseModel):
    uuid_id: str
    revision: int
    title: str | None
    artist: str | None
    album: str | None
    codec: str | None
    bitrate_kbps: float | None
    sample_rate_hz: int | None
    channels: int | None
    duration_s: float | None
    added_at: int
    master_present: bool | None  # None: the server could not check the file


class DuplicatePairOut(BaseModel):
    uuid_a: str
    uuid_b: str
    kind: Literal["exact", "fingerprint"]
    band: Literal["exact", "strong", "possible"]
    score: float | None
    status: Literal["open", "dismissed"]
    detected_at: int
    track_a: DuplicatePairTrack
    track_b: DuplicatePairTrack


class DuplicatePairPage(BaseModel):
    pairs: list[DuplicatePairOut]
    next_after: str | None


class PairCounts(BaseModel):
    open: int
    dismissed: int


class DuplicateBands(BaseModel):
    exact: PairCounts
    strong: PairCounts
    possible: PairCounts


class ExactCoverage(BaseModel):
    pending: int
    current: int
    failed: int
    unsupported: int


class FingerprintCoverage(BaseModel):
    pending: int
    current: int
    unavailable: int
    too_short: int
    low_information: int
    failed: int


class MatchCoverage(BaseModel):
    pending: int
    current: int


class IdentityCoverage(BaseModel):
    exact: ExactCoverage
    fingerprint: FingerprintCoverage
    match: MatchCoverage


class DuplicateSummaryOut(BaseModel):
    bands: DuplicateBands
    coverage: IdentityCoverage
    fingerprinter: str | None


class PairRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    uuid_a: UUID
    uuid_b: UUID


class PairStatusOut(BaseModel):
    uuid_a: str
    uuid_b: str
    status: Literal["open", "dismissed"]
