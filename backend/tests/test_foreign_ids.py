"""Phase M.0b (SC-28 rule 4, spec §4.2 "Cross-owner answers are 404"): another
user's IDs look absent through every route.

M.0 has no login: every request acts as the master admin (``current_library``).
The other user exists only as rows a test creates, which is enough to prove
that each route reads through the caller's ``Library``.
"""

import json
import sqlite3
import uuid

import pytest

from app.library import Library
from app.models import Track, TrackMetaData
from app.models.history import HistoryEvent
from app.services.encoder_coordinator import PrefetchOutcome
from tests.owned_database import add_test_user


def _track(source, title, artist="Radiohead", album="OK Computer"):
    source.parent.mkdir(parents=True, exist_ok=True)
    source.write_bytes(b"not really flac")
    return Track(
        file_path=source,
        metadata=TrackMetaData(
            title=title, artist=artist, album=album, codec="flac", duration=1.0,
            bitrate_kbps=900.0, sample_rate_hz=44100, channels=2,
            track_number=1, disc_number=1,
        ),
    )


@pytest.fixture
def two_users(app_client, tmp_path):
    """The admin and sam both own "Radiohead / OK Computer"."""
    db = app_client.app.state.database
    sam = Library(db, add_test_user(db, "sam"))
    mine = _track(tmp_path / "music" / "admin" / "Airbag.flac", "Airbag")
    theirs = _track(tmp_path / "music" / "sam" / "Lucky.flac", "Lucky")
    assert app_client.app.state.admin_library.add_track(mine)
    assert sam.add_track(theirs)
    return app_client, mine, theirs


def _sam_parent_ids(client, uuid_id):
    conn = sqlite3.connect(client.app.state.database.context.database_path)
    try:
        return conn.execute(
            "SELECT artist_id, album_id FROM trackmetadata WHERE uuid_id = ?", (uuid_id,)
        ).fetchone()
    finally:
        conn.close()


def _rows(client, sql, params=()):
    conn = sqlite3.connect(client.app.state.database.context.database_path)
    try:
        return conn.execute(sql, params).fetchall()
    finally:
        conn.close()


# ── single-resource routes: 404 ──────────────────────────────────────────────

def test_get_track_of_another_user_is_404(two_users):
    client, _, theirs = two_users

    assert client.get(f"/tracks/{theirs.uuid_id}").status_code == 404


def test_stream_of_another_user_is_404(two_users):
    client, _, theirs = two_users

    r = client.get(f"/tracks/{theirs.uuid_id}/stream", params={"quality": "original"})

    assert r.status_code == 404


def test_post_job_for_another_users_track_is_404_and_queues_nothing(two_users):
    client, _, theirs = two_users

    r = client.post("/jobs", json={
        "type": "conversion",
        "uuid_id": theirs.uuid_id,
        "params": {"target_codec": "aac", "target_bitrate_kbps": 192},
        "base_revision": theirs.revision,
    })

    assert r.status_code == 404, r.text
    assert _rows(client, "SELECT id FROM conversion_jobs") == []


def test_master_patch_of_another_users_track_is_404_and_changes_nothing(two_users):
    client, _, theirs = two_users

    r = client.patch(f"/tracks/{theirs.uuid_id}", json={
        "base_revision": theirs.revision, "title": "Stolen", "write_mode": "db_and_master",
    })

    assert r.status_code == 404, r.text
    assert _rows(
        client, "SELECT title FROM trackmetadata WHERE uuid_id = ?", (theirs.uuid_id,)
    ) == [("Lucky",)]


# ── browse and filters: only the caller's rows, empty 200 for foreign IDs ───

def test_browse_lists_only_the_callers_tracks(two_users):
    client, mine, _ = two_users

    r = client.get("/tracks")

    assert r.status_code == 200
    assert [t["uuid_id"] for t in r.json()["data"]] == [mine.uuid_id]


def test_browse_filtered_by_another_users_artist_or_album_is_empty(two_users):
    client, _, theirs = two_users
    artist_id, album_id = _sam_parent_ids(client, theirs.uuid_id)

    by_artist = client.get("/tracks", params={"artist_id": artist_id})
    by_album = client.get("/tracks", params={"artist_id": artist_id, "album_id": album_id})

    assert (by_artist.status_code, by_artist.json()["data"]) == (200, [])
    assert (by_album.status_code, by_album.json()["data"]) == (200, [])


def test_a_cursor_carrying_another_users_search_parameters_is_empty(two_users):
    client, _, theirs = two_users
    cursor = json.dumps({
        "order_parameters": [{"column": "uuid_id", "isAscending": True}],
        "row_filter_parameters": [],
        "search_parameters": [{"column": "uuid_id", "operator": "=", "value": theirs.uuid_id}],
        "artist_id": None,
        "album_id": None,
    })

    r = client.get("/tracks", params={"cursor": cursor})

    assert (r.status_code, r.json()["data"]) == (200, [])


def test_db_only_patch_of_another_users_track_is_404_and_changes_nothing(two_users):
    client, _, theirs = two_users

    r = client.patch(f"/tracks/{theirs.uuid_id}", json={
        "base_revision": theirs.revision, "title": "Stolen",
    })

    assert r.status_code == 404, r.text
    assert _rows(
        client, "SELECT title FROM trackmetadata WHERE uuid_id = ?", (theirs.uuid_id,)
    ) == [("Lucky",)]


def test_default_quality_warming_iterates_only_the_admins_tracks(two_users):
    client, mine, _ = two_users

    assert list(client.app.state.encoder_coordinator.all_uuids_fn()) == [mine.uuid_id]


def test_changes_list_only_the_callers_tracks_with_the_callers_latest_revision(two_users):
    client, mine, _ = two_users
    my_revision = client.app.state.admin_library.get_track_by_uuid(mine.uuid_id).revision

    body = client.get("/changes", params={"after_revision": 0}).json()

    assert [c["uuid_id"] for c in body["changes"]] == [mine.uuid_id]
    assert body["latestRevision"] == my_revision


def test_artists_and_albums_list_only_the_callers(two_users):
    client, mine, _ = two_users
    my_artist, my_album = _sam_parent_ids(client, mine.uuid_id)

    artists = client.get("/artists").json()["data"]
    albums = client.get("/albums").json()["data"]

    assert [(a["id"], a["name"]) for a in artists] == [(my_artist, "Radiohead")]
    assert [a["id"] for a in albums] == [my_album]


def test_albums_filtered_by_another_users_artist_are_empty(two_users):
    client, _, theirs = two_users
    their_artist, _ = _sam_parent_ids(client, theirs.uuid_id)

    r = client.get("/albums", params={"artist_id": their_artist})

    assert (r.status_code, r.json()["data"]) == (200, [])


def test_search_returns_only_the_callers_rows(two_users):
    client, mine, _ = two_users

    body = client.get("/search", params={"q": "radiohead"}).json()

    assert [t["uuid_id"] for t in body["tracks"]] == [mine.uuid_id]
    assert len(body["artists"]) == 1 and len(body["albums"]) == 1


# ── history ──────────────────────────────────────────────────────────────────

def _history_event():
    return {
        "event_uuid": str(uuid.uuid4()), "kind": "listen", "entity_type": "track",
        "entity_ref": "t", "occurred_at": 1, "seconds_played": 1.0, "track_length": 2.0,
    }


def _sam_library(client):
    db = client.app.state.database
    [(sam,)] = _rows(client, "SELECT id FROM users WHERE username_key = 'sam'")
    return Library(db, sam)


def test_posting_another_users_event_id_is_the_existing_409_even_when_identical(two_users):
    client, _, _ = two_users
    theirs = _history_event()
    _sam_library(client).insert_history_events([HistoryEvent(**theirs)])

    r = client.post("/history", json={"events": [theirs]})

    assert r.status_code == 409, r.text
    detail = r.json()["detail"]
    assert detail["error"] == "history_event_conflict"
    assert detail["conflicting_event_uuids"] == [theirs["event_uuid"]]


def test_history_changes_list_only_the_callers_events(two_users):
    client, _, _ = two_users
    mine = _history_event()
    assert client.post("/history", json={"events": [mine]}).status_code == 200
    _sam_library(client).insert_history_events([HistoryEvent(**_history_event())])

    body = client.get("/history/changes").json()

    assert [e["event_uuid"] for e in body["events"]] == [mine["event_uuid"]]
    assert body["latestRevision"] == body["events"][0]["revision"]


# ── jobs ─────────────────────────────────────────────────────────────────────

def _sam_job(client, theirs):
    return _sam_library(client).insert_conversion_job(theirs.uuid_id, "aac", "m4a", 192)


def test_job_lists_show_only_the_callers_jobs(two_users):
    client, mine, theirs = two_users
    my_job = client.app.state.admin_library.insert_conversion_job(mine.uuid_id, "aac", "m4a", 192)
    _sam_job(client, theirs)

    everything = client.get("/jobs").json()["data"]
    by_foreign_uuid = client.get("/jobs", params={"uuid_id": theirs.uuid_id})

    assert [j["job_id"] for j in everything] == [my_job]
    assert (by_foreign_uuid.status_code, by_foreign_uuid.json()["data"]) == (200, [])


def test_cancelling_another_users_job_answers_cancelled_false_and_leaves_it(two_users):
    client, _, theirs = two_users
    their_job = _sam_job(client, theirs)

    r = client.delete(f"/jobs/{their_job}")

    assert (r.status_code, r.json()) == (200, {"cancelled": False})
    assert _rows(client, "SELECT status FROM conversion_jobs WHERE id = ?", (their_job,)) == [
        ("queued",)
    ]


# ── warm ─────────────────────────────────────────────────────────────────────

class _RecordingCoordinator:
    """Stands in for the encoder: records what warm enqueues."""

    def __init__(self, outcome):
        self.outcome = outcome
        self.enqueued = []

    def enqueue_prefetch(self, uuid_id, quality, source_bitrate_kbps=None):
        self.enqueued.append(uuid_id)
        return self.outcome

    def shutdown(self):
        pass


def _warm(client, uuids, **body):
    return client.post("/tracks/warm", json={
        "current_index": 0, "quality": "128", "track_uuids": uuids, **body,
    })


@pytest.mark.parametrize("outcome", [PrefetchOutcome.QUEUED, PrefetchOutcome.ALREADY_CACHED])
def test_warm_drops_foreign_and_unknown_uuids_uncounted(two_users, outcome):
    client, mine, theirs = two_users
    coordinator = _RecordingCoordinator(outcome)
    client.app.state.encoder_coordinator = coordinator

    r = _warm(client, [theirs.uuid_id, mine.uuid_id, "no-such-track"], count=3)

    assert r.status_code == 200
    body = r.json()
    assert coordinator.enqueued == [mine.uuid_id]
    assert body["prefetch_queued"] + body["prefetch_skipped"] == 1


def test_warm_filters_the_requested_window_not_the_whole_list(two_users):
    client, mine, theirs = two_users
    coordinator = _RecordingCoordinator(PrefetchOutcome.QUEUED)
    client.app.state.encoder_coordinator = coordinator

    body = _warm(client, [theirs.uuid_id, mine.uuid_id], count=1).json()

    assert coordinator.enqueued == []
    assert (body["prefetch_queued"], body["prefetch_skipped"]) == (0, 0)
