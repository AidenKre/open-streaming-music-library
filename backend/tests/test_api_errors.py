"""SC-22: one typed API error envelope helper.

Every new endpoint in Phases 5-9 returns errors as
``{"detail": {"error": "<stable_snake_case_code>", "message": "<human text>",
"retryable": <bool>, ...code-specific fields}}`` built by ``api_error``. It
is a strict superset of the existing ``detail.error`` convention.
"""

import pytest
from fastapi import FastAPI, HTTPException
from fastapi.testclient import TestClient

from app.core.api_errors import api_error


def test_builds_the_envelope_with_extra_fields():
    exc = api_error(
        409,
        "history_event_conflict",
        "An event with this id already exists with different values.",
        retryable=False,
        conflicting_event_uuids=["a", "b"],
    )
    assert isinstance(exc, HTTPException)
    assert exc.status_code == 409
    assert exc.detail == {
        "error": "history_event_conflict",
        "message": "An event with this id already exists with different values.",
        "retryable": False,
        "conflicting_event_uuids": ["a", "b"],
    }


def test_retryable_is_required_and_kept_as_bool():
    exc = api_error(503, "database_busy", "Try again.", retryable=True)
    assert exc.detail["retryable"] is True
    with pytest.raises(TypeError):
        api_error(503, "database_busy", "Try again.")  # retryable is keyword-only + required


@pytest.mark.parametrize("bad", ["Conflict", "with-dash", "", "1starts_digit", "has space"])
def test_code_must_be_stable_snake_case(bad):
    with pytest.raises(ValueError):
        api_error(400, bad, "m", retryable=False)


def test_extra_fields_cannot_override_the_envelope_keys():
    with pytest.raises(ValueError):
        api_error(400, "bad_request", "m", retryable=False, error="other")


def test_round_trips_through_fastapi_as_detail():
    app = FastAPI()

    @app.get("/boom")
    def boom():
        raise api_error(409, "thing_conflict", "Conflict.", retryable=False, ids=[1])

    with TestClient(app) as client:
        response = client.get("/boom")
    assert response.status_code == 409
    assert response.json() == {
        "detail": {
            "error": "thing_conflict",
            "message": "Conflict.",
            "retryable": False,
            "ids": [1],
        }
    }
