import sqlite3
from datetime import UTC, datetime
from os import path
from pathlib import Path
from typing import List
from unittest.mock import patch

import pytest

from app.database.database import (
    ALLOWED_METADATA_COLUMNS,
    Database,
    DatabaseContext,
    OrderParameter,
    RowFilterParameter,
    SearchParameter,
)
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
        for track in expected_tracks:
            assert track in returned_tracks

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

        results = database.get_tracks(artist="ArtistA")
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

        results = database.get_tracks(artist="Artist", album="Album1")
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

        results = database.get_tracks(artist="Artist", album=None)
        assert len(results) == 1
        assert results[0].metadata.title == "song_b"

    def test_get_tracks__album_without_artist__raises_value_error(self, tmp_path):
        database_path = tmp_path / "database.db"
        database = set_up_database(database_path)
        database.initialize()

        with pytest.raises(ValueError):
            database.get_tracks(album="SomeAlbum")

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

        results = database.get_tracks(artist="MainArtist", album="TheAlbum")
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

        results = database.get_tracks(artist="feat_artist")
        assert len(results) == 0


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
        assert sorted(expected_artists) == sorted(returned_artists)

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
        assert sorted(expected_album_artists) == sorted(returned_artists)

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
        assert sorted(expected_artists) == sorted(returned_artists)

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
        assert returned_artist == ["artist"]

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

        assert database.get_artists() == [artist]

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
            returned_artists.append(artist_list[0])

        print(sorted(expected_artists))
        print(sorted(returned_artists))
        assert len(expected_artists) == len(returned_artists)
        assert len(returned_artists) == len(set(returned_artists))
        assert sorted(expected_artists) == sorted(returned_artists)

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


class TestGetAlbums:
    def test_get_albums__empty_db__returns_empty(self, tmp_path):
        database_path = tmp_path / "database.db"
        database = set_up_database(database_path=database_path)
        database.initialize()

        returned_artists = database.get_albums(artist="artist")
        assert returned_artists is not None
        assert len(returned_artists) == 0

    def test_get_albums__no_albums__returns_empty(self, tmp_path):
        database_path = tmp_path / "database.db"
        database = set_up_database(database_path=database_path)
        database.initialize()

        artist = "artist"
        for i in range(5):
            title = f"song_{i}"
            file_path = tmp_path / (title + ".mp3")
            track = create_track(file_path, title, artist)
            assert database.add_track(track=track)

        returned_albums = database.get_albums(artist=artist)
        assert returned_albums is not None
        assert len(returned_albums) == 0

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

        returned_albums = database.get_albums(artist=artist)
        assert returned_albums
        assert sorted(albums) == sorted(returned_albums)

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

        returned_albums = database.get_albums(artist=album_artist)
        assert returned_albums
        assert sorted(albums) == sorted(returned_albums)

    def test_get_albums__no_indpendant_artist_albums__returns_empty(
        self, tmp_path
    ):
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
            returned_albums = database.get_albums(artist=artist)
            assert returned_albums is not None
            assert len(returned_albums) == 0

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

        for duplicate_artist in duplicate_artists:
            returned_albums = database.get_albums(artist=duplicate_artist)
            assert returned_albums
            assert sorted(albums) == sorted(returned_albums)

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

        with pytest.raises(ValueError):
            database.get_albums(artist=artist, limit=0)

        with pytest.raises(ValueError):
            database.get_albums(artist=artist, limit=-1)

        with pytest.raises(ValueError):
            database.get_albums(artist=artist, limit=2000)

        with pytest.raises(ValueError):
            database.get_albums(artist=artist, offset=-1)

        returned_albums = database.get_albums(artist=artist, offset=1000)
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

        total_returned_albums = []
        returned_albums = database.get_albums(artist=artist, limit=1)
        assert returned_albums
        assert len(returned_albums) == 1
        total_returned_albums.append(returned_albums[0])

        offset = 1
        while returned_albums:
            returned_albums = database.get_albums(
                artist=artist, limit=1, offset=offset
            )
            offset += 1
            if returned_albums:
                assert len(returned_albums) == 1
                total_returned_albums.append(returned_albums[0])

        assert sorted(expected_albums) == sorted(total_returned_albums)

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

        # Albums with no artist (just a title and file)
        for i in range(2):
            title = f"song_no_artist_{i}"
            file_path = tmp_path / (title + ".mp3")
            album = f"no_artist_album_{i}"
            all_albums.add(album)
            track = create_track(file_path, title, "")
            track.metadata.album = album
            assert database.add_track(track=track)

        returned_albums = database.get_albums(artist=None)
        assert returned_albums is not None
        assert sorted(all_albums) == sorted(returned_albums)

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

        total_returned = []
        offset = 0
        while True:
            returned = database.get_albums(artist=None, limit=2, offset=offset)
            assert returned is not None
            if not returned:
                break
            total_returned.extend(returned)
            offset += 2

        assert sorted(all_albums) == sorted(total_returned)

    def test_get_albums__order_by_alphabetical__returns_sorted(self, tmp_path):
        database = set_up_database(database_path=tmp_path / "database.db")
        database.initialize()

        albums_to_insert = ["Zebra", "apple", "Mango", "banana", "Cherry"]
        for i, album in enumerate(albums_to_insert):
            title = f"song_{i}"
            file_path = tmp_path / (title + ".mp3")
            track = create_track(file_path, title, f"artist_{i}")
            track.metadata.album = album
            assert database.add_track(track=track)

        returned_albums = database.get_albums(artist=None, order_by="alphabetical")
        assert returned_albums is not None
        expected_order = sorted(albums_to_insert, key=str.lower)
        assert returned_albums == expected_order

    def test_get_albums__order_by_year__returns_year_sorted(self, tmp_path):
        database = set_up_database(database_path=tmp_path / "database.db")
        database.initialize()

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

        returned_albums = database.get_albums(artist=artist, order_by="year")
        assert returned_albums is not None
        assert returned_albums == ["Early Album", "Mid Album", "Late Album"]


class TestGetAlbumsCount:
    def test_get_albums_count__missing_artist__returns_0(self, tmp_path):
        database_path = tmp_path / "database.db"
        database = set_up_database(database_path=database_path)
        database.initialize()

        album_count = database.get_albums_count(artist="artist")
        assert album_count == 0

    def test_get_albums_count__no_albums__returns_0(self, tmp_path):
        database_path = tmp_path / "database.db"
        database = set_up_database(database_path=database_path)
        database.initialize()

        artist = "artist"
        for i in range(3):
            title = f"song_{i}"
            file_path = tmp_path / (title + ".mp3")
            track = create_track(file_path, title, artist)
            assert database.add_track(track=track)

        album_count = database.get_albums_count(artist=artist)

        assert album_count == 0

    def test_get_albums_count__albums__returns_count(self, tmp_path):
        database_path = tmp_path / "database.db"
        database = set_up_database(database_path=database_path)
        database.initialize()

        expected_ablums = set()
        artist = "artist"
        for i in range(3):
            title = f"song_{i}"
            album = f"album_{i}"
            expected_ablums.add(album)
            file_path = tmp_path / (title + ".mp3")
            track = create_track(file_path, title, artist)
            track.metadata.album = album
            assert database.add_track(track=track)

        album_count = database.get_albums_count(artist=artist)
        assert album_count == len(expected_ablums)

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

        for duplicate_artist in duplicate_artists:
            album_count = database.get_albums_count(artist=duplicate_artist)
            assert album_count
            assert len(albums) == album_count

    def test_get_albums_count__artist_ablums__returns_count(self, tmp_path):
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

        album_count = database.get_albums_count(artist=album_artist)
        assert album_count == len(expected_artist_albums)

        # Check that the individual artists do not have any albums
        # if only on artist album
        for artist in empty_artists:
            album_count = database.get_albums_count(artist=artist)
            assert album_count == 0

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

        album_count = database.get_albums_count(artist=artist)
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

        album_count = database.get_albums_count(artist=None)
        assert album_count == len(all_albums)
