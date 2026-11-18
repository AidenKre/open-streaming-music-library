"""Outcomes of the Last.fm connection writes (spec §7.4)."""

from dataclasses import dataclass
from enum import Enum


class BindOutcome(Enum):
    BOUND = "bound"
    REBOUND = "rebound"
    ACCOUNT_MISMATCH = "account_mismatch"
    TOKEN_CHANGED = "token_changed"


@dataclass(frozen=True)
class BindResult:
    outcome: BindOutcome
    connection_id: str | None = None
    stored_account: str | None = None


class EnableOutcome(Enum):
    ENABLED = "enabled"
    NOT_CONNECTED = "not_connected"
    CONNECTION_CHANGED = "connection_changed"
    RECONNECT_REQUIRED = "reconnect_required"
