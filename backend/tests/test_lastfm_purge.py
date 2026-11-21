"""Phase 9D.1b (spec §7.11, SC-16d note, drift D20, review 9-U08c): the
operator purge, ``python -m app.cli lastfm purge``.

Built like ``users delete``: it checks the schema, takes the instance lock
(flock) and refuses while the server runs. It deletes every row of both
Last.fm tables, then runs ``VACUUM`` so the deleted values are no longer in
the database file (or its ``-wal`` / ``-shm`` companions). It works with or
without Last.fm settings and leaves listening history and every other table
untouched.

All data lives under ``tmp_path``; every Last.fm value is made up.
"""

import os
from pathlib import Path

import pytest

from app.core.instance_lock import acquire_instance_lock
from app.services.lastfm_crypto import encrypt
from tests.cli_fixtures import cli_settings, run_cli, sql
from tests.lastfm_secrets import ALL, CREDENTIAL_KEY, SESSION_KEY, TOKEN, assert_no_secret
from tests.user_delete_world import build_world, dump

LASTFM_TABLES = ("lastfm_connections", "scrobble_outbox")
# A track name that exists only inside one queued scrobble's frozen payload.
OUTBOX_ONLY = "Zzqxvbn outbox-only title"


@pytest.fixture
def world(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    world = build_world(cli_settings(tmp_path))
    # Real Fernet ciphertext (under a made-up key) for Sam's key and token.
    world.session_enc = encrypt(CREDENTIAL_KEY, SESSION_KEY)
    world.token_enc = encrypt(CREDENTIAL_KEY, TOKEN)
    sql(world.db, "UPDATE lastfm_connections SET session_key_enc = ?, pending_token_enc = ? "
                  "WHERE owner_id = ?", (world.session_enc, world.token_enc, world.sam))
    sql(world.db, "INSERT INTO scrobble_outbox (event_uuid, owner_id, payload, listened_at_s, "
                  "created_at) VALUES ('sam-unique', ?, ?, 100, 1)",
        (world.sam, '{"artist": "Radiohead", "track": "%s", "timestamp": 100}' % OUTBOX_ONLY))
    return world


def _files(world) -> list[Path]:
    path = Path(world.db.context.database_path)
    return [p for p in (path, path.with_name(path.name + "-wal"), path.with_name(path.name + "-shm"))
            if p.exists()]


def _in_files(world, value: str) -> bool:
    needle = value.encode("utf-8")
    return any(needle in p.read_bytes() for p in _files(world))


def _count(world, table) -> int:
    return sql(world.db, f'SELECT count(*) FROM "{table}"')[0][0]


def _others(world) -> dict:
    return {t: rows for t, rows in dump(world.db).items() if t not in LASTFM_TABLES}


def _purge(world, tmp_path, *, answer="purge", settings=None):
    asked = []

    def confirm(text):
        asked.append(text)
        return answer

    result = run_cli(settings or world.settings, tmp_path, "lastfm", "purge", confirm=confirm)
    result.asked = asked
    return result


def _lock_is_free(world) -> bool:
    lock = acquire_instance_lock(world.settings.app_data_dir)
    lock.release()
    return True


# --- the Database method ----------------------------------------------------------------------


def test_the_purge_empties_both_tables_for_every_user_and_reports_the_counts(world):
    assert world.db.purge_lastfm_data() == (2, 7)

    assert [_count(world, t) for t in LASTFM_TABLES] == [0, 0]


def test_the_purge_leaves_history_and_every_other_table_unchanged(world):
    before = _others(world)
    history = _count(world, "history_events")

    world.db.purge_lastfm_data()

    assert _count(world, "history_events") == history > 0
    assert _others(world) == before


def test_after_the_purge_no_deleted_value_is_left_in_the_database_files(world):
    for value in (world.session_enc, world.token_enc, OUTBOX_ONLY):
        assert _in_files(world, value), "the planted value must be findable before"

    world.db.purge_lastfm_data()

    for index, value in enumerate((world.session_enc, world.token_enc, OUTBOX_ONLY)):
        assert not _in_files(world, value), f"deleted value #{index} is still in the file"
    for index, secret in enumerate(ALL):
        assert not _in_files(world, secret), f"secret #{index} is in the file"


def test_a_purge_of_an_empty_database_is_harmless(world):
    world.db.purge_lastfm_data()
    assert world.db.purge_lastfm_data() == (0, 0)


# --- the CLI command --------------------------------------------------------------------------


def test_the_cli_purge_asks_then_deletes_both_tables_and_vacuums(world, tmp_path):
    before = _others(world)

    result = _purge(world, tmp_path)

    assert result.code == 0, result.err
    assert len(result.asked) == 1
    assert [_count(world, t) for t in LASTFM_TABLES] == [0, 0]
    assert _others(world) == before
    assert not _in_files(world, world.session_enc)
    assert not _in_files(world, OUTBOX_ONLY)
    assert _lock_is_free(world)


def test_the_cli_purge_prints_no_stored_value(world, tmp_path):
    result = _purge(world, tmp_path)

    for text, where in ((result.out, "stdout"), (result.err, "stderr")):
        assert_no_secret(text, where, (*ALL, world.session_enc, world.token_enc, OUTBOX_ONLY,
                                       "sam-on-lastfm", "alex-on-lastfm"))


def test_a_wrong_confirmation_deletes_nothing(world, tmp_path):
    before = dump(world.db)

    result = _purge(world, tmp_path, answer="yes")

    assert result.code == 1
    assert dump(world.db) == before
    assert _lock_is_free(world)


def test_the_cli_purge_refuses_while_the_server_holds_the_flock(world, tmp_path):
    before = dump(world.db)
    lock = acquire_instance_lock(world.settings.app_data_dir)
    try:
        result = _purge(world, tmp_path)
    finally:
        lock.release()

    assert result.code == 1
    assert "server" in result.err and "osml.lock" in result.err
    assert result.asked == []
    assert dump(world.db) == before


@pytest.mark.parametrize(
    "lastfm",
    [
        {},
        {"lastfm_enabled": "maybe", "lastfm_credential_key": "not-a-fernet-key",
         "lastfm_api_key": "short", "lastfm_api_secret_file": "/nonexistent/secret",
         "lastfm_settle_delay_s": "soon"},
        {"lastfm_enabled": "true", "lastfm_api_key": "k" * 32, "lastfm_api_secret": "s",
         "lastfm_credential_key": CREDENTIAL_KEY},
    ],
    ids=["no_settings", "broken_settings", "valid_settings"],
)
def test_the_cli_purge_works_with_or_without_lastfm_settings(world, tmp_path, lastfm, monkeypatch):
    # 9-R1-17: "without settings" must mean none, also from the shell's environment.
    for name in list(os.environ):
        if name.startswith(("LASTFM_", "OSML_INSECURE_LASTFM_")):
            monkeypatch.delenv(name)
    settings = cli_settings(tmp_path, **lastfm)

    result = _purge(world, tmp_path, settings=settings)

    assert result.code == 0, result.err
    assert [_count(world, t) for t in LASTFM_TABLES] == [0, 0]


def test_the_purge_is_listed_in_the_cli_usage(world, tmp_path):
    result = run_cli(world.settings, tmp_path, "lastfm", "unpurge")

    assert result.code == 2
    assert "purge" in result.err


# --- another program holding the file open ----------------------------------------------------


@pytest.fixture
def reader(world, monkeypatch):
    """Another program (a backup tool, a sqlite3 shell) with an open read
    snapshot: the WAL cannot be truncated while it lasts."""
    import sqlite3

    from app.database import lastfm as lastfm_module

    monkeypatch.setattr(lastfm_module, "PURGE_BUSY_TIMEOUT_S", 0.05)
    conn = sqlite3.connect(world.db.context.database_path)
    conn.execute("BEGIN")
    conn.execute("SELECT count(*) FROM tracks").fetchone()
    yield conn
    conn.close()


def test_a_purge_that_cannot_compact_the_files_says_so(world, reader):
    from app.database.database import LastfmPurgeIncomplete

    with pytest.raises(LastfmPurgeIncomplete) as raised:
        world.db.purge_lastfm_data()

    assert_no_secret(str(raised.value), "the error", (*ALL, world.session_enc, OUTBOX_ONLY))
    reader.close()
    assert [_count(world, t) for t in LASTFM_TABLES] == [0, 0]  # the rows are gone
    world.db.purge_lastfm_data()  # running it again finishes the job
    assert not _in_files(world, world.session_enc)
    assert not _in_files(world, OUTBOX_ONLY)


def test_the_cli_reports_an_incomplete_purge_and_asks_for_a_rerun(world, tmp_path, reader):
    result = _purge(world, tmp_path)

    assert result.code == 1
    assert "lastfm purge" in result.err and "again" in result.err
    assert_no_secret(result.out + result.err, "the output",
                     (*ALL, world.session_enc, world.token_enc, OUTBOX_ONLY))
    assert _lock_is_free(world)


def test_the_purge_compacts_the_file_and_empties_the_wal(world):
    """SQLite builds that zero deleted cells (``secure_delete``) hide a missing
    VACUUM from the byte scan; free pages and the WAL do not."""
    import sqlite3

    payload = '{"artist": "Radiohead", "track": "%s", "timestamp": 1}' % ("x" * 2000)
    sql(world.db, "INSERT INTO scrobble_outbox (event_uuid, owner_id, payload, listened_at_s, "
                  "created_at) WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 400) "
                  "SELECT 'bulk-' || i, ?, ?, 1, 1 FROM n",
        (world.alex, payload))

    world.db.purge_lastfm_data()

    conn = sqlite3.connect(world.db.context.database_path)
    try:
        assert conn.execute("PRAGMA freelist_count").fetchone()[0] == 0
    finally:
        conn.close()
    path = Path(world.db.context.database_path)
    wal = path.with_name(path.name + "-wal")
    assert not wal.exists() or wal.stat().st_size == 0


@pytest.fixture
def writer(world, monkeypatch):
    """Another program holding the write lock."""
    import sqlite3

    from app.database import lastfm as lastfm_module

    monkeypatch.setattr(lastfm_module, "PURGE_BUSY_TIMEOUT_S", 0.05)
    conn = sqlite3.connect(world.db.context.database_path)
    conn.execute("BEGIN IMMEDIATE")
    yield conn
    conn.rollback()
    conn.close()


def test_review_r1_f3_a_purge_blocked_by_a_writer_deletes_nothing_and_says_so(world, writer):
    from app.database.database import LastfmPurgeBusy

    with pytest.raises(LastfmPurgeBusy):
        world.db.purge_lastfm_data()

    writer.rollback()
    assert _count(world, "lastfm_connections") == 2


def test_review_r1_f3_the_cli_reports_a_blocked_purge_without_a_traceback(world, tmp_path, writer):
    result = _purge(world, tmp_path)

    assert result.code == 1
    assert "nothing was deleted" in result.err.lower() and "again" in result.err
    assert _lock_is_free(world)
