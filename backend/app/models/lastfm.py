"""Outcomes of the Last.fm connection writes (spec §7.4), and the result codes
OSML itself gives a scrobble row (spec §7.9)."""

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


# The result codes OSML itself stores on a scrobble row; Last.fm's own codes
# are stored as decimal text. Stored, sent to the app and matched by text there,
# and named in the scrobble_outbox CHECK of init.sql: never change a value.
RESULT_INVALID_ROW = "invalid_row"  # failed: the stored row cannot be put into a request
RESULT_NO_ANSWER = "no_answer"  # dropped: Last.fm's reply did not mention the row
RESULT_TOO_OLD = "too_old"  # dropped: its listen became too old before it was sent
RESULT_TOO_MANY_TRIES = "too_many_tries"  # dropped: it was tried the maximum number of times
