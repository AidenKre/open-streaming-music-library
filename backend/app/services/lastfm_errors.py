"""SC-22 errors of the Last.fm routes (spec §7.4). The one home for these codes."""

from app.core.api_errors import ApiError


class LastfmError(ApiError):
    """An error of the Last.fm routes."""


def lastfm_disabled() -> LastfmError:
    return LastfmError(
        403, "lastfm_disabled", "Last.fm scrobbling is turned off on this server.", retryable=False
    )


def lastfm_stopped() -> LastfmError:
    return LastfmError(
        503,
        "lastfm_stopped",
        "Last.fm is stopped on this server right now.",
        retryable=False,
    )


def lastfm_unavailable() -> LastfmError:
    return LastfmError(
        503,
        "lastfm_unavailable",
        "Last.fm did not respond. Try again shortly.",
        retryable=True,
    )


def lastfm_too_soon(*, retry_after_s: int) -> LastfmError:
    if (
        not isinstance(retry_after_s, int)
        or isinstance(retry_after_s, bool)
        or retry_after_s <= 0
    ):
        raise ValueError("retry_after_s must be a positive int")
    return LastfmError(
        429,
        "lastfm_too_soon",
        "You started a Last.fm connection a moment ago. Wait a little and try again.",
        retryable=True,
        headers={"Retry-After": str(retry_after_s)},
    )


def lastfm_not_authorized_yet() -> LastfmError:
    return LastfmError(
        409,
        "lastfm_not_authorized_yet",
        "Last.fm has not been approved yet. Approve it on last.fm, then try again.",
        retryable=True,
    )


def lastfm_approval_expired() -> LastfmError:
    return LastfmError(
        410,
        "lastfm_approval_expired",
        "The Last.fm approval has expired. Start connecting again.",
        retryable=False,
    )


def lastfm_account_mismatch(*, stored_account, approved_account) -> LastfmError:
    return LastfmError(
        409,
        "lastfm_account_mismatch",
        "That approval was for a different Last.fm account than the one connected.",
        retryable=False,
        stored_account=stored_account,
        approved_account=approved_account,
    )


def lastfm_not_connected() -> LastfmError:
    return LastfmError(
        409, "lastfm_not_connected", "Last.fm is not connected yet.", retryable=False
    )


def lastfm_connection_changed() -> LastfmError:
    return LastfmError(
        409,
        "lastfm_connection_changed",
        "The Last.fm connection changed since you last looked. Check it and try again.",
        retryable=False,
    )


def lastfm_reconnect_required() -> LastfmError:
    return LastfmError(
        409,
        "lastfm_reconnect_required",
        "Last.fm needs to be reconnected before it can be turned on.",
        retryable=False,
    )
