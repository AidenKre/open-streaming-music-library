"""Phase M.0a (SC-28 rules 1 and 3, insert half): owned rows are written with
their owner.

Owned inserts take a required keyword-only ``owner_id`` with no default
(omitting it is a ``TypeError``). Rows derived from an existing owned row
(a tombstone, an edit's artist and album) take that row's owner. Reads gain
their owner predicates in M.0b; these tests only check what is stored.
"""

import sqlite3

import pytest
from fastapi.testclient import TestClient

from app.database.database import Database, DatabaseContext
from app.models import Track, TrackMetaData
from tests.schema_fixtures import INIT_SQL


@pytest.fixture
def db(tmp_path):
    database = Database(DatabaseContext(database_path=tmp_path / "db.sqlite", init_sql_path=INIT_SQL))
    assert database.initialize()
    return database


def _user(db, name):
    conn = sqlite3.connect(db.context.database_path)
    try:
        uid = conn.execute(
            "INSERT INTO users (username, username_key, password_hash, library_folder, "
            "created_at) VALUES (?, ?, 'h', ?, 1)",
            (name, name.lower(), name.lower()),
        ).lastrowid
        conn.commit()
        return uid
    finally:
        conn.close()


def _rows(db, sql, params=()):
    conn = sqlite3.connect(db.context.database_path)
    try:
        return conn.execute(sql, params).fetchall()
    finally:
        conn.close()


def _track(title="Airbag", artist="Radiohead", album="OK Computer"):
    return Track(
        file_path=f"/music/{title}.flac",
        metadata=TrackMetaData(
            title=title, artist=artist, album=album, codec="flac", duration=1.0,
            bitrate_kbps=900.0, sample_rate_hz=44100, channels=2,
        ),
    )


def test_add_track_requires_an_owner(db):
    with pytest.raises(TypeError):
        db.add_track(_track())


def test_add_track_stores_the_owner_on_the_track_and_its_parents(db):
    sam = _user(db, "Sam")
    track = _track()

    assert db.add_track(track, owner_id=sam)

    assert _rows(db, "SELECT owner_id FROM tracks WHERE uuid_id = ?", (track.uuid_id,)) == [(sam,)]
    assert _rows(db, "SELECT name, owner_id FROM artists") == [("Radiohead", sam)]
    assert db.get_track_by_uuid(track.uuid_id, owner_id=sam).owner_id == sam


def test_two_owners_get_their_own_artist_and_album(db):
    sam, alex = _user(db, "Sam"), _user(db, "Alex")

    assert db.add_track(_track("Airbag"), owner_id=sam)
    assert db.add_track(_track("Lucky", artist="RADIOHEAD"), owner_id=alex)
    assert db.add_track(_track("Karma Police"), owner_id=sam)

    artists = _rows(db, "SELECT owner_id, name_lower FROM artists ORDER BY owner_id")
    assert artists == sorted([(sam, "radiohead"), (alex, "radiohead")])
    albums = _rows(
        db,
        "SELECT ar.owner_id, al.name_lower FROM albums al "
        "JOIN artists ar ON ar.id = al.artist_id ORDER BY ar.owner_id",
    )
    assert albums == sorted([(sam, "ok computer"), (alex, "ok computer")])
    # Each track links to its own owner's parents.
    links = _rows(
        db,
        "SELECT t.owner_id, ar.owner_id FROM tracks t "
        "JOIN trackmetadata tm ON tm.uuid_id = t.uuid_id "
        "JOIN artists ar ON ar.id = tm.artist_id",
    )
    assert all(track_owner == artist_owner for track_owner, artist_owner in links)
    assert len(links) == 3


def test_an_edit_links_parents_of_the_tracks_own_owner(db):
    sam, alex = _user(db, "Sam"), _user(db, "Alex")
    assert db.add_track(_track("Airbag", artist="Radiohead"), owner_id=sam)
    alex_track = _track("Song", artist="Someone Else", album="Other")
    assert db.add_track(alex_track, owner_id=alex)
    revision = db.get_track_by_uuid(alex_track.uuid_id, owner_id=alex).revision

    db.apply_track_metadata_edit(
        alex_track.uuid_id, {"artist": "Radiohead", "album": "OK Computer"}, revision,
        owner_id=alex,
    )

    [(artist_owner, album_artist_owner)] = _rows(
        db,
        "SELECT ar.owner_id, al_ar.owner_id FROM trackmetadata tm "
        "JOIN artists ar ON ar.id = tm.artist_id "
        "JOIN albums al ON al.id = tm.album_id "
        "JOIN artists al_ar ON al_ar.id = al.artist_id WHERE tm.uuid_id = ?",
        (alex_track.uuid_id,),
    )
    assert (artist_owner, album_artist_owner) == (alex, alex)
    assert sorted(_rows(db, "SELECT owner_id FROM artists WHERE name_lower = 'radiohead'")) == sorted(
        [(sam,), (alex,)]
    )


def test_a_tombstone_keeps_the_deleted_tracks_owner(db):
    sam = _user(db, "Sam")
    track = _track()
    assert db.add_track(track, owner_id=sam)

    assert db.delete_track(track.uuid_id, owner_id=sam)

    assert _rows(
        db, "SELECT owner_id FROM track_tombstones WHERE uuid_id = ?", (track.uuid_id,)
    ) == [(sam,)]


def test_ingest_files_tracks_under_the_master_admin(configure_app):
    main = configure_app(env={"ENABLE_FILE_WATCHER": "true"})
    with TestClient(main.app) as client:
        track = _track()
        assert client.app.state.organizer.ctx.add_to_database(track)
        admin_id = client.app.state.admin_user_id
        owner = client.app.state.admin_library.get_track_by_uuid(track.uuid_id).owner_id
    assert admin_id is not None
    assert owner == admin_id


# ── conversion jobs and the edit journal (S13) ──────────────────────────────

def _owned_track(db, owner):
    track = _track()
    assert db.add_track(track, owner_id=owner)
    return db.get_track_by_uuid(track.uuid_id, owner_id=owner)


def test_conversion_jobs_require_and_store_an_owner(db):
    sam = _user(db, "Sam")
    track = _owned_track(db, sam)
    with pytest.raises(TypeError):
        db.insert_conversion_job(track.uuid_id, "aac", "m4a", 192)

    job_id = db.insert_conversion_job(track.uuid_id, "aac", "m4a", 192, owner_id=sam)

    assert _rows(db, "SELECT owner_id FROM conversion_jobs WHERE id = ?", (job_id,)) == [(sam,)]
    assert db.get_conversion_job(job_id, owner_id=sam)["owner_id"] == sam
    assert [j["owner_id"] for j in db.list_conversion_jobs_with_status("queued", owner_id=sam)] == [sam]


def test_journal_entries_require_and_store_an_owner(db):
    sam = _user(db, "Sam")
    track = _owned_track(db, sam)
    with pytest.raises(TypeError):
        db.insert_journal_entry("inplace", track.uuid_id, old_path="/a", temp_path="/t")

    entry = db.insert_journal_entry(
        "inplace", track.uuid_id, old_path="/a", temp_path="/t", owner_id=sam
    )

    assert _rows(db, "SELECT owner_id FROM edit_journal WHERE id = ?", (entry,)) == [(sam,)]
    assert [e["owner_id"] for e in db.list_journal_entries(owner_id=sam)] == [sam]


def test_an_inplace_conversion_journal_row_takes_the_jobs_owner(db):
    sam = _user(db, "Sam")
    track = _owned_track(db, sam)
    job_id = db.insert_conversion_job(track.uuid_id, "aac", "m4a", 192, owner_id=sam)
    assert db.mark_conversion_job_running(job_id, owner_id=sam)

    _, entry = db.complete_conversion_job(
        job_id, track.uuid_id, "aac", 192.0, 44100, 2,
        inplace_journal=(str(track.file_path), "/staging/t.m4a"), owner_id=sam,
    )

    assert _rows(db, "SELECT owner_id FROM edit_journal WHERE id = ?", (entry,)) == [(sam,)]


# ── history (S14) ───────────────────────────────────────────────────────────

def _history_event(event_uuid="00000000-0000-4000-8000-000000000001"):
    from app.models.history import HistoryEvent

    return HistoryEvent.model_validate({
        "event_uuid": event_uuid, "kind": "play", "entity_type": "track",
        "entity_ref": "t-1", "occurred_at": 1_800_000_000_000,
        "seconds_played": 12.5, "track_length": 200.0,
    })


def test_history_inserts_require_and_store_an_owner(db):
    sam = _user(db, "Sam")
    with pytest.raises(TypeError):
        db.insert_history_events([_history_event()])

    db.insert_history_events([_history_event()], owner_id=sam)

    assert _rows(db, "SELECT owner_id, typeof(owner_id) FROM history_events") == [(sam, "integer")]


def test_history_hooks_see_the_owner_of_each_new_event(db):
    from app.services.history_hooks import register_history_hook, unregister_history_hook

    sam = _user(db, "Sam")
    seen = []
    register_history_hook("owner-probe", lambda conn, events: seen.extend(events))
    try:
        db.insert_history_events([_history_event()], owner_id=sam)
    finally:
        unregister_history_hook("owner-probe")

    assert [event["owner_id"] for event in seen] == [sam]


def test_posted_history_belongs_to_the_master_admin(app_client):
    event = _history_event().model_dump()
    response = app_client.post("/history", json={"events": [event]})
    assert response.status_code == 200, response.text

    path = app_client.app.state.database.context.database_path
    conn = sqlite3.connect(path)
    try:
        owners = conn.execute("SELECT owner_id FROM history_events").fetchall()
    finally:
        conn.close()
    assert owners == [(app_client.app.state.admin_user_id,)]
