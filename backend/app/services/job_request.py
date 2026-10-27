from typing import Literal, Optional

from pydantic import BaseModel, ConfigDict, Field


class ConversionParams(BaseModel):
    """Conversion-specific job params. ``target_container`` is deliberately
    NOT accepted from the client -- it's 1:1 derived from ``target_codec``
    (``media_types.CODEC_TO_EXT``) in this format matrix, so taking it as
    input would just be a second source of truth that could disagree with
    the first."""

    model_config = ConfigDict(extra="forbid")

    target_codec: str
    target_bitrate_kbps: Optional[int] = None


class PostJobRequest(BaseModel):
    """``POST /jobs`` body. ``type`` is a forward-looking discriminator (only
    ``"conversion"`` exists today) so future bulk/upload job types add zero
    endpoints, per the doc's generic-/jobs-resource design.

    ``base_revision`` is required but NULLABLE -- same "Option A" shape as
    ``TrackPatchRequest``: a client with an unknown local base sends an
    explicit null, which must reach ``RevisionConflict`` (409), not a 422
    (the client outbox treats 422 as a permanent rejection)."""

    model_config = ConfigDict(extra="forbid")

    type: Literal["conversion"]
    uuid_id: str
    params: ConversionParams
    base_revision: Optional[int] = Field(...)
