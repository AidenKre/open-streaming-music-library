"""9D.1a (spec §7.2, 9-U08): the Last.fm settings are loosely typed, so a typo
never stops ``Settings()``; ``resolve_lastfm_config`` checks them and returns a
usable configuration, ``off``, or the **name** of the offending setting, never
its value."""

import pytest

from app.config import Settings
from app.services.lastfm_config import (
    DEFAULT_API_URL,
    LastfmConfig,
    LastfmInvalid,
    LastfmOff,
    resolve_lastfm_config,
)
from tests import lastfm_secrets as planted
from tests.lastfm_secrets import (
    LASTFM_ENV,
    assert_no_secret,
    assert_secret_equal,
    valid_env,
)


@pytest.fixture
def settings_from_env(monkeypatch, tmp_path):
    """Build ``Settings`` through the real environment loading."""
    monkeypatch.chdir(tmp_path)  # no .env, relative dirs inside tmp
    for name in LASTFM_ENV:
        monkeypatch.delenv(name, raising=False)

    def _build(env: dict[str, str]) -> Settings:
        for name, value in env.items():
            monkeypatch.setenv(name, value)
        return Settings(_env_file=None)

    return _build


# ── off ─────────────────────────────────────────────────────────────────────


def test_default_is_off(settings_from_env):
    assert resolve_lastfm_config(settings_from_env({})) == LastfmOff(switch_unparseable=False)


@pytest.mark.parametrize("value", ["false", "FALSE", "False", "0", "no", "off", "f", "n", " false ", ""])
def test_a_false_switch_is_off(settings_from_env, value):
    result = resolve_lastfm_config(settings_from_env({"LASTFM_ENABLED": value}))
    assert result == LastfmOff(switch_unparseable=False)


@pytest.mark.parametrize("value", ["maybe", "2", "tru", "yes please", "enabled", "-1"])
def test_a_non_boolean_switch_counts_as_off(settings_from_env, value):
    result = resolve_lastfm_config(settings_from_env(valid_env(LASTFM_ENABLED=value)))
    assert result == LastfmOff(switch_unparseable=True)


def test_off_checks_nothing_else(settings_from_env):
    env = {
        "LASTFM_ENABLED": "false",
        "LASTFM_API_KEY": "short",
        "LASTFM_SETTLE_DELAY_S": "abc",
        "LASTFM_MIN_REQUEST_GAP_S": "0",
        "LASTFM_CREDENTIAL_KEY": "nope",
        "LASTFM_API_SECRET_FILE": "/definitely/not/there",
        "OSML_INSECURE_LASTFM_API_URL": "http://10.0.0.1",
    }
    assert resolve_lastfm_config(settings_from_env(env)) == LastfmOff(switch_unparseable=False)


# ── a valid configuration ───────────────────────────────────────────────────


@pytest.mark.parametrize("value", ["true", "TRUE", "True", "1", "yes", "on", "t", "y", " true "])
def test_an_enabled_valid_configuration_resolves(settings_from_env, value):
    result = resolve_lastfm_config(settings_from_env(valid_env(LASTFM_ENABLED=value)))

    assert isinstance(result, LastfmConfig)
    assert_secret_equal(result.api_key.get_secret_value(), planted.API_KEY, "api_key")
    assert_secret_equal(result.api_secret.get_secret_value(), planted.API_SECRET, "api_secret")
    assert_secret_equal(result.credential_key.get_secret_value(), planted.CREDENTIAL_KEY, "credential_key")
    assert result.settle_delay_s == 60
    assert result.min_request_gap_s == 5
    assert result.api_url == DEFAULT_API_URL == "https://ws.audioscrobbler.com/2.0/"
    assert result.insecure_api_url is False


def test_the_numbers_are_read_as_whole_seconds(settings_from_env):
    env = valid_env(LASTFM_SETTLE_DELAY_S="0", LASTFM_MIN_REQUEST_GAP_S=" 30 ")
    result = resolve_lastfm_config(settings_from_env(env))
    assert (result.settle_delay_s, result.min_request_gap_s) == (0, 30)

    env = valid_env(LASTFM_SETTLE_DELAY_S="3600", LASTFM_MIN_REQUEST_GAP_S="1")
    result = resolve_lastfm_config(settings_from_env(env))
    assert (result.settle_delay_s, result.min_request_gap_s) == (3600, 1)


def test_empty_numbers_take_the_defaults(settings_from_env):
    env = valid_env(LASTFM_SETTLE_DELAY_S="", LASTFM_MIN_REQUEST_GAP_S="")
    result = resolve_lastfm_config(settings_from_env(env))
    assert (result.settle_delay_s, result.min_request_gap_s) == (60, 5)


def test_the_config_never_shows_its_secrets(settings_from_env):
    result = resolve_lastfm_config(settings_from_env(valid_env()))

    assert "LastfmConfig" in repr(result)
    assert_no_secret(repr(result), "repr(LastfmConfig)")
    assert_no_secret(str(result), "str(LastfmConfig)")
    assert_no_secret(f"{result}", "format(LastfmConfig)")
    assert_no_secret(repr([result]), "repr of a list holding the config")


def test_serialising_the_config_shows_no_secret(settings_from_env):
    import dataclasses

    from fastapi.encoders import jsonable_encoder

    result = resolve_lastfm_config(settings_from_env(valid_env()))

    assert_no_secret(str(dataclasses.asdict(result)), "dataclasses.asdict(config)")
    assert_no_secret(str(vars(result)), "vars(config)")
    assert_no_secret(str(jsonable_encoder(result)), "jsonable_encoder(config)")


# ── Settings itself never fails and never shows a secret ────────────────────


def test_garbage_in_every_lastfm_setting_still_builds_settings(settings_from_env):
    env = {name: "garbage \x7f value" for name in LASTFM_ENV}
    settings = settings_from_env(env)
    assert settings is not None


def test_a_settings_dump_shows_no_secret(settings_from_env):
    settings = settings_from_env(valid_env())

    assert_no_secret(repr(settings), "repr(Settings)")
    assert_no_secret(str(settings), "str(Settings)")
    assert_no_secret(settings.model_dump_json(), "Settings.model_dump_json()")
    assert_no_secret(str(settings.model_dump()), "Settings.model_dump()")


# ── invalid forms: stopped, naming the setting, never the value (step 4) ────


def _assert_invalid(result, setting: str, value: str) -> None:
    assert isinstance(result, LastfmInvalid), type(result).__name__
    assert result.setting == setting
    for text, where in ((result.problem, "problem"), (repr(result), "repr"), (str(result), "str")):
        assert_no_secret(text, where, secrets=[value, *planted.ALL])


def _scannable(value: str) -> str:
    """A short digit string such as "0" may legitimately occur in the stated
    range ("from 0 to 3600"); it is not a secret. Scan for anything else."""
    return "" if value.isascii() and value.isdigit() and len(value) < 5 else value


@pytest.mark.parametrize("value", ["abc", "-1", "3601", "1.5", "60.0", "1_0", "+5", "1e3", "٣", "6 0"])
def test_a_bad_settle_delay_names_the_setting(settings_from_env, value):
    result = resolve_lastfm_config(settings_from_env(valid_env(LASTFM_SETTLE_DELAY_S=value)))
    _assert_invalid(result, "LASTFM_SETTLE_DELAY_S", _scannable(value))


@pytest.mark.parametrize("value", ["abc", "0", "31", "-5", "5.0", "٥", "999999999999999999999999"])
def test_a_bad_request_gap_names_the_setting(settings_from_env, value):
    result = resolve_lastfm_config(settings_from_env(valid_env(LASTFM_MIN_REQUEST_GAP_S=value)))
    _assert_invalid(result, "LASTFM_MIN_REQUEST_GAP_S", _scannable(value))


@pytest.mark.parametrize(
    "value",
    [planted.API_KEY[:-1], planted.API_KEY + "x", " " + planted.API_KEY, planted.API_KEY[:-1] + "é" * 2],
)
def test_an_api_key_of_the_wrong_length_names_the_setting(settings_from_env, value):
    result = resolve_lastfm_config(settings_from_env(valid_env(LASTFM_API_KEY=value)))
    _assert_invalid(result, "LASTFM_API_KEY", value)


@pytest.mark.parametrize(
    ("missing", "setting"),
    [
        ("LASTFM_API_KEY", "LASTFM_API_KEY"),
        ("LASTFM_API_SECRET", "LASTFM_API_SECRET"),
        ("LASTFM_CREDENTIAL_KEY", "LASTFM_CREDENTIAL_KEY"),
    ],
)
def test_a_missing_secret_names_the_setting(settings_from_env, missing, setting):
    env = valid_env()
    del env[missing]
    _assert_invalid(resolve_lastfm_config(settings_from_env(env)), setting, "")


@pytest.mark.parametrize("name", ["LASTFM_API_KEY", "LASTFM_API_SECRET", "LASTFM_CREDENTIAL_KEY"])
def test_an_empty_secret_counts_as_missing(settings_from_env, name):
    _assert_invalid(resolve_lastfm_config(settings_from_env(valid_env(**{name: ""}))), name, "")


@pytest.mark.parametrize(
    "value",
    [
        "planted-not-a-fernet-key",
        planted.CREDENTIAL_KEY[:-2],
        planted.CREDENTIAL_KEY.rstrip("=") + "!!",
        "QUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUE=" + "QUFB",  # 35 bytes
    ],
)
def test_a_bad_fernet_key_names_the_setting(settings_from_env, value):
    result = resolve_lastfm_config(settings_from_env(valid_env(LASTFM_CREDENTIAL_KEY=value)))
    _assert_invalid(result, "LASTFM_CREDENTIAL_KEY", value)


# ── the _FILE variants ──────────────────────────────────────────────────────


_SECRETS = {
    "LASTFM_API_KEY": planted.API_KEY,
    "LASTFM_API_SECRET": planted.API_SECRET,
    "LASTFM_CREDENTIAL_KEY": planted.CREDENTIAL_KEY,
}


def _secret_file(tmp_path, name: str, data: bytes, mode=0o600):
    path = tmp_path / f"{name.lower()}.secret"
    path.write_bytes(data)
    path.chmod(mode)
    return path


def test_every_secret_can_come_from_its_file(settings_from_env, tmp_path, caplog):
    env = {"LASTFM_ENABLED": "true"}
    for name, value in _SECRETS.items():
        env[f"{name}_FILE"] = str(_secret_file(tmp_path, name, (value + "\n").encode()))
    caplog.set_level("DEBUG")

    result = resolve_lastfm_config(settings_from_env(env))

    assert isinstance(result, LastfmConfig), type(result).__name__
    assert_secret_equal(result.api_key.get_secret_value(), planted.API_KEY, "api_key")
    assert_secret_equal(result.api_secret.get_secret_value(), planted.API_SECRET, "api_secret")
    assert_secret_equal(result.credential_key.get_secret_value(), planted.CREDENTIAL_KEY, "credential_key")
    assert [r for r in caplog.records if r.levelname == "WARNING"] == []
    assert_no_secret(caplog.text, "captured logs")


@pytest.mark.parametrize("name", list(_SECRETS))
def test_a_group_readable_secret_file_warns_and_still_works(settings_from_env, tmp_path, caplog, name):
    path = _secret_file(tmp_path, name, _SECRETS[name].encode(), mode=0o644)
    env = valid_env(**{f"{name}_FILE": str(path)})
    del env[name]
    caplog.set_level("DEBUG")

    result = resolve_lastfm_config(settings_from_env(env))

    assert isinstance(result, LastfmConfig), type(result).__name__
    warnings = [r.getMessage() for r in caplog.records if r.levelname == "WARNING"]
    assert warnings == [
        f"{path} is readable by group or others and holds a Last.fm secret; run: chmod 600 {path}"
    ]
    assert_no_secret(caplog.text, "captured logs")


@pytest.mark.parametrize("name", list(_SECRETS))
def test_both_forms_of_one_secret_name_the_file_setting(settings_from_env, tmp_path, name):
    path = _secret_file(tmp_path, name, _SECRETS[name].encode())
    result = resolve_lastfm_config(settings_from_env(valid_env(**{f"{name}_FILE": str(path)})))
    _assert_invalid(result, f"{name}_FILE", str(path))
    assert name in result.problem


@pytest.mark.parametrize("name", list(_SECRETS))
def test_an_unreadable_secret_file_names_the_file_setting(settings_from_env, tmp_path, name):
    env = valid_env(**{f"{name}_FILE": str(tmp_path / "absent")})
    del env[name]
    _assert_invalid(resolve_lastfm_config(settings_from_env(env)), f"{name}_FILE", "")


@pytest.mark.parametrize("name", list(_SECRETS))
def test_a_non_utf8_secret_file_names_the_file_setting(settings_from_env, tmp_path, name):
    path = _secret_file(tmp_path, name, _SECRETS[name].encode() + b"\xff")
    env = valid_env(**{f"{name}_FILE": str(path)})
    del env[name]
    _assert_invalid(resolve_lastfm_config(settings_from_env(env)), f"{name}_FILE", "")


@pytest.mark.parametrize(
    ("name", "bad"),
    [("LASTFM_API_KEY", planted.API_KEY + "Z"), ("LASTFM_API_SECRET", ""), ("LASTFM_CREDENTIAL_KEY", "planted-bad-fernet")],
)
def test_a_bad_value_in_a_file_names_the_file_setting(settings_from_env, tmp_path, name, bad):
    env = valid_env(**{f"{name}_FILE": str(_secret_file(tmp_path, name, bad.encode()))})
    del env[name]
    _assert_invalid(resolve_lastfm_config(settings_from_env(env)), f"{name}_FILE", bad)


def test_an_empty_file_setting_counts_as_unset(settings_from_env):
    env = valid_env(LASTFM_API_KEY_FILE="", LASTFM_API_SECRET_FILE="  ")
    assert isinstance(resolve_lastfm_config(settings_from_env(env)), LastfmConfig)


def test_a_relative_secret_file_resolves_against_the_working_directory(settings_from_env, tmp_path):
    _secret_file(tmp_path, "rel", planted.API_SECRET.encode())
    env = valid_env(LASTFM_API_SECRET_FILE="rel.secret")
    del env["LASTFM_API_SECRET"]
    result = resolve_lastfm_config(settings_from_env(env))
    assert isinstance(result, LastfmConfig), type(result).__name__
    assert_secret_equal(result.api_secret.get_secret_value(), planted.API_SECRET, "api_secret")


# ── the test seam: loopback only (step 5) ───────────────────────────────────


@pytest.mark.parametrize(
    "url",
    ["http://127.0.0.1:8123/2.0/", "http://127.5.6.7/", "http://[::1]:9000/2.0/", "https://127.0.0.1:4443/"],
)
def test_a_loopback_simulator_url_is_accepted(settings_from_env, url):
    result = resolve_lastfm_config(settings_from_env(valid_env(OSML_INSECURE_LASTFM_API_URL=url)))
    assert isinstance(result, LastfmConfig), type(result).__name__
    assert result.api_url == url
    assert result.insecure_api_url is True


@pytest.mark.parametrize(
    "url",
    [
        "http://10.0.0.1",
        "http://10.0.0.1/2.0/",
        "http://192.168.1.2:8000/",
        "http://0.0.0.0:8000/",
        "http://localhost:8000/",
        "https://ws.audioscrobbler.com/2.0/",
        "http://127.0.0.1.example.com/",
        "http://127.1/",
        "http://user:planted-pw@127.0.0.1/",
        "http://127.0.0.1/?x=1",
        "http://127.0.0.1/#frag",
        "ftp://127.0.0.1/",
        "127.0.0.1:8000",
        "http://[::1",
        "http://127.0.0.1:99999/",
    ],
)
def test_a_non_loopback_simulator_url_is_refused(settings_from_env, url):
    result = resolve_lastfm_config(settings_from_env(valid_env(OSML_INSECURE_LASTFM_API_URL=url)))
    assert isinstance(result, LastfmInvalid), type(result).__name__
    assert result.setting == "OSML_INSECURE_LASTFM_API_URL"
    assert_no_secret(result.problem + repr(result), "the refusal", secrets=[url, "planted-pw"])


def test_an_empty_simulator_url_is_unset(settings_from_env):
    result = resolve_lastfm_config(settings_from_env(valid_env(OSML_INSECURE_LASTFM_API_URL="")))
    assert result.api_url == DEFAULT_API_URL
    assert result.insecure_api_url is False


@pytest.mark.parametrize("name", ["LASTFM_SETTLE_DELAY_S", "LASTFM_MIN_REQUEST_GAP_S"])
def test_a_number_too_long_for_int_is_invalid_not_a_crash(settings_from_env, name):
    # Python refuses int() of a string over 4300 digits with a ValueError.
    result = resolve_lastfm_config(settings_from_env(valid_env(**{name: "9" * 5000})))
    assert isinstance(result, LastfmInvalid), type(result).__name__
    assert result.setting == name


def test_a_secret_file_path_with_a_nul_byte_is_invalid_not_a_crash(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    for name in LASTFM_ENV:
        monkeypatch.delenv(name, raising=False)
    env = valid_env()
    del env["LASTFM_API_SECRET"]
    values = {k.lower(): v for k, v in env.items()}
    settings = Settings(_env_file=None, lastfm_api_secret_file="planted\0path", **values)
    result = resolve_lastfm_config(settings)
    assert isinstance(result, LastfmInvalid), type(result).__name__
    assert result.setting == "LASTFM_API_SECRET_FILE"


# ── review r1 fixes ─────────────────────────────────────────────────────────


@pytest.mark.parametrize("name", list(_SECRETS))
def test_a_blank_plain_secret_counts_as_not_set(settings_from_env, name):
    result = resolve_lastfm_config(settings_from_env(valid_env(**{name: "   "})))
    _assert_invalid(result, name, "")
    assert result.problem == "is not set"


@pytest.mark.parametrize("name", list(_SECRETS))
def test_a_blank_plain_secret_beside_its_file_is_unset(settings_from_env, tmp_path, name):
    path = _secret_file(tmp_path, name, _SECRETS[name].encode())
    result = resolve_lastfm_config(settings_from_env(valid_env(**{name: " ", f"{name}_FILE": str(path)})))
    assert isinstance(result, LastfmConfig), type(result).__name__


def test_an_unreadable_file_keeps_the_os_reason(settings_from_env, tmp_path):
    env = valid_env(LASTFM_API_SECRET_FILE=str(tmp_path / "absent"))
    del env["LASTFM_API_SECRET"]
    result = resolve_lastfm_config(settings_from_env(env))
    _assert_invalid(result, "LASTFM_API_SECRET_FILE", "")
    assert "No such file" in result.problem


def test_a_non_utf8_file_says_so(settings_from_env, tmp_path):
    path = _secret_file(tmp_path, "LASTFM_API_SECRET", planted.API_SECRET.encode() + b"\xff")
    env = valid_env(LASTFM_API_SECRET_FILE=str(path))
    del env["LASTFM_API_SECRET"]
    result = resolve_lastfm_config(settings_from_env(env))
    _assert_invalid(result, "LASTFM_API_SECRET_FILE", "")
    assert "UTF-8" in result.problem


@pytest.mark.parametrize(
    "url",
    ["http://127.0.0.1/\n@evil.example", "http://127.0.0.1/\x7f", "http://127.0.0.1/a b", "http://127.0.0.1/\tx"],
)
def test_a_simulator_url_with_control_characters_or_spaces_is_refused(settings_from_env, url):
    result = resolve_lastfm_config(settings_from_env(valid_env(OSML_INSECURE_LASTFM_API_URL=url)))
    assert isinstance(result, LastfmInvalid), type(result).__name__
    assert result.setting == "OSML_INSECURE_LASTFM_API_URL"


# 9D.2a S7 (9D.1d review S3): an environment value is decoded with surrogate
# escapes, so a byte that is not UTF-8 arrives as a lone surrogate; it could
# never be sent (the request raises naming the byte), so the setting is invalid.
@pytest.mark.parametrize(
    ("name", "value"),
    [
        ("LASTFM_API_KEY", planted.API_KEY[:-1] + "\udcff"),
        ("LASTFM_API_SECRET", planted.API_SECRET + "\udcfe"),
        ("LASTFM_API_SECRET", "\udc80"),
    ],
    ids=["key", "secret", "secret-only-the-byte"],  # never print the values
)
def test_a_key_or_secret_that_is_not_utf8_names_the_setting(settings_from_env, name, value):
    result = resolve_lastfm_config(settings_from_env(valid_env(**{name: value})))
    _assert_invalid(result, name, value)
    assert "UTF-8" in result.problem


# ── signoff-9-lastfm-app-name (DEV-9-06; spec §7.5): LASTFM_APP_NAME ────────
# The name the operator registered on last.fm, for the consent screen. Optional
# and not a secret: trimmed; blank or unset means "not provided" (None); more
# than 100 characters or a control, format, surrogate or line/paragraph
# separator character is invalid. User decision 2026-11-14 (DEV-s9an-01): an
# invalid name is ignored (None, flagged for a startup warning), it never
# makes the configuration invalid.


def test_an_unset_app_name_is_not_provided(settings_from_env):
    result = resolve_lastfm_config(settings_from_env(valid_env()))
    assert isinstance(result, LastfmConfig)
    assert result.app_name is None


@pytest.mark.parametrize("value", ["", " ", "   \t  "])
def test_a_blank_app_name_is_not_provided(settings_from_env, value):
    result = resolve_lastfm_config(settings_from_env(valid_env(LASTFM_APP_NAME=value)))
    assert isinstance(result, LastfmConfig)
    assert result.app_name is None


@pytest.mark.parametrize(
    ("value", "expected"),
    [
        ("OSML at Home", "OSML at Home"),
        ("  OSML at Home \t", "OSML at Home"),
        ("Musik für alle – 音楽", "Musik für alle – 音楽"),
        ("a" * 100, "a" * 100),
        ("é" * 100, "é" * 100),
        (" " + "b" * 100 + " ", "b" * 100),
        ("🎵" * 100, "🎵" * 100),
    ],
    ids=["plain", "trimmed", "unicode", "100-ascii", "100-non-ascii", "100-after-trim", "100-astral"],
)
def test_an_app_name_is_kept_trimmed(settings_from_env, value, expected):
    result = resolve_lastfm_config(settings_from_env(valid_env(LASTFM_APP_NAME=value)))
    assert isinstance(result, LastfmConfig)
    assert result.app_name == expected


@pytest.mark.parametrize(
    "value",
    [
        "a" * 101,
        "é" * 101,
        "🎵" * 101,
        "OSML\nHome",
        "OSML\x01",
        "OSML\x7f",
        "OSML​Home",  # zero-width space (format)
        "OSML‮emoH",  # right-to-left override (format)
        "OSML Home",  # line separator
        "OSML Home",  # paragraph separator
        "OSML\udcff",  # a byte that is not UTF-8 (lone surrogate)
    ],
    ids=["101-ascii", "101-non-ascii", "101-astral", "newline", "c0", "del", "zwsp", "rlo", "ls", "ps", "surrogate"],
)
def test_a_bad_app_name_is_ignored_not_invalid(settings_from_env, value):
    result = resolve_lastfm_config(settings_from_env(valid_env(LASTFM_APP_NAME=value)))
    assert isinstance(result, LastfmConfig), type(result).__name__
    assert result.app_name is None
    assert result.app_name_ignored is True
    assert_no_secret(repr(result), "repr", secrets=[value, *planted.ALL])


@pytest.mark.parametrize("value", [None, "", "OSML at Home", "a" * 100])
def test_a_good_or_missing_app_name_is_not_flagged(settings_from_env, value):
    env = valid_env() if value is None else valid_env(LASTFM_APP_NAME=value)
    result = resolve_lastfm_config(settings_from_env(env))
    assert isinstance(result, LastfmConfig)
    assert result.app_name_ignored is False


def test_a_bad_app_name_does_not_hide_another_bad_setting(settings_from_env):
    env = valid_env(LASTFM_APP_NAME="x" * 101, LASTFM_MIN_REQUEST_GAP_S="0")
    _assert_invalid(resolve_lastfm_config(settings_from_env(env)), "LASTFM_MIN_REQUEST_GAP_S", "")


def test_off_ignores_a_bad_app_name(settings_from_env):
    env = {"LASTFM_ENABLED": "false", "LASTFM_APP_NAME": "x" * 500}
    assert resolve_lastfm_config(settings_from_env(env)) == LastfmOff(switch_unparseable=False)


def test_the_app_name_is_not_hidden_like_a_secret(settings_from_env):
    # Not a secret (DEV-9-06): a plain string, shown in the config's repr.
    result = resolve_lastfm_config(settings_from_env(valid_env(LASTFM_APP_NAME="OSML at Home")))
    assert isinstance(result, LastfmConfig)
    assert type(result.app_name) is str
    assert "OSML at Home" in repr(result)
