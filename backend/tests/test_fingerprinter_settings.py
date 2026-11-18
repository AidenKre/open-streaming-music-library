"""Phase 6.5B.1a (spec §4.1 "Selection", review 6.5-U07): the fingerprinter
is chosen by ``AUDIO_FINGERPRINT_BACKEND=auto|fpcalc|ffmpeg|off`` (default
``auto``) with an optional ``FPCALC_PATH``."""

import pytest
from pydantic import ValidationError

from app.config import Settings

_ENV = ("AUDIO_FINGERPRINT_BACKEND", "FPCALC_PATH", "FPCALC_TIMEOUT_S")


@pytest.fixture(autouse=True)
def _clean_env(monkeypatch):
    for var in _ENV:
        monkeypatch.delenv(var, raising=False)


def test_defaults_are_auto_with_no_fpcalc_path():
    settings = Settings(_env_file=None)

    assert settings.audio_fingerprint_backend == "auto"
    assert settings.fpcalc_path is None
    assert settings.fpcalc_timeout_s > 0


@pytest.mark.parametrize("mode", ["auto", "fpcalc", "ffmpeg", "off"])
def test_every_documented_mode_is_accepted_from_the_environment(monkeypatch, mode):
    monkeypatch.setenv("AUDIO_FINGERPRINT_BACKEND", mode)

    assert Settings(_env_file=None).audio_fingerprint_backend == mode


@pytest.mark.parametrize("mode", ["", "chromaprint", "FFMPEG-chromaprint", "none"])
def test_an_unknown_mode_is_rejected(monkeypatch, mode):
    monkeypatch.setenv("AUDIO_FINGERPRINT_BACKEND", mode)

    with pytest.raises(ValidationError):
        Settings(_env_file=None)


def test_fpcalc_path_and_timeout_come_from_the_environment(monkeypatch, tmp_path):
    monkeypatch.setenv("FPCALC_PATH", str(tmp_path / "bin" / "fpcalc"))
    monkeypatch.setenv("FPCALC_TIMEOUT_S", "12.5")

    settings = Settings(_env_file=None)

    assert settings.fpcalc_path == tmp_path / "bin" / "fpcalc"
    assert settings.fpcalc_timeout_s == 12.5


@pytest.mark.parametrize("blank", ["", "   "])
def test_a_blank_fpcalc_path_means_unset(monkeypatch, blank):
    monkeypatch.setenv("FPCALC_PATH", blank)

    assert Settings(_env_file=None).fpcalc_path is None


@pytest.mark.parametrize("timeout", ["0", "-1"])
def test_a_non_positive_timeout_is_rejected(monkeypatch, timeout):
    monkeypatch.setenv("FPCALC_TIMEOUT_S", timeout)

    with pytest.raises(ValidationError):
        Settings(_env_file=None)

