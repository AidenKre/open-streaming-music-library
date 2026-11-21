"""Phase M.1a review r1 #4, #6, #7: what auth errors and results carry.

- A body that fails validation becomes a 422 whose exception chain holds no
  ``ValidationError`` (its text includes the raw body, password and all).
- A subclass of a mapped refusal maps like its base, never a 500.
- The account result handed to routes carries no password hash.
"""

import asyncio

import pytest
from fastapi import HTTPException

from app.auth import accounts
from app.routers import auth as auth_router

PASSWORD = "a long enough password"


def test_a_validation_failure_chains_no_exception_holding_the_body():
    raw = b'{"username": 5, "password": "' + PASSWORD.encode() + b'"}'
    with pytest.raises(HTTPException) as refused:
        asyncio.run(auth_router._credentials(raw))

    error = refused.value
    assert error.status_code == 422
    assert error.__cause__ is None
    assert error.__suppress_context__ is True


def test_a_subclass_of_a_refusal_maps_like_its_base():
    class Narrower(accounts.InvalidCredentials):
        pass

    error = auth_router._refusal(Narrower())
    assert error.status_code == 401
    assert error.detail["error"] == "invalid_credentials"


def test_register_and_login_results_carry_no_password_hash(open_app_client):
    with open_app_client() as client:
        database, settings = client.app.state.database, client.app.state.settings
        registered = accounts.register(database, settings, "Sam", PASSWORD)
        logged_in = accounts.login(database, settings, "Sam", PASSWORD)

    for result in (registered, logged_in):
        fields = vars(result.user) if not isinstance(result.user, dict) else result.user
        assert "password_hash" not in fields
        assert result.user.username == "Sam"
