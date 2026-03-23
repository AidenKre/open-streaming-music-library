import sqlite3
from datetime import UTC, datetime
from pathlib import Path
from typing import List
from unittest.mock import patch

import pytest

from app.database.database import (
    ALLOWED_METADATA_COLUMNS,
    AlbumOrderParameter,
    AlbumRowFilterParameter,
    ArtistOrderParameter,
    ArtistRowFilterParameter,
    Database,
    DatabaseContext,
    OrderParameter,
    RowFilterParameter,
    SearchEntityType,
    SearchParameter,
    prepare_fts_query,
)
from app.models.album import Album
from app.models.artist import Artist
from app.models.track import Track
from app.models.track_meta_data import TrackMetaData


def set_up_database(database_path: Path):
    context = DatabaseContext(
        database_path=database_path,
        init_sql_path=Path(__file__).parent.parent / "app" / "database" / "init.sql",
    )
    return Database(context=context)


def seed_metadata():
    metadata = TrackMetaData(
        codec="test",
        duration=2.0,
        bitrate_kbps=320.0,
        sample_rate_hz=44,
        channels=2,
    )
    return metadata


def create_track(path, title, artist, album_artist=None):
    metadata = seed_metadata()

    metadata.title = title
    metadata.artist = artist
    if album_artist:
        metadata.album_artist = album_artist

    track = Track(file_path=path, metadata=metadata)

    return track


def get_artist_id(database, name):
    """Look up an artist_id by name (case-insensitive) from the artists table."""
    artists = database.get_artists(limit=1000)
    if artists is None:
        return None
    for a in artists:
        if a.name.lower() == name.lower():
            return a.id
    return None


def get_album_id(database, album_name, artist_id):
    """Look up an album_id by album name and artist_id."""
    albums = database.get_albums(artist_id=artist_id, limit=1000)
    if albums is None:
        return None
    for a in albums:
        if a.name is not None and a.name.lower() == album_name.lower():
            return a.id
    return None


class TestDatabaseInitialize:
    def test_initialize__database_does_not_exist__gets_created(self, tmp_path: Path):
        database_path = tmp_path / "database.db"
        database = set_up_database(database_path=database_path)
        result = database.initialize()

        assert result

        assert database_path.exists()

        conn = sqlite3.connect(database_path)

        conn.row_factory = sqlite3.Row

        cur = conn.cursor()

        res = cur.execute("SELECT name FROM sqlite_master WHERE type='table';")

        db_names = [row["name"] for row in res.fetchall()]

        assert "tracks" in db_names
        assert "trackmetadata" in db_names
        assert "artists" in db_names
        assert "albums" in db_names

        conn.close()

    def test_initialize__database_does_exist__does_not_overwrite(self, tmp_path: Path):
        database_path = tmp_path / "database.db"

        conn = sqlite3.connect(database_path)
        cur = conn.cursor()
        fake_table_str = "this_table_is_not_real"
        cur.execute(f"CREATE TABLE {fake_table_str} ('id' INTEGER PRIMARY KEY);")
        conn.commit()
        conn.close()

        database = set_up_database(database_path=database_path)
        result = database.initialize()

        assert result

        conn = sqlite3.connect(database_path)
        conn.row_factory = sqlite3.Row
        cur = conn.cursor()

        res = cur.execute("SELECT name FROM sqlite_master WHERE type='table';")

        table_names = [row["name"] for row in res.fetchall()]

        assert fake_table_str in table_names

    def test_initialize__database_error__returns_false(self, tmp_path: Path):
        database_path = tmp_path / "database.db"

        with patch("app.database.database.sqlite3") as sqlite:
            sqlite.connect.side_effect = Exception("Database error!")

            database = set_up_database(database_path=database_path)
            result = database.initialize()

            assert result is False
            assert not database_path.exists()


class TestDatabaseAddTrack:
    def test_add_track__empty__returns_false(self, tmp_path: Path):
        file_path = tmp_path / "fake_track"
        empty_track = Track(file_path=file_path, metadata=TrackMetaData())
        database_path = tmp_path / "database.db"
        database = set_up_database(database_path=database_path)
        database.initialize()

        track_added = database.add_track(track=empty_track, timeout=0.1)
        print(empty_track.metadata)
        assert not track_added

        conn = sqlite3.connect(database_path)

        cur = conn.cursor()

        res = cur.execute(
            "SELECT * FROM tracks WHERE file_path = ?;", (str(file_path),)
        )

        found_tracks = res.fetchall()
        assert len(found_tracks) == 0

    def test_add_track__db_not_initialized__returns_false(self, tmp_path: Path):
        file_path = tmp_path / "track.mp3"
        metadata = TrackMetaData(
            codec="test",
            duration=2.0,
            bitrate_kbps=320.0,
            sample_rate_hz=44,
            channels=2,
        )

        track = Track(
            file_path=file_path,
            metadata=metadata,
        )

        database_path = tmp_path / "database.db"
        database = set_up_database(database_path)

        track_added = database.add_track(track=track, timeout=5)
        assert not track_added

        conn = sqlite3.connect(database_path)

        cur = conn.cursor()

        res = cur.execute("SELECT name FROM sqlite_master WHERE type='table';")
        tracks_added = res.fetchall()

        assert len(tracks_added) == 0

    def test_add_track__db_busy__returns_false(self, tmp_path: Path):
        database_path = tmp_path / "database.db"
        database = set_up_database(database_path)

        database.initialize()

        blocking_conn = sqlite3.connect(database_path)
        blocking_conn.execute("BEGIN EXCLUSIVE")

        file_path = tmp_path / "track.mp3"
        metadata = TrackMetaData(
            codec="test",
            duration=2.0,
            bitrate_kbps=320.0,
            sample_rate_hz=44,
            channels=2,
        )

        track = Track(
            file_path=file_path,
            metadata=metadata,
        )

        track_added = database.add_track(track=track, timeout=0.05)
        blocking_conn.close()
        assert not track_added

    def test_add_track__invalid_uuid__returns_false(self, tmp_path: Path):
        database_path = tmp_path / "database.db"
        # seed the database with some data
        database = set_up_database(database_path)
        database.initialize()

        file_path_1 = tmp_path / "track_1.mp4"
        file_path_2 = tmp_path / "track_2.mp4"

        metadata = TrackMetaData(
            codec="test",
            duration=2.0,
            bitrate_kbps=320.0,
            sample_rate_hz=44,
            channels=2,
        )

        track_1 = Track(
            uuid_id="a",
            file_path=file_path_1,
            metadata=metadata,
        )

        track_2 = Track(
            uuid_id="a",
            file_path=file_path_2,
            metadata=metadata,
        )

        track_1_added = database.add_track(track=track_1, timeout=1)
        track_2_added = database.add_track(track=track_2, timeout=1)

        assert track_1_added
        assert not track_2_added

    def test_add_track__duplicate_hash__returns_false(self, tmp_path: Path):
        database_path = tmp_path / "database.db"
        database = set_up_database(database_path)
        database.initialize()

        file_path_1 = tmp_path / "track_1.mp4"
        file_path_2 = tmp_path / "track_2.mp4"

        metadata = TrackMetaData(
            codec="test",
            duration=2.0,
            bitrate_kbps=320.0,
            sample_rate_hz=44,
            channels=2,
        )

        track_1 = Track(
            file_hash="a",
            file_path=file_path_1,
            metadata=metadata,
        )

        track_2 = Track(
            file_hash="a",
            file_path=file_path_2,
            metadata=metadata,
        )

        track_1_added = database.add_track(track=track_1, timeout=1)
        track_2_added = database.add_track(track=track_2, timeout=1)

        assert track_1_added
        assert not track_2_added

    def test_add_track__valid_tracks__add_to_database(self, tmp_path: Path):
        database_path = tmp_path / "database.db"
        # seed the database with some data
        database = set_up_database(database_path)
        database.initialize()

        def execute_query(query: str):
            conn = sqlite3.connect(database_path)
            cur = conn.cursor()
            res = cur.execute(query)
            tracks = res.fetchall()
            conn.close()
            return tracks

        track_1_path = tmp_path / "track_1.mp3"
        track_2_path = tmp_path / "track_2.mp3"
        track_3_path = tmp_path / "track_3.mp3"
        track_4_path = tmp_path / "track_4.mp3"

        track_1 = create_track(track_1_path, "title_1", "artist")
        track_2 = create_track(track_2_path, "title_2", "artist")
        track_3 = create_track(track_3_path, "title_3", "artist")
        track_4 = create_track(track_4_path, "title_4", "artist")

        database.add_track(track_1, 1)

        query_result = execute_query("SELECT file_path FROM tracks;")
        assert len(query_result) == 1
        assert query_result[0] == (str(track_1_path),)

        query_result = execute_query("SELECT title FROM trackmetadata;")
        assert len(query_result) == 1
        assert query_result[0] == ("title_1",)

        database.add_track(track_2, 1)
        database.add_track(track_3, 1)
        database.add_track(track_4, 1)

        query_result = execute_query("SELECT file_path FROM tracks;")
        assert len(query_result) == 4

        assert set(query_result) == set(
            [
                (str(track_1_path),),
                (str(track_2_path),),
                (str(track_3_path),),
                (str(track_4_path),),
            ]
        )

        query_result = execute_query("SELECT title FROM trackmetadata;")
        assert len(query_result) == 4
        assert set(query_result) == set(
            [("title_1",), ("title_2",), ("title_3",), ("title_4",)]
        )

        # Verify the artists table is populated correctly
        query_result = execute_query("SELECT name FROM artists;")
        assert len(query_result) == 1
        assert query_result[0] == ("artist",)

        # Verify the albums table is populated (single grouping since no album set)
        query_result = execute_query("SELECT id, is_single_grouping FROM albums;")
        assert len(query_result) == 1
        assert query_result[0][1] == 1  # is_single_grouping

    def test_add_track__same_artist_different_casing__creates_one_artist_row(self, tmp_path):
        """Same artist with different casing should produce only one row in artists table."""
        database = set_up_database(database_path=tmp_path / "database.db")
        assert database.initialize()

        for i, name in enumerate(["MyArtist", "myartist", "MYARTIST", "myArtist"]):
            track = create_track(tmp_path / f"t{i}.mp3", f"song_{i}", name)
            assert database.add_track(track=track)

        artists = database.get_artists(limit=1000)
        assert artists is not None
        assert len(artists) == 1
        # The first inserted name wins
        assert artists[0].name == "MyArtist"

    def test_add_track__album_artist_set__uses_album_artist_for_artist_row(self, tmp_path):
        """When album_artist is set, it should be used for the artists table entry."""
        database = set_up_database(database_path=tmp_path / "database.db")
        assert database.initialize()

        track = create_track(tmp_path / "t.mp3", "song", "feat_artist", "MainArtist")
        assert database.add_track(track=track)

        artists = database.get_artists(limit=1000)
        assert artists is not None
        artist_names = [a.name for a in artists]
        assert "MainArtist" in artist_names
        assert "feat_artist" not in artist_names

    def test_add_track__same_album_same_artist__creates_one_album_row(self, tmp_path):
        """Same album+artist should produce only one album row."""
        database = set_up_database(database_path=tmp_path / "database.db")
        assert database.initialize()

        for i in range(3):
            track = create_track(tmp_path / f"t{i}.mp3", f"song_{i}", "artist")
            track.metadata.album = "TheAlbum"
            assert database.add_track(track=track)

        artist_id = get_artist_id(database, "artist")
        assert artist_id is not None
        albums = database.get_albums(artist_id=artist_id)
        assert albums is not None
        regular = [a for a in albums if not a.is_single_grouping]
        assert len(regular) == 1
        assert regular[0].name == "TheAlbum"

    def test_add_track__no_album__creates_single_grouping(self, tmp_path):
        """Tracks without album should create a single grouping entry."""
        database = set_up_database(database_path=tmp_path / "database.db")
        assert database.initialize()

        for i in range(3):
            track = create_track(tmp_path / f"t{i}.mp3", f"song_{i}", "artist")
            assert database.add_track(track=track)

        artist_id = get_artist_id(database, "artist")
        assert artist_id is not None
        albums = database.get_albums(artist_id=artist_id)
        assert albums is not None
        assert len(albums) == 1
        assert albums[0].is_single_grouping is True
        assert albums[0].name is None

    def test_add_track__higher_year_track__updates_album_year(self, tmp_path):
        """Adding a track with higher year should update the album year."""
        database = set_up_database(database_path=tmp_path / "database.db")
        assert database.initialize()

        track1 = create_track(tmp_path / "t1.mp3", "song_1", "artist")
        track1.metadata.album = "AlbumX"
        track1.metadata.year = 2015
        assert database.add_track(track=track1)

        artist_id = get_artist_id(database, "artist")
        assert artist_id is not None
        albums = database.get_albums(artist_id=artist_id)
        regular = [a for a in albums if not a.is_single_grouping]
        assert regular[0].year == 2015

        track2 = create_track(tmp_path / "t2.mp3", "song_2", "artist")
        track2.metadata.album = "AlbumX"
        track2.metadata.year = 2020
        assert database.add_track(track=track2)

        albums = database.get_albums(artist_id=artist_id)
        regular = [a for a in albums if not a.is_single_grouping]
        assert len(regular) == 1
        assert regular[0].year == 2020


class TestDatabaseDeleteTrack:
    def test_delete_track__db_not_initialized__returns_false(self, tmp_path: Path):
        database_path = tmp_path / "database.db"
        database = set_up_database(database_path)

        track_deleted = database.delete_track(uuid_id="missing")
        assert track_deleted is False

    def test_delete_track__missing_uuid__returns_false(self, tmp_path: Path):
        database_path = tmp_path / "database.db"
        database = set_up_database(database_path)
        database.initialize()

        track_deleted = database.delete_track(uuid_id="missing")
        assert track_deleted is False

    def test_delete_track__db_busy__returns_false(self, tmp_path: Path):
        database_path = tmp_path / "database.db"
        database = set_up_database(database_path)
        database.initialize()

        blocking_conn = sqlite3.connect(database_path)
        blocking_conn.execute("BEGIN EXCLUSIVE")

        track_deleted = database.delete_track(uuid_id="missing", timeout=0.05)
        assert track_deleted is False

        blocking_conn.close()

    def test_delete_track__valid_uuid__deletes_tracks_and_trackmetadata(
        self, tmp_path: Path
    ):
        database_path = tmp_path / "database.db"
        database = set_up_database(database_path)
        database.initialize()

        def execute_query(query: str, params: tuple = ()):
            conn = sqlite3.connect(database_path)
            cur = conn.cursor()
            res = cur.execute(query, params)
            rows = res.fetchall()
            conn.close()
            return rows

        file_path = tmp_path / "track_1.mp3"
        metadata = TrackMetaData(
            title="title",
            artist="artist",
            codec="test",
            duration=2.0,
            bitrate_kbps=320.0,
            sample_rate_hz=44,
            channels=2,
        )

        uuid_id = "test_uuid"
        track = Track(
            uuid_id=uuid_id,
            file_path=file_path,
            metadata=metadata,
        )

        track_added = database.add_track(track=track, timeout=1)
        assert track_added

        track_deleted = database.delete_track(uuid_id=uuid_id)
        assert track_deleted

        query_result = execute_query(
            "SELECT uuid_id FROM tracks WHERE uuid_id = ?;", (uuid_id,)
        )
        assert len(query_result) == 0

        query_result = execute_query(
            "SELECT uuid_id FROM trackmetadata WHERE uuid_id = ?;", (uuid_id,)
        )
        assert len(query_result) == 0

        # Verify orphaned artist is cleaned up
        query_result = execute_query("SELECT * FROM artists;")
        assert len(query_result) == 0

        # Verify orphaned album is cleaned up
        query_result = execute_query("SELECT * FROM albums;")
        assert len(query_result) == 0

    def test_delete_track__last_track_for_artist__removes_orphaned_artist(self, tmp_path):
        """Deleting the last track for an artist should remove the artist row."""
        database = set_up_database(database_path=tmp_path / "database.db")
        assert database.initialize()

        track = create_track(tmp_path / "t.mp3", "song", "LonelyArtist")
        track.uuid_id = "lonely_uuid"
        assert database.add_track(track=track)

        artists = database.get_artists(limit=1000)
        assert artists is not None
        assert len(artists) == 1

        assert database.delete_track(uuid_id="lonely_uuid")

        artists = database.get_artists(limit=1000)
        assert artists is not None
        assert len(artists) == 0

    def test_delete_track__last_track_for_album__removes_orphaned_album(self, tmp_path):
        """Deleting the last track for an album should remove the album row."""
        database = set_up_database(database_path=tmp_path / "database.db")
        assert database.initialize()

        track = create_track(tmp_path / "t.mp3", "song", "artist")
        track.metadata.album = "LonelyAlbum"
        track.uuid_id = "lonely_album_uuid"
        assert database.add_track(track=track)

        artist_id = get_artist_id(database, "artist")
        assert artist_id is not None
        albums = database.get_albums(artist_id=artist_id)
        assert albums is not None
        assert len(albums) == 1

        assert database.delete_track(uuid_id="lonely_album_uuid")

        # Artist should also be gone (orphan cleanup)
        artists = database.get_artists(limit=1000)
        assert artists is not None
        assert len(artists) == 0

        # Albums table should be empty
        conn = sqlite3.connect(tmp_path / "database.db")
        cur = conn.cursor()
        res = cur.execute("SELECT COUNT(*) FROM albums;")
        assert res.fetchone()[0] == 0
        conn.close()


class TestDatabaseGetTracks:
    def test_get_tracks__db_not_initialized__returns_empty_list(self, tmp_path: Path):
        database_path = tmp_path / "database.db"
        database = set_up_database(database_path)

        search_parameters = [
            SearchParameter(column="title", operator="=", value="test")
        ]

        returned_tracks = database.get_tracks(search_parameters=search_parameters)
        assert len(returned_tracks) == 0

    def test_get_tracks__empty_db__returns_empty_list(self, tmp_path: Path):
        database_path = tmp_path / "database.db"
        database = set_up_database(database_path)

        assert database.initialize()

        search_parameters = [
            SearchParameter(column="title", operator="=", value="test")
        ]

        returned_tracks = database.get_tracks(search_parameters=search_parameters)
        assert len(returned_tracks) == 0

    def test_get_tracks__invalid_columns__throws_error(self, tmp_path: Path):
        database_path = tmp_path / "database.db"
        database = set_up_database(database_path)

        assert database.initialize()

        with pytest.raises(ValueError):
            search_parameters = [
                SearchParameter(column="invalid_column", operator="=", value="test")
            ]
            database.get_tracks(search_parameters=search_parameters)

        with pytest.raises(ValueError):
            order_parameters = [OrderParameter(column="invalid_column")]
            database.get_tracks(order_parameters=order_parameters)

    def test_get_tracks__valid_search__returns_results(self, tmp_path: Path):
        database_path = tmp_path / "database.db"
        database = set_up_database(database_path)

        assert database.initialize()

        track_1_path = tmp_path / "track_1.mp3"
        track_2_path = tmp_path / "track_2.mp3"
        track_3_path = tmp_path / "track_3.mp3"
        track_4_path = tmp_path / "track_4.mp3"
        track_5_path = tmp_path / "track_5.mp3"

        track_1 = create_track(track_1_path, "title_1", "artist")
        track_2 = create_track(track_2_path, "title_2", "artist")
        track_3 = create_track(track_3_path, "title_3", "artist")
        track_4 = create_track(track_4_path, "title_4", "artist")
        track_5 = create_track(track_5_path, "title_5", "different_artist")

        assert database.add_track(track=track_1, timeout=1)
        assert database.add_track(track=track_2, timeout=1)
        assert database.add_track(track=track_3, timeout=1)
        assert database.add_track(track=track_4, timeout=1)
        assert database.add_track(track=track_5, timeout=1)

        # Searching by artist returns only the specified artists
        search_parameters = [
            SearchParameter(column="artist", operator="=", value="artist")
        ]

        returned_tracks = database.get_tracks(search_parameters=search_parameters)

        assert len(returned_tracks) == 4

        titles = []
        for track in returned_tracks:
            assert track.metadata.artist == "artist"
            titles.append(track.metadata.title)

        assert len(titles) == 4

        # Artist + title search returns just the specific track
        search_parameters = [
            SearchParameter(column="artist", operator="=", value="artist"),
            SearchParameter(column="title", operator="=", value="title_1"),
        ]
        returned_tracks = database.get_tracks(search_parameters=search_parameters)

        assert len(returned_tracks) == 1

        assert returned_tracks[0].metadata.title == "title_1"

        # Empty search returns all tracks
        search_parameters = []
        returned_tracks = database.get_tracks(search_parameters=search_parameters)

        titles = []
        for track in returned_tracks:
            titles.append(track.metadata.title)

        assert len(titles) == 5

        artists = set()
        for track in returned_tracks:
            artists.add(track.metadata.artist)

        assert len(artists) == 2
        assert "artist" in artists
        assert "different_artist" in artists

    def test_get_tracks__order_by__returns_ordered_results(self, tmp_path: Path):
        database_path = tmp_path / "database.db"
        database = set_up_database(database_path)

        assert database.initialize()

        for i in range(5):
            track = create_track(tmp_path / f"track_{i}.mp3", f"title_{i}", "artist")
            assert database.add_track(track=track, timeout=1)

        order_by_asc = [OrderParameter(column="title", isAscending=True)]

        returned_tracks = database.get_tracks(order_parameters=order_by_asc)
        assert returned_tracks
        assert len(returned_tracks) == 5

        returned_titles = [
            t.metadata.title for t in returned_tracks if t.metadata.title
        ]
        assert sorted(returned_titles) == returned_titles

        order_by_desc = [OrderParameter(column="title", isAscending=False)]

        returned_tracks = database.get_tracks(order_parameters=order_by_desc)
        assert returned_tracks
        assert len(returned_tracks) == 5

        returned_titles = [
            t.metadata.title for t in returned_tracks if t.metadata.title
        ]
        assert sorted(returned_titles, reverse=True) == returned_titles

    def test_get_tracks__limit_offset__works(self, tmp_path: Path):
        database_path = tmp_path / "database.db"
        database = set_up_database(database_path)

        assert database.initialize()

        expected_tracks: List[Track] = []
        for i in range(5):
            track = create_track(tmp_path / f"track_{i}.mp3", f"title_{i}", "artist")
            assert database.add_track(track=track, timeout=1)
            expected_tracks.append(track)

        returned_tracks: List[Track] = []
        for i in range(5):
            returned_track = database.get_tracks(limit=1, offset=i)
            assert len(returned_track) == 1
            returned_tracks.append(returned_track[0])

        assert len(returned_tracks) == len(expected_tracks)
        returned_uuids = {t.uuid_id for t in returned_tracks}
        for track in expected_tracks:
            assert track.uuid_id in returned_uuids

    def test_get_artists__bad_limit_offset__fails(self, tmp_path):
        database = set_up_database(database_path=tmp_path / "database.db")
        assert database.initialize()

        for i in range(5):
            artist = f"artist_{i}"
            title = f"song_{i}"
            file_path = tmp_path / title
            track = create_track(file_path, title, artist)

            track_added = database.add_track(track=track)
            assert track_added

        with pytest.raises(ValueError):
            database.get_tracks(limit=0)

        with pytest.raises(ValueError):
            database.get_tracks(limit=-1)

        with pytest.raises(ValueError):
            database.get_tracks(limit=2000)

        with pytest.raises(ValueError):
            database.get_tracks(offset=-1)

        returned_artists = database.get_tracks(offset=1000)
        assert returned_artists is not None
        assert len(returned_artists) == 0

    def test_get_tracks__track_search_parameters__work(self, tmp_path: Path):
        database_path = tmp_path / "database.db"
        database = set_up_database(database_path)

        assert database.initialize()

        now = int(datetime.now(UTC).timestamp())
        expected_tracks: List[Track] = []
        for i in range(5):
            track = create_track(tmp_path / f"track_{i}.mp3", f"title_{i}", "artist")
            track.created_at = now
            assert database.add_track(track=track, timeout=1)
            expected_tracks.append(track)

        search_parameter = [
            SearchParameter(column="created_at", operator=">", value=str(now - 1))
        ]

        returned_tracks = database.get_tracks(search_parameters=search_parameter)
        assert len(returned_tracks) == 5

        search_parameter = [
            SearchParameter(column="created_at", operator=">", value=str(now + 1))
        ]

        returned_tracks = database.get_tracks(search_parameters=search_parameter)
        assert len(returned_tracks) == 0

    def test_get_tracks__row_filter_parameters__work(self, tmp_path: Path):
        database_path = tmp_path / "database.db"
        database = set_up_database(database_path)

        assert database.initialize()

        for i in range(2):
            artist = f"artist_{i}"
            for j in range(2):
                album = f"album_{i}"
                for k in range(3):
                    title = f"song_{i}_{j}_{k}"
                    file_path = tmp_path / (title + ".mp3")
                    track = create_track(path=file_path, title=title, artist=artist)
                    track.metadata.album = album
                    assert database.add_track(track=track)

        columns: List[str] = [
            "artist",
            "album",
            "disc_number",
            "track_number",
            "uuid_id",
        ]

        order_parameters: List[OrderParameter] = []
        for column in columns:
            order_parameters.append(OrderParameter(column=column, isAscending=True))

        returned_tracks = database.get_tracks(
            order_parameters=order_parameters, limit=4
        )

        all_returned_uuids = set()
        all_returned_uuids.update([track.uuid_id for track in returned_tracks])

        last_track = returned_tracks[-1]
        row_filter_parameters: List[RowFilterParameter] = []
        for column in columns:
            if column in ALLOWED_METADATA_COLUMNS:
                param = RowFilterParameter(
                    column=column, value=str(getattr(last_track.metadata, column))
                )
            else:
                param = RowFilterParameter(
                    column=column, value=str(getattr(last_track, column))
                )

            row_filter_parameters.append(param)

        returned_tracks = database.get_tracks(
            order_parameters=order_parameters,
            row_filter_parameters=row_filter_parameters,
        )

        for track in returned_tracks:
            assert track.uuid_id not in all_returned_uuids

        returned_uuids = [track.uuid_id for track in returned_tracks]
        assert len(returned_uuids) == len(set(returned_uuids))

    def test_get_tracks__artist_filter__returns_matching_tracks(self, tmp_path):
        database_path = tmp_path / "database.db"
        database = set_up_database(database_path)
        database.initialize()

        # album=None means filter for IS NULL, so tracks here have no album
        track_a = create_track(tmp_path / "a.mp3", "song_a", "ArtistA")
        track_b = create_track(tmp_path / "b.mp3", "song_b", "ArtistB")
        assert database.add_track(track=track_a)
        assert database.add_track(track=track_b)

        artist_a_id = get_artist_id(database, "ArtistA")
        assert artist_a_id is not None
        results = database.get_tracks(artist_id=artist_a_id)
        assert len(results) == 1
        assert results[0].metadata.title == "song_a"

    def test_get_tracks__artist_and_album_filter__returns_matching_tracks(
        self, tmp_path
    ):
        database_path = tmp_path / "database.db"
        database = set_up_database(database_path)
        database.initialize()

        track_a = create_track(tmp_path / "a.mp3", "song_a", "Artist")
        track_a.metadata.album = "Album1"
        track_b = create_track(tmp_path / "b.mp3", "song_b", "Artist")
        track_b.metadata.album = "Album2"
        track_c = create_track(tmp_path / "c.mp3", "song_c", "Other")
        track_c.metadata.album = "Album1"
        assert database.add_track(track=track_a)
        assert database.add_track(track=track_b)
        assert database.add_track(track=track_c)

        artist_id = get_artist_id(database, "Artist")
        album_id = get_album_id(database, "Album1", artist_id)
        assert artist_id is not None
        assert album_id is not None
        results = database.get_tracks(artist_id=artist_id, album_id=album_id)
        assert len(results) == 1
        assert results[0].metadata.title == "song_a"

    def test_get_tracks__artist_with_null_album__returns_tracks_without_album(
        self, tmp_path
    ):
        database_path = tmp_path / "database.db"
        database = set_up_database(database_path)
        database.initialize()

        track_with_album = create_track(tmp_path / "a.mp3", "song_a", "Artist")
        track_with_album.metadata.album = "SomeAlbum"
        track_no_album = create_track(tmp_path / "b.mp3", "song_b", "Artist")
        assert database.add_track(track=track_with_album)
        assert database.add_track(track=track_no_album)

        # Use search parameter to filter for null album
        artist_id = get_artist_id(database, "Artist")
        assert artist_id is not None
        results = database.get_tracks(
            artist_id=artist_id,
            search_parameters=[
                SearchParameter(column="album", operator="=", value=None)
            ],
        )
        assert len(results) == 1
        assert results[0].metadata.title == "song_b"

    def test_get_tracks__album_without_artist__raises_value_error(self, tmp_path):
        database_path = tmp_path / "database.db"
        database = set_up_database(database_path)
        database.initialize()

        with pytest.raises(ValueError):
            database.get_tracks(album_id=1)

    def test_get_tracks__album_artist_filter__uses_album_artist(self, tmp_path):
        database_path = tmp_path / "database.db"
        database = set_up_database(database_path)
        database.initialize()

        track_aa = create_track(
            tmp_path / "a.mp3", "song_a", "feat_artist", "MainArtist"
        )
        track_aa.metadata.album = "TheAlbum"
        track_plain = create_track(tmp_path / "b.mp3", "song_b", "MainArtist")
        track_plain.metadata.album = "TheAlbum"
        track_other = create_track(tmp_path / "c.mp3", "song_c", "Other")
        track_other.metadata.album = "TheAlbum"
        assert database.add_track(track=track_aa)
        assert database.add_track(track=track_plain)
        assert database.add_track(track=track_other)

        artist_id = get_artist_id(database, "MainArtist")
        album_id = get_album_id(database, "TheAlbum", artist_id)
        assert artist_id is not None
        assert album_id is not None
        results = database.get_tracks(artist_id=artist_id, album_id=album_id)
        assert len(results) == 2
        titles = {r.metadata.title for r in results}
        assert titles == {"song_a", "song_b"}

    def test_get_tracks__album_artist_excludes_plain_artist(self, tmp_path):
        database_path = tmp_path / "database.db"
        database = set_up_database(database_path)
        database.initialize()

        track = create_track(tmp_path / "a.mp3", "song_a", "feat_artist", "MainArtist")
        track.metadata.album = "TheAlbum"
        assert database.add_track(track=track)

        # feat_artist should not have an artist entry since album_artist takes priority
        feat_id = get_artist_id(database, "feat_artist")
        assert feat_id is None

        # Even with search parameter on raw artist field, the artist_id filter
        # should work correctly
        main_id = get_artist_id(database, "MainArtist")
        assert main_id is not None
        results = database.get_tracks(artist_id=main_id)
        assert len(results) == 1


class TestGetTracksCount:
    def test_get_tracks_count__empty_db__returns_0(self, tmp_path):
        database_path = tmp_path / "database.db"
        database = set_up_database(database_path)

        assert database.initialize()
        assert database.get_tracks_count() == 0

    def test_get_tracks_count__non_empty_db__returns_count(self, tmp_path):
        database_path = tmp_path / "database.db"
        database = set_up_database(database_path)

        assert database.initialize()

        for i in range(5):
            track = create_track(tmp_path / f"track_{i}.mp3", f"title_{i}", "artist")
            assert database.add_track(track=track, timeout=1)

        assert database.get_tracks_count() == 5

    def test_get_tracks_count__search_parameters__filter_count(self, tmp_path):
        database_path = tmp_path / "database.db"
        database = set_up_database(database_path)

        assert database.initialize()

        for i in range(5):
            track = create_track(tmp_path / f"track_{i}.mp3", f"title_{i}", "artist_1")
            assert database.add_track(track=track, timeout=1)

        for i in range(5):
            track = create_track(tmp_path / f"track_{i}.mp3", f"title_{i}", "artist_2")
            assert database.add_track(track=track, timeout=1)

        expected_count = 5
        search_parameters: List[SearchParameter] = [
            SearchParameter(column="artist", operator="=", value="artist_1")
        ]

        returned_count = database.get_tracks_count(search_parameters=search_parameters)
        assert returned_count == expected_count

        search_parameters: List[SearchParameter] = [
            SearchParameter(column="artist", operator="=", value="artist_2")
        ]

        returned_count = database.get_tracks_count(search_parameters=search_parameters)
        assert returned_count == expected_count


class TestGetArtists:
    def test_get_artists__empty_db__returns_empty(self, tmp_path):
        database = set_up_database(database_path=tmp_path / "database.db")
        assert database.initialize()

        returned_artists = database.get_artists()
        assert returned_artists is not None
        assert len(returned_artists) == 0

    def test_get_artists__no_artists__returns_empty(self, tmp_path):
        database = set_up_database(database_path=tmp_path / "database.db")
        assert database.initialize()
        for i in range(5):
            track = create_track(tmp_path / f"song_{i}.mp3", f"song_{i}", None)
            track_added = database.add_track(track=track)
            assert track_added

        returned_artists = database.get_artists()
        assert returned_artists is not None
        assert len(returned_artists) == 0

    def test_get_artists__artists_exist__returns_artists(self, tmp_path):
        database = set_up_database(database_path=tmp_path / "database.db")
        assert database.initialize()
        expected_artists = set()
        for i in range(5):
            artist = f"artist_{i}"
            expected_artists.add(artist)
            for j in range(3):
                title = f"song_{j}"
                file_path = tmp_path / f"song_{i}_{j}.mp3"
                track = create_track(file_path, title, artist)
                track_added = database.add_track(track=track)
                assert track_added

        returned_artists = database.get_artists()
        assert returned_artists is not None
        returned_names = sorted([a.name for a in returned_artists])
        assert returned_names == sorted(expected_artists)

    def test_get_artists__album_artists_exist__returns_only_album_artists(
        self, tmp_path
    ):
        database = set_up_database(database_path=tmp_path / "database.db")
        assert database.initialize()
        expected_album_artists = set()

        # Each song has an album artist, so none of the artists here should
        # be returned. Only the album artists should be returned
        for i in range(5):
            album_artist = f"album_artist_{i}"
            expected_album_artists.add(album_artist)
            for j in range(3):
                artist = f"artist_{j}"
                title = f"song_{j}"
                file_path = tmp_path / f"song_{i}_{j}.mp3"
                track = create_track(file_path, title, artist, album_artist)
                track_added = database.add_track(track=track)
                assert track_added

        returned_artists = database.get_artists()
        assert returned_artists is not None
        returned_names = sorted([a.name for a in returned_artists])
        assert returned_names == sorted(expected_album_artists)

    def test_get_artsits__album_artists_and_artists__returns_both(self, tmp_path):
        # Make sure that one "artist" is also an artist for a track on an album that
        # has an album artist
        database = set_up_database(database_path=tmp_path / "database.db")
        assert database.initialize()
        expected_artists = set()

        for i in range(10):
            if i % 2 == 0:
                album_artist = f"album_artist_{i}"
                expected_artists.add(album_artist)
                for j in range(3):
                    artist = f"artist_{j}"
                    title = f"song_{j}"
                    file_path = f"song_{i}_{j}.mp3"
                    track = create_track(file_path, title, artist, album_artist)
                    track_added = database.add_track(track=track)
                    assert track_added
            else:
                artist = f"artist_{i}"
                expected_artists.add(artist)
                for j in range(3):
                    title = f"song_{j}"
                    file_path = tmp_path / f"song_{i}_{j}.mp3"
                    track = create_track(file_path, title, artist)
                    track_added = database.add_track(track=track)
                    assert track_added

        returned_artists = database.get_artists()
        assert returned_artists is not None
        returned_names = sorted([a.name for a in returned_artists])
        assert returned_names == sorted(expected_artists)

    def test_get_artist__no_duplicate_artists(self, tmp_path):
        database = set_up_database(database_path=tmp_path / "database.db")
        assert database.initialize()

        album_artist = "artist"
        artist = "artist"

        track_1 = create_track(tmp_path / "track_1.mp3", "track_1", artist)
        track_2 = create_track(
            tmp_path / "track_2.mp3", "track_2", artist, album_artist
        )

        assert database.add_track(track=track_1)
        assert database.add_track(track=track_2)

        returned_artist = database.get_artists()
        assert returned_artist
        assert len(returned_artist) == 1
        assert returned_artist[0].name == "artist"

    def test_get_artist__different_casing__returns_first_artist(self, tmp_path):
        database = set_up_database(database_path=tmp_path / "database.db")
        assert database.initialize()

        artist = "ArTiSt"
        duplicate_artists = [artist, artist.lower(), artist.upper()]

        for i, duplicate_artist in enumerate(duplicate_artists):
            title = f"song_{i}"
            file_path = tmp_path / (title + ".mp3")
            track = create_track(file_path, title, duplicate_artist)
            assert database.add_track(track=track)

        result = database.get_artists()
        assert result is not None
        assert len(result) == 1
        assert result[0].name == artist  # first inserted wins

    def test_get_artists__limit_offset__works(self, tmp_path):
        database = set_up_database(database_path=tmp_path / "database.db")
        assert database.initialize()
        expected_artists = set()

        for i in range(10):
            if i % 2 == 0:
                album_artist = f"album_artist_{i}"
                expected_artists.add(album_artist)
                for j in range(3):
                    artist = f"artist_{j * 4}"
                    title = f"song_{j}"
                    file_path = f"song_{i}_{j}.mp3"
                    track = create_track(file_path, title, artist, album_artist)
                    track_added = database.add_track(track=track)
                    assert track_added
            else:
                artist = f"artist_{i}"
                expected_artists.add(artist)
                for j in range(3):
                    title = f"song_{j}"
                    file_path = tmp_path / f"song_{i}_{j}.mp3"
                    track = create_track(file_path, title, artist)
                    track_added = database.add_track(track=track)
                    assert track_added

        returned_artists = []
        for i in range(len(expected_artists)):
            artist_list = database.get_artists(limit=1, offset=i)
            assert artist_list
            assert len(artist_list) == 1
            returned_artists.append(artist_list[0].name)

        returned_names = sorted(returned_artists)
        expected_sorted = sorted(expected_artists)
        assert len(expected_artists) == len(returned_artists)
        assert len(returned_artists) == len(set(returned_artists))
        assert expected_sorted == returned_names

    def test_get_artists__bad_limit_offset__fails(self, tmp_path):
        database = set_up_database(database_path=tmp_path / "database.db")
        assert database.initialize()

        for i in range(5):
            artist = f"artist_{i}"
            title = f"song_{i}"
            file_path = tmp_path / title
            track = create_track(file_path, title, artist)

            track_added = database.add_track(track=track)
            assert track_added

        with pytest.raises(ValueError):
            database.get_artists(limit=0)

        with pytest.raises(ValueError):
            database.get_artists(limit=-1)

        with pytest.raises(ValueError):
            database.get_artists(limit=2000)

        with pytest.raises(ValueError):
            database.get_artists(offset=-1)

        returned_artists = database.get_artists(offset=1000)
        assert returned_artists is not None
        assert len(returned_artists) == 0

    def test_get_artists__cursor_pagination__skips_before_cursor(self, tmp_path):
        database = set_up_database(database_path=tmp_path / "database.db")
        assert database.initialize()

        for name in ["Alice", "Bob", "Charlie"]:
            track = create_track(tmp_path / f"{name}.mp3", f"song_{name}", name)
            assert database.add_track(track=track)

        order_params = [ArtistOrderParameter(column="name", isAscending=True)]
        row_filters = [ArtistRowFilterParameter(column="name", value="Bob")]

        result = database.get_artists(
            order_parameters=order_params,
            row_filter_parameters=row_filters,
        )
        assert result is not None
        assert len(result) == 1
        assert result[0].name == "Charlie"

    def test_get_artists__cursor_pagination__across_pages(self, tmp_path):
        database = set_up_database(database_path=tmp_path / "database.db")
        assert database.initialize()

        names = ["Alice", "Bob", "Charlie", "Dave", "Eve"]
        for name in names:
            track = create_track(tmp_path / f"{name}.mp3", f"song_{name}", name)
            assert database.add_track(track=track)

        order_params = [ArtistOrderParameter(column="name", isAscending=True)]
        all_artists = []

        # First page
        result = database.get_artists(order_parameters=order_params, limit=2)
        assert result is not None
        all_artists.extend([a.name for a in result])

        # Pages via cursor
        while len(result) == 2:
            row_filters = [ArtistRowFilterParameter(column="name", value=result[-1].name)]
            result = database.get_artists(
                order_parameters=order_params,
                row_filter_parameters=row_filters,
                limit=2,
            )
            assert result is not None
            all_artists.extend([a.name for a in result])

        assert sorted(all_artists) == sorted(names)
        assert len(all_artists) == len(names)


class TestGetArtistsCount:
    def test_get_artists_count__empty_db__returns_0(self, tmp_path):
        database_path = tmp_path / "database.db"
        database = set_up_database(database_path)

        assert database.initialize()
        assert database.get_artists_count() == 0

    def test_get_artists_count__non_empty_db__returns_count(self, tmp_path):
        database_path = tmp_path / "database.db"
        database = set_up_database(database_path)

        assert database.initialize()

        unique_artists = set()
        unique_artists.add("artist")
        for i in range(5):
            track = create_track(tmp_path / f"track_{i}.mp3", f"title_{i}", "artist")
            assert database.add_track(track=track, timeout=1)

        assert database.get_artists_count() == len(unique_artists)

        for i in range(5):
            artist = f"artist_{i}"
            unique_artists.add(artist)
            path = tmp_path / f"new_track_{i}.mp3"
            title = f"title_{i}"

            track = create_track(path, title, artist)
            assert database.add_track(track=track)

        assert database.get_artists_count() == len(unique_artists)

        album_artist = "album_artist"
        unique_artists.add(album_artist)

        for i in range(5):
            artist = f"new_artist_{i}"
            path = f"new_new_track_{i}.mp3"
            title = f"title_{i}"

            track = create_track(path, title, artist, album_artist)
            assert database.add_track(track=track)

        assert database.get_artists_count() == len(unique_artists)

    def test_get_artists_count__duplicate_artists__returns_1(self, tmp_path):
        database = set_up_database(database_path=tmp_path / "database.db")
        assert database.initialize()

        album_artist = "artist"
        artist = "artist"

        track_1 = create_track(tmp_path / "track_1.mp3", "track_1", artist)
        track_2 = create_track(
            tmp_path / "track_2.mp3", "track_2", artist, album_artist
        )

        assert database.add_track(track=track_1)
        assert database.add_track(track=track_2)
        assert database.get_artists_count() == 1

    def test_get_artists_count__different_casing__returns_1(self, tmp_path):
        database = set_up_database(database_path=tmp_path / "database.db")
        assert database.initialize()

        artist = "ArTiSt"
        duplicate_artists = [artist, artist.lower(), artist.upper()]

        for i, duplicate_artist in enumerate(duplicate_artists):
            title = f"song_{i}"
            file_path = tmp_path / (title + ".mp3")
            track = create_track(file_path, title, duplicate_artist)
            assert database.add_track(track=track)

        assert database.get_artists_count() == 1

    def test_get_artists_count__with_cursor__counts_remaining(self, tmp_path):
        database = set_up_database(database_path=tmp_path / "database.db")
        assert database.initialize()

        for name in ["Alice", "Bob", "Charlie"]:
            track = create_track(tmp_path / f"{name}.mp3", f"song_{name}", name)
            assert database.add_track(track=track)

        order_params = [ArtistOrderParameter(column="name", isAscending=True)]
        # Cursor at Bob: count rows after Bob = Charlie = 1
        row_filters = [ArtistRowFilterParameter(column="name", value="Bob")]

        count = database.get_artists_count(
            order_parameters=order_params,
            row_filter_parameters=row_filters,
        )
        assert count == 1


class TestGetAlbums:
    def test_get_albums__empty_db__returns_empty(self, tmp_path):
        database_path = tmp_path / "database.db"
        database = set_up_database(database_path=database_path)
        database.initialize()

        # Use a non-existent artist_id
        returned_albums = database.get_albums(artist_id=99999)
        assert returned_albums is not None
        assert len(returned_albums) == 0

    def test_get_albums__no_albums__returns_singles(self, tmp_path):
        database_path = tmp_path / "database.db"
        database = set_up_database(database_path=database_path)
        database.initialize()

        artist = "artist"
        for i in range(5):
            title = f"song_{i}"
            file_path = tmp_path / (title + ".mp3")
            track = create_track(file_path, title, artist)
            assert database.add_track(track=track)

        artist_id = get_artist_id(database, artist)
        assert artist_id is not None
        returned_albums = database.get_albums(artist_id=artist_id)
        assert returned_albums is not None
        # 5 tracks with no album from same artist, same year (None)
        # -> 1 single grouping (artist, None)
        assert len(returned_albums) == 1
        assert returned_albums[0].is_single_grouping is True
        assert returned_albums[0].name is None

    def test_get_albums__artist_has_albums__returns_albums(self, tmp_path):
        database_path = tmp_path / "database.db"
        database = set_up_database(database_path=database_path)
        database.initialize()

        albums = set()
        artist = "artist"
        for i in range(5):
            title = f"song_{i}"
            file_path = tmp_path / (title + ".mp3")
            album = f"album_{i}"
            track = create_track(file_path, title, artist)
            track.metadata.album = album
            albums.add(album)
            assert database.add_track(track=track)

        artist_id = get_artist_id(database, artist)
        assert artist_id is not None
        returned_albums = database.get_albums(artist_id=artist_id)
        assert returned_albums
        regular = [a for a in returned_albums if not a.is_single_grouping]
        returned_album_names = [a.name for a in regular]
        assert sorted(albums) == sorted(
            a for a in returned_album_names if a is not None
        )

    def test_get_albums__album_artist_has_albums__returns_albums(self, tmp_path):
        database_path = tmp_path / "database.db"
        database = set_up_database(database_path=database_path)
        database.initialize()

        albums = set()
        album_artist = "album_artist"
        for i in range(5):
            title = f"song_{i}"
            artist = f"artist_{i}"
            file_path = tmp_path / (title + ".mp3")
            album = f"album_{i}"
            track = create_track(file_path, title, artist, album_artist)
            track.metadata.album = album
            albums.add(album)
            assert database.add_track(track=track)

        artist_id = get_artist_id(database, album_artist)
        assert artist_id is not None
        returned_albums = database.get_albums(artist_id=artist_id)
        assert returned_albums
        regular = [a for a in returned_albums if not a.is_single_grouping]
        returned_album_names = [a.name for a in regular]
        assert sorted(albums) == sorted(
            a for a in returned_album_names if a is not None
        )

    def test_get_albums__no_indpendant_artist_albums__returns_empty(self, tmp_path):
        database_path = tmp_path / "database.db"
        database = set_up_database(database_path=database_path)
        database.initialize()

        artists = set()
        album_artist = "album_artist"
        for i in range(5):
            title = f"song_{i}"
            artist = f"artist_{i}"
            artists.add(artist)
            file_path = tmp_path / (title + ".mp3")
            album = f"album_{i}"
            track = create_track(file_path, title, artist, album_artist)
            track.metadata.album = album
            assert database.add_track(track=track)

        for artist in artists:
            artist_id = get_artist_id(database, artist)
            # When album_artist is set, the individual artists are NOT created in
            # the artists table, so artist_id should be None
            assert artist_id is None

    def test_get_albums__different_casing__returns_albums(self, tmp_path):
        database = set_up_database(database_path=tmp_path / "database.db")
        assert database.initialize()

        artist = "ArTiSt"
        duplicate_artists = [artist, artist.lower(), artist.upper()]

        albums = set()
        for i, duplicate_artist in enumerate(duplicate_artists):
            title = f"song_{i}"
            file_path = tmp_path / (title + ".mp3")
            track = create_track(file_path, title, duplicate_artist)
            album = f"album_{i}"
            track.metadata.album = album
            albums.add(album)
            assert database.add_track(track=track)

        # All casings should resolve to the same artist_id
        artist_id = get_artist_id(database, artist)
        assert artist_id is not None
        returned_albums = database.get_albums(artist_id=artist_id)
        assert returned_albums
        regular = [a for a in returned_albums if not a.is_single_grouping]
        returned_album_names = [a.name for a in regular]
        assert sorted(albums) == sorted(
            a for a in returned_album_names if a is not None
        )

    def test_get_albums__bad_limit_offset__fails(self, tmp_path):
        database = set_up_database(database_path=tmp_path / "database.db")
        assert database.initialize()

        artist = "artist"
        for i in range(5):
            album = f"album_{i}"
            title = f"song_{i}"
            file_path = tmp_path / title
            track = create_track(file_path, title, artist)
            track.metadata.album = album

            assert database.add_track(track=track)

        artist_id = get_artist_id(database, artist)
        assert artist_id is not None

        with pytest.raises(ValueError):
            database.get_albums(artist_id=artist_id, limit=0)

        with pytest.raises(ValueError):
            database.get_albums(artist_id=artist_id, limit=-1)

        with pytest.raises(ValueError):
            database.get_albums(artist_id=artist_id, limit=2000)

        with pytest.raises(ValueError):
            database.get_albums(artist_id=artist_id, offset=-1)

        returned_albums = database.get_albums(artist_id=artist_id, offset=1000)
        assert returned_albums is not None
        assert len(returned_albums) == 0

    def test_get_albums__limit_offset__works(self, tmp_path):
        database_path = tmp_path / "database.db"
        database = set_up_database(database_path=database_path)
        database.initialize()

        artist = "artist"
        album_artist = "album_artist"
        expected_albums = set()
        for i in range(10):
            if i % 2 == 0:
                for j in range(5):
                    title = f"song_{i}_{j}"
                    file_path = tmp_path / (title + ".mp3")
                    album = f"album_{i}_{j}"
                    expected_albums.add(album)
                    track = create_track(file_path, title, artist)
                    track.metadata.album = album
                    assert database.add_track(track=track)
            else:
                # These albums should not be returned from "artist" since
                # they have an album artist
                for j in range(5):
                    title = f"song_{i}_{j}"
                    file_path = tmp_path / (title + ".mp3")
                    album = f"album_{i}_{j}"
                    track = create_track(file_path, title, artist, album_artist)
                    track.metadata.album = album
                    assert database.add_track(track=track)

        artist_id = get_artist_id(database, artist)
        assert artist_id is not None

        total_returned_album_names = []
        returned_albums = database.get_albums(artist_id=artist_id, limit=1)
        assert returned_albums
        assert len(returned_albums) == 1
        total_returned_album_names.append(returned_albums[0].name)

        offset = 1
        while returned_albums:
            returned_albums = database.get_albums(artist_id=artist_id, limit=1, offset=offset)
            offset += 1
            if returned_albums:
                assert len(returned_albums) == 1
                total_returned_album_names.append(returned_albums[0].name)

        # Filter out single groupings (None album names) for comparison
        regular_names = [n for n in total_returned_album_names if n is not None]
        assert sorted(expected_albums) == sorted(regular_names)

    def test_get_albums__no_artist__returns_all_albums(self, tmp_path):
        database = set_up_database(database_path=tmp_path / "database.db")
        database.initialize()

        all_albums = set()

        # Albums with artist set
        for i in range(3):
            title = f"song_a_{i}"
            file_path = tmp_path / (title + ".mp3")
            album = f"artist_album_{i}"
            all_albums.add(album)
            track = create_track(file_path, title, f"artist_{i}")
            track.metadata.album = album
            assert database.add_track(track=track)

        # Albums with album_artist set
        for i in range(2):
            title = f"song_aa_{i}"
            file_path = tmp_path / (title + ".mp3")
            album = f"album_artist_album_{i}"
            all_albums.add(album)
            track = create_track(file_path, title, f"feat_{i}", "album_artist")
            track.metadata.album = album
            assert database.add_track(track=track)

        returned_albums = database.get_albums(artist_id=None)
        assert returned_albums is not None
        regular = [a for a in returned_albums if not a.is_single_grouping]
        returned_album_names = [a.name for a in regular]
        assert sorted(all_albums) == sorted(
            a for a in returned_album_names if a is not None
        )

    def test_get_albums__no_artist__pagination_works(self, tmp_path):
        database = set_up_database(database_path=tmp_path / "database.db")
        database.initialize()

        all_albums = set()
        for i in range(5):
            title = f"song_{i}"
            file_path = tmp_path / (title + ".mp3")
            album = f"album_{i}"
            all_albums.add(album)
            track = create_track(file_path, title, f"artist_{i}")
            track.metadata.album = album
            assert database.add_track(track=track)

        total_returned_names = []
        offset = 0
        while True:
            returned = database.get_albums(artist_id=None, limit=2, offset=offset)
            assert returned is not None
            if not returned:
                break
            total_returned_names.extend([a.name for a in returned])
            offset += 2

        regular_names = [n for n in total_returned_names if n is not None]
        assert sorted(all_albums) == sorted(regular_names)

    def test_get_albums__order_by_alphabetical__returns_sorted(self, tmp_path):
        database = set_up_database(database_path=tmp_path / "database.db")
        assert database.initialize()

        albums_to_insert = ["Zebra", "apple", "Mango", "banana", "Cherry"]
        for i, album in enumerate(albums_to_insert):
            title = f"song_{i}"
            file_path = tmp_path / (title + ".mp3")
            track = create_track(file_path, title, f"artist_{i}")
            track.metadata.album = album
            assert database.add_track(track=track)

        returned_albums = database.get_albums(
            artist_id=None,
            order_parameters=[
                AlbumOrderParameter("is_single_grouping", True),
                AlbumOrderParameter("name", True, nullsLast=True),
            ],
        )
        assert returned_albums is not None
        regular = [a for a in returned_albums if not a.is_single_grouping]
        returned_album_names = [a.name for a in regular]
        expected_order = sorted(albums_to_insert, key=str.lower)
        assert returned_album_names == expected_order

    def test_get_albums__order_by_year__returns_year_sorted(self, tmp_path):
        database = set_up_database(database_path=tmp_path / "database.db")
        assert database.initialize()

        artist = "artist"
        # Insert in non-chronological order
        album_years = [("Late Album", 2022), ("Early Album", 2018), ("Mid Album", 2020)]
        for i, (album, year) in enumerate(album_years):
            title = f"song_{i}"
            file_path = tmp_path / (title + ".mp3")
            track = create_track(file_path, title, artist)
            track.metadata.album = album
            track.metadata.year = year
            assert database.add_track(track=track)

        artist_id = get_artist_id(database, artist)
        assert artist_id is not None
        returned_albums = database.get_albums(
            artist_id=artist_id,
            order_parameters=[
                AlbumOrderParameter("is_single_grouping", True),
                AlbumOrderParameter("year", True, nullsLast=True),
            ],
        )
        assert returned_albums is not None
        regular = [a for a in returned_albums if not a.is_single_grouping]
        returned_album_names = [a.name for a in regular]
        assert returned_album_names == ["Early Album", "Mid Album", "Late Album"]

    def test_get_albums__no_artist__returns_correct_artists(self, tmp_path):
        database = set_up_database(database_path=tmp_path / "database.db")
        database.initialize()

        # Track with plain artist (no album_artist)
        track1 = create_track(tmp_path / "s1.mp3", "song_1", "Artist A")
        track1.metadata.album = "Album X"
        assert database.add_track(track=track1)

        # Track with album_artist
        track2 = create_track(
            tmp_path / "s2.mp3", "song_2", "feat_artist", "Album Artist B"
        )
        track2.metadata.album = "Album Y"
        assert database.add_track(track=track2)

        returned_albums = database.get_albums(artist_id=None)
        assert returned_albums is not None
        regular = [a for a in returned_albums if not a.is_single_grouping]
        assert len(regular) == 2

        album_map = {a.name: a.artist for a in regular}
        assert album_map["Album X"] == "Artist A"
        assert album_map["Album Y"] == "Album Artist B"

    def test_get_albums__same_album_different_artists__returns_both(self, tmp_path):
        database = set_up_database(database_path=tmp_path / "database.db")
        database.initialize()

        track1 = create_track(tmp_path / "s1.mp3", "song_1", "Artist A")
        track1.metadata.album = "Greatest Hits"
        assert database.add_track(track=track1)

        track2 = create_track(tmp_path / "s2.mp3", "song_2", "Artist B")
        track2.metadata.album = "Greatest Hits"
        assert database.add_track(track=track2)

        returned_albums = database.get_albums(artist_id=None)
        assert returned_albums is not None
        regular = [a for a in returned_albums if not a.is_single_grouping]
        assert len(regular) == 2

        artists = {a.artist for a in regular}
        assert artists == {"Artist A", "Artist B"}
        assert all(a.name == "Greatest Hits" for a in regular)

    def test_get_albums__with_artist__returns_artist_field(self, tmp_path):
        database = set_up_database(database_path=tmp_path / "database.db")
        database.initialize()

        artist = "Artist A"
        track = create_track(tmp_path / "s1.mp3", "song_1", artist)
        track.metadata.album = "My Album"
        assert database.add_track(track=track)

        artist_id = get_artist_id(database, artist)
        assert artist_id is not None
        returned_albums = database.get_albums(artist_id=artist_id)
        assert returned_albums is not None
        regular = [a for a in returned_albums if not a.is_single_grouping]
        assert len(regular) == 1
        assert regular[0].name == "My Album"
        assert regular[0].artist == artist
        assert regular[0].id is not None
        assert regular[0].artist_id == artist_id

    # --- New tests for singles and grouping behavior ---

    def test_get_albums__singles_included_with_artist(self, tmp_path):
        database = set_up_database(database_path=tmp_path / "database.db")
        database.initialize()

        artist = "artist"
        # Insert tracks with no album -> should produce single groupings
        for i in range(3):
            title = f"single_{i}"
            file_path = tmp_path / (title + ".mp3")
            track = create_track(file_path, title, artist)
            assert database.add_track(track=track)

        artist_id = get_artist_id(database, artist)
        assert artist_id is not None
        returned_albums = database.get_albums(artist_id=artist_id)
        assert returned_albums is not None
        singles = [a for a in returned_albums if a.is_single_grouping]
        assert len(singles) == 1
        assert singles[0].name is None
        assert singles[0].is_single_grouping is True

    def test_get_albums__singles_included_without_artist(self, tmp_path):
        database = set_up_database(database_path=tmp_path / "database.db")
        database.initialize()

        # Insert tracks with no album for different artists
        for i in range(3):
            title = f"single_{i}"
            file_path = tmp_path / (title + ".mp3")
            track = create_track(file_path, title, f"artist_{i}")
            assert database.add_track(track=track)

        returned_albums = database.get_albums(artist_id=None)
        assert returned_albums is not None
        singles = [a for a in returned_albums if a.is_single_grouping]
        # 3 different artists, each with no album, same year (None)
        # -> 3 single groupings
        assert len(singles) == 3

    def test_get_albums__singles_sort_last(self, tmp_path):
        database = set_up_database(database_path=tmp_path / "database.db")
        database.initialize()

        artist = "artist"
        # Insert a regular album
        track1 = create_track(tmp_path / "s1.mp3", "album_song", artist)
        track1.metadata.album = "Real Album"
        track1.metadata.year = 2020
        assert database.add_track(track=track1)

        # Insert a single (no album)
        track2 = create_track(tmp_path / "s2.mp3", "single_song", artist)
        assert database.add_track(track=track2)

        artist_id = get_artist_id(database, artist)
        assert artist_id is not None
        returned_albums = database.get_albums(
            artist_id=artist_id,
            order_parameters=[
                AlbumOrderParameter("is_single_grouping", True),
                AlbumOrderParameter("year", True, nullsLast=True),
            ],
        )
        assert returned_albums is not None
        assert len(returned_albums) == 2
        # Regular album first, single last
        assert returned_albums[0].is_single_grouping is False
        assert returned_albums[0].name == "Real Album"
        assert returned_albums[1].is_single_grouping is True

    def test_get_albums__singles_grouped_by_artist_year(self, tmp_path):
        database = set_up_database(database_path=tmp_path / "database.db")
        database.initialize()

        artist = "artist"
        # Two singles from same artist but different years -> two groupings
        track1 = create_track(tmp_path / "s1.mp3", "single_2020", artist)
        track1.metadata.year = 2020
        assert database.add_track(track=track1)

        track2 = create_track(tmp_path / "s2.mp3", "single_2021", artist)
        track2.metadata.year = 2021
        assert database.add_track(track=track2)

        artist_id = get_artist_id(database, artist)
        assert artist_id is not None
        returned_albums = database.get_albums(artist_id=artist_id)
        assert returned_albums is not None
        singles = [a for a in returned_albums if a.is_single_grouping]
        assert len(singles) == 2
        years = {s.year for s in singles}
        assert years == {2020, 2021}

    def test_get_albums__same_album_same_artist_different_years__merged_entry(
        self, tmp_path
    ):
        database = set_up_database(database_path=tmp_path / "database.db")
        database.initialize()

        artist = "artist"
        # Same album name, same artist, different years -> 1 entry with max year
        track1 = create_track(tmp_path / "s1.mp3", "song_1", artist)
        track1.metadata.album = "Greatest Hits"
        track1.metadata.year = 2010
        assert database.add_track(track=track1)

        track2 = create_track(tmp_path / "s2.mp3", "song_2", artist)
        track2.metadata.album = "Greatest Hits"
        track2.metadata.year = 2020
        assert database.add_track(track=track2)

        artist_id = get_artist_id(database, artist)
        assert artist_id is not None
        returned_albums = database.get_albums(artist_id=artist_id)
        assert returned_albums is not None
        regular = [a for a in returned_albums if not a.is_single_grouping]
        assert len(regular) == 1
        assert regular[0].year == 2020

    def test_get_albums__same_album_same_artist_same_year__one_entry(self, tmp_path):
        database = set_up_database(database_path=tmp_path / "database.db")
        database.initialize()

        artist = "artist"
        # Two tracks, same album, same artist, same year -> 1 entry
        for i in range(2):
            track = create_track(tmp_path / f"s{i}.mp3", f"song_{i}", artist)
            track.metadata.album = "Greatest Hits"
            track.metadata.year = 2020
            assert database.add_track(track=track)

        artist_id = get_artist_id(database, artist)
        assert artist_id is not None
        returned_albums = database.get_albums(artist_id=artist_id)
        assert returned_albums is not None
        regular = [a for a in returned_albums if not a.is_single_grouping]
        assert len(regular) == 1
        assert regular[0].name == "Greatest Hits"
        assert regular[0].year == 2020

    def test_get_albums__null_year_sorts_last(self, tmp_path):
        database = set_up_database(database_path=tmp_path / "database.db")
        database.initialize()

        artist = "artist"
        # Album with year
        track1 = create_track(tmp_path / "s1.mp3", "song_1", artist)
        track1.metadata.album = "Album With Year"
        track1.metadata.year = 2020
        assert database.add_track(track=track1)

        # Album without year
        track2 = create_track(tmp_path / "s2.mp3", "song_2", artist)
        track2.metadata.album = "Album No Year"
        assert database.add_track(track=track2)

        artist_id = get_artist_id(database, artist)
        assert artist_id is not None
        returned_albums = database.get_albums(
            artist_id=artist_id,
            order_parameters=[
                AlbumOrderParameter("is_single_grouping", True),
                AlbumOrderParameter("year", True, nullsLast=True),
            ],
        )
        assert returned_albums is not None
        regular = [a for a in returned_albums if not a.is_single_grouping]
        assert len(regular) == 2
        assert regular[0].name == "Album With Year"
        assert regular[0].year == 2020
        assert regular[1].name == "Album No Year"
        assert regular[1].year is None

    def test_get_albums__null_artist_sorts_last(self, tmp_path):
        database = set_up_database(database_path=tmp_path / "database.db")
        database.initialize()

        # Album with an artist
        track1 = create_track(tmp_path / "s1.mp3", "song_1", "Artist A")
        track1.metadata.album = "Album A"
        assert database.add_track(track=track1)

        returned_albums = database.get_albums(
            artist_id=None,
            order_parameters=[
                AlbumOrderParameter("is_single_grouping", True),
                AlbumOrderParameter("artist", True, nullsLast=True),
            ],
        )
        assert returned_albums is not None
        regular = [a for a in returned_albums if not a.is_single_grouping]
        assert len(regular) == 1
        assert regular[0].artist == "Artist A"

    def test_get_albums__cursor_pagination(self, tmp_path):
        database = set_up_database(database_path=tmp_path / "database.db")
        database.initialize()

        artist = "artist"
        # Insert albums with distinct years for deterministic ordering
        album_data = [
            ("Album A", 2018),
            ("Album B", 2019),
            ("Album C", 2020),
        ]
        for i, (album, year) in enumerate(album_data):
            track = create_track(tmp_path / f"s{i}.mp3", f"song_{i}", artist)
            track.metadata.album = album
            track.metadata.year = year
            assert database.add_track(track=track)

        artist_id = get_artist_id(database, artist)
        assert artist_id is not None

        order_params = [
            AlbumOrderParameter("is_single_grouping", True),
            AlbumOrderParameter("year", True, nullsLast=True),
            AlbumOrderParameter("name", True, nullsLast=True),
        ]

        # Get first page
        all_results = []
        page = database.get_albums(
            artist_id=artist_id, order_parameters=order_params, limit=1
        )
        assert page is not None
        assert len(page) == 1
        all_results.extend(page)

        # Paginate one-at-a-time using cursor
        while page:
            last = page[-1]
            row_filters = [
                AlbumRowFilterParameter(
                    "is_single_grouping",
                    str(int(last.is_single_grouping)),
                ),
                AlbumRowFilterParameter(
                    "year",
                    str(last.year) if last.year is not None else None,
                ),
                AlbumRowFilterParameter(
                    "name",
                    last.name,
                ),
            ]
            page = database.get_albums(
                artist_id=artist_id,
                order_parameters=order_params,
                row_filter_parameters=row_filters,
                limit=1,
            )
            assert page is not None
            if page:
                all_results.extend(page)

        regular = [a for a in all_results if not a.is_single_grouping]
        assert [a.name for a in regular] == ["Album A", "Album B", "Album C"]

    def test_get_albums__cursor_pagination_across_singles(self, tmp_path):
        database = set_up_database(database_path=tmp_path / "database.db")
        database.initialize()

        artist = "artist"
        # Regular album
        track1 = create_track(tmp_path / "s1.mp3", "album_song", artist)
        track1.metadata.album = "Real Album"
        track1.metadata.year = 2020
        assert database.add_track(track=track1)

        # Single (no album)
        track2 = create_track(tmp_path / "s2.mp3", "single_song", artist)
        track2.metadata.year = 2021
        assert database.add_track(track=track2)

        artist_id = get_artist_id(database, artist)
        assert artist_id is not None

        order_params = [
            AlbumOrderParameter("is_single_grouping", True),
            AlbumOrderParameter("year", True, nullsLast=True),
            AlbumOrderParameter("name", True, nullsLast=True),
        ]

        # First page: should get the regular album
        all_results = []
        page = database.get_albums(
            artist_id=artist_id, order_parameters=order_params, limit=1
        )
        assert page is not None
        assert len(page) == 1
        all_results.extend(page)

        # Second page via cursor: should get the single
        last = page[-1]
        row_filters = [
            AlbumRowFilterParameter(
                "is_single_grouping",
                str(int(last.is_single_grouping)),
            ),
            AlbumRowFilterParameter(
                "year",
                str(last.year) if last.year is not None else None,
            ),
            AlbumRowFilterParameter(
                "name",
                last.name,
            ),
        ]
        page = database.get_albums(
            artist_id=artist_id,
            order_parameters=order_params,
            row_filter_parameters=row_filters,
            limit=1,
        )
        assert page is not None
        assert len(page) == 1
        all_results.extend(page)

        assert len(all_results) == 2
        assert all_results[0].is_single_grouping is False
        assert all_results[0].name == "Real Album"
        assert all_results[1].is_single_grouping is True


class TestGetAlbumsCount:
    def test_get_albums_count__missing_artist__returns_0(self, tmp_path):
        database_path = tmp_path / "database.db"
        database = set_up_database(database_path=database_path)
        database.initialize()

        album_count = database.get_albums_count(artist_id=99999)
        assert album_count == 0

    def test_get_albums_count__no_albums__returns_1_single(self, tmp_path):
        database_path = tmp_path / "database.db"
        database = set_up_database(database_path=database_path)
        database.initialize()

        artist = "artist"
        for i in range(3):
            title = f"song_{i}"
            file_path = tmp_path / (title + ".mp3")
            track = create_track(file_path, title, artist)
            assert database.add_track(track=track)

        artist_id = get_artist_id(database, artist)
        assert artist_id is not None
        album_count = database.get_albums_count(artist_id=artist_id)
        # 3 tracks with no album, same artist, same year (None)
        # -> 1 single grouping
        assert album_count == 1

    def test_get_albums_count__albums__returns_count(self, tmp_path):
        database_path = tmp_path / "database.db"
        database = set_up_database(database_path=database_path)
        database.initialize()

        expected_albums = set()
        artist = "artist"
        for i in range(3):
            title = f"song_{i}"
            album = f"album_{i}"
            expected_albums.add(album)
            file_path = tmp_path / (title + ".mp3")
            track = create_track(file_path, title, artist)
            track.metadata.album = album
            assert database.add_track(track=track)

        artist_id = get_artist_id(database, artist)
        assert artist_id is not None
        album_count = database.get_albums_count(artist_id=artist_id)
        assert album_count == len(expected_albums)

    def test_get_albums_count__different_casing__excludes_none(self, tmp_path):
        database = set_up_database(database_path=tmp_path / "database.db")
        assert database.initialize()

        artist = "ArTiSt"
        duplicate_artists = [artist, artist.lower(), artist.upper()]

        albums = set()
        for i, duplicate_artist in enumerate(duplicate_artists):
            title = f"song_{i}"
            file_path = tmp_path / (title + ".mp3")
            track = create_track(file_path, title, duplicate_artist)
            album = f"album_{i}"
            track.metadata.album = album
            albums.add(album)
            assert database.add_track(track=track)

        # All casings resolve to same artist_id
        artist_id = get_artist_id(database, artist)
        assert artist_id is not None
        album_count = database.get_albums_count(artist_id=artist_id)
        assert album_count
        assert len(albums) == album_count

    def test_get_albums_count__artist_albums__returns_count(self, tmp_path):
        database_path = tmp_path / "database.db"
        database = set_up_database(database_path=database_path)
        database.initialize()

        expected_artist_albums = set()
        empty_artists = set()
        album_artist = "album_artist"
        for i in range(3):
            artist = f"artist_{i}"
            empty_artists.add(artist)
            title = f"song_{i}"
            album = f"album_{i}"
            expected_artist_albums.add(album)
            file_path = tmp_path / (title + ".mp3")
            track = create_track(file_path, title, artist, album_artist)
            track.metadata.album = album
            assert database.add_track(track=track)

        album_artist_id = get_artist_id(database, album_artist)
        assert album_artist_id is not None
        album_count = database.get_albums_count(artist_id=album_artist_id)
        assert album_count == len(expected_artist_albums)

        # Check that the individual artists do not have any albums
        # (they don't exist in artists table since album_artist takes priority)
        for artist in empty_artists:
            artist_id = get_artist_id(database, artist)
            assert artist_id is None

        # Add some albums to one of the empty artists, to ensure that counts
        # are correct
        artist = list(empty_artists)[0]
        expected_albums = set()
        for i in range(3):
            title = f"new_song_{i}"
            file_path = tmp_path / (title + ".mp3")
            album = f"new_album_{i}"
            expected_albums.add(album)
            track = create_track(file_path, title, artist)
            track.metadata.album = album
            assert database.add_track(track=track)

        artist_id = get_artist_id(database, artist)
        assert artist_id is not None
        album_count = database.get_albums_count(artist_id=artist_id)
        assert album_count == len(expected_albums)

    def test_get_albums_count__no_artist__returns_total_count(self, tmp_path):
        database = set_up_database(database_path=tmp_path / "database.db")
        database.initialize()

        all_albums = set()

        # Albums with artist
        for i in range(3):
            title = f"song_a_{i}"
            file_path = tmp_path / (title + ".mp3")
            album = f"artist_album_{i}"
            all_albums.add(album)
            track = create_track(file_path, title, f"artist_{i}")
            track.metadata.album = album
            assert database.add_track(track=track)

        # Albums with album_artist
        for i in range(2):
            title = f"song_aa_{i}"
            file_path = tmp_path / (title + ".mp3")
            album = f"album_artist_album_{i}"
            all_albums.add(album)
            track = create_track(file_path, title, f"feat_{i}", "album_artist")
            track.metadata.album = album
            assert database.add_track(track=track)

        album_count = database.get_albums_count(artist_id=None)
        assert album_count == len(all_albums)

    def test_get_albums_count__with_cursor__counts_remaining(self, tmp_path):
        database = set_up_database(database_path=tmp_path / "database.db")
        database.initialize()

        artist = "artist"
        album_data = [
            ("Album A", 2018),
            ("Album B", 2019),
            ("Album C", 2020),
        ]
        for i, (album, year) in enumerate(album_data):
            track = create_track(tmp_path / f"s{i}.mp3", f"song_{i}", artist)
            track.metadata.album = album
            track.metadata.year = year
            assert database.add_track(track=track)

        artist_id = get_artist_id(database, artist)
        assert artist_id is not None

        order_params = [
            AlbumOrderParameter("is_single_grouping", True),
            AlbumOrderParameter("year", True, nullsLast=True),
        ]

        # Count with cursor past first album (year=2018)
        row_filters = [
            AlbumRowFilterParameter("is_single_grouping", "0"),
            AlbumRowFilterParameter("year", "2018"),
        ]
        count = database.get_albums_count(
            artist_id=artist_id,
            order_parameters=order_params,
            row_filter_parameters=row_filters,
        )
        assert count == 2  # Album B (2019) and Album C (2020)

    def test_get_albums_count__includes_singles(self, tmp_path):
        database = set_up_database(database_path=tmp_path / "database.db")
        database.initialize()

        artist = "artist"
        # Regular album
        track1 = create_track(tmp_path / "s1.mp3", "album_song", artist)
        track1.metadata.album = "Real Album"
        track1.metadata.year = 2020
        assert database.add_track(track=track1)

        # Single (no album)
        track2 = create_track(tmp_path / "s2.mp3", "single_song", artist)
        assert database.add_track(track=track2)

        artist_id = get_artist_id(database, artist)
        assert artist_id is not None
        album_count = database.get_albums_count(artist_id=artist_id)
        # 1 regular album + 1 single grouping = 2
        assert album_count == 2


class TestGetSearchResults:
    def test_search_by_track_title__returns_matching_tracks(self, tmp_path):
        database = set_up_database(database_path=tmp_path / "database.db")
        assert database.initialize()

        track = create_track(tmp_path / "t.mp3", "Bohemian Rhapsody", "Queen")
        track.metadata.album = "A Night at the Opera"
        assert database.add_track(track=track)

        results = database.get_search_results("Bohemian", return_types=SearchEntityType.TRACKS)
        assert len(results.tracks) == 1
        assert results.tracks[0].metadata.title == "Bohemian Rhapsody"
        assert len(results.artists) == 0
        assert len(results.albums) == 0

    def test_search_by_artist_name__returns_matching_artists(self, tmp_path):
        database = set_up_database(database_path=tmp_path / "database.db")
        assert database.initialize()

        track = create_track(tmp_path / "t.mp3", "Some Song", "Radiohead")
        assert database.add_track(track=track)

        results = database.get_search_results("Radiohead", return_types=SearchEntityType.ARTISTS)
        assert len(results.artists) == 1
        assert results.artists[0].name == "Radiohead"
        assert len(results.tracks) == 0
        assert len(results.albums) == 0

    def test_search_by_album_name__returns_matching_albums(self, tmp_path):
        database = set_up_database(database_path=tmp_path / "database.db")
        assert database.initialize()

        track = create_track(tmp_path / "t.mp3", "Song", "Artist")
        track.metadata.album = "Dark Side of the Moon"
        assert database.add_track(track=track)

        results = database.get_search_results("Dark Side", return_types=SearchEntityType.ALBUMS)
        assert len(results.albums) == 1
        assert results.albums[0].name == "Dark Side of the Moon"
        assert len(results.tracks) == 0
        assert len(results.artists) == 0

    def test_search_title_and_artist__matches_track(self, tmp_path):
        """Searching 'title artist' should match the track via multi-field FTS."""
        database = set_up_database(database_path=tmp_path / "database.db")
        assert database.initialize()

        track = create_track(tmp_path / "t.mp3", "Creep", "Radiohead")
        assert database.add_track(track=track)

        # Other track that should not match
        other = create_track(tmp_path / "o.mp3", "OtherSong", "OtherArtist")
        assert database.add_track(track=other)

        results = database.get_search_results("Creep Radiohead", return_types=SearchEntityType.TRACKS)
        assert len(results.tracks) >= 1
        titles = {t.metadata.title for t in results.tracks}
        assert "Creep" in titles

    def test_search_album_and_artist__matches_album(self, tmp_path):
        """Searching 'album artist' should match the album."""
        database = set_up_database(database_path=tmp_path / "database.db")
        assert database.initialize()

        track = create_track(tmp_path / "t.mp3", "Song", "PinkFloyd")
        track.metadata.album = "TheWall"
        assert database.add_track(track=track)

        results = database.get_search_results("TheWall PinkFloyd", return_types=SearchEntityType.ALBUMS)
        assert len(results.albums) >= 1
        album_names = {a.name for a in results.albums}
        assert "TheWall" in album_names

    def test_get_search_results__prefix_query__matches_prefix(self, tmp_path):
        """Prefix matching: 'art' should match 'artist'."""
        database = set_up_database(database_path=tmp_path / "database.db")
        assert database.initialize()

        track = create_track(tmp_path / "t.mp3", "Song", "ArtistName")
        assert database.add_track(track=track)

        results = database.get_search_results("Art", return_types=SearchEntityType.ARTISTS)
        assert len(results.artists) >= 1
        assert any(a.name == "ArtistName" for a in results.artists)

    def test_get_search_results__type_tracks_only__returns_only_tracks(self, tmp_path):
        database = set_up_database(database_path=tmp_path / "database.db")
        assert database.initialize()

        track = create_track(tmp_path / "t.mp3", "TestSong", "TestArtist")
        track.metadata.album = "TestAlbum"
        assert database.add_track(track=track)

        results = database.get_search_results("Test", return_types=SearchEntityType.TRACKS)
        assert len(results.tracks) >= 1
        assert len(results.artists) == 0
        assert len(results.albums) == 0

    def test_get_search_results__type_artists_only__returns_only_artists(self, tmp_path):
        database = set_up_database(database_path=tmp_path / "database.db")
        assert database.initialize()

        track = create_track(tmp_path / "t.mp3", "TestSong", "TestArtist")
        track.metadata.album = "TestAlbum"
        assert database.add_track(track=track)

        results = database.get_search_results("Test", return_types=SearchEntityType.ARTISTS)
        assert len(results.tracks) == 0
        assert len(results.artists) >= 1
        assert len(results.albums) == 0

    def test_get_search_results__type_albums_only__returns_only_albums(self, tmp_path):
        database = set_up_database(database_path=tmp_path / "database.db")
        assert database.initialize()

        track = create_track(tmp_path / "t.mp3", "TestSong", "TestArtist")
        track.metadata.album = "TestAlbum"
        assert database.add_track(track=track)

        results = database.get_search_results("Test", return_types=SearchEntityType.ALBUMS)
        assert len(results.tracks) == 0
        assert len(results.artists) == 0
        assert len(results.albums) >= 1

    def test_get_search_results__type_combination__returns_matching_types(self, tmp_path):
        database = set_up_database(database_path=tmp_path / "database.db")
        assert database.initialize()

        track = create_track(tmp_path / "t.mp3", "TestSong", "TestArtist")
        track.metadata.album = "TestAlbum"
        assert database.add_track(track=track)

        results = database.get_search_results(
            "Test",
            return_types=SearchEntityType.TRACKS | SearchEntityType.ARTISTS,
        )
        assert len(results.tracks) >= 1
        assert len(results.artists) >= 1
        assert len(results.albums) == 0

    def test_get_search_results__all_types__returns_all(self, tmp_path):
        database = set_up_database(database_path=tmp_path / "database.db")
        assert database.initialize()

        track = create_track(tmp_path / "t.mp3", "TestSong", "TestArtist")
        track.metadata.album = "TestAlbum"
        assert database.add_track(track=track)

        results = database.get_search_results(
            "Test",
            return_types=SearchEntityType.TRACKS | SearchEntityType.ARTISTS | SearchEntityType.ALBUMS,
        )
        assert len(results.tracks) >= 1
        assert len(results.artists) >= 1
        assert len(results.albums) >= 1

    def test_search_empty_query__returns_empty(self, tmp_path):
        database = set_up_database(database_path=tmp_path / "database.db")
        assert database.initialize()

        track = create_track(tmp_path / "t.mp3", "Song", "Artist")
        assert database.add_track(track=track)

        results = database.get_search_results("")
        assert len(results.tracks) == 0
        assert len(results.artists) == 0
        assert len(results.albums) == 0

    def test_search_no_matches__returns_empty(self, tmp_path):
        database = set_up_database(database_path=tmp_path / "database.db")
        assert database.initialize()

        track = create_track(tmp_path / "t.mp3", "Song", "Artist")
        assert database.add_track(track=track)

        results = database.get_search_results("zzzznonexistent")
        assert len(results.tracks) == 0
        assert len(results.artists) == 0
        assert len(results.albums) == 0

    def test_search_after_delete__no_longer_returns_track(self, tmp_path):
        database = set_up_database(database_path=tmp_path / "database.db")
        assert database.initialize()

        track = create_track(tmp_path / "t.mp3", "UniqueTitle", "UniqueArtist")
        track.uuid_id = "search_delete_uuid"
        assert database.add_track(track=track)

        results = database.get_search_results("UniqueTitle")
        assert len(results.tracks) == 1

        assert database.delete_track(uuid_id="search_delete_uuid")

        results = database.get_search_results("UniqueTitle")
        assert len(results.tracks) == 0

    def test_search_after_delete_all_tracks__no_longer_returns_artist(self, tmp_path):
        database = set_up_database(database_path=tmp_path / "database.db")
        assert database.initialize()

        track = create_track(tmp_path / "t.mp3", "Song", "OrphanArtist")
        track.uuid_id = "orphan_uuid"
        assert database.add_track(track=track)

        results = database.get_search_results("OrphanArtist", return_types=SearchEntityType.ARTISTS)
        assert len(results.artists) == 1

        assert database.delete_track(uuid_id="orphan_uuid")

        results = database.get_search_results("OrphanArtist", return_types=SearchEntityType.ARTISTS)
        assert len(results.artists) == 0

    def test_search_special_characters__does_not_crash(self, tmp_path):
        database = set_up_database(database_path=tmp_path / "database.db")
        assert database.initialize()

        track = create_track(tmp_path / "t.mp3", "Normal Song", "Normal Artist")
        assert database.add_track(track=track)

        special_queries = [
            '"quotes"',
            "it's",
            "test & test",
            "hello (world)",
            "a*b",
            "a OR b",
            "test:value",
            "---",
            "   ",
        ]

        for query in special_queries:
            # Should not raise an exception
            results = database.get_search_results(query)
            assert results is not None

    def test_get_search_results__after_album_orphan_cleanup__album_not_in_results(self, tmp_path):
        database = set_up_database(database_path=tmp_path / "database.db")
        assert database.initialize()

        track = create_track(tmp_path / "t.mp3", "song", "CleanupArtist")
        track.metadata.album = "CleanupAlbum"
        track.uuid_id = "cleanup_uuid"
        assert database.add_track(track=track)

        results = database.get_search_results("CleanupAlbum", return_types=SearchEntityType.ALBUMS)
        assert len(results.albums) == 1

        assert database.delete_track(uuid_id="cleanup_uuid")

        results = database.get_search_results("CleanupAlbum", return_types=SearchEntityType.ALBUMS)
        assert len(results.albums) == 0


class TestPrepareFtsQuery:
    def test_prepare_fts_query__empty_string__returns_empty(self):
        assert prepare_fts_query("") == ""

    def test_prepare_fts_query__whitespace_only__returns_empty(self):
        assert prepare_fts_query("   ") == ""

    def test_prepare_fts_query__single_word__returns_quoted_prefix(self):
        assert prepare_fts_query("hello") == '"hello"*'

    def test_prepare_fts_query__multiple_words__returns_space_joined(self):
        assert prepare_fts_query("hello world") == '"hello"* "world"*'

    def test_prepare_fts_query__double_quotes__escapes_correctly(self):
        assert prepare_fts_query('say "hi"') == '"say"* """hi"""*'


class TestDatabaseMigration:
    def _create_v0_database(self, tmp_path: Path) -> Path:
        """Create a database at version 0 (no cover_arts table, no cover_art_id column)."""
        database_path = tmp_path / "database.db"
        conn = sqlite3.connect(database_path)
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA foreign_keys=ON")
        # Create minimal schema without cover_arts
        conn.executescript("""
            CREATE TABLE IF NOT EXISTS artists (
                "id" INTEGER PRIMARY KEY,
                "name" TEXT NOT NULL,
                "name_lower" TEXT NOT NULL GENERATED ALWAYS AS (LOWER("name")) STORED UNIQUE
            );
            CREATE TABLE IF NOT EXISTS albums (
                "id" INTEGER PRIMARY KEY,
                "name" TEXT,
                "name_lower" TEXT GENERATED ALWAYS AS (LOWER("name")) STORED,
                "artist_id" INTEGER NOT NULL,
                "year" INTEGER,
                "is_single_grouping" INTEGER NOT NULL DEFAULT 0,
                FOREIGN KEY ("artist_id") REFERENCES artists("id")
            );
            CREATE TABLE IF NOT EXISTS tracks (
                "id" INTEGER PRIMARY KEY,
                "uuid_id" TEXT UNIQUE NOT NULL,
                "file_path" TEXT NOT NULL,
                "file_hash" TEXT UNIQUE,
                "created_at" INTEGER NOT NULL DEFAULT (unixepoch()),
                "last_updated" INTEGER NOT NULL DEFAULT (unixepoch())
            );
            CREATE TABLE IF NOT EXISTS trackmetadata (
                "track_id" INTEGER UNIQUE NOT NULL,
                "uuid_id" TEXT UNIQUE NOT NULL,
                "title" TEXT,
                "artist" TEXT,
                "album" TEXT,
                "album_artist" TEXT,
                "artist_id" INTEGER,
                "album_id" INTEGER,
                "year" INTEGER,
                "date" TEXT,
                "genre" TEXT,
                "track_number" INTEGER,
                "disc_number" INTEGER,
                "codec" TEXT,
                "duration" FLOAT,
                "bitrate_kbps" FLOAT,
                "sample_rate_hz" INTEGER,
                "channels" INTEGER,
                "has_album_art" INTEGER NOT NULL CHECK ("has_album_art" IN (0,1)),
                FOREIGN KEY ("track_id") REFERENCES tracks("id"),
                FOREIGN KEY ("uuid_id") REFERENCES tracks("uuid_id"),
                FOREIGN KEY ("artist_id") REFERENCES artists("id"),
                FOREIGN KEY ("album_id") REFERENCES albums("id")
            );
        """)
        # user_version stays at 0 (default)
        conn.commit()
        conn.close()
        return database_path

    def test_migrate__v0_database__creates_cover_arts_table(self, tmp_path: Path):
        database_path = self._create_v0_database(tmp_path)

        database = set_up_database(database_path=database_path)
        database.initialize()

        conn = sqlite3.connect(database_path)
        conn.row_factory = sqlite3.Row
        tables = [row["name"] for row in conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table'"
        ).fetchall()]
        conn.close()

        assert "cover_arts" in tables

    def test_migrate__v0_database__adds_cover_art_id_column(self, tmp_path: Path):
        database_path = self._create_v0_database(tmp_path)

        database = set_up_database(database_path=database_path)
        database.initialize()

        conn = sqlite3.connect(database_path)
        conn.row_factory = sqlite3.Row
        columns = [row["name"] for row in conn.execute(
            "PRAGMA table_info(trackmetadata)"
        ).fetchall()]
        conn.close()

        assert "cover_art_id" in columns

    def test_migrate__v0_database__sets_user_version_to_1(self, tmp_path: Path):
        database_path = self._create_v0_database(tmp_path)

        database = set_up_database(database_path=database_path)
        database.initialize()

        conn = sqlite3.connect(database_path)
        version = conn.execute("PRAGMA user_version").fetchone()[0]
        conn.close()

        assert version == 1

    def test_migrate__already_at_v1__does_not_fail(self, tmp_path: Path):
        database_path = tmp_path / "database.db"
        database = set_up_database(database_path=database_path)
        database.initialize()

        # Initialize again — should not fail
        database2 = set_up_database(database_path=database_path)
        result = database2.initialize()

        assert result is True

    def test_fresh_database__includes_cover_arts_table(self, tmp_path: Path):
        database_path = tmp_path / "database.db"
        database = set_up_database(database_path=database_path)
        database.initialize()

        conn = sqlite3.connect(database_path)
        conn.row_factory = sqlite3.Row
        tables = [row["name"] for row in conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table'"
        ).fetchall()]
        conn.close()

        assert "cover_arts" in tables

    def test_fresh_database__trackmetadata_has_cover_art_id(self, tmp_path: Path):
        database_path = tmp_path / "database.db"
        database = set_up_database(database_path=database_path)
        database.initialize()

        conn = sqlite3.connect(database_path)
        conn.row_factory = sqlite3.Row
        columns = [row["name"] for row in conn.execute(
            "PRAGMA table_info(trackmetadata)"
        ).fetchall()]
        conn.close()

        assert "cover_art_id" in columns


class TestDatabaseCoverArtCrud:
    def test_insert_and_get_by_id(self, tmp_path: Path):
        database_path = tmp_path / "database.db"
        database = set_up_database(database_path=database_path)
        database.initialize()

        cover_art_id = database.insert_cover_art(
            sha256="abc123", phash="0123456789abcdef", phash_prefix="0123", file_path="/tmp/art.png"
        )

        result = database.get_cover_art_by_id(cover_art_id)

        assert result is not None
        assert result.id == cover_art_id
        assert result.sha256 == "abc123"
        assert result.phash == "0123456789abcdef"
        assert result.phash_prefix == "0123"

    def test_get_by_id__nonexistent__returns_none(self, tmp_path: Path):
        database_path = tmp_path / "database.db"
        database = set_up_database(database_path=database_path)
        database.initialize()

        result = database.get_cover_art_by_id(999)

        assert result is None

    def test_get_by_sha256__found(self, tmp_path: Path):
        database_path = tmp_path / "database.db"
        database = set_up_database(database_path=database_path)
        database.initialize()

        database.insert_cover_art(
            sha256="unique_hash", phash="abcdef0123456789", phash_prefix="abcd", file_path="/tmp/a.png"
        )

        result = database.get_cover_art_by_sha256("unique_hash")

        assert result is not None
        assert result.sha256 == "unique_hash"

    def test_get_by_sha256__not_found__returns_none(self, tmp_path: Path):
        database_path = tmp_path / "database.db"
        database = set_up_database(database_path=database_path)
        database.initialize()

        result = database.get_cover_art_by_sha256("nonexistent")

        assert result is None

    def test_get_by_phash_prefix__returns_matching_entries(self, tmp_path: Path):
        database_path = tmp_path / "database.db"
        database = set_up_database(database_path=database_path)
        database.initialize()

        database.insert_cover_art(sha256="a", phash="aaaa111122223333", phash_prefix="aaaa", file_path="/tmp/1.png")
        database.insert_cover_art(sha256="b", phash="aaaa444455556666", phash_prefix="aaaa", file_path="/tmp/2.png")
        database.insert_cover_art(sha256="c", phash="bbbb111122223333", phash_prefix="bbbb", file_path="/tmp/3.png")

        results = database.get_cover_arts_by_phash_prefix("aaaa")

        assert len(results) == 2
        sha_set = {r.sha256 for r in results}
        assert sha_set == {"a", "b"}

    def test_get_by_phash_prefix__no_matches__returns_empty(self, tmp_path: Path):
        database_path = tmp_path / "database.db"
        database = set_up_database(database_path=database_path)
        database.initialize()

        results = database.get_cover_arts_by_phash_prefix("zzzz")

        assert results == []

    def test_delete__existing__returns_true(self, tmp_path: Path):
        database_path = tmp_path / "database.db"
        database = set_up_database(database_path=database_path)
        database.initialize()

        cover_art_id = database.insert_cover_art(
            sha256="del_me", phash="1111222233334444", phash_prefix="1111", file_path="/tmp/del.png"
        )

        result = database.delete_cover_art(cover_art_id)

        assert result is True
        assert database.get_cover_art_by_id(cover_art_id) is None

    def test_delete__nonexistent__returns_false(self, tmp_path: Path):
        database_path = tmp_path / "database.db"
        database = set_up_database(database_path=database_path)
        database.initialize()

        result = database.delete_cover_art(999)

        assert result is False

    def test_insert_duplicate_sha256__raises_error(self, tmp_path: Path):
        database_path = tmp_path / "database.db"
        database = set_up_database(database_path=database_path)
        database.initialize()

        database.insert_cover_art(sha256="dup", phash="aaaa", phash_prefix="aa", file_path="/tmp/1.png")

        with pytest.raises(Exception):
            database.insert_cover_art(sha256="dup", phash="bbbb", phash_prefix="bb", file_path="/tmp/2.png")
