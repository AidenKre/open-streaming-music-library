"""The admin tool's quiet exits: a taken instance lock, Ctrl-C at a prompt and
input that ends (a closed standard input, as under cron or a pipe) each give
one line on standard error and exit code 1, with no traceback and nothing
changed.

The lock and closed-input cases run the real tool (``python -m app.cli``) in a
child process, so what reaches its standard error is what an operator sees.
Everything lives under the test's ``tmp_path`` (see ``cli_fixtures``)."""

import subprocess
import sys

import pytest

from app.core.instance_lock import acquire_instance_lock
from tests.cli_fixtures import (  # noqa: F401  (interpreter_noise is a fixture)
    ADMIN,
    add_user,
    child_env,
    cli_settings,
    interpreter_noise,
    open_server_database,
    run_cli,
    sql,
)
from tests.user_delete_world import build_world, dump, exists

GOOD_PASSWORD = "a-good-new-password"
# The commands that ask for a confirmation, with the answer that confirms.
CONFIRMING = [(("users", "delete", "Sam"), "Sam"), (("lastfm", "purge"), "purge")]


@pytest.fixture
def world(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    return build_world(cli_settings(tmp_path))


def _tool(settings, tmp_path, noise, *argv) -> subprocess.CompletedProcess:
    """The tool as an operator runs it, its standard input closed. Every
    folder is passed explicitly; the working directory holds no ``.env``.
    Its standard error is given without ``noise``, what the interpreter
    itself writes while the tool's modules load (``interpreter_noise``), so
    only the tool's own lines are counted."""
    assert not (tmp_path / ".env").exists()
    result = subprocess.run(
        [sys.executable, "-m", "app.cli", *argv],
        cwd=tmp_path, env=child_env(settings), stdin=subprocess.DEVNULL,
        capture_output=True, text=True, timeout=60,
    )
    assert result.stderr.startswith(noise), result.stderr
    result.stderr = result.stderr[len(noise):]
    return result


def _one_line(text: str) -> str:
    assert "Traceback" not in text, text
    lines = text.splitlines()
    assert len(lines) == 1, lines
    return lines[0]


def _unchanged(world, before):
    assert dump(world.db) == before
    assert all(exists(p) for p in world.files.values())


def _in_process(settings, tmp_path, *argv, **answers):
    try:
        return run_cli(settings, tmp_path, *argv, **answers)
    except (KeyboardInterrupt, EOFError) as exc:  # would end the tool with a traceback
        pytest.fail(f"{type(exc).__name__} escaped the tool")


def _raising(exc_type, after=()):
    """A prompt that returns ``after`` answers in turn, then raises."""
    answers = list(after)

    def ask(text):
        if answers:
            return answers.pop(0)
        raise exc_type()

    return ask


# --- a taken lock ---------------------------------------------------------------------


@pytest.mark.integration
@pytest.mark.parametrize("argv", [argv for argv, _ in CONFIRMING], ids=["users-delete", "lastfm-purge"])
def test_a_taken_lock_prints_one_line_and_exits_1(world, tmp_path, interpreter_noise, argv):
    before = dump(world.db)
    lock = acquire_instance_lock(world.settings.app_data_dir)
    try:
        result = _tool(world.settings, tmp_path, interpreter_noise, *argv)
    finally:
        lock.release()

    assert result.returncode == 1
    assert "The server is running" in _one_line(result.stderr)
    assert result.stdout == ""
    _unchanged(world, before)


# --- input that ends at a confirmation ------------------------------------------------


@pytest.mark.integration
@pytest.mark.parametrize("argv", [argv for argv, _ in CONFIRMING], ids=["users-delete", "lastfm-purge"])
def test_a_closed_standard_input_at_the_confirmation_deletes_nothing(
    world, tmp_path, interpreter_noise, argv
):
    before = dump(world.db)

    result = _tool(world.settings, tmp_path, interpreter_noise, *argv)

    assert result.returncode == 1
    assert "nothing was deleted" in _one_line(result.stderr)
    _unchanged(world, before)
    acquire_instance_lock(world.settings.app_data_dir).release()  # the lock was let go


@pytest.mark.parametrize("exc_type", [KeyboardInterrupt, EOFError], ids=["ctrl-c", "end-of-input"])
@pytest.mark.parametrize("argv,_answer", CONFIRMING, ids=["users-delete", "lastfm-purge"])
def test_no_answer_at_the_confirmation_deletes_nothing(world, tmp_path, argv, _answer, exc_type):
    before = dump(world.db)

    result = _in_process(world.settings, tmp_path, *argv, confirm=_raising(exc_type))

    assert result.code == 1
    assert "nothing was deleted" in _one_line(result.err)
    _unchanged(world, before)
    acquire_instance_lock(world.settings.app_data_dir).release()  # the lock was let go


# --- Ctrl-C or end of input at a password prompt --------------------------------------


@pytest.fixture
def sam(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    settings = cli_settings(tmp_path)
    db = open_server_database(settings)
    add_user(db, ADMIN, master=True)
    uid = add_user(db, "Sam")
    return settings, db, uid


@pytest.mark.parametrize("answered", [0, 1], ids=["first-prompt", "repeat-prompt"])
@pytest.mark.parametrize("exc_type", [KeyboardInterrupt, EOFError], ids=["ctrl-c", "end-of-input"])
def test_no_answer_at_a_password_prompt_changes_nothing(sam, tmp_path, exc_type, answered):
    settings, db, uid = sam
    before = sql(db, "SELECT password_hash FROM users WHERE id = ?", (uid,))

    result = _in_process(
        settings, tmp_path, "users", "reset-password", "Sam",
        prompt=_raising(exc_type, after=[GOOD_PASSWORD] * answered),
    )

    assert result.code == 1
    assert "not changed" in _one_line(result.err)
    assert result.out == ""
    assert sql(db, "SELECT password_hash FROM users WHERE id = ?", (uid,)) == before


@pytest.mark.parametrize("argv", [("library", "check"), ("users", "list"), ("users", "delete", "Sam")],
                         ids=["library-check", "users-list", "users-delete"])
def test_ctrl_c_during_the_schema_check_ends_in_one_line(world, tmp_path, monkeypatch, argv):
    # The check can copy the whole database when its -wal has no -shm: it can take a while.
    from app.database.database import Database

    def interrupted(self):
        raise KeyboardInterrupt

    monkeypatch.setattr(Database, "require_current_schema", interrupted)
    before = dump(world.db)

    result = _in_process(world.settings, tmp_path, *argv, confirm=lambda text: "Sam")

    assert result.code == 1
    assert _one_line(result.err) == "Stopped before anything was done."
    _unchanged(world, before)
