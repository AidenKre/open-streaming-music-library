import importlib
import json
import sys
from pathlib import Path
from typing import List, Optional, Set

import pytest
from fastapi.testclient import TestClient

from app.models import (
    Album,
    Artist,
    ChangeEntry,
    GetAlbumsResponse,
    GetArtistsResponse,
    GetChangesResponse,
    GetSearchResponse,
    GetTracksResponse,
    Track,
    TrackMetaData,
)
from app.models.client_track import ClientTrack
from app.database.database import EDITABLE_METADATA_COLUMNS


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("APP_DATA_DIR", str(tmp_path / "data"))
    monkeypatch.setenv("MUSIC_LIBRARY_DIR", str(tmp_path / "music"))
    monkeypatch.setenv("IMPORT_DIR", str(tmp_path / "import"))
    monkeypatch.setenv("ENABLE_FILE_WATCHER", "false")

    # Ensure env is applied before import
    sys.modules.pop("app.main", None)
    # also pop config modules if they cache paths
    sys.modules.pop("app.config", None)
    import app.main

    importlib.reload(app.main)

    with TestClient(app.main.app) as c:
        yield c


def get_artist_id(client, artist_name: str) -> int:
    """Look up artist ID by name from the database."""
    artists = client.app.state.database.get_artists()
    for a in artists:
        if a.name.lower() == artist_name.lower():
            return a.id
    raise ValueError(f"Artist '{artist_name}' not found")


def get_album_id(client, album_name: str, artist_name: Optional[str] = None) -> int:
    """Look up album ID by name (and optionally artist name) from the database."""
    artist_id = None
    if artist_name:
        artist_id = get_artist_id(client, artist_name)
    albums = client.app.state.database.get_albums(artist_id=artist_id)
    for a in albums:
        if a.name is not None and a.name.lower() == album_name.lower():
            return a.id
    raise ValueError(f"Album '{album_name}' not found")


def get_singles_album_id(client, artist_name: str) -> int:
    """Look up single grouping album ID for an artist."""
    artist_id = get_artist_id(client, artist_name)
    albums = client.app.state.database.get_albums(artist_id=artist_id)
    for a in albums:
        if a.is_single_grouping:
            return a.id
    raise ValueError(f"Singles album for '{artist_name}' not found")


# Tests assume that each track has a unique artist and album
def add_tracks_to_client(
    client,
    amount_to_add: int = 1,
    artist: Optional[str] = None,
    album: Optional[str] = None,
) -> List[Track]:
    tracks = []
    for i in range(amount_to_add):
        metadata = TrackMetaData(
            title=f"song_{i}",
            album=f"album_{i}",
            artist=f"artist_{i}",
            track_number=i,
            duration=1.0,
        )
        if artist:
            metadata.artist = artist

        if album:
            metadata.album = album

        track = Track(file_path=Path(f"path_{i}"), metadata=metadata)

        tracks.append(track)

    for track in tracks:
        assert client.app.state.database.add_track(track)

    return tracks


class TestGetSingleTrack:
    def test_returns_current_track_state(self, client):
        tracks = add_tracks_to_client(client=client, amount_to_add=1)
        uuid = tracks[0].uuid_id

        r = client.get(f"/tracks/{uuid}")
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["uuid_id"] == uuid
        assert isinstance(body["revision"], int)
        assert body["metadata"]["title"] == "song_0"

    def test_missing_track_404s(self, client):
        r = client.get("/tracks/does-not-exist")
        assert r.status_code == 404, r.text


class TestGetTracks:
    def test_tracks__default__returns_track(self, client):
        tracks = add_tracks_to_client(client=client, amount_to_add=5)

        r = client.get("/tracks")
        assert r.status_code == 200, r.text

        gettracksresponse = GetTracksResponse.model_validate(r.json())
        assert gettracksresponse

        gotten_tracks = gettracksresponse.data

        assert len(gotten_tracks) == len(tracks)
        assert sorted(t.uuid_id for t in gotten_tracks) == sorted(
            t.uuid_id for t in tracks
        )

    def test_tracks__bad_cursor__fails(self, client):
        add_tracks_to_client(client=client, amount_to_add=5)
        bad_cursor = {"bad": "cursor"}

        r = client.get(f"/tracks?cursor={json.dumps(bad_cursor)}")
        assert r.status_code == 400, r.text

    def test_tracks__album_id_without_artist_id__rejected(self, client):
        """album_id is meaningful only when paired with artist_id (album IDs
        are not globally unique across artists). The query layer used to
        500 in this case; the API should reject it as 422 instead."""
        add_tracks_to_client(client=client, amount_to_add=3)
        r = client.get("/tracks", params={"album_id": 1})
        assert r.status_code == 422, r.text
        assert "album_id" in r.text and "artist_id" in r.text

    def test_tracks__full_library_cursor_logic__works(self, client):
        tracks = []

        for i in range(5):
            tracks.extend(
                add_tracks_to_client(
                    client=client,
                    amount_to_add=5,
                    artist=f"artist_{i}",
                    album=f"album_{i}",
                )
            )

        returned_tracks = []

        r = client.get("/tracks?limit=1")
        assert r.status_code == 200, r.text

        gettracksresponse = GetTracksResponse.model_validate(r.json())

        assert gettracksresponse is not None
        assert gettracksresponse.nextCursor is not None
        assert len(gettracksresponse.data) == 1

        returned_tracks.append(gettracksresponse.data[0])

        nextCursor = gettracksresponse.nextCursor

        while nextCursor:
            r = client.get("/tracks", params={"limit": 1, "cursor": nextCursor})
            assert r.status_code == 200, r.text

            gettracksresponse = GetTracksResponse.model_validate(r.json())

            assert gettracksresponse is not None
            nextCursor = gettracksresponse.nextCursor

            assert len(gettracksresponse.data) == 1
            returned_tracks.append(gettracksresponse.data[0])

        assert len(returned_tracks) == len(tracks)
        assert sorted(t.uuid_id for t in returned_tracks) == sorted(
            t.uuid_id for t in tracks
        )

    def test_tracks__artist_album_cursor_logic__works(self, client):
        # Random tracks that sort BEFORE the target artist
        add_tracks_to_client(client=client, amount_to_add=10)
        # Tracks from an artist that sorts AFTER the target artist
        add_tracks_to_client(
            client=client, amount_to_add=5, artist="zzz_artist", album="zzz_album"
        )

        artist = "some random artist"
        albums = [f"album_{i}" for i in range(2)]

        for album in albums:
            tracks = add_tracks_to_client(
                client=client, amount_to_add=5, artist=artist, album=album
            )

            artist_id = get_artist_id(client, artist)
            album_id = get_album_id(client, album, artist)

            returned_tracks = []

            r = client.get(
                "/tracks",
                params={"limit": 1, "artist_id": artist_id, "album_id": album_id},
            )
            assert r.status_code == 200, r.text

            gettracksresponse = GetTracksResponse.model_validate(r.json())

            assert gettracksresponse is not None
            assert gettracksresponse.nextCursor is not None
            assert len(gettracksresponse.data) == 1

            returned_tracks.append(gettracksresponse.data[0])

            nextCursor = gettracksresponse.nextCursor

            while nextCursor:
                r = client.get(
                    "/tracks",
                    params={
                        "limit": 1,
                        "cursor": nextCursor,
                    },
                )
                assert r.status_code == 200, r.text

                gettracksresponse = GetTracksResponse.model_validate(r.json())

                assert gettracksresponse is not None
                nextCursor = gettracksresponse.nextCursor

                assert len(gettracksresponse.data) == 1
                returned_tracks.append(gettracksresponse.data[0])

            assert len(returned_tracks) == len(tracks)
            assert sorted(t.uuid_id for t in returned_tracks) == sorted(
                t.uuid_id for t in tracks
            )

    def test_tracks__limit_offset__works(self, client):
        tracks = add_tracks_to_client(client=client, amount_to_add=5)

        gotten_tracks: List[ClientTrack] = []
        for i in range(len(tracks)):
            r = client.get(f"/tracks?limit=1&offset={i}")

            assert r.status_code == 200, r.text

            gettracksresponse = GetTracksResponse.model_validate(r.json())

            assert gettracksresponse
            assert len(gettracksresponse.data) == 1
            gotten_tracks.append(gettracksresponse.data[0])

        assert sorted(t.uuid_id for t in gotten_tracks) == sorted(
            t.uuid_id for t in tracks
        )

    def test_tracks__artist_album_filter_with_album_artist__works(self, client):
        album_artist = "MainArtist"
        feat_artist = "feat_artist"
        album = "TheAlbum"

        # Track with album_artist — should be found when querying MainArtist
        metadata_aa = TrackMetaData(
            title="song_aa",
            artist=feat_artist,
            album_artist=album_artist,
            album=album,
            duration=1.0,
        )
        track_aa = Track(file_path=Path("aa.mp3"), metadata=metadata_aa)
        assert client.app.state.database.add_track(track_aa)

        # Track with plain artist — should also be found when querying MainArtist
        metadata_plain = TrackMetaData(
            title="song_plain",
            artist=album_artist,
            album=album,
            duration=1.0,
        )
        track_plain = Track(file_path=Path("plain.mp3"), metadata=metadata_plain)
        assert client.app.state.database.add_track(track_plain)

        # Track that should NOT match
        metadata_other = TrackMetaData(
            title="song_other",
            artist="OtherArtist",
            album=album,
            duration=1.0,
        )
        track_other = Track(file_path=Path("other.mp3"), metadata=metadata_other)
        assert client.app.state.database.add_track(track_other)

        # MainArtist + TheAlbum returns both album_artist and plain artist tracks
        artist_id = get_artist_id(client, album_artist)
        album_id = get_album_id(client, album, album_artist)
        r = client.get(
            "/tracks", params={"artist_id": artist_id, "album_id": album_id}
        )
        assert r.status_code == 200, r.text

        response = GetTracksResponse.model_validate(r.json())
        assert len(response.data) == 2
        titles = {t.metadata.title for t in response.data}
        assert titles == {"song_aa", "song_plain"}

        # feat_artist is NOT a standalone artist — album_artist takes priority,
        # so only MainArtist and OtherArtist exist in the artists table
        all_artists = client.app.state.database.get_artists()
        artist_names = {a.name for a in all_artists}
        assert feat_artist not in artist_names

        # OtherArtist should only return their own track
        other_artist_id = get_artist_id(client, "OtherArtist")
        other_album_id = get_album_id(client, album, "OtherArtist")
        r = client.get(
            "/tracks",
            params={"artist_id": other_artist_id, "album_id": other_album_id},
        )
        assert r.status_code == 200, r.text

        response = GetTracksResponse.model_validate(r.json())
        assert len(response.data) == 1
        assert response.data[0].metadata.title == "song_other"

    def test_tracks__bad_limit_offset__fails(self, client):
        # Ensure that database is populated so no other codes return
        add_tracks_to_client(client=client, amount_to_add=5)

        # Bad limit tests
        r = client.get("/tracks?limit=0")
        assert r.status_code == 422, r.text

        r = client.get("/tracks?limit=-1")
        assert r.status_code == 422, r.text

        r = client.get("/tracks?limit=2000")
        assert r.status_code == 422, r.text

        # Bad offset tests
        r = client.get("/tracks?offset=-1")
        assert r.status_code == 422, r.text

        r = client.get("/tracks?offset=1000")
        assert r.status_code == 200, r.text

        gettracksresponse = GetTracksResponse.model_validate(r.json())
        assert len(gettracksresponse.data) == 0
        assert gettracksresponse.nextCursor is None


def _drain_changes(client, limit: int = 500) -> List[dict]:
    """Page through /changes from 0 and return all change entries in order."""
    after = 0
    collected: List[dict] = []
    while True:
        r = client.get("/changes", params={"after_revision": after, "limit": limit})
        assert r.status_code == 200, r.text
        body = GetChangesResponse.model_validate(r.json())
        collected.extend(c.model_dump() for c in body.changes)
        if body.nextCursor is None:
            break
        after = body.nextCursor
    return collected


class TestGetChanges:
    def test_change_entry__validates_track_payload_shape(self, client):
        with pytest.raises(ValueError, match="upsert"):
            ChangeEntry(type="upsert", revision=1, uuid_id="missing-track")

        add_tracks_to_client(client=client, amount_to_add=1)
        body = GetChangesResponse.model_validate(client.get("/changes").json())
        track = body.changes[0].track
        assert track is not None

        with pytest.raises(ValueError, match="delete"):
            ChangeEntry(
                type="delete",
                revision=2,
                uuid_id=body.changes[0].uuid_id,
                track=track,
            )

    def test_changes__from_zero__returns_all_upserts_in_order(self, client):
        add_tracks_to_client(client=client, amount_to_add=3)

        r = client.get("/changes")
        assert r.status_code == 200, r.text
        body = GetChangesResponse.model_validate(r.json())

        assert [c.type for c in body.changes] == ["upsert"] * 3
        revisions = [c.revision for c in body.changes]
        assert revisions == sorted(revisions)
        assert body.latestRevision == revisions[-1]
        assert body.nextCursor is None  # short page → caught up
        # Upserts carry full track payloads.
        assert all(c.track is not None for c in body.changes)

    def test_changes__after_revision__excludes_already_seen(self, client):
        add_tracks_to_client(client=client, amount_to_add=3)
        first = GetChangesResponse.model_validate(client.get("/changes").json())
        seen_through = first.changes[1].revision

        r = client.get("/changes", params={"after_revision": seen_through})
        body = GetChangesResponse.model_validate(r.json())
        assert all(c.revision > seen_through for c in body.changes)
        assert len(body.changes) == 1

    def test_changes__interleaves_upserts_and_deletes_by_revision(self, client):
        tracks = add_tracks_to_client(client=client, amount_to_add=2)
        # Delete the first track so its tombstone gets the newest revision.
        assert client.app.state.database.delete_track(uuid_id=tracks[0].uuid_id)

        entries = _drain_changes(client)
        # Strictly increasing revisions across the whole interleaved stream.
        revs = [e["revision"] for e in entries]
        assert revs == sorted(revs)
        # The delete is last (newest revision) and names the removed uuid.
        assert entries[-1]["type"] == "delete"
        assert entries[-1]["uuid_id"] == tracks[0].uuid_id
        assert entries[-1]["track"] is None

    def test_changes__delete_on_later_page__is_not_missed(self, client):
        # Regression for the old design where deletes only rode page 1: with
        # limit=1 the delete lands on a later page and must still surface.
        tracks = add_tracks_to_client(client=client, amount_to_add=3)
        assert client.app.state.database.delete_track(uuid_id=tracks[0].uuid_id)

        entries = _drain_changes(client, limit=1)
        delete_entries = [e for e in entries if e["type"] == "delete"]
        assert len(delete_entries) == 1
        assert delete_entries[0]["uuid_id"] == tracks[0].uuid_id
        # It genuinely paginated past the first page.
        assert delete_entries[0]["revision"] > entries[0]["revision"]

    def test_changes__pagination_cursor_resumes(self, client):
        tracks = add_tracks_to_client(client=client, amount_to_add=5)

        entries = _drain_changes(client, limit=2)
        assert [e["uuid_id"] for e in entries if e["type"] == "upsert"]
        # Every added track appears exactly once across the paged stream.
        upserted = sorted(e["uuid_id"] for e in entries if e["type"] == "upsert")
        assert upserted == sorted(t.uuid_id for t in tracks)

    def test_changes__upsert_unhydratable_on_full_page__still_paginates(
        self, client
    ):
        # Regression: an upsert whose metadata can't hydrate (simulating a
        # track concurrently hard-deleted between the stream query and the
        # hydration JOIN) is dropped from `changes`, shrinking the page below
        # the limit. nextCursor must still be derived from the raw stream so
        # pagination does not falsely report "caught up" and strand newer rows.
        tracks = add_tracks_to_client(client=client, amount_to_add=2)

        # Insert a bare `tracks` row (revision 3, no trackmetadata) so the
        # change stream lists it as an upsert but the hydration JOIN misses it.
        # Advance the counter past it so the next real add gets revision 4.
        db = client.app.state.database
        with db._connection(commit=True) as conn:
            conn.execute(
                "INSERT INTO tracks (uuid_id, file_path, created_at, "
                "last_updated, revision) VALUES ('orphan', '/o', 0, 0, 3)"
            )
            conn.execute("UPDATE revision_counter SET value = 3 WHERE id = 0")

        # A full raw page (limit == 3) that yields only 2 hydrated entries.
        r = client.get("/changes", params={"after_revision": 0, "limit": 3})
        body = GetChangesResponse.model_validate(r.json())
        assert len(body.changes) == 2
        assert {c.uuid_id for c in body.changes} == {t.uuid_id for t in tracks}
        # Must not be None — the old len(entries)==limit logic returned None here.
        assert body.nextCursor == 3

        # A later real change is reachable by resuming from the cursor.
        newer = add_tracks_to_client(client=client, amount_to_add=1)[0]
        r = client.get("/changes", params={"after_revision": body.nextCursor})
        body = GetChangesResponse.model_validate(r.json())
        assert [c.uuid_id for c in body.changes] == [newer.uuid_id]

    def test_changes__unhydratable_final_page_still_advances_cursor(
        self, client
    ):
        # Same raw-row drop as above, but on a final short page. Even when no
        # newer rows remain, the client still needs a cursor so it can advance
        # past the consumed raw revision instead of requesting it forever.
        tracks = add_tracks_to_client(client=client, amount_to_add=1)

        db = client.app.state.database
        with db._connection(commit=True) as conn:
            conn.execute(
                "INSERT INTO tracks (uuid_id, file_path, created_at, "
                "last_updated, revision) VALUES ('final-orphan', '/o', 0, 0, 2)"
            )
            conn.execute("UPDATE revision_counter SET value = 2 WHERE id = 0")

        r = client.get("/changes", params={"after_revision": 0, "limit": 500})
        body = GetChangesResponse.model_validate(r.json())
        assert [c.uuid_id for c in body.changes] == [tracks[0].uuid_id]
        assert body.nextCursor == 2

        r = client.get("/changes", params={"after_revision": body.nextCursor})
        body = GetChangesResponse.model_validate(r.json())
        assert body.changes == []
        assert body.nextCursor is None
        assert body.latestRevision == 2

    def test_changes__db_error__returns_500(self, client):
        # A DB failure must surface as a 5xx, not a silent empty page that the
        # client would read as "caught up" and stop syncing on.
        db = client.app.state.database
        with db._connection(commit=True) as conn:
            conn.execute("DROP TABLE revision_counter")

        r = client.get("/changes")
        assert r.status_code == 500

    def test_changes__caught_up__returns_empty(self, client):
        add_tracks_to_client(client=client, amount_to_add=2)
        latest = GetChangesResponse.model_validate(
            client.get("/changes").json()
        ).latestRevision

        r = client.get("/changes", params={"after_revision": latest})
        body = GetChangesResponse.model_validate(r.json())
        assert body.changes == []
        assert body.nextCursor is None
        assert body.latestRevision == latest

    def test_changes__invalid_after_revision__fails_validation(self, client):
        r = client.get("/changes", params={"after_revision": -1})
        assert r.status_code == 422, r.text

    def test_changes__invalid_limit__fails_validation(self, client):
        for limit in (0, -1, 1001):
            r = client.get("/changes", params={"limit": limit})
            assert r.status_code == 422, r.text

    def test_changes__exactly_full_final_page_returns_empty_followup(
        self, client
    ):
        add_tracks_to_client(client=client, amount_to_add=2)

        r = client.get("/changes", params={"after_revision": 0, "limit": 2})
        assert r.status_code == 200, r.text
        body = GetChangesResponse.model_validate(r.json())

        assert len(body.changes) == 2
        assert body.nextCursor == body.changes[-1].revision

        r = client.get(
            "/changes", params={"after_revision": body.nextCursor, "limit": 2}
        )
        assert r.status_code == 200, r.text
        followup = GetChangesResponse.model_validate(r.json())

        assert followup.changes == []
        assert followup.nextCursor is None
        assert followup.latestRevision == body.latestRevision


class TestGetTracksStream:
    def test_tracks_stream__invalid_uuid__fails(self, client):
        add_tracks_to_client(client=client, amount_to_add=5)

        r = client.get("/tracks/fake_uuid/stream")
        assert r.status_code == 404, r.text

    def test_tracks_stream__valid_uuid__streams(self, client, tmp_path: Path):
        metadata = TrackMetaData(duration=1.0)

        track_path = tmp_path / "track.mp3"
        track = Track(file_path=track_path, metadata=metadata)
        data = b"track" * 1000
        track_path.touch()
        track_path.write_bytes(data)

        track_added = client.app.state.database.add_track(track=track)
        assert track_added

        # Get tracks uuid_id and test that it was added
        r = client.get("/tracks")
        assert r.status_code == 200, r.text

        gettrackresponse = GetTracksResponse.model_validate(r.json())

        assert gettrackresponse

        assert gettrackresponse.data

        gotten_track = gettrackresponse.data[0]
        assert gotten_track

        track_uuid = gotten_track.uuid_id
        assert track_uuid == track.uuid_id

        # Stream the whole track
        with client.stream("GET", f"/tracks/{track_uuid}/stream") as resp:
            assert resp.status_code == 200, r.text
            assert resp.headers.get("accept-ranges") == "bytes"
            assert int(resp.headers["content-length"]) == len(data)
            body = b"".join(resp.iter_bytes())

        assert body == data

        # Stream some specific bytes of the track_file
        headers = {"Range": "bytes=10-19"}
        with client.stream(
            "GET", f"/tracks/{track_uuid}/stream", headers=headers
        ) as resp:
            assert resp.status_code == 206
            assert resp.headers["content-range"].startswith("bytes 10-19/")
            assert int(resp.headers["content-length"]) == 10
            body = b"".join(resp.iter_bytes())

        assert body == data[10:20]


# TODO: Refactor tests to also include album_artist songs.
# Although, I suppose I already test that functionality in test_database.py::TestGetArtists
class TestGetArtists:
    def test_artists__default__returns_artists(self, client):
        tracks = add_tracks_to_client(client=client, amount_to_add=5)
        expected_artists = {track.metadata.artist for track in tracks}

        r = client.get("/artists")
        assert r.status_code == 200, r.text

        getartistresponse = GetArtistsResponse.model_validate(r.json())

        assert getartistresponse

        gotten_artist_names = {artist.name for artist in getartistresponse.data}
        assert gotten_artist_names == expected_artists
        assert len(expected_artists) == len(getartistresponse.data)

    def test_artists__cursor_logic__works(self, client):
        tracks = add_tracks_to_client(client=client, amount_to_add=5)
        expected_artists = set()
        for track in tracks:
            artist = track.metadata.artist
            if artist:
                expected_artists.add(artist)

        gotten_artist_names = []

        r = client.get("/artists?limit=1")
        assert r.status_code == 200, r.text

        getartistresponse = GetArtistsResponse.model_validate(r.json())
        assert getartistresponse

        assert len(getartistresponse.data) == 1
        gotten_artist_names.append(getartistresponse.data[0].name)

        nextCursor = getartistresponse.nextCursor
        assert nextCursor

        while nextCursor:
            r = client.get("/artists", params={"limit": 1, "cursor": nextCursor})
            assert r.status_code == 200, r.text

            getartistresponse = GetArtistsResponse.model_validate(r.json())
            assert getartistresponse

            assert len(getartistresponse.data) == 1
            gotten_artist_names.append(getartistresponse.data[0].name)

            nextCursor = getartistresponse.nextCursor

        assert sorted(expected_artists) == sorted(gotten_artist_names)

    def test_artists__limit_offset__works(self, client):
        tracks = add_tracks_to_client(client=client, amount_to_add=2)
        expected_artists = {track.metadata.artist for track in tracks}

        r = client.get("/artists?limit=1")
        assert r.status_code == 200, r.text

        first_response = GetArtistsResponse.model_validate(r.json())
        assert first_response
        assert len(first_response.data) == 1
        assert first_response.data[0].name in expected_artists

        r = client.get("/artists?limit=1&offset=1")
        assert r.status_code == 200, r.text

        second_response = GetArtistsResponse.model_validate(r.json())
        assert second_response
        assert len(second_response.data) == 1
        assert second_response.data[0].name in expected_artists

        all_gotten_artists = {a.name for a in first_response.data + second_response.data}

        assert all_gotten_artists == expected_artists

    def test_artists__bad_limit_offset__fails(self, client):
        # Add tracks to database so no other errors get thrown
        add_tracks_to_client(client=client, amount_to_add=5)

        # Bad limit tests
        r = client.get("/artists?limit=0")
        assert r.status_code == 422, r.text

        r = client.get("/artists?limit=-1")
        assert r.status_code == 422, r.text

        r = client.get("/artists?limit=2000")
        assert r.status_code == 422, r.text

        # Bad offset tests
        r = client.get("/artists?offset=-1")
        assert r.status_code == 422, r.text

        r = client.get("/artists?offset=1000")
        assert r.status_code == 200, r.text

        getartistresponse = GetArtistsResponse.model_validate(r.json())
        assert len(getartistresponse.data) == 0
        assert getartistresponse.nextCursor is None

    def test_artists__invalid_cursor__returns_error(self, client):
        add_tracks_to_client(client=client, amount_to_add=5)

        bad_cursor = {"bad": "cursor"}
        r = client.get(f"/artists?cursor={json.dumps(bad_cursor)}")
        assert r.status_code == 400, r.text

    def test_artists__json_cursor__paginates_correctly(self, client):
        add_tracks_to_client(client=client, amount_to_add=10)

        all_artists = []

        r = client.get("/artists?limit=3")
        assert r.status_code == 200, r.text

        response = GetArtistsResponse.model_validate(r.json())
        all_artists.extend(response.data)
        nextCursor = response.nextCursor

        while nextCursor:
            r = client.get("/artists", params={"limit": 3, "cursor": nextCursor})
            assert r.status_code == 200, r.text

            response = GetArtistsResponse.model_validate(r.json())
            all_artists.extend(response.data)
            nextCursor = response.nextCursor

        assert len(all_artists) == 10
        assert len({a.name for a in all_artists}) == 10


class TestGetAlbums:
    def test_albums__invalid_artist__returns_empty(self, client):
        add_tracks_to_client(client=client, amount_to_add=1)

        # Use a non-existent artist_id
        r = client.get("/albums", params={"artist_id": 999999})
        assert r.status_code == 200, r.text

        response = GetAlbumsResponse.model_validate(r.json())
        assert response
        assert len(response.data) == 0

    def test_albums__no_albums__returns_single_grouping(self, client):
        metadata = TrackMetaData(artist="artist", duration=1.0)
        track = Track(metadata=metadata, file_path=Path("fake.mp3"))

        client.app.state.database.add_track(track=track)

        artist_id = get_artist_id(client, "artist")
        r = client.get("/albums", params={"artist_id": artist_id})
        assert r.status_code == 200, r.text

        response = GetAlbumsResponse.model_validate(r.json())
        assert response
        # Track with no album produces a single grouping
        assert len(response.data) == 1
        assert response.data[0].is_single_grouping is True
        assert response.data[0].name is None

    def test_albums__has_albums__returns_albums(self, client):
        tracks = add_tracks_to_client(client=client, amount_to_add=5)
        artist_albums: dict[str, Set[str]] = {}
        for track in tracks:
            artist = track.metadata.artist
            album = track.metadata.album

            if artist is None or album is None:
                continue

            if artist == "" or album == "":
                continue

            if artist not in artist_albums:
                artist_albums[artist] = set()

            artist_albums[artist].add(album)

        for artist_name in artist_albums:
            expected_albums = artist_albums[artist_name]
            artist_id = get_artist_id(client, artist_name)
            r = client.get("/albums", params={"artist_id": artist_id})
            assert r.status_code == 200, r.text

            response = GetAlbumsResponse.model_validate(r.json())
            assert response

            gotten_album_names = [a.name for a in response.data]
            set_gotten_albums = set(gotten_album_names)
            assert len(gotten_album_names) == len(set_gotten_albums)
            assert set_gotten_albums == expected_albums

    def test_albums__cursor_logic__works(self, client, tmp_path):
        tracks = []
        for i in range(3):
            artist = f"artist_{i}"
            for j in range(3):
                album = f"album_{i}_{j}"
                title = f"song_{i}_{j}"
                file_path = tmp_path / title
                metadata = TrackMetaData(
                    title=title, artist=artist, album=album, duration=1.0
                )
                track = Track(file_path=file_path, metadata=metadata)
                assert client.app.state.database.add_track(track=track)
                tracks.append(track)

        artist_albums: dict[str, Set[str]] = {}
        for track in tracks:
            artist = track.metadata.artist
            album = track.metadata.album

            if artist is None or album is None:
                continue

            if artist == "" or album == "":
                continue

            if artist not in artist_albums:
                artist_albums[artist] = set()

            artist_albums[artist].add(album)

        for artist_name, expected_albums in artist_albums.items():
            if len(expected_albums) == 0:
                continue

            artist_id = get_artist_id(client, artist_name)
            gotten_album_names: List[str] = []
            r = client.get("/albums", params={"artist_id": artist_id, "limit": 1})
            assert r.status_code == 200, r.text

            response = GetAlbumsResponse.model_validate(r.json())
            assert response
            assert len(response.data) == 1
            gotten_album_names.append(response.data[0].name)

            nextCursor = response.nextCursor
            assert response.nextCursor

            while nextCursor:
                r = client.get(
                    "/albums",
                    params={"artist_id": artist_id, "limit": 1, "cursor": nextCursor},
                )
                assert r.status_code == 200, r.text

                response = GetAlbumsResponse.model_validate(r.json())
                assert response
                assert len(response.data) == 1
                gotten_album_names.append(response.data[0].name)

                nextCursor = response.nextCursor

            assert sorted(expected_albums) == sorted(gotten_album_names)

    def test_albums__limit_offset__works(self, client):
        artist = "artist"
        tracks: List[Track] = []
        albums: set[str] = set()

        for i in range(3):
            album = f"album_{i}"
            albums.add(album)

            metadata = TrackMetaData(artist=artist, album=album, duration=1.0)

            file_path = Path(f"track_{i}")
            track = Track(metadata=metadata, file_path=file_path)

            tracks.append(track)

            track_added = client.app.state.database.add_track(track=track)
            assert track_added

        artist_id = get_artist_id(client, artist)
        gotten_album_names: List[str] = []
        for i in range(len(albums)):
            r = client.get(
                "/albums", params={"artist_id": artist_id, "limit": 1, "offset": i}
            )
            assert r.status_code == 200, r.text

            response = GetAlbumsResponse.model_validate(r.json())
            assert response
            assert len(response.data) == 1

            gotten_album_name = response.data[0].name
            assert gotten_album_name not in gotten_album_names
            assert gotten_album_name in albums

            gotten_album_names.append(gotten_album_name)

        assert len(gotten_album_names) == len(albums)
        assert set(gotten_album_names) == albums

    def test_albums__bad_limit_offset__fails(self, client):
        artist = "artist"

        for i in range(3):
            album = f"album_{i}"
            metadata = TrackMetaData(artist=artist, album=album, duration=1.0)
            file_path = Path(f"track_{i}")
            track = Track(metadata=metadata, file_path=file_path)
            track_added = client.app.state.database.add_track(track=track)
            assert track_added

        artist_id = get_artist_id(client, artist)

        # Bad limit tests
        r = client.get(f"/albums?artist_id={artist_id}&limit=0")
        assert r.status_code == 422, r.text

        r = client.get(f"/albums?artist_id={artist_id}&limit=-1")
        assert r.status_code == 422, r.text

        r = client.get(f"/albums?artist_id={artist_id}&limit=2000")
        assert r.status_code == 422, r.text

        # Bad offset tests
        r = client.get(f"/albums?artist_id={artist_id}&offset=-1")
        assert r.status_code == 422, r.text

        r = client.get(f"/albums?artist_id={artist_id}&offset=1000")
        assert r.status_code == 200, r.text

        response = GetAlbumsResponse.model_validate(r.json())
        assert len(response.data) == 0
        assert response.nextCursor is None

    def test_albums__no_artist__returns_all_albums(self, client, tmp_path):
        all_albums = set()

        # Albums from different artists
        for i in range(3):
            artist = f"artist_{i}"
            album = f"album_{i}"
            all_albums.add(album)
            title = f"song_{i}"
            file_path = tmp_path / title
            metadata = TrackMetaData(
                title=title, artist=artist, album=album, duration=1.0
            )
            track = Track(file_path=file_path, metadata=metadata)
            assert client.app.state.database.add_track(track=track)

        # Albums with album_artist
        for i in range(2):
            album = f"aa_album_{i}"
            all_albums.add(album)
            title = f"aa_song_{i}"
            file_path = tmp_path / title
            metadata = TrackMetaData(
                title=title,
                artist=f"feat_{i}",
                album=album,
                album_artist="album_artist",
                duration=1.0,
            )
            track = Track(file_path=file_path, metadata=metadata)
            assert client.app.state.database.add_track(track=track)

        r = client.get("/albums")
        assert r.status_code == 200, r.text

        response = GetAlbumsResponse.model_validate(r.json())
        returned_album_names = [a.name for a in response.data]
        assert sorted(a for a in returned_album_names if a is not None) == sorted(
            all_albums
        )

    def test_albums__no_artist__pagination_works(self, client, tmp_path):
        all_albums = set()
        for i in range(5):
            album = f"album_{i}"
            all_albums.add(album)
            title = f"song_{i}"
            file_path = tmp_path / title
            metadata = TrackMetaData(
                title=title, artist=f"artist_{i}", album=album, duration=1.0
            )
            track = Track(file_path=file_path, metadata=metadata)
            assert client.app.state.database.add_track(track=track)

        gotten_album_names: List[str] = []
        r = client.get("/albums", params={"limit": 2})
        assert r.status_code == 200, r.text

        response = GetAlbumsResponse.model_validate(r.json())
        gotten_album_names.extend(a.name for a in response.data if a.name is not None)

        nextCursor = response.nextCursor
        while nextCursor:
            r = client.get("/albums", params={"limit": 2, "cursor": nextCursor})
            assert r.status_code == 200, r.text
            response = GetAlbumsResponse.model_validate(r.json())
            gotten_album_names.extend(
                a.name for a in response.data if a.name is not None
            )
            nextCursor = response.nextCursor

        assert sorted(all_albums) == sorted(gotten_album_names)

    def test_albums__no_artist__returns_artist_then_album_order(self, client, tmp_path):
        # Same artist for all albums so we test album sub-sorting
        albums_to_insert = ["Zebra", "apple", "Mango", "banana"]
        for i, album in enumerate(albums_to_insert):
            title = f"song_{i}"
            file_path = tmp_path / title
            metadata = TrackMetaData(
                title=title, artist="same_artist", album=album, duration=1.0
            )
            track = Track(file_path=file_path, metadata=metadata)
            assert client.app.state.database.add_track(track=track)

        r = client.get("/albums")
        assert r.status_code == 200, r.text

        response = GetAlbumsResponse.model_validate(r.json())
        returned_album_names = [a.name for a in response.data]
        expected_order = sorted(albums_to_insert, key=str.lower)
        assert returned_album_names == expected_order

    def test_albums__with_artist__returns_year_order(self, client, tmp_path):
        artist = "artist"
        album_years = [("Late Album", 2022), ("Early Album", 2018), ("Mid Album", 2020)]
        for i, (album, year) in enumerate(album_years):
            title = f"song_{i}"
            file_path = tmp_path / title
            metadata = TrackMetaData(
                title=title, artist=artist, album=album, year=year, duration=1.0
            )
            track = Track(file_path=file_path, metadata=metadata)
            assert client.app.state.database.add_track(track=track)

        artist_id = get_artist_id(client, artist)
        r = client.get("/albums", params={"artist_id": artist_id})
        assert r.status_code == 200, r.text

        response = GetAlbumsResponse.model_validate(r.json())
        returned_album_names = [a.name for a in response.data]
        assert returned_album_names == ["Late Album", "Mid Album", "Early Album"]

    def test_albums__returns_correct_artist_field(self, client, tmp_path):
        # Plain artist track
        metadata1 = TrackMetaData(
            title="song_1", artist="Artist A", album="Album X", duration=1.0
        )
        track1 = Track(file_path=tmp_path / "s1", metadata=metadata1)
        assert client.app.state.database.add_track(track=track1)

        # Album artist track
        metadata2 = TrackMetaData(
            title="song_2",
            artist="feat_artist",
            album="Album Y",
            album_artist="Album Artist B",
            duration=1.0,
        )
        track2 = Track(file_path=tmp_path / "s2", metadata=metadata2)
        assert client.app.state.database.add_track(track=track2)

        r = client.get("/albums")
        assert r.status_code == 200, r.text

        response = GetAlbumsResponse.model_validate(r.json())
        assert len(response.data) == 2

        album_map = {a.name: a.artist for a in response.data}
        assert album_map["Album X"] == "Artist A"
        assert album_map["Album Y"] == "Album Artist B"

    def test_albums__same_album_different_artists__returns_both(self, client, tmp_path):
        metadata1 = TrackMetaData(
            title="song_1", artist="Artist A", album="Greatest Hits", duration=1.0
        )
        track1 = Track(file_path=tmp_path / "s1", metadata=metadata1)
        assert client.app.state.database.add_track(track=track1)

        metadata2 = TrackMetaData(
            title="song_2", artist="Artist B", album="Greatest Hits", duration=1.0
        )
        track2 = Track(file_path=tmp_path / "s2", metadata=metadata2)
        assert client.app.state.database.add_track(track=track2)

        r = client.get("/albums")
        assert r.status_code == 200, r.text

        response = GetAlbumsResponse.model_validate(r.json())
        assert len(response.data) == 2

        artists = {a.artist for a in response.data}
        assert artists == {"Artist A", "Artist B"}
        assert all(a.name == "Greatest Hits" for a in response.data)


class TestSearch:
    def test_search__by_title__returns_track(self, client, tmp_path):
        metadata = TrackMetaData(
            title="Bohemian Rhapsody", artist="Queen", album="A Night at the Opera",
            duration=1.0,
        )
        track = Track(file_path=tmp_path / "br.mp3", metadata=metadata)
        assert client.app.state.database.add_track(track=track)

        r = client.get("/search", params={"q": "Bohemian"})
        assert r.status_code == 200, r.text

        response = GetSearchResponse.model_validate(r.json())
        assert len(response.tracks) >= 1
        assert any(t.metadata.title == "Bohemian Rhapsody" for t in response.tracks)

    def test_search__by_artist__returns_artist(self, client, tmp_path):
        metadata = TrackMetaData(
            title="Song", artist="Radiohead", album="OK Computer", duration=1.0,
        )
        track = Track(file_path=tmp_path / "s.mp3", metadata=metadata)
        assert client.app.state.database.add_track(track=track)

        r = client.get("/search", params={"q": "Radiohead"})
        assert r.status_code == 200, r.text

        response = GetSearchResponse.model_validate(r.json())
        assert len(response.artists) >= 1
        assert any(a.name == "Radiohead" for a in response.artists)

    def test_search__by_album__returns_album(self, client, tmp_path):
        metadata = TrackMetaData(
            title="Song", artist="Artist", album="Dark Side of the Moon", duration=1.0,
        )
        track = Track(file_path=tmp_path / "s.mp3", metadata=metadata)
        assert client.app.state.database.add_track(track=track)

        r = client.get("/search", params={"q": "Dark Side"})
        assert r.status_code == 200, r.text

        response = GetSearchResponse.model_validate(r.json())
        assert len(response.albums) >= 1
        assert any(a.name == "Dark Side of the Moon" for a in response.albums)

    def test_search__types_filter__works(self, client, tmp_path):
        metadata = TrackMetaData(
            title="Song", artist="Artist", album="Album", duration=1.0,
        )
        track = Track(file_path=tmp_path / "s.mp3", metadata=metadata)
        assert client.app.state.database.add_track(track=track)

        r = client.get("/search", params={"q": "Song", "types": "tracks"})
        assert r.status_code == 200, r.text

        response = GetSearchResponse.model_validate(r.json())
        assert len(response.artists) == 0
        assert len(response.albums) == 0

    def test_search__no_match__returns_empty(self, client, tmp_path):
        metadata = TrackMetaData(
            title="Song", artist="Artist", album="Album", duration=1.0,
        )
        track = Track(file_path=tmp_path / "s.mp3", metadata=metadata)
        assert client.app.state.database.add_track(track=track)

        r = client.get("/search", params={"q": "xyznonexistent"})
        assert r.status_code == 200, r.text

        response = GetSearchResponse.model_validate(r.json())
        assert len(response.tracks) == 0
        assert len(response.artists) == 0
        assert len(response.albums) == 0

    def test_search__invalid_types__returns_error(self, client):
        r = client.get("/search", params={"q": "test", "types": "invalid"})
        assert r.status_code == 400, r.text


class TestAppInfo:
    def test_app_info__advertises_track_edit_fields(self, client):
        r = client.get("/app/info")
        assert r.status_code == 200, r.text
        body = r.json()

        track = body["entities"]["track"]
        keys = [f["key"] for f in track["fields"]]
        assert keys == EDITABLE_METADATA_COLUMNS  # advertised == accepted
        assert track["actions"] == []  # no actions in Phase 1
        assert all(f["editable"] for f in track["fields"])


class TestPatchTrack:
    def _add_one(self, client, **meta) -> Track:
        return add_tracks_to_client(client=client, amount_to_add=1, **meta)[0]

    def test_patch__db_only_edit__200_bumps_revision_and_shows_in_changes(self, client):
        track = self._add_one(client)

        r = client.patch(
            f"/tracks/{track.uuid_id}",
            json={"base_revision": track.revision, "title": "Renamed"},
        )
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["uuid_id"] == track.uuid_id
        assert body["revision"] > track.revision

        changes = GetChangesResponse.model_validate(client.get("/changes").json())
        edited = next(c for c in changes.changes if c.uuid_id == track.uuid_id)
        assert edited.track is not None
        assert edited.track.metadata.title == "Renamed"
        assert edited.track.revision == body["revision"]

    def test_patch__stale_base_revision__409(self, client):
        track = self._add_one(client)
        r = client.patch(
            f"/tracks/{track.uuid_id}",
            json={"base_revision": track.revision + 999, "title": "X"},
        )
        assert r.status_code == 409, r.text

    def test_patch__missing_uuid__404(self, client):
        r = client.patch(
            "/tracks/does-not-exist",
            json={"base_revision": 1, "title": "X"},
        )
        assert r.status_code == 404, r.text

    def test_patch__non_allowlisted_field__422(self, client):
        track = self._add_one(client)
        # `codec` is audio-derived — not in the edit allowlist.
        r = client.patch(
            f"/tracks/{track.uuid_id}",
            json={"base_revision": track.revision, "codec": "mp3"},
        )
        assert r.status_code == 422, r.text

    def test_patch__missing_base_revision__422(self, client):
        track = self._add_one(client)
        r = client.patch(f"/tracks/{track.uuid_id}", json={"title": "X"})
        assert r.status_code == 422, r.text

    def test_patch__null_base_revision__409_conflict_not_422(self, client):
        # Option A: a NULL client-side revision means "unknown base" and must
        # force the conflict-prompt path (do NOT treat NULL as 0). The client
        # really sends null — e.g. resolveKeepMine rebasing onto an
        # unparseable 409 body. A 422 would be fatal client-side: the outbox
        # treats 422 as a permanent rejection and silently reverts + discards
        # the user's edit, so null must get the 409 conflict shape instead.
        track = self._add_one(client)
        r = client.patch(
            f"/tracks/{track.uuid_id}",
            json={"base_revision": None, "title": "Renamed"},
        )
        assert r.status_code == 409, r.text
        body = r.json()
        assert body["detail"]["error"] == "revision_conflict"
        assert body["detail"]["current_revision"] == track.revision

    def test_patch__blanks_whole_track__422(self, client):
        track = self._add_one(client)
        r = client.patch(
            f"/tracks/{track.uuid_id}",
            json={
                "base_revision": track.revision,
                "title": "",
                "artist": "",
                "album": "",
            },
        )
        assert r.status_code == 422, r.text

    def test_patch__db_and_master__missing_master_degrades_to_db_only(self, client):
        # The test track's file_path is a placeholder that doesn't exist on
        # disk, so db_and_master degrades to DB-only: the edit applies but the
        # response reports the master was not written.
        track = self._add_one(client)
        r = client.patch(
            f"/tracks/{track.uuid_id}",
            json={
                "base_revision": track.revision,
                "write_mode": "db_and_master",
                "title": "X",
            },
        )
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["master_written"] is False
        assert body["revision"] > track.revision
