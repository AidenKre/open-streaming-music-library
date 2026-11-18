"""Phase M.1b (M-U12, spec §5.3 "What handlers see"): the request principal.

The auth middleware puts an immutable ``Principal(user_id, is_admin,
is_master_admin, session_hash)`` in ``scope["state"]``; handlers read it only
through ``current_principal()``. A request that somehow reaches a handler
without one is refused (fail closed), never treated as the admin.
"""

import dataclasses

import pytest
from fastapi import HTTPException
from starlette.requests import Request

from app.auth.principal import Principal, current_principal


def _request(state=None) -> Request:
    scope = {"type": "http", "method": "GET", "path": "/tracks", "headers": []}
    if state is not None:
        scope["state"] = state
    return Request(scope)


def _principal(**overrides) -> Principal:
    values = dict(user_id=3, is_admin=False, is_master_admin=False, session_hash="ab" * 32)
    values.update(overrides)
    return Principal(**values)


def test_a_principal_carries_exactly_the_spec_fields():
    assert [f.name for f in dataclasses.fields(Principal)] == [
        "user_id", "is_admin", "is_master_admin", "session_hash",
    ]


@pytest.mark.parametrize("field", ["user_id", "is_admin", "is_master_admin", "session_hash"])
def test_a_principal_is_immutable(field):
    principal = _principal()
    with pytest.raises(dataclasses.FrozenInstanceError):
        setattr(principal, field, 1)
    assert principal == _principal()


def test_current_principal_reads_the_principal_from_the_scope_state():
    principal = _principal(user_id=7, is_admin=True)

    assert current_principal(_request({"principal": principal})) is principal


@pytest.mark.parametrize("state", [None, {}, {"principal": None}, {"principal": {"user_id": 1}}])
def test_a_request_without_a_principal_is_refused_not_defaulted(state):
    with pytest.raises(HTTPException) as caught:
        current_principal(_request(state))

    assert caught.value.status_code == 401
    assert caught.value.detail["error"] == "auth_required"
    assert caught.value.detail["retryable"] is False
