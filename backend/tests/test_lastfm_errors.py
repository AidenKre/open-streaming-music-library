"""9D.1d (spec §7.4 error table, SC-22, 9-U10): ``services/lastfm_errors.py`` is
the one home of the Last.fm feature's error codes and holds exactly the
table's rows: code, HTTP status, ``retryable``, the extra fields and
``Retry-After``."""

import inspect

import pytest
from fastapi import HTTPException

from app.services import lastfm_errors
from app.services.lastfm_errors import LastfmError

# Spec §7.4, copied by hand from the error table.
TABLE = {
    "lastfm_disabled": (403, False),
    "lastfm_stopped": (503, False),
    "lastfm_unavailable": (503, True),
    "lastfm_too_soon": (429, True),
    "lastfm_not_authorized_yet": (409, True),
    "lastfm_approval_expired": (410, False),
    "lastfm_account_mismatch": (409, False),
    "lastfm_not_connected": (409, False),
    "lastfm_connection_changed": (409, False),
    "lastfm_reconnect_required": (409, False),
}

ARGS = {
    "lastfm_too_soon": {"retry_after_s": 7},
    "lastfm_account_mismatch": {"stored_account": "alpha", "approved_account": "beta"},
}


def _build(code):
    return getattr(lastfm_errors, code)(**ARGS.get(code, {}))


def test_the_module_offers_exactly_the_codes_of_the_table():
    constructors = {
        name for name, value in vars(lastfm_errors).items()
        if name.startswith("lastfm_") and inspect.isfunction(value)
    }

    assert constructors == set(TABLE)


@pytest.mark.parametrize("code", sorted(TABLE))
def test_each_code_has_the_tables_status_and_retryable(code):
    status, retryable = TABLE[code]

    http = _build(code).to_http()

    assert isinstance(http, HTTPException)
    assert http.status_code == status
    assert http.detail["error"] == code
    assert http.detail["retryable"] is retryable
    assert isinstance(http.detail["message"], str) and http.detail["message"]


@pytest.mark.parametrize("code", sorted(set(TABLE) - {"lastfm_account_mismatch"}))
def test_only_the_mismatch_carries_extra_fields(code):
    assert set(_build(code).to_http().detail) == {"error", "message", "retryable"}


def test_the_mismatch_names_both_accounts():
    detail = _build("lastfm_account_mismatch").to_http().detail

    assert set(detail) == {"error", "message", "retryable", "stored_account", "approved_account"}
    assert (detail["stored_account"], detail["approved_account"]) == ("alpha", "beta")


def test_too_soon_carries_retry_after_in_whole_seconds():
    http = lastfm_errors.lastfm_too_soon(retry_after_s=7).to_http()

    assert http.headers == {"Retry-After": "7"}


@pytest.mark.parametrize("code", sorted(set(TABLE) - {"lastfm_too_soon"}))
def test_no_other_code_sets_a_header(code):
    assert not _build(code).to_http().headers


@pytest.mark.parametrize("bad", [0, -1, 1.5, True, None])
def test_too_soon_refuses_a_retry_after_that_is_not_a_positive_whole_number(bad):
    with pytest.raises(ValueError):
        lastfm_errors.lastfm_too_soon(retry_after_s=bad)


def test_an_error_is_an_exception_with_its_code():
    error = lastfm_errors.lastfm_disabled()

    assert isinstance(error, LastfmError) and isinstance(error, Exception)
    assert error.code == "lastfm_disabled"
