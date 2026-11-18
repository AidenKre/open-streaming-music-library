"""Phase M.2b (spec §6.4, review M-U17): ``python -m app.cli users ...``.

Every test runs the CLI in-process against a temporary data dir (see
``tests/cli_fixtures.py``). The CLI loads ``Settings`` without the admin
bootstrap and refuses any schema version but the current one.
"""

import os

import pytest

from app.database.database import Database, SchemaVersionRefused
from tests.cli_fixtures import (
    ADMIN,
    add_track,
    add_user,
    cli_settings,
    database_file,
    open_server_database,
    run_cli,
    sql,
)
from tests.schema_fixtures import REFUSED_VERSIONS, make_database_at

PAST_NS = 1_000_000_000_000_000_000


@pytest.fixture
def settings(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)  # no .env can be picked up
    return cli_settings(tmp_path)


@pytest.fixture
def db(settings):
    database = open_server_database(settings)
    add_user(database, ADMIN, master=True)
    return database


def _rows(out: str) -> dict[str, dict[str, str]]:
    lines = [line for line in out.splitlines() if line.strip()]
    header = lines[0].split("\t")
    assert header == [
        "id", "username", "role", "folder", "created", "disabled", "deleting", "tracks",
    ]
    rows = [dict(zip(header, line.split("\t"))) for line in lines[1:]]
    return {row["username"]: row for row in rows}


def _snapshot(path):
    os.utime(path, ns=(PAST_NS, PAST_NS))
    return path.read_bytes(), path.stat().st_mtime_ns


# --- users list ---------------------------------------------------------------


def test_list_shows_every_user_with_flags_folder_dates_and_track_count(db, settings, tmp_path):
    sam = add_user(db, "Sam", created_at=1_700_000_000)
    alex = add_user(db, "Alex")
    add_track(db, settings, sam, title="Lucky", track_number=1)
    add_track(db, settings, sam, title="Airbag", track_number=2)
    sql(db, "UPDATE users SET disabled_at = 1700000060 WHERE id = ?", (alex,))

    result = run_cli(settings, tmp_path, "users", "list")

    assert result.code == 0, result.err
    rows = _rows(result.out)
    assert set(rows) == {ADMIN, "Sam", "Alex"}
    assert rows[ADMIN]["role"] == "master-admin"
    assert rows["Sam"] == {
        "id": str(sam), "username": "Sam", "role": "user", "folder": "Sam",
        "created": "2023-11-14T22:13:20Z", "disabled": "-", "deleting": "-", "tracks": "2",
    }
    assert rows["Alex"]["disabled"] == "2023-11-14T22:14:20Z"
    assert rows["Alex"]["tracks"] == "0"


def test_list_shows_a_user_being_deleted(db, settings, tmp_path):
    sam = add_user(db, "Sam")
    sql(db, "UPDATE users SET deleting_at = 1700000000 WHERE id = ?", (sam,))

    rows = _rows(run_cli(settings, tmp_path, "users", "list").out)

    assert rows["Sam"]["deleting"] == "2023-11-14T22:13:20Z"


def test_list_never_bootstraps_or_renames_the_admin(tmp_path, monkeypatch):
    """Admin env vars present and different: the CLI must not act on them."""
    monkeypatch.chdir(tmp_path)
    settings = cli_settings(
        tmp_path, osml_admin_username="someone-else", osml_admin_password="a-different-password"
    )
    db = open_server_database(settings)
    add_user(db, ADMIN, master=True)
    before = sql(db, "SELECT id, username, password_hash FROM users")

    result = run_cli(settings, tmp_path, "users", "list")

    assert result.code == 0, result.err
    assert sql(db, "SELECT id, username, password_hash FROM users") == before


def test_cli_loads_settings_from_the_environment_without_admin_vars(tmp_path, monkeypatch):
    """No ``settings`` passed: ``main`` builds ``Settings()`` itself, and works
    with none of the master-admin variables set."""
    monkeypatch.chdir(tmp_path)
    for name in ("OSML_ADMIN_USERNAME", "OSML_ADMIN_PASSWORD", "OSML_ADMIN_PASSWORD_FILE"):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setenv("APP_DATA_DIR", str(tmp_path / "data"))
    monkeypatch.setenv("MUSIC_LIBRARY_DIR", str(tmp_path / "music"))
    monkeypatch.setenv("IMPORT_DIR", str(tmp_path / "import"))
    monkeypatch.setenv("USER_IMPORT_DIR", str(tmp_path / "import-users"))
    db = open_server_database(cli_settings(tmp_path))
    add_user(db, ADMIN, master=True)
    add_user(db, "Sam")

    import io

    from app.cli import main

    out, err = io.StringIO(), io.StringIO()
    code = main(["users", "list"], out=out, err=err)

    assert code == 0, err.getvalue()
    assert set(_rows(out.getvalue())) == {ADMIN, "Sam"}


# --- schema refusal (every command) ---------------------------------------------

COMMANDS = [
    ("users", "list"),
    ("users", "disable", "Sam"),
    ("users", "enable", "Sam"),
    ("users", "reset-password", "Sam"),
    ("users", "delete", "Sam"),
    # 9D.1b: the operator purge checks the schema first, like delete.
    ("lastfm", "purge"),
]


@pytest.mark.parametrize("argv", COMMANDS)
def test_every_command_refuses_a_missing_database_and_creates_nothing(settings, tmp_path, argv):
    result = run_cli(settings, tmp_path, *argv, prompt=lambda _: "x" * 12, confirm=lambda _: "Sam")

    assert result.code == 1
    assert "No database" in result.err
    assert not database_file(settings).exists()


@pytest.mark.parametrize("argv", COMMANDS)
@pytest.mark.parametrize("version", REFUSED_VERSIONS)
def test_every_command_refuses_another_schema_version_untouched(settings, tmp_path, argv, version):
    path = database_file(settings)
    make_database_at(path, version)
    before = _snapshot(path)
    listing = sorted(os.listdir(path.parent))

    result = run_cli(settings, tmp_path, *argv, prompt=lambda _: "x" * 12, confirm=lambda _: "Sam")

    assert result.code == 1
    # The command prints the refusal itself and nothing else (its words are
    # pinned in test_schema_refusal.py).
    assert result.err.strip() == str(SchemaVersionRefused(
        version, Database.LATEST_SCHEMA_VERSION, Database.MINIMUM_SCHEMA_VERSION
    ))
    assert _snapshot_now(path) == before
    assert sorted(os.listdir(path.parent)) == listing


def _snapshot_now(path):
    return path.read_bytes(), path.stat().st_mtime_ns


@pytest.mark.parametrize("argv", COMMANDS)
def test_every_command_refuses_a_non_sqlite_file(settings, tmp_path, argv):
    path = database_file(settings)
    path.parent.mkdir(parents=True)
    path.write_bytes(b"not a database" * 500)
    before = _snapshot(path)

    result = run_cli(settings, tmp_path, *argv, prompt=lambda _: "x" * 12, confirm=lambda _: "Sam")

    assert result.code == 1
    assert "not a SQLite database" in result.err
    assert _snapshot_now(path) == before


def test_an_unknown_command_is_a_usage_error(db, settings, tmp_path):
    result = run_cli(settings, tmp_path, "users", "promote", "Sam")

    assert result.code == 2
