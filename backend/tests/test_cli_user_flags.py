"""Phase M.2b (spec §6.4, M-U17): ``users disable|enable|reset-password``.

These commands run while the server runs: short WAL transactions, no flock.
``reset-password`` and ``disable`` refuse the master admin (``.env`` owns it).
"""

import logging

import pytest

from app.auth.passwords import verify_password
from app.auth.sessions import hash_token
from app.core.instance_lock import acquire_instance_lock
from tests.auth_helpers import create_session
from tests.cli_fixtures import ADMIN, add_user, cli_settings, open_server_database, run_cli, sql

NEW_PASSWORD = "a-good-new-password"


@pytest.fixture
def settings(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    return cli_settings(tmp_path)


@pytest.fixture
def db(settings):
    database = open_server_database(settings)
    add_user(database, ADMIN, master=True)
    return database


def _user(db, name):
    rows = sql(
        db,
        "SELECT id, password_hash, disabled_at, deleting_at FROM users WHERE username = ?",
        (name,),
    )
    return rows[0]


def _live_sessions(db, uid):
    return sql(
        db, "SELECT count(*) FROM auth_sessions WHERE user_id = ? AND revoked_at IS NULL", (uid,)
    )[0][0]


def _prompts(*answers):
    asked = []
    queue = list(answers)

    def prompt(text):
        asked.append(text)
        return queue.pop(0)

    prompt.asked = asked
    return prompt


# --- disable / enable --------------------------------------------------------------


def test_disable_sets_disabled_at_and_revokes_the_users_sessions(db, settings, tmp_path):
    sam = add_user(db, "Sam")
    alex = add_user(db, "Alex")
    create_session(db, sam)
    create_session(db, sam)
    create_session(db, alex)

    result = run_cli(settings, tmp_path, "users", "disable", "Sam")

    assert result.code == 0, result.err
    assert _user(db, "Sam")[2] is not None
    assert _live_sessions(db, sam) == 0
    assert _live_sessions(db, alex) == 1
    assert _user(db, "Alex")[2] is None


def test_enable_clears_disabled_at(db, settings, tmp_path):
    sam = add_user(db, "Sam")
    assert run_cli(settings, tmp_path, "users", "disable", "Sam").code == 0

    result = run_cli(settings, tmp_path, "users", "enable", "Sam")

    assert result.code == 0, result.err
    assert _user(db, "Sam")[2] is None
    assert _live_sessions(db, sam) == 0  # revoked sessions stay revoked


def test_a_user_is_found_case_insensitively(db, settings, tmp_path):
    add_user(db, "Sam")

    assert run_cli(settings, tmp_path, "users", "disable", "sAM").code == 0
    assert _user(db, "Sam")[2] is not None


@pytest.mark.parametrize("command", ["disable", "enable", "reset-password", "delete"])
def test_an_unknown_user_is_refused(db, settings, tmp_path, command):
    prompt = _prompts(NEW_PASSWORD, NEW_PASSWORD)

    result = run_cli(
        settings, tmp_path, "users", command, "nobody", prompt=prompt, confirm=lambda _: "nobody"
    )

    assert result.code == 1
    assert "No user named 'nobody'" in result.err
    assert prompt.asked == []


@pytest.mark.parametrize("command", ["disable", "enable", "reset-password", "delete"])
def test_the_master_admin_is_refused(db, settings, tmp_path, command):
    admin = _user(db, ADMIN)
    create_session(db, admin[0])
    prompt = _prompts(NEW_PASSWORD, NEW_PASSWORD)
    confirmed = []

    result = run_cli(
        settings, tmp_path, "users", command, ADMIN,
        prompt=prompt, confirm=lambda text: confirmed.append(text) or ADMIN,
    )

    assert result.code == 1
    assert "master admin" in result.err
    assert _user(db, ADMIN) == admin
    assert _live_sessions(db, admin[0]) == 1
    assert prompt.asked == [] and confirmed == []


@pytest.mark.parametrize("command", ["disable", "enable", "reset-password"])
def test_a_user_being_deleted_is_refused(db, settings, tmp_path, command):
    sam = add_user(db, "Sam")
    sql(db, "UPDATE users SET deleting_at = 1 WHERE id = ?", (sam,))
    before = _user(db, "Sam")
    prompt = _prompts(NEW_PASSWORD, NEW_PASSWORD)

    result = run_cli(settings, tmp_path, "users", command, "Sam", prompt=prompt)

    assert result.code == 1
    assert "being deleted" in result.err
    assert _user(db, "Sam") == before


@pytest.mark.parametrize("command", ["disable", "enable", "reset-password", "list"])
def test_non_delete_commands_run_while_the_server_holds_the_flock(db, settings, tmp_path, command):
    add_user(db, "Sam")
    lock = acquire_instance_lock(settings.app_data_dir)
    try:
        argv = ["users", command] + ([] if command == "list" else ["Sam"])
        result = run_cli(settings, tmp_path, *argv, prompt=_prompts(NEW_PASSWORD, NEW_PASSWORD))
    finally:
        lock.release()

    assert result.code == 0, result.err


# --- reset-password ----------------------------------------------------------------


def test_reset_password_prompts_twice_sets_the_hash_and_revokes_sessions(
    db, settings, tmp_path, caplog
):
    sam = add_user(db, "Sam")
    tokens = create_session(db, sam)
    prompt = _prompts(NEW_PASSWORD, NEW_PASSWORD)
    caplog.set_level(logging.DEBUG)

    result = run_cli(settings, tmp_path, "users", "reset-password", "Sam", prompt=prompt)

    assert result.code == 0, result.err
    assert len(prompt.asked) == 2
    assert verify_password(settings, _user(db, "Sam")[1], NEW_PASSWORD)
    assert _live_sessions(db, sam) == 0
    assert sql(
        db, "SELECT revoked_at IS NOT NULL FROM auth_sessions WHERE token_hash = ?",
        (hash_token(tokens.token),),
    ) == [(1,)]
    for text in (result.out, result.err, caplog.text, *prompt.asked):
        assert NEW_PASSWORD not in text


def test_reset_password_normalizes_like_registration(db, settings, tmp_path):
    add_user(db, "Sam")
    decomposed = "café-password"  # NFD; NFC is "café-password"

    result = run_cli(
        settings, tmp_path, "users", "reset-password", "Sam",
        prompt=_prompts(decomposed, decomposed),
    )

    assert result.code == 0, result.err
    assert verify_password(settings, _user(db, "Sam")[1], "café-password")


@pytest.mark.parametrize(
    "first, second, message",
    [
        (NEW_PASSWORD, NEW_PASSWORD + "x", "do not match"),
        ("short12", "short12", "8-1024"),
        ("x" * 1025, "x" * 1025, "8-1024"),
    ],
    ids=["mismatch", "too-short", "too-long"],
)
def test_reset_password_refuses_bad_input_and_changes_nothing(
    db, settings, tmp_path, first, second, message
):
    sam = add_user(db, "Sam")
    create_session(db, sam)
    before = _user(db, "Sam")

    result = run_cli(
        settings, tmp_path, "users", "reset-password", "Sam", prompt=_prompts(first, second)
    )

    assert result.code == 1
    assert message in result.err
    assert first not in result.err and first not in result.out
    assert _user(db, "Sam") == before
    assert _live_sessions(db, sam) == 1
