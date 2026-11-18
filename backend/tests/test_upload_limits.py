"""Phase 7A.1d (spec §3 limits, SC-03 "Limits are effective values"): upload
limits come from settings with the spec's defaults, and one function turns
them into the values the server really enforces (after caps). Everything
that checks or advertises a limit reads those effective values."""

import dataclasses

import pytest
from pydantic import ValidationError

from app.config import Settings
from app.services.upload_limits import UploadLimits, effective_upload_limits
from tests.upload_limit_values import EFFECTIVE_DEFAULTS, GiB, MiB

# Spec §3, quoted: "One batch holds up to 100 selected files/archives; ZIP can
# expand to 1000 audio candidates total per batch. Defaults: 250 MiB per
# selected file, 2 GiB transferred per batch, 2 GiB expanded bytes per batch,
# 250 MiB per expanded member, archive compression ratio 100:1, two receiving
# transfers globally per server" ... "Archive-wide member limit is 2000"
# ... "configurable floor (default 256 MiB)" ... "Global staged-byte quota
# defaults to 10 GiB".
SPEC_DEFAULTS = {
    "upload_max_files_per_batch": 100,
    "upload_max_file_bytes": 250 * MiB,
    "upload_max_batch_bytes": 2 * GiB,
    "upload_max_expanded_bytes_per_batch": 2 * GiB,
    "upload_max_expanded_member_bytes": 250 * MiB,
    "upload_max_audio_items_per_batch": 1000,
    "upload_max_archive_members": 2000,
    "upload_max_compression_ratio": 100,
    "upload_max_receives": 2,
    "upload_staged_quota_bytes": 10 * GiB,
    "storage_free_space_floor_bytes": 256 * MiB,
}


def _settings(**overrides) -> Settings:
    return Settings(_env_file=None, **overrides)


def _effective(**overrides) -> dict:
    return dataclasses.asdict(effective_upload_limits(_settings(**overrides)))


@pytest.fixture(autouse=True)
def _no_upload_env(monkeypatch):
    for name in [*SPEC_DEFAULTS, "upload_max_receives_per_user", "upload_user_staged_quota_bytes"]:
        monkeypatch.delenv(name.upper(), raising=False)


def test_the_settings_default_to_the_spec_values():
    settings = _settings()

    assert {name: getattr(settings, name) for name in SPEC_DEFAULTS} == SPEC_DEFAULTS


@pytest.mark.parametrize("name", sorted(SPEC_DEFAULTS))
def test_each_setting_is_read_from_its_environment_variable(monkeypatch, name):
    monkeypatch.setenv(name.upper(), "7")

    assert getattr(_settings(), name) == 7


@pytest.mark.parametrize("name", sorted(set(SPEC_DEFAULTS) - {"storage_free_space_floor_bytes"}))
@pytest.mark.parametrize("value", [0, -1])
def test_a_limit_must_be_positive(name, value):
    with pytest.raises(ValidationError) as caught:
        _settings(**{name: value})

    [error] = caught.value.errors()
    assert (error["loc"], error["type"]) == ((name,), "greater_than_equal")


def test_the_free_space_floor_may_be_zero_but_not_negative():
    assert _settings(storage_free_space_floor_bytes=0).storage_free_space_floor_bytes == 0
    with pytest.raises(ValidationError) as caught:
        _settings(storage_free_space_floor_bytes=-1)
    [error] = caught.value.errors()
    assert error["type"] == "greater_than_equal"


def test_the_effective_defaults_are_the_spec_values():
    limits = effective_upload_limits(_settings())

    assert isinstance(limits, UploadLimits)
    assert dataclasses.asdict(limits) == EFFECTIVE_DEFAULTS


def test_a_file_can_never_be_larger_than_its_batch():
    limits = _effective(upload_max_file_bytes=900, upload_max_batch_bytes=500)

    assert (limits["max_file_bytes"], limits["max_batch_bytes"]) == (500, 500)


def test_a_batch_can_never_be_larger_than_the_staged_quota():
    limits = _effective(
        upload_max_file_bytes=900, upload_max_batch_bytes=800, upload_staged_quota_bytes=300
    )

    assert (limits["max_file_bytes"], limits["max_batch_bytes"], limits["staged_quota_bytes"]) == (
        300, 300, 300,
    )


def test_expanded_bytes_are_capped_by_the_quota_and_a_member_by_its_batch():
    limits = _effective(
        upload_max_expanded_bytes_per_batch=800,
        upload_max_expanded_member_bytes=900,
        upload_staged_quota_bytes=600,
    )

    assert (limits["max_expanded_bytes_per_batch"], limits["max_expanded_member_bytes"]) == (600, 600)


def test_limits_below_their_caps_are_kept_as_configured():
    limits = _effective(
        upload_max_files_per_batch=3,
        upload_max_file_bytes=10,
        upload_max_batch_bytes=20,
        upload_max_expanded_bytes_per_batch=30,
        upload_max_expanded_member_bytes=5,
        upload_max_audio_items_per_batch=4,
        upload_max_archive_members=6,
        upload_max_compression_ratio=7,
        upload_max_receives=1,
        upload_staged_quota_bytes=40,
    )

    assert limits == {
        "max_files_per_batch": 3,
        "max_file_bytes": 10,
        "max_batch_bytes": 20,
        "max_expanded_bytes_per_batch": 30,
        "max_expanded_member_bytes": 5,
        "max_audio_items_per_batch": 4,
        "max_archive_members": 6,
        "max_compression_ratio": 7,
        "receives": 1,
        "staged_quota_bytes": 40,
        "receives_per_user": 1,
        "user_staged_quota_bytes": 40,
    }


def test_the_limits_are_immutable():
    limits = effective_upload_limits(_settings())

    with pytest.raises(dataclasses.FrozenInstanceError):
        limits.max_files_per_batch = 1
