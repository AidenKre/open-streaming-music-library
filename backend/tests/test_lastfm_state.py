"""9D.1a (spec §7.2, 9-U08): the Last.fm server state is held in memory and
thread-safe. ``off`` is the operator's decision; ``stopped`` is entered for an
invalid configuration or at run time, with the cause logged at ERROR on the
operator logger, and lasts until a restart (O10)."""

import logging
import threading

import pytest
from pydantic import SecretStr

from app.config import Settings
from app.core.operator_log import operator_logger
from app.services.lastfm_config import LastfmConfig
from app.services.lastfm_state import LastfmService, LastfmState, start_lastfm
from tests import lastfm_secrets as planted
from tests.lastfm_secrets import LASTFM_ENV, assert_no_secret, valid_env

OPERATOR = operator_logger.name


def _config() -> LastfmConfig:
    return LastfmConfig(
        api_key=SecretStr(planted.API_KEY),
        api_secret=SecretStr(planted.API_SECRET),
        credential_key=SecretStr(planted.CREDENTIAL_KEY),
        settle_delay_s=60,
        min_request_gap_s=5,
    )


def _errors(caplog):
    return [r for r in caplog.records if r.levelno >= logging.ERROR]


@pytest.fixture
def settings_from_env(monkeypatch, tmp_path):
    monkeypatch.chdir(tmp_path)
    for name in LASTFM_ENV:
        monkeypatch.delenv(name, raising=False)

    def _build(env):
        for name, value in env.items():
            monkeypatch.setenv(name, value)
        return Settings(_env_file=None)

    return _build


# ── the holder ──────────────────────────────────────────────────────────────


def test_the_three_values_are_the_client_strings():
    assert [s.value for s in LastfmService] == ["off", "running", "stopped"]


def test_running_holds_its_config():
    config = _config()
    state = LastfmState(LastfmService.RUNNING, config)
    assert state.service is LastfmService.RUNNING
    assert state.is_running
    assert state.config is config


def test_stop_moves_running_to_stopped_and_logs_the_cause_once(caplog):
    caplog.set_level(logging.DEBUG)
    state = LastfmState(LastfmService.RUNNING, _config())

    assert state.stop("Last.fm rejected the API key (error 10)") is True
    assert state.stop("ten rejected scrobble requests in a row") is False

    assert state.service is LastfmService.STOPPED
    assert not state.is_running
    errors = _errors(caplog)
    assert len(errors) == 1
    assert errors[0].name == OPERATOR
    assert "Last.fm rejected the API key (error 10)" in errors[0].getMessage()
    assert "stopped" in errors[0].getMessage()


def test_off_never_becomes_stopped(caplog):
    caplog.set_level(logging.DEBUG)
    state = LastfmState(LastfmService.OFF, None)

    assert state.stop("anything") is False

    assert state.service is LastfmService.OFF
    assert _errors(caplog) == []


def test_concurrent_stops_change_the_state_once_and_log_once(caplog):
    caplog.set_level(logging.DEBUG)
    state = LastfmState(LastfmService.RUNNING, _config())
    barrier = threading.Barrier(32, timeout=10)
    results = []
    lock = threading.Lock()

    def worker(i):
        barrier.wait()
        changed = state.stop(f"cause {i}")
        with lock:
            results.append(changed)

    threads = [threading.Thread(target=worker, args=(i,)) for i in range(32)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(timeout=10)

    assert not any(t.is_alive() for t in threads)  # 9-R1-34: a hang fails here, no thread leaks on
    assert results.count(True) == 1
    assert len(results) == 32
    assert len(_errors(caplog)) == 1
    assert state.service is LastfmService.STOPPED


def test_the_holder_never_shows_secrets():
    state = LastfmState(LastfmService.RUNNING, _config())
    assert_no_secret(repr(state), "repr(LastfmState)")
    assert_no_secret(str(state), "str(LastfmState)")


# ── start_lastfm: resolve, log, hold ────────────────────────────────────────


def test_default_starts_off_and_quiet(settings_from_env, caplog):
    caplog.set_level(logging.DEBUG)
    state = start_lastfm(settings_from_env({}))
    assert state.service is LastfmService.OFF
    assert state.config is None
    assert [r for r in caplog.records if r.levelno >= logging.WARNING] == []


def test_a_non_boolean_switch_starts_off_with_an_error_naming_it(settings_from_env, caplog):
    caplog.set_level(logging.DEBUG)
    value = "planted-not-a-bool"

    state = start_lastfm(settings_from_env(valid_env(LASTFM_ENABLED=value)))

    assert state.service is LastfmService.OFF
    assert state.config is None
    errors = _errors(caplog)
    assert len(errors) == 1
    assert errors[0].name == OPERATOR
    assert "LASTFM_ENABLED" in errors[0].getMessage()
    assert_no_secret(caplog.text, "captured logs", secrets=[value, *planted.ALL])


def test_an_invalid_configuration_starts_stopped_with_an_error_naming_the_setting(
    settings_from_env, caplog
):
    caplog.set_level(logging.DEBUG)
    bad_key = planted.API_KEY + "Z"

    state = start_lastfm(settings_from_env(valid_env(LASTFM_API_KEY=bad_key)))

    assert state.service is LastfmService.STOPPED
    assert state.config is None
    errors = _errors(caplog)
    assert len(errors) == 1
    assert errors[0].name == OPERATOR
    assert "LASTFM_API_KEY" in errors[0].getMessage()
    assert_no_secret(caplog.text, "captured logs", secrets=[bad_key, *planted.ALL])


def test_a_valid_configuration_starts_running(settings_from_env, caplog):
    caplog.set_level(logging.DEBUG)

    state = start_lastfm(settings_from_env(valid_env()))

    assert state.service is LastfmService.RUNNING
    assert isinstance(state.config, LastfmConfig)
    assert _errors(caplog) == []
    assert_no_secret(caplog.text, "captured logs")


def test_the_simulator_seam_warns_at_startup(settings_from_env, caplog):
    caplog.set_level(logging.DEBUG)

    state = start_lastfm(
        settings_from_env(valid_env(OSML_INSECURE_LASTFM_API_URL="http://127.0.0.1:8123/2.0/"))
    )

    assert state.service is LastfmService.RUNNING
    warnings = [r for r in caplog.records if r.levelno == logging.WARNING]
    assert len(warnings) == 1
    assert warnings[0].name == OPERATOR
    assert "OSML_INSECURE_LASTFM_API_URL" in warnings[0].getMessage()
    assert_no_secret(caplog.text, "captured logs")


def test_a_refused_simulator_url_starts_stopped(settings_from_env, caplog):
    caplog.set_level(logging.DEBUG)

    state = start_lastfm(settings_from_env(valid_env(OSML_INSECURE_LASTFM_API_URL="http://10.0.0.1")))

    assert state.service is LastfmService.STOPPED
    assert "OSML_INSECURE_LASTFM_API_URL" in _errors(caplog)[0].getMessage()
    assert "10.0.0.1" not in caplog.text


# ── signoff-9-lastfm-app-name (DEV-9-06): LASTFM_APP_NAME at startup ────────


@pytest.mark.parametrize("value", ["planted-app-name\x01", "planted-app-name" + "z" * 120])
def test_a_bad_app_name_is_ignored_with_one_warning_naming_the_setting(settings_from_env, caplog, value):
    # User decision 2026-11-14 (DEV-s9an-01): ignored with a warning, never stopped.
    caplog.set_level(logging.DEBUG)

    state = start_lastfm(settings_from_env(valid_env(LASTFM_APP_NAME=value)))

    assert state.service is LastfmService.RUNNING
    assert state.config is not None and state.config.app_name is None
    assert _errors(caplog) == []
    warnings = [r for r in caplog.records if r.levelno == logging.WARNING]
    assert len(warnings) == 1
    assert warnings[0].name == OPERATOR
    message = warnings[0].getMessage()
    assert "LASTFM_APP_NAME" in message
    assert "ignored" in message
    assert "planted-app-name" not in caplog.text
    assert_no_secret(caplog.text, "captured logs", secrets=[value, *planted.ALL])


def test_a_valid_app_name_starts_running_and_is_never_logged(settings_from_env, caplog):
    caplog.set_level(logging.DEBUG)

    state = start_lastfm(settings_from_env(valid_env(LASTFM_APP_NAME="Planted App Name 7")))

    assert state.service is LastfmService.RUNNING
    assert state.config.app_name == "Planted App Name 7"
    assert [r for r in caplog.records if r.levelno >= logging.WARNING] == []
    assert "Planted App Name 7" not in caplog.text
