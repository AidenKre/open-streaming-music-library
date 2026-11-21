"""A database error on the single-track read is not "no such track".

``get_track_by_uuid`` used to go through ``get_tracks``, which turns every
exception into ``[]``, so a locked or unreadable database read as "this track
does not exist". The routes then answered 404, and the app takes a 404 as
proof that the track is gone: it skips the playing track, reverts a saved
edit, and on an edit conflict resolved as "take server" deletes its local row
and its download. A database error must reach the caller as an error; a
missing, foreign or deleted track still reads as None and answers 404.
"""

import sqlite3
from contextlib import contextmanager

import pytest
from fastapi.testclient import TestClient

from app.database.database import ANY_OWNER
from app.library import Library
from app.services import conversion as conversion_module
from app.services.conversion import TRACK_CHANGED_ERROR
from tests.auth_helpers import flac_track
from tests.conversion_fixtures import (
    _add_track,
    _lib,
    _make_audio,
    _make_orchestrator,
    _root,
    _run_submitted,
    _staging_files,
)
from tests.owned_database import add_test_user
from tests.sqlite_helpers import sql_rows

UNKNOWN_UUID = "6b1f6b39-5d0d-4a4a-9d3c-0d6c5d6f0001"


class _BusyOn:
    """A connection whose statements containing ``fragment`` find the database
    locked (SQLite's own error); every other statement runs normally, so the
    sign-in read and the pending-deletion check still work."""

    def __init__(self, conn, fragment):
        self._conn = conn
        self._fragment = fragment

    def execute(self, sql, *args):
        if self._fragment in sql:
            raise sqlite3.OperationalError("database is locked")
        return self._conn.execute(sql, *args)

    def cursor(self):
        return _BusyOn(self._conn.cursor(), self._fragment)

    def __getattr__(self, name):
        return getattr(self._conn, name)


def _busy_track_reads(monkeypatch, database, armed=None):
    """Every statement that reads track metadata finds the database locked
    (only while ``armed`` is non-empty, when a list is given)."""
    real = type(database)._connection

    @contextmanager
    def connection(self, **kwargs):
        with real(self, **kwargs) as conn:
            yield _BusyOn(conn, "trackmetadata") if armed is None or armed else conn

    monkeypatch.setattr(type(database), "_connection", connection)


@pytest.fixture
def world(app_client, tmp_path):
    database = app_client.app.state.database
    admin = app_client.app.state.admin_library
    mine = flac_track(tmp_path / "music" / "admin" / "Airbag.flac", "Airbag")
    assert admin.add_track(mine)
    sam = add_test_user(database, "sam")
    theirs = flac_track(tmp_path / "music" / "sam" / "Lucky.flac", "Lucky")
    assert Library(database, sam).add_track(theirs)
    gone = flac_track(tmp_path / "music" / "admin" / "Gone.flac", "Gone")
    assert admin.add_track(gone)
    assert admin.delete_track(gone.uuid_id)
    return {
        "client": app_client,
        "database": database,
        "admin": admin,
        "sam": sam,
        "mine": admin.get_track_by_uuid(mine.uuid_id),
        "theirs": theirs.uuid_id,
        "gone": gone.uuid_id,
    }


def _quiet_client(client):
    """The same started app, answering an unhandled error with a 500 instead
    of raising it into the test (no ``with``: a second lifespan would refuse)."""
    quiet = TestClient(client.app, raise_server_exceptions=False)
    quiet.headers.update({"Authorization": client.headers["Authorization"]})
    return quiet


# ── the read itself ─────────────────────────────────────────────────────────


def test_a_locked_database_raises_instead_of_reading_as_no_track(world, monkeypatch):
    _busy_track_reads(monkeypatch, world["database"])

    with pytest.raises(sqlite3.OperationalError, match="database is locked"):
        world["admin"].get_track_by_uuid(world["mine"].uuid_id)


def test_a_locked_database_raises_for_the_any_owner_read_too(world, monkeypatch):
    _busy_track_reads(monkeypatch, world["database"])

    with pytest.raises(sqlite3.OperationalError):
        world["database"].get_track_by_uuid(world["mine"].uuid_id, owner_id=ANY_OWNER)


def test_an_own_track_reads_whole(world):
    track = world["admin"].get_track_by_uuid(world["mine"].uuid_id)

    assert track.uuid_id == world["mine"].uuid_id
    assert track.metadata.title == "Airbag"
    assert track.metadata.codec == "flac"
    assert track.owner_id == world["admin"].owner_id
    assert track.revision == world["mine"].revision


@pytest.mark.parametrize("which", ["unknown", "theirs", "gone"])
def test_a_missing_foreign_or_deleted_track_still_reads_none(world, which):
    uuid_id = UNKNOWN_UUID if which == "unknown" else world[which]

    assert world["admin"].get_track_by_uuid(uuid_id) is None


def test_any_owner_still_finds_another_users_track(world):
    track = world["database"].get_track_by_uuid(world["theirs"], owner_id=ANY_OWNER)

    assert track is not None
    assert track.owner_id == world["sam"]
    assert track.metadata.title == "Lucky"


# ── what a client sees ──────────────────────────────────────────────────────


def test_get_track_answers_an_error_not_404_when_the_database_is_locked(world, monkeypatch):
    client = _quiet_client(world["client"])
    _busy_track_reads(monkeypatch, world["database"])

    response = client.get(f"/tracks/{world['mine'].uuid_id}")

    assert response.status_code >= 500, response.text


def test_a_stream_open_answers_an_error_not_404_when_the_database_is_locked(
    world, monkeypatch
):
    client = _quiet_client(world["client"])
    _busy_track_reads(monkeypatch, world["database"])

    response = client.get(f"/tracks/{world['mine'].uuid_id}/stream?quality=original")

    assert response.status_code >= 500, response.text


def test_a_file_edit_answers_503_not_404_when_the_database_is_locked(world, monkeypatch):
    client = _quiet_client(world["client"])
    _busy_track_reads(monkeypatch, world["database"])

    response = client.patch(
        f"/tracks/{world['mine'].uuid_id}",
        json={
            "base_revision": world["mine"].revision,
            "write_mode": "db_and_master",
            "title": "Renamed",
        },
    )

    assert response.status_code == 503, response.text
    assert response.json() == {"detail": "Database busy, retry"}


@pytest.mark.parametrize("which", ["unknown", "theirs", "gone"])
def test_a_missing_foreign_or_deleted_track_still_answers_404(world, which):
    client = world["client"]
    uuid_id = UNKNOWN_UUID if which == "unknown" else world[which]

    assert client.get(f"/tracks/{uuid_id}").status_code == 404
    assert client.get(f"/tracks/{uuid_id}/stream?quality=original").status_code == 404
    edit = client.patch(
        f"/tracks/{uuid_id}",
        json={"base_revision": 0, "write_mode": "db_and_master", "title": "Mine now"},
    )
    assert edit.status_code == 404, edit.text


# ── a conversion job ────────────────────────────────────────────────
# A job whose track read meets a busy database fails, but never with a
# sentence that says the track or its file is gone or changed. (The text for
# this unnamed case is Phase 10 W1's; only what it must not say is pinned.)


def _reservations(db):
    return sql_rows(db, "SELECT id FROM storage_reservations")


def test_a_busy_read_at_the_start_of_a_job_is_not_master_not_found(tmp_path, monkeypatch):
    db, orch, coordinator = _make_orchestrator(tmp_path)
    source = _root(tmp_path) / "song.flac"
    source.write_bytes(b"fake")
    track = _add_track(db, source, codec="flac")
    job_id = orch.enqueue(_lib(orch), track.uuid_id, "aac", 192, track.revision)
    _busy_track_reads(monkeypatch, db)

    _run_submitted(coordinator)

    job = db.get_conversion_job(job_id)
    assert job["status"] == "failed"
    assert job["error_text"] not in ("master file not found", TRACK_CHANGED_ERROR)
    assert source.read_bytes() == b"fake"
    assert _staging_files(tmp_path) == []
    assert _reservations(db) == []


@pytest.mark.requires_ffmpeg
def test_a_busy_read_at_the_commit_check_is_not_track_changed(tmp_path, monkeypatch):
    db, orch, coordinator = _make_orchestrator(tmp_path)
    source = _root(tmp_path) / "song.flac"
    _make_audio(source, codec="flac")
    track = _add_track(db, source, codec="flac")
    original = source.read_bytes()
    job_id = orch.enqueue(_lib(orch), track.uuid_id, "aac", 192, track.revision)
    armed = []
    _busy_track_reads(monkeypatch, db, armed)
    real_fsync = conversion_module.fsync_file

    def fsync_then_busy(path):
        # The last step before the commit check takes the track lock and
        # re-reads the row: from here on, track reads find the database busy.
        real_fsync(path)
        armed.append(True)

    monkeypatch.setattr(conversion_module, "fsync_file", fsync_then_busy)

    _run_submitted(coordinator)

    assert armed, "the job never reached the commit check"
    armed.clear()
    job = db.get_conversion_job(job_id)
    assert job["status"] == "failed"
    assert job["error_text"] != TRACK_CHANGED_ERROR
    assert source.read_bytes() == original
    assert db.get_track_by_uuid(track.uuid_id).metadata.codec == "flac"
    assert not (_root(tmp_path) / "song.m4a").exists()
    assert db.list_journal_entries() == []
    assert _staging_files(tmp_path) == []
    assert _reservations(db) == []
