"""Phase 7A.1d, decision O4 / DEV-7-02 (per-user fairness): a per-user cap on
receiving transfers (default 1) and a per-user staged quota (default 5 GiB),
both capped by their server-wide counterparts and advertised in
``uploads.limits``; a busy transfer slot answers 503 ``upload_slots_busy``
(retryable, with ``Retry-After``). 7A.2b raises that error; this piece
defines it. Kept in its own file and commits so the decision reverts alone."""

import dataclasses

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from pydantic import ValidationError

from app.config import Settings
from app.services.upload_errors import UploadError, upload_slots_busy
from app.services.upload_limits import effective_upload_limits

GiB = 1024**3


def _settings(**overrides) -> Settings:
    return Settings(_env_file=None, **overrides)


def _effective(**overrides) -> dict:
    return dataclasses.asdict(effective_upload_limits(_settings(**overrides)))


@pytest.fixture(autouse=True)
def _no_upload_env(monkeypatch):
    for name in ("UPLOAD_MAX_RECEIVES_PER_USER", "UPLOAD_USER_STAGED_QUOTA_BYTES",
                 "UPLOAD_MAX_RECEIVES", "UPLOAD_STAGED_QUOTA_BYTES"):
        monkeypatch.delenv(name, raising=False)


def test_the_per_user_settings_default_to_one_receive_and_5_gib():
    settings = _settings()

    assert settings.upload_max_receives_per_user == 1
    assert settings.upload_user_staged_quota_bytes == 5 * GiB


def test_the_per_user_settings_are_read_from_the_environment(monkeypatch):
    monkeypatch.setenv("UPLOAD_MAX_RECEIVES_PER_USER", "2")
    monkeypatch.setenv("UPLOAD_USER_STAGED_QUOTA_BYTES", "77")

    settings = _settings()

    assert (settings.upload_max_receives_per_user, settings.upload_user_staged_quota_bytes) == (2, 77)


@pytest.mark.parametrize("name", ["upload_max_receives_per_user", "upload_user_staged_quota_bytes"])
def test_a_per_user_limit_must_be_positive(name):
    with pytest.raises(ValidationError) as caught:
        _settings(**{name: 0})
    [error] = caught.value.errors()
    assert (error["loc"], error["type"]) == ((name,), "greater_than_equal")


def test_the_effective_per_user_defaults():
    limits = _effective()

    assert (limits["receives_per_user"], limits["user_staged_quota_bytes"]) == (1, 5 * GiB)
    # The per-user quota (5 GiB) is above the default batch (2 GiB): nothing else moves.
    assert (limits["max_batch_bytes"], limits["max_file_bytes"]) == (2 * GiB, 250 * 1024**2)


def test_a_user_can_never_have_more_than_the_server_wide_values():
    limits = _effective(
        upload_max_receives=2, upload_max_receives_per_user=5,
        upload_staged_quota_bytes=300, upload_user_staged_quota_bytes=900,
    )

    assert (limits["receives_per_user"], limits["user_staged_quota_bytes"]) == (2, 300)


def test_a_batch_file_and_expansion_never_exceed_the_user_s_quota():
    limits = _effective(
        upload_user_staged_quota_bytes=100,
        upload_max_batch_bytes=800, upload_max_file_bytes=700,
        upload_max_expanded_bytes_per_batch=600, upload_max_expanded_member_bytes=500,
    )

    assert {k: limits[k] for k in (
        "max_batch_bytes", "max_file_bytes", "max_expanded_bytes_per_batch", "max_expanded_member_bytes",
        "user_staged_quota_bytes",
    )} == {
        "max_batch_bytes": 100, "max_file_bytes": 100, "max_expanded_bytes_per_batch": 100,
        "max_expanded_member_bytes": 100, "user_staged_quota_bytes": 100,
    }
    assert limits["staged_quota_bytes"] == 10 * GiB  # the server-wide value is unchanged


def test_app_info_advertises_the_effective_per_user_values(open_app_client):
    env = {"UPLOAD_MAX_RECEIVES_PER_USER": "4", "UPLOAD_MAX_RECEIVES": "3",
           "UPLOAD_USER_STAGED_QUOTA_BYTES": "9000", "UPLOAD_STAGED_QUOTA_BYTES": "4000"}
    with open_app_client(env=env) as client:
        limits = client.get("/app/info").json()["uploads"]["limits"]

    assert (limits["receives"], limits["receives_per_user"]) == (3, 3)
    assert (limits["staged_quota_bytes"], limits["user_staged_quota_bytes"]) == (4000, 4000)


# ── 503 upload_slots_busy (SC-22) ──────────────────────────────────────────

def test_slots_busy_is_a_retryable_503_with_retry_after():
    error = upload_slots_busy(retry_after_s=7)

    assert isinstance(error, UploadError)
    http = error.to_http()
    assert http.status_code == 503
    assert http.detail == {
        "error": "upload_slots_busy",
        "message": http.detail["message"],
        "retryable": True,
        "retry_after_s": 7,
    }
    assert http.detail["message"]
    assert http.headers == {"Retry-After": "7"}


@pytest.mark.parametrize("bad", [0, -1])
def test_slots_busy_needs_a_positive_delay(bad):
    with pytest.raises(ValueError):
        upload_slots_busy(retry_after_s=bad)


def test_slots_busy_reaches_the_client_as_an_sc22_envelope_with_the_header():
    app = FastAPI()

    @app.put("/probe")
    def probe():
        raise upload_slots_busy(retry_after_s=3).to_http()

    response = TestClient(app).put("/probe")

    assert response.status_code == 503
    assert response.headers["Retry-After"] == "3"
    detail = response.json()["detail"]
    assert (detail["error"], detail["retryable"], detail["retry_after_s"]) == ("upload_slots_busy", True, 3)
