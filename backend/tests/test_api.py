from datetime import UTC, datetime
from pathlib import Path
from typing import List, Set

import pytest
from fastapi.testclient import TestClient

from app.models import GetArtistsResponse, GetTracksResponse, Track, TrackMetaData
from app.models.client_track import ClientTrack


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("APP_DATA_DIR", str(tmp_path / "data"))
    monkeypatch.setenv("MUSIC_LIBRARY_DIR", str(tmp_path / "music"))
    monkeypatch.setenv("IMPORT_DIR", str(tmp_path / "import"))
    monkeypatch.setenv("ENABLE_FILE_WATCHER", "false")

    from app.main import app

    with TestClient(app) as c:
        yield c


# Tests assume that each track has a unique artist and album
def add_tracks_to_client(client, amount_to_add: int = 1) -> List[Track]:
    tracks = []
    for i in range(amount_to_add):
        metadata = TrackMetaData(
            title=f"song_{i}", album=f"album_{i}", artist=f"artist_{i}", duration=1.0
        )
        track = Track(file_path=Path(f"path_{i}"), metadata=metadata)
        tracks.append(track)

    for track in tracks:
        track_added = client.app.state.database.add_track(track)
        assert track_added

    return tracks


class TestGetTracks:
    def test_tracks__default__returns_track(self, client):
        tracks = add_tracks_to_client(client=client, amount_to_add=5)

        r = client.get("/tracks")
        assert r.status_code == 200, r.text

        gettracksresponse = GetTracksResponse.model_validate_json(r.json())
        assert gettracksresponse

        gotten_tracks = gettracksresponse.data

        assert len(gotten_tracks) == len(tracks)
        assert sorted(t.uuid_id for t in gotten_tracks) == sorted(
            t.uuid_id for t in tracks
        )

    def test_tracks__cursor_logic__works(self, client):
        tracks = add_tracks_to_client(client=client, amount_to_add=10)

        returned_tracks = []

        r = client.get("/tracks?limit=1")
        assert r.status_code == 200, r.text

        gettracksresponse = GetTracksResponse.model_validate_json(r.json())

        assert gettracksresponse is not None
        assert gettracksresponse.nextCursor is not None
        assert len(gettracksresponse.data) == 1

        returned_tracks.append(gettracksresponse.data[0])

        nextCursor = gettracksresponse.nextCursor

        while nextCursor:
            r = client.get("/tracks?limit=1")
            assert r.status_code == 200, r.text

            gettracksresponse = GetTracksResponse.model_validate_json(r.json())

            assert gettracksresponse is not None
            nextCursor = gettracksresponse.nextCursor

            assert len(gettracksresponse.data) == 1
            returned_tracks.append(gettracksresponse.data[0])

        assert len(returned_tracks) == len(tracks)
        assert sorted(t.uuid_id for t in returned_tracks) == sorted(
            t.uuid_id for t in tracks
        )

    def test_tracks__older_than__works(self, client):
        metadata = TrackMetaData(duration=1.0)

        now = int(datetime.now(UTC).timestamp())
        track = Track(
            metadata=metadata,
            file_path=Path("whatever.mp3"),
            created_at=now,
            last_updated=now,
        )

        track_added = client.app.state.database.add_track(track)
        assert track_added

        # Check if track gets returned older_than is 1 second past now
        r = client.get(f"/tracks?older_than={now + 1}")

        assert r.status_code == 200, r.text

        gettracksresponse = GetTracksResponse.model_validate_json(r.json())

        assert gettracksresponse
        assert gettracksresponse.nextCursor is None
        assert gettracksresponse.data
        assert len(gettracksresponse.data) == 1
        assert gettracksresponse.data[0].uuid_id == track.uuid_id

        # Check if track does not get returned older_than is 1 before now
        r = client.get(f"/tracks?older_than={now - 1}")

        assert r.status_code == 200, r.text

        gettracksresponse = GetTracksResponse.model_validate_json(r.json())

        assert gettracksresponse
        assert gettracksresponse.nextCursor is None
        assert len(gettracksresponse.data) == 0

    def test_tracks__limit_offset__works(self, client):
        tracks = add_tracks_to_client(client=client, amount_to_add=5)

        gotten_tracks: List[ClientTrack] = []
        for i in range(len(tracks)):
            r = client.get(f"/tracks?limit=1&offset={i}")

            assert r.status_code == 200, r.text

            gettracksresponse = GetTracksResponse.model_validate_json(r.json())

            assert gettracksresponse
            assert len(gettracksresponse.data) == 1
            gotten_tracks.append(gettracksresponse.data[0])

        assert sorted(t.uuid_id for t in gotten_tracks) == sorted(
            t.uuid_id for t in tracks
        )

    def test_tracks__bad_limit_offset__fails(self, client):
        # Ensure that database is populated so no other codes return
        tracks = add_tracks_to_client(client=client, amount_to_add=5)

        # Bad limit tests
        r = client.get("/tracks?limit=0")
        assert r.status_code == 400, r.text

        r = client.get("/tracks?limit=-1")
        assert r.status_code == 400, r.text

        r = client.get("/tracks?limit=1000")
        assert r.status_code == 400, r.text

        # Bad offset tests
        r = client.get("/tracks?offset=-1")
        assert r.status_code == 400, r.text

        r = client.get("/tracks?offset=1000")
        assert r.status_code == 200, r.text


class TestGetTracksStream:
    def test_tracks_stream__invalid_uuid__fails(self, client):
        tracks = add_tracks_to_client(client=client, amount_to_add=5)
        r = client.get("/tracks/fake_uuid/stream")
        assert r.status_code == 404, r.text

    def test_tracks_stream__valid_uuid__streams(self, client, tmp_path: Path):
        metadata = TrackMetaData(duration=1.0)

        track_path = tmp_path / "track.mp3"
        track = Track(file_path=track_path, metadata=metadata)
        data = b"track" * 1000
        track_path.write_bytes(data)

        track_added = client.app.state.database.add_track(track=track)
        assert track_added

        # Get tracks uuid_id
        r = client.get("/tracks")
        assert r.status_code == 200, r.text

        gettrackresponse = GetTracksResponse.model_validate_json(r.json())

        assert gettrackresponse

        assert gettrackresponse.data

        gotten_track = gettrackresponse.data[0]
        assert gotten_track

        track_uuid = gotten_track.uuid_id

        # Stream the whole track
        with client.stream("GET", f"/tracks{track_uuid}/stream") as resp:
            assert resp.status_code == 200
            assert resp.headers.get("accept-ranges") == "bytes"
            assert int(resp.headers["content-length"]) == len(data)
            body = b"".join(resp.iter_bytes())

        assert body == data

        # Stream some specific bytes of the track_file
        headers = {"Range": "bytes=10-19"}
        with client.stream(
            "GET", f"/tracks{track_uuid}/stream", headers=headers
        ) as resp:
            assert resp.status_code == 206
            assert resp.headers["content-range"].startswith("bytes 10-19/")
            assert int(resp.headers["content-length"]) == 10
            body = b"".join(resp.iter_bytes())

        assert body == data[10:20]


class TestGetArtists:
    def test_artists__default__returns_artists(self, client):
        tracks = add_tracks_to_client(client=client, amount_to_add=5)
        expected_artists = {track.metadata.artist for track in tracks}

        r = client.get("/artists")
        assert r.status_code == 200, r.text

        getartistresponse = GetArtistsResponse.model_validate_json(r.json())

        assert getartistresponse

        gotten_artists = {artist for artist in getartistresponse.data}
        assert gotten_artists == expected_artists
        assert len(expected_artists) == len(getartistresponse.data)

    def test_artists__limit_offset__works(self, client):
        tracks = add_tracks_to_client(client=client, amount_to_add=2)
        expected_artists = {track.metadata.artist for track in tracks}

        r = client.get("/artists?limit=1")
        assert r.status_code == 200, r.text

        first_response = GetArtistsResponse.model_validate_json(r.json())
        assert first_response
        assert len(first_response.data) == 1
        assert first_response.data[0] in expected_artists

        r = client.get("/artists?limit=1&offset=1")
        assert r.status_code == 200, r.text

        second_response = GetArtistsResponse.model_validate_json(r.json())
        assert second_response
        assert len(second_response.data) == 1
        assert second_response.data[0] in expected_artists

        all_gotten_artists = set(first_response.data + second_response.data)

        assert all_gotten_artists == expected_artists

    def test_artists__bad_limit_offset__fails(self, client):
        # Add tracks to database so no other errors get thrown
        tracks = add_tracks_to_client(client=client, amount_to_add=5)

        # Bad limit tests
        r = client.get("/artists?limit=0")
        assert r.status_code == 400, r.text

        r = client.get("/artists?limit=-1")
        assert r.status_code == 400, r.text

        r = client.get("/artists?limit=1000")
        assert r.status_code == 400, r.text

        # Bad offset tests
        r = client.get("/artists?offset=-1")
        assert r.status_code == 400, r.text

        r = client.get("/artists?offset=1000")
        assert r.status_code == 200, r.text


class TestGetArtistsAlbums:
    def test_artists_albums__invalid_artist__returns_empty(self, client):
        add_tracks_to_client(client=client, amount_to_add=1)

        r = client.get("/artists/fake_artist/albums")
        assert r.status_code == 200, r.text

        getartistresponse = GetArtistsResponse.model_validate_json(r.json())
        assert getartistresponse
        assert len(getartistresponse.data) == 0

    def test_artsits_albums__no_albums__returns_empty(self, client):
        metadata = TrackMetaData(artist="artist", duration=1.0)
        track = Track(metadata=metadata, file_path=Path("fake.mp3"))

        client.app.state.database.add_track(track=track)

        r = client.get("/artists/artist/albums")
        assert r.status_code == 200, r.text

        getartistresponse = GetArtistsResponse.model_validate_json(r.json())
        assert getartistresponse
        assert len(getartistresponse.data) == 0

    def test_artsits_albums__has_albums__returns_albums(self, client):
        tracks = add_tracks_to_client(client=client, amount_to_add=5)
        albums: dict[str, Set[str]] = {}
        for track in tracks:
            artist = track.metadata.artist
            album = track.metadata.album

            if artist is None or album is None:
                continue

            if artist == "" or album == "":
                continue

            if artist not in albums:
                albums[artist] = set()

            albums[artist].add(album)

        for artist in albums:
            expected_albums = albums[artist]
            r = client.get(f"/artists/{artist}/albums")
            assert r.status_code == 200, r.text

            getartistresponse = GetArtistsResponse.model_validate_json(r.json())
            assert getartistresponse

            gotten_albums = getartistresponse.data
            set_gotten_albums = set(gotten_albums)
            assert len(gotten_albums) == len(set_gotten_albums)
            assert set_gotten_albums == expected_albums

    def test_artsits_albums__limit_offset__works(self, client):
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

        gotten_albums: List[str] = []
        for i in range(len(albums)):
            r = client.get(f"/artists/{artist}/albums?limit=1&offset={i}")
            assert r.status_code == 200, r.text

            getartistresponse = GetArtistsResponse.model_validate_json(r.json())
            assert getartistresponse
            assert len(getartistresponse.data) == 1

            gotten_album = getartistresponse.data[0]
            assert gotten_album not in gotten_albums
            assert gotten_album in albums

            gotten_albums.append(gotten_album)

        assert len(gotten_albums) == len(albums)
        assert set(gotten_albums) == albums

    def test_artists_albums__bad_limit_offset__fails(self, client):
        artist = "artist"

        for i in range(3):
            album = f"album_{i}"
            metadata = TrackMetaData(artist=artist, album=album, duration=1.0)
            file_path = Path(f"track_{i}")
            track = Track(metadata=metadata, file_path=file_path)
            track_added = client.app.state.database.add_track(track=track)
            assert track_added

        # Bad limit tests
        r = client.get("/artists/artist/albums?limit=0")
        assert r.status_code == 400, r.text

        r = client.get("/artists/artist/albums?limit=-1")
        assert r.status_code == 400, r.text

        r = client.get("/artists/artist/albums?limit=1000")
        assert r.status_code == 400, r.text

        # Bad offset tests
        r = client.get("/artists/artist/albums?offset=-1")
        assert r.status_code == 400, r.text

        r = client.get("/artists/artist/albums?offset=1000")
        assert r.status_code == 200, r.text
