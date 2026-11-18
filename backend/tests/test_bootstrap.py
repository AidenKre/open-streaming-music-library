"""Phase M.0a (M-U09 bootstrap half, spec §4.4): the master admin comes from
``.env``.

Startup runs ``bootstrap_master_admin`` right after ``Database.initialize()``.
Missing admin variables or a password shorter than 8 characters are fatal.
The first boot creates the master admin with an argon2id hash; later boots
find it by ``is_master_admin``. The password never appears in a log line, an
exception or a ``repr``.
"""

import logging
import sqlite3

import pytest
from argon2 import Type, extract_parameters
from fastapi.testclient import TestClient

from app.auth.passwords import password_hasher, verify_password
from app.bootstrap import BootstrapError, bootstrap_master_admin
from app.config import Settings
from app.database.database import Database, DatabaseContext
from tests.schema_fixtures import INIT_SQL

PASSWORD = "correct horse battery"


@pytest.fixture(autouse=True)
def _tmp_dirs(tmp_path, monkeypatch):
    # Folder choice lists the music and user-import dirs; keep them in tmp.
    monkeypatch.setenv("MUSIC_LIBRARY_DIR", str(tmp_path / "music"))
    monkeypatch.setenv("USER_IMPORT_DIR", str(tmp_path / "import-users"))


@pytest.fixture(autouse=True)
def _no_admin_env(monkeypatch):
    for var in (
        "OSML_ADMIN_USERNAME",
        "OSML_ADMIN_PASSWORD",
        "OSML_ADMIN_PASSWORD_FILE",
        "OSML_INSECURE_FAST_PASSWORD_HASHING",
    ):
        monkeypatch.delenv(var, raising=False)


def _settings(**overrides) -> Settings:
    values = dict(
        osml_admin_username="Admin",

        osml_admin_password=PASSWORD,
        osml_insecure_fast_password_hashing=True,
    )
    values.update(overrides)
    return Settings(_env_file=None, **values)


@pytest.fixture
def db(tmp_path):
    # A plain Database: bootstrap must see no users but its own.
    database = Database(DatabaseContext(database_path=tmp_path / "database.db", init_sql_path=INIT_SQL))
    assert database.initialize()
    return database


def _users(db):
    conn = sqlite3.connect(db.context.database_path)
    conn.row_factory = sqlite3.Row
    try:
        return [dict(r) for r in conn.execute("SELECT * FROM users ORDER BY id")]
    finally:
        conn.close()


def _boot(db, settings, tmp_path):
    # An explicit, absent .env keeps these tests away from any real one.
    return bootstrap_master_admin(db, settings, env_file=tmp_path / "absent.env")


# ── first boot ──────────────────────────────────────────────────────────────

def test_first_boot_creates_the_master_admin(db, tmp_path):
    settings = _settings()

    admin_id = _boot(db, settings, tmp_path)

    [row] = _users(db)
    assert row["id"] == admin_id
    assert (row["username"], row["username_key"]) == ("Admin", "admin")
    assert (row["is_admin"], row["is_master_admin"]) == (1, 1)
    assert row["library_folder"] == "admin"
    assert row["disabled_at"] is None and row["deleting_at"] is None
    assert row["password_hash"].startswith("$argon2id$")
    assert PASSWORD not in row["password_hash"]
    assert verify_password(settings, row["password_hash"], PASSWORD)
    assert not verify_password(settings, row["password_hash"], PASSWORD + "x")


def test_the_admins_folder_is_chosen_past_a_stray_music_folder(db, tmp_path):
    (tmp_path / "music" / "ADMIN").mkdir(parents=True)

    _boot(db, _settings(), tmp_path)

    [row] = _users(db)
    assert row["library_folder"] == "admin-2"


def test_a_second_boot_reuses_the_master_admin_unchanged(db, tmp_path):
    settings = _settings()
    first = _boot(db, settings, tmp_path)
    before = _users(db)

    assert _boot(db, settings, tmp_path) == first
    assert _users(db) == before


@pytest.mark.parametrize(
    "overrides, variable",
    [
        ({"osml_admin_username": None}, "OSML_ADMIN_USERNAME"),
        ({"osml_admin_username": ""}, "OSML_ADMIN_USERNAME"),
        ({"osml_admin_password": None}, "OSML_ADMIN_PASSWORD"),
        ({"osml_admin_password": ""}, "OSML_ADMIN_PASSWORD"),
    ],
)
def test_missing_admin_variables_are_fatal(db, tmp_path, overrides, variable):
    with pytest.raises(BootstrapError) as failed:
        _boot(db, _settings(**overrides), tmp_path)
    assert variable in str(failed.value)
    assert _users(db) == []


def test_a_password_shorter_than_8_is_fatal_and_never_echoed(db, tmp_path):
    short = "s3cr3t!"  # 7 characters
    with pytest.raises(BootstrapError) as failed:
        _boot(db, _settings(osml_admin_password=short), tmp_path)

    assert "8" in str(failed.value)
    assert short not in str(failed.value)
    assert short not in repr(failed.value)
    assert _users(db) == []


def test_a_password_shorter_than_8_once_nfc_normalized_is_fatal(db, tmp_path):
    # Eight code points decomposed (e + U+0301, four times), four composed.
    decomposed = "é" * 4
    with pytest.raises(BootstrapError):
        _boot(db, _settings(osml_admin_password=decomposed), tmp_path)
    assert _users(db) == []


def test_a_password_longer_than_1024_is_fatal(db, tmp_path):
    with pytest.raises(BootstrapError):
        _boot(db, _settings(osml_admin_password="p" * 1025), tmp_path)
    assert _users(db) == []


def test_a_password_of_exactly_8_is_accepted(db, tmp_path):
    _boot(db, _settings(osml_admin_password="12345678"), tmp_path)
    assert len(_users(db)) == 1


@pytest.mark.parametrize("username", ["ab", "a b", "-admin", "ädmin", "a" * 33])
def test_an_invalid_admin_username_is_fatal(db, tmp_path, username):
    with pytest.raises(BootstrapError):
        _boot(db, _settings(osml_admin_username=username), tmp_path)
    assert _users(db) == []


def test_the_env_admin_may_use_a_reserved_name(db, tmp_path):
    # Reserved names are refused for signup only (spec §4.4).
    _boot(db, _settings(osml_admin_username="root"), tmp_path)
    assert _users(db)[0]["username_key"] == "root"


def test_the_password_never_reaches_logs_stdout_or_settings_repr(db, tmp_path, caplog, capsys):
    settings = _settings()
    with caplog.at_level(logging.DEBUG):
        _boot(db, settings, tmp_path)
        _boot(db, _settings(osml_admin_password=PASSWORD + "-new"), tmp_path)

    captured = capsys.readouterr()
    for text in (caplog.text, captured.out, captured.err, repr(settings), str(settings)):
        assert PASSWORD not in text


# ── hashing parameters ──────────────────────────────────────────────────────

def test_production_hashing_uses_the_specified_argon2id_parameters():
    hasher = password_hasher(_settings(osml_insecure_fast_password_hashing=False))
    assert hasher.type is Type.ID
    assert (hasher.memory_cost, hasher.time_cost, hasher.parallelism) == (19 * 1024, 2, 1)


def test_the_test_only_setting_makes_hashing_cheap():
    hasher = password_hasher(_settings())
    assert hasher.type is Type.ID
    assert hasher.memory_cost < 19 * 1024 and hasher.time_cost == 1


# ── startup wiring ──────────────────────────────────────────────────────────

def test_startup_bootstraps_the_admin_after_initialize(configure_app):
    main = configure_app()
    with TestClient(main.app) as client:
        admin_id = client.app.state.admin_user_id
        [row] = _users(client.app.state.database)
    assert row["id"] == admin_id
    assert row["is_master_admin"] == 1


def test_startup_without_admin_variables_fails(configure_app):
    main = configure_app(env={"OSML_ADMIN_USERNAME": ""})
    with pytest.raises(BootstrapError):
        with TestClient(main.app):
            pass


# ── password file and permission warning (S8) ───────────────────────────────

def test_the_password_can_come_from_a_file(db, tmp_path):
    secret = tmp_path / "admin-password"
    secret.write_text(PASSWORD + "\n")
    secret.chmod(0o600)
    settings = _settings(osml_admin_password=None, osml_admin_password_file=secret)

    _boot(db, settings, tmp_path)

    [row] = _users(db)
    assert verify_password(settings, row["password_hash"], PASSWORD)


def test_a_password_and_a_password_file_together_are_fatal(db, tmp_path):
    secret = tmp_path / "admin-password"
    secret.write_text(PASSWORD)
    secret.chmod(0o600)
    with pytest.raises(BootstrapError) as failed:
        _boot(db, _settings(osml_admin_password_file=secret), tmp_path)
    assert "OSML_ADMIN_PASSWORD_FILE" in str(failed.value)
    assert _users(db) == []


def test_an_unreadable_password_file_is_fatal(db, tmp_path):
    missing = tmp_path / "nope"
    with pytest.raises(BootstrapError) as failed:
        _boot(db, _settings(osml_admin_password=None, osml_admin_password_file=missing), tmp_path)
    assert str(missing) in str(failed.value)


def test_a_short_password_file_is_fatal(db, tmp_path):
    secret = tmp_path / "admin-password"
    secret.write_text("short\n")
    secret.chmod(0o600)
    with pytest.raises(BootstrapError) as failed:
        _boot(db, _settings(osml_admin_password=None, osml_admin_password_file=secret), tmp_path)
    assert "at least 8" in str(failed.value)


@pytest.mark.parametrize("mode", [0o644, 0o640, 0o604])
def test_a_group_or_world_readable_env_file_warns(db, tmp_path, caplog, mode):
    env_file = tmp_path / ".env"
    env_file.write_text("OSML_ADMIN_PASSWORD=whatever\n")
    env_file.chmod(mode)

    with caplog.at_level(logging.WARNING):
        bootstrap_master_admin(db, _settings(), env_file=env_file)

    warnings = [r.getMessage() for r in caplog.records if r.levelno == logging.WARNING]
    assert any(str(env_file) in w and "chmod 600" in w for w in warnings), warnings


def test_an_owner_only_env_file_does_not_warn(db, tmp_path, caplog):
    env_file = tmp_path / ".env"
    env_file.write_text("x=1\n")
    env_file.chmod(0o600)

    with caplog.at_level(logging.WARNING):
        bootstrap_master_admin(db, _settings(), env_file=env_file)

    assert [r for r in caplog.records if r.levelno >= logging.WARNING] == []


def test_a_group_readable_password_file_warns(db, tmp_path, caplog):
    secret = tmp_path / "admin-password"
    secret.write_text(PASSWORD)
    secret.chmod(0o640)

    with caplog.at_level(logging.WARNING):
        _boot(db, _settings(osml_admin_password=None, osml_admin_password_file=secret), tmp_path)

    warnings = [r.getMessage() for r in caplog.records if r.levelno == logging.WARNING]
    assert any(str(secret) in w and "chmod 600" in w for w in warnings), warnings


# ── later boots: rename (S9) ────────────────────────────────────────────────

def _add_user(db, username):
    conn = sqlite3.connect(db.context.database_path)
    try:
        conn.execute(
            "INSERT INTO users (username, username_key, password_hash, library_folder, "
            "created_at) VALUES (?, ?, 'h', ?, 1)",
            (username, username.lower(), username.lower()),
        )
        conn.commit()
    finally:
        conn.close()


def test_a_changed_admin_username_renames_the_master_admin(db, tmp_path):
    admin_id = _boot(db, _settings(), tmp_path)

    assert _boot(db, _settings(osml_admin_username="Boss"), tmp_path) == admin_id

    [row] = _users(db)
    assert (row["id"], row["username"], row["username_key"]) == (admin_id, "Boss", "boss")
    assert row["library_folder"] == "admin"  # the folder never follows the name


def test_a_case_only_rename_keeps_the_key(db, tmp_path):
    admin_id = _boot(db, _settings(), tmp_path)

    _boot(db, _settings(osml_admin_username="ADMIN"), tmp_path)

    [row] = _users(db)
    assert (row["id"], row["username"], row["username_key"]) == (admin_id, "ADMIN", "admin")


def test_a_rename_onto_a_taken_name_is_fatal(db, tmp_path):
    _boot(db, _settings(), tmp_path)
    _add_user(db, "Boss")
    before = _users(db)

    with pytest.raises(BootstrapError) as failed:
        _boot(db, _settings(osml_admin_username="BOSS"), tmp_path)

    assert "BOSS" in str(failed.value) or "boss" in str(failed.value)
    assert _users(db) == before


def test_a_rename_onto_a_user_being_deleted_says_to_finish_the_delete(db, tmp_path):
    """Review r1 m-R1-43: bootstrap runs before the boot delete resume, so a
    name held by an unfinished ``users delete`` cannot be freed by this boot;
    the message says how to recover."""
    _boot(db, _settings(), tmp_path)
    _add_user(db, "Boss")
    db.mark_user_deleting(db.get_user_by_username_key("boss")["id"], 1)

    with pytest.raises(BootstrapError) as failed:
        _boot(db, _settings(osml_admin_username="boss"), tmp_path)

    assert "users delete Boss" in str(failed.value)


# ── later boots: password change (S10) ──────────────────────────────────────

def _add_session(db, token, user_id, revoked_at=None):
    conn = sqlite3.connect(db.context.database_path)
    try:
        conn.execute(
            "INSERT INTO auth_sessions (token_hash, media_hash, user_id, created_at, "
            "revoked_at) VALUES (?, ?, ?, 1, ?)",
            (token, "m-" + token, user_id, revoked_at),
        )
        conn.commit()
    finally:
        conn.close()


def _sessions(db):
    conn = sqlite3.connect(db.context.database_path)
    try:
        return dict(conn.execute("SELECT token_hash, revoked_at FROM auth_sessions"))
    finally:
        conn.close()


def test_a_changed_password_rehashes_and_revokes_the_admins_sessions(db, tmp_path):
    admin_id = _boot(db, _settings(), tmp_path)
    _add_user(db, "Sam")
    sam_id = _users(db)[1]["id"]
    _add_session(db, "live", admin_id)
    _add_session(db, "old", admin_id, revoked_at=5)
    _add_session(db, "sams", sam_id)
    new_password = PASSWORD + "-rotated"
    settings = _settings(osml_admin_password=new_password)

    assert _boot(db, settings, tmp_path) == admin_id

    admin = _users(db)[0]
    assert verify_password(settings, admin["password_hash"], new_password)
    assert not verify_password(settings, admin["password_hash"], PASSWORD)
    sessions = _sessions(db)
    assert sessions["live"] is not None
    assert sessions["old"] == 5  # already revoked: untouched
    assert sessions["sams"] is None  # another user's session: untouched


def test_an_unchanged_password_revokes_nothing(db, tmp_path):
    admin_id = _boot(db, _settings(), tmp_path)
    _add_session(db, "live", admin_id)

    _boot(db, _settings(), tmp_path)

    assert _sessions(db) == {"live": None}


def test_a_weak_parameter_hash_is_rehashed_without_revoking_sessions(db, tmp_path):
    # A hash made under the test-only cheap flag must not stay weak once the
    # flag is gone (M.0a review #5).
    admin_id = _boot(db, _settings(), tmp_path)
    _add_session(db, "live", admin_id)
    production = _settings(osml_insecure_fast_password_hashing=False)

    _boot(db, production, tmp_path)

    stored = _users(db)[0]["password_hash"]
    params = extract_parameters(stored)
    assert (params.memory_cost, params.time_cost, params.parallelism) == (19 * 1024, 2, 1)
    assert verify_password(production, stored, PASSWORD)
    assert _sessions(db) == {"live": None}


# ── quality seed (S11) ──────────────────────────────────────────────────────

def _admin_quality(db, admin_id):
    conn = sqlite3.connect(db.context.database_path)
    try:
        return conn.execute(
            "SELECT value FROM user_settings WHERE user_id = ? "
            "AND key = 'default_streaming_quality'",
            (admin_id,),
        ).fetchall()
    finally:
        conn.close()


def test_first_boot_seeds_the_admins_quality_from_the_env(db, tmp_path):
    admin_id = _boot(db, _settings(default_streaming_quality="320"), tmp_path)
    assert _admin_quality(db, admin_id) == [("320",)]


def test_a_stored_quality_is_never_overwritten(db, tmp_path):
    admin_id = _boot(db, _settings(default_streaming_quality="320"), tmp_path)

    _boot(db, _settings(default_streaming_quality="original"), tmp_path)

    assert _admin_quality(db, admin_id) == [("320",)]


def test_a_missing_quality_is_seeded_on_a_later_boot(db, tmp_path):
    admin_id = _boot(db, _settings(default_streaming_quality="320"), tmp_path)
    conn = sqlite3.connect(db.context.database_path)
    conn.execute("DELETE FROM user_settings")
    conn.commit()
    conn.close()

    _boot(db, _settings(default_streaming_quality="128"), tmp_path)

    assert _admin_quality(db, admin_id) == [("128",)]


# ── review r1 fixes ─────────────────────────────────────────────────────────

def test_an_empty_password_file_variable_counts_as_unset(db, tmp_path, monkeypatch):
    monkeypatch.setenv("OSML_ADMIN_PASSWORD_FILE", "")
    settings = _settings()
    assert settings.osml_admin_password_file is None

    _boot(db, settings, tmp_path)

    assert len(_users(db)) == 1


def test_a_password_file_that_is_not_utf8_is_fatal_without_leaking_bytes(db, tmp_path):
    secret = tmp_path / "admin-password"
    secret.write_bytes(b"\xffsecret-tail-bytes\n")
    secret.chmod(0o600)

    with pytest.raises(BootstrapError) as failed:
        _boot(db, _settings(osml_admin_password=None, osml_admin_password_file=secret), tmp_path)

    assert str(secret) in str(failed.value)
    assert failed.value.__cause__ is None and failed.value.__suppress_context__
    for text in (str(failed.value), repr(failed.value)):
        assert "secret-tail" not in text and "0xff" not in text
    assert _users(db) == []

