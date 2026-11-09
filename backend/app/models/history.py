from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, field_validator


class HistoryEvent(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)

    event_uuid: str
    kind: str = Field(min_length=1, max_length=64)
    entity_type: str = Field(min_length=1, max_length=64)
    entity_ref: str = Field(min_length=1, max_length=256)
    occurred_at: int = Field(ge=0, le=253402300799999)
    seconds_played: float | None = Field(default=None, ge=0, allow_inf_nan=False)
    track_length: float | None = Field(default=None, gt=0, allow_inf_nan=False)

    @field_validator("kind", "entity_type", "entity_ref")
    @classmethod
    def no_control_characters(cls, value: str) -> str:
        if any(ord(char) < 32 or ord(char) == 127 for char in value):
            raise ValueError("history text must not contain control characters")
        return value

    @field_validator("event_uuid")
    @classmethod
    def canonical_uuid4(cls, value: str) -> str:
        try:
            parsed = UUID(value)
        except ValueError:
            raise ValueError("event_uuid must be a canonical UUID v4") from None
        if parsed.version != 4 or str(parsed) != value:
            raise ValueError("event_uuid must be a canonical UUID v4")
        return value


class PostHistoryRequest(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)

    events: list[HistoryEvent] = Field(min_length=1, max_length=200)


class HistoryEventResponse(HistoryEvent):
    revision: int
    received_at: int


class GetHistoryChangesResponse(BaseModel):
    events: list[HistoryEventResponse]
    nextCursor: int | None
    latestRevision: int
