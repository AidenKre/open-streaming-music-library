"""9D.1a exit proof (spec §7.2, 9-U08): a wrong or missing Last.fm setting never
stops the server or a CLI command from starting. Every invalid form leaves the
feature ``off`` (a non-boolean switch) or ``stopped``, the ERROR names the
setting, and no captured log or output holds a secret value.

Everything is in-process: the server through the real lifespan (``TestClient``
on a reloaded ``app.main``), the CLI through ``app.cli.main`` building its own
``Settings`` from the environment."""

import io
import logging

import pytest

from app.services.lastfm_state import LastfmService
from tests import lastfm_secrets as planted
from tests.cli_fixtures import add_user, cli_settings, open_server_database
from tests.lastfm_secrets import LASTFM_ENV, assert_no_secret, valid_env

BAD_SWITCH = "planted-maybe"
BAD_KEY = planted.API_KEY + "Z"
BAD_FERNET = "planted-bad-fernet-key"


def _forms(tmp_path):
    """Each invalid form: (id, env, expected service, the setting named, extra planted values)."""
    secret_file = tmp_path / "secret.txt"
    secret_file.write_text(planted.API_SECRET)
    secret_file.chmod(0o600)
    no_secret = valid_env()
    del no_secret["LASTFM_API_SECRET"]
    return {
        "non-bool switch": (valid_env(LASTFM_ENABLED=BAD_SWITCH), LastfmService.OFF, "LASTFM_ENABLED", [BAD_SWITCH]),
        "non-numeric delay": (valid_env(LASTFM_SETTLE_DELAY_S="planted12x"), LastfmService.STOPPED, "LASTFM_SETTLE_DELAY_S", ["planted12x"]),
        "out-of-range delay": (valid_env(LASTFM_SETTLE_DELAY_S="3601"), LastfmService.STOPPED, "LASTFM_SETTLE_DELAY_S", ["3601"]),
        "non-numeric gap": (valid_env(LASTFM_MIN_REQUEST_GAP_S="planted5s"), LastfmService.STOPPED, "LASTFM_MIN_REQUEST_GAP_S", ["planted5s"]),
        "out-of-range gap": (valid_env(LASTFM_MIN_REQUEST_GAP_S="0"), LastfmService.STOPPED, "LASTFM_MIN_REQUEST_GAP_S", []),
        "wrong-length key": (valid_env(LASTFM_API_KEY=BAD_KEY), LastfmService.STOPPED, "LASTFM_API_KEY", [BAD_KEY]),
        "bad Fernet key": (valid_env(LASTFM_CREDENTIAL_KEY=BAD_FERNET), LastfmService.STOPPED, "LASTFM_CREDENTIAL_KEY", [BAD_FERNET]),
        "unreadable file": ({**no_secret, "LASTFM_API_SECRET_FILE": str(tmp_path / "absent")}, LastfmService.STOPPED, "LASTFM_API_SECRET_FILE", []),
        "both forms": (valid_env(LASTFM_API_SECRET_FILE=str(secret_file)), LastfmService.STOPPED, "LASTFM_API_SECRET_FILE", []),
        "non-loopback seam": (valid_env(OSML_INSECURE_LASTFM_API_URL="http://10.0.0.1"), LastfmService.STOPPED, "OSML_INSECURE_LASTFM_API_URL", ["10.0.0.1"]),
    }


FORM_IDS = [
    "non-bool switch",
    "non-numeric delay",
    "out-of-range delay",
    "non-numeric gap",
    "out-of-range gap",
    "wrong-length key",
    "bad Fernet key",
    "unreadable file",
    "both forms",
    "non-loopback seam",
]


@pytest.fixture(autouse=True)
def _clean_lastfm_env(monkeypatch):
    for name in LASTFM_ENV:
        monkeypatch.delenv(name, raising=False)


def _scan(caplog, capsys, extra):
    out = capsys.readouterr()
    for text, where in ((caplog.text, "captured logs"), (out.out, "stdout"), (out.err, "stderr")):
        assert_no_secret(text, where, secrets=[*extra, *planted.ALL])


# ── the server ──────────────────────────────────────────────────────────────


@pytest.mark.parametrize("form", FORM_IDS)
def test_the_server_starts_under_every_invalid_form(open_app_client, tmp_path, caplog, capsys, form):
    env, service, setting, extra = _forms(tmp_path)[form]
    caplog.set_level(logging.DEBUG)

    with open_app_client(env=env) as client:
        assert client.get("/app/info").status_code == 200
        assert client.get("/auth/me").status_code == 200
        state = client.app.state.lastfm
        assert state.service is service
        assert state.config is None

    errors = [r.getMessage() for r in caplog.records if r.levelno >= logging.ERROR]
    assert any(setting in e for e in errors), "no ERROR line names the setting"
    _scan(caplog, capsys, extra)


def test_the_server_runs_lastfm_with_a_valid_configuration(open_app_client, caplog, capsys):
    caplog.set_level(logging.DEBUG)
    with open_app_client(env=valid_env()) as client:
        assert client.app.state.lastfm.service is LastfmService.RUNNING
    assert [r for r in caplog.records if r.levelno >= logging.ERROR and "LASTFM" in r.getMessage()] == []
    _scan(caplog, capsys, [])


def test_the_server_starts_off_by_default(open_app_client):
    with open_app_client() as client:
        assert client.app.state.lastfm.service is LastfmService.OFF


# ── every CLI command ───────────────────────────────────────────────────────

COMMANDS = {
    "list": (["users", "list"], 0),
    "disable": (["users", "disable", "bob"], 0),
    "enable": (["users", "enable", "bob"], 0),
    "reset-password": (["users", "reset-password", "bob"], 0),
    "delete": (["users", "delete", "bob"], 1),  # confirmation deliberately wrong
    "usage error": (["users", "frobnicate"], 2),
}


@pytest.mark.parametrize("command", list(COMMANDS))
@pytest.mark.parametrize("form", FORM_IDS)
def test_every_cli_command_starts_under_every_invalid_form(
    tmp_path, monkeypatch, caplog, capsys, form, command
):
    from app.cli import main

    monkeypatch.chdir(tmp_path)
    settings = cli_settings(tmp_path)
    db = open_server_database(settings)
    add_user(db, "bob")
    for name, value in {
        "APP_DATA_DIR": settings.app_data_dir,
        "MUSIC_LIBRARY_DIR": settings.music_library_dir,
        "IMPORT_DIR": settings.import_dir,
        "USER_IMPORT_DIR": settings.user_import_dir,
        "OSML_INSECURE_FAST_PASSWORD_HASHING": "true",
    }.items():
        monkeypatch.setenv(name, str(value))
    env, _service, _setting, extra = _forms(tmp_path)[form]
    for name, value in env.items():
        monkeypatch.setenv(name, value)
    argv, expected = COMMANDS[command]
    caplog.set_level(logging.DEBUG)
    out, err = io.StringIO(), io.StringIO()

    code = main(
        argv,  # settings=None: the CLI builds Settings() from this environment
        out=out,
        err=err,
        prompt=lambda _text: "planted-new-password-1",
        confirm=lambda _text: "not bob",
    )

    assert code == expected, err.getvalue()
    if command == "list":
        assert "bob" in out.getvalue()
    for text, where in ((out.getvalue(), "CLI stdout"), (err.getvalue(), "CLI stderr")):
        assert_no_secret(text, where, secrets=[*extra, *planted.ALL])
    _scan(caplog, capsys, extra)
