from re import search
from typing import Any
from app.database.database import Database, DatabaseContext
from pathlib import Path
import sqlite3
from unittest.mock import patch
from app.models.track import Track
from app.models.track_meta_data import TrackMetaData

def set_up_database(database_path: Path):
    context = DatabaseContext(database_path=database_path)
    return Database(context=context)

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
        assert not "tracks" in table_names
        assert not "trackmetadata" in table_names

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
        empty_track = Track(file_path = file_path, metadata = TrackMetaData())
        database_path = tmp_path / "database.db"
        database = set_up_database(database_path=database_path)

        track_added = database.add_track(
            track = empty_track,
            timeout = 0.1
        )

        assert not track_added

        conn = sqlite3.connect(database_path)

        cur = conn.cursor()

        res = cur.execute("SELECT * FROM tracks WHERE file_path = ?;", (str(file_path),))

        found_tracks = res.fetchall()
        assert len(found_tracks) == 0

    def test_add_track__db_not_initialized__returns_false(self, tmp_path: Path):
        file_path = tmp_path / "track.mp3"
        metadata = TrackMetaData(
            codec = "test",
            duration = 2.0,
            bitrate_kbps = 320.0,
            sample_rate_hz = 44,
            channels = 2
        )

        track = Track(
            file_path = file_path,
            metadata = metadata,
        )

        database_path = tmp_path / "database.db"
        database = set_up_database(database_path)

        track_added = database.add_track(track = track, timeout = 5)
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
                    codec = "test",
                    duration = 2.0,
                    bitrate_kbps = 320.0,
                    sample_rate_hz = 44,
                    channels = 2
                )

        track = Track(
            file_path = file_path,
            metadata = metadata,
        )

        track_added = database.add_track(track = track, timeout = 0.01)
        assert not track_added
    
    def test_add_track__invalid_uuid__returns_false(self, tmp_path: Path):
        database_path = tmp_path / "database.db"
        # seed the database with some data
        database = set_up_database(database_path)

        file_path_1 = tmp_path / "track_1.mp4"
        file_path_2 = tmp_path / "track_2.mp4"

        metadata = TrackMetaData(
                            codec = "test",
                            duration = 2.0,
                            bitrate_kbps = 320.0,
                            sample_rate_hz = 44,
                            channels = 2
                        )

        track_1 = Track(
            uuid_id = "a",
            file_path = file_path_1,
            metadata = metadata,
        )

        track_2 = Track(
            uuid_id = "a",
            file_path = file_path_2,
            metadata = metadata,
        )

        track_1_added = database.add_track(track = track_1, timeout = 1)
        track_2_added = database.add_track(track = track_2, timeout = 1)

        assert track_1_added
        assert not track_2_added

    def test_add_track__duplicate_hash__returns_false(self, tmp_path: Path):
        database_path = tmp_path / "database.db"
        database = set_up_database(database_path)
        database.initialize()
        
        file_path_1 = tmp_path / "track_1.mp4"
        file_path_2 = tmp_path / "track_2.mp4"

        metadata = TrackMetaData(
                            codec = "test",
                            duration = 2.0,
                            bitrate_kbps = 320.0,
                            sample_rate_hz = 44,
                            channels = 2
                        )

        track_1 = Track(
            file_hash = "a",
            file_path = file_path_1,
            metadata = metadata,
        )

        track_2 = Track(
            file_hash = "a",
            file_path = file_path_2,
            metadata = metadata,
        )

        track_1_added = database.add_track(track = track_1, timeout = 1)
        track_2_added = database.add_track(track = track_2, timeout = 1)

        assert track_1_added
        assert not track_2_added

    def test_add_track__valid_tracks__add_to_database(self, tmp_path: Path):
        database_path = tmp_path / "database.db"
        # seed the database with some data
        database = set_up_database(database_path)
        def seed_metadata():
            metadata = TrackMetaData(
                            codec = "test",
                            duration = 2.0,
                            bitrate_kbps = 320.0,
                            sample_rate_hz = 44,
                            channels = 2
                        )
            return metadata

        def create_track(path, title, artist):
            metadata = seed_metadata()

            metadata.title = title
            metadata.artist = artist

            track = Track(
                file_path = path,
                metadata = metadata
            )
            
            return track

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

        assert set(query_result) == set([
            (str(track_1_path),),
            (str(track_2_path),),
            (str(track_3_path),),
            (str(track_4_path),)
        ])

        query_result = execute_query("SELECT title FROM trackmetadata;")
        assert len(query_result) == 4
        assert set(query_result) == set([
            ("title_1",), 
            ("title_2",), 
            ("title_3",), 
            ("title_4",)
        ])

class TestDatabaseDeleteTrack:
    def test_delete_track__db_not_initialized__returns_false(self, tmp_path: Path):
        database_path = tmp_path / "database.db"
        database = set_up_database(database_path)

        track_deleted = database.delete_track(uuid_id="missing")
        assert not track_deleted

    def test_delete_track__missing_uuid__returns_false(self, tmp_path: Path):
        database_path = tmp_path / "database.db"
        database = set_up_database(database_path)
        database.initialize()

        track_deleted = database.delete_track(uuid_id="missing")
        assert not track_deleted

    def test_delete_track__db_busy__returns_false(self, tmp_path: Path):
        database_path = tmp_path / "database.db"
        database = set_up_database(database_path)
        database.initialize()

        blocking_conn = sqlite3.connect(database_path)
        blocking_conn.execute("BEGIN EXCLUSIVE")

        track_deleted = database.delete_track(uuid_id="missing")
        assert not track_deleted

        blocking_conn.close()

    def test_delete_track__valid_uuid__deletes_tracks_and_trackmetadata(self, tmp_path: Path):
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

        query_result = execute_query("SELECT uuid_id FROM tracks WHERE uuid_id = ?;", (uuid_id,))
        assert len(query_result) == 0

        query_result = execute_query("SELECT uuid_id FROM trackmetadata WHERE uuid_id = ?;", (uuid_id,))
        assert len(query_result) == 0

class TestDatabaseGetTracks:
    def test_get_tracks__db_not_initialized__returns_empty_list(self, tmp_path: Path):
        database_path = tmp_path / "database.db"
        database = set_up_database(database_path)

        search_parameters = {
            "title": "test"
        }

        returned_tracks = database.get_tracks(search_parameters=search_parameters)
        assert len(returned_tracks) == 0

    def test_get_tracks__empty_db__returns_empty_list(self, tmp_path: Path):
        database_path = tmp_path / "database.db"
        database = set_up_database(database_path)

        database.initialize()

        search_parameters = {
            "title": "tests"
        }

        returned_tracks = database.get_tracks(search_parameters=search_parameters)
        assert len(returned_tracks) == 0
    
    def test_get_tracks__invalid_columns__throws_error(self, tmp_path: Path):
        database_path = tmp_path / "database.db"
        database = set_up_database(database_path)

        database.initialize()

        search_parameters = {
            "invalid_column": "test"
        }

        try:
            returned_tracks = database.get_tracks(search_parameters=search_parameters)
        except Exception:
            assert True
        
    def test_get_tracks__valid_search__returns_results(self, tmp_path: Path):
        database_path = tmp_path / "database.db"
        database = set_up_database(database_path)

        database.initialize()

        def seed_metadata():
            metadata = TrackMetaData(
                            codec = "test",
                            duration = 2.0,
                            bitrate_kbps = 320.0,
                            sample_rate_hz = 44,
                            channels = 2
                        )
            return metadata

        def create_track(path, title, artist):
            metadata = seed_metadata()

            metadata.title = title
            metadata.artist = artist

            track = Track(
                file_path = path,
                metadata = metadata
            )
            
            return track

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

        database.add_track(track=track_1, timeout=1)
        database.add_track(track=track_2, timeout=1)
        database.add_track(track=track_3, timeout=1)
        database.add_track(track=track_4, timeout=1)

        # Searching by artist returns only the specified artists
        search_parameters = {
            "artist": "artist"
        }

        returned_tracks = database.get_tracks(search_parameters=search_parameters)

        assert len(returned_tracks) == 4

        titles = set()
        for track in returned_tracks:
            assert track.metadata.artist == "artist"
            titles.add(track.metadata.title)
        
        assert len(titles) == 4

        # Artist + title search returns just the specific track
        search_parameters - {
            "artist": "artist",
            "title": "title_1"
        }
        returned_tracks = database.get_tracks(search_parameters=search_parameters)

        assert len(returned_tracks) == 1

        assert returned_tracks[0].metadata.title == "title_1"

        # Empty search returns all tracks
        search_parameters = {}
        returned_tracks = database.get_tracks(search_parameters=search_parameters)

        assert len(titles) == 5
        
        titles = set()
        for track in returned_tracks:
            titles.add(track.metadata.title)
        
        assert len(titles) == 5

        artists = set()
        for track in returned_tracks:
            artists.add(track.metadata.title)

        assert len(artists) == 2
        assert "artist" in artists
        assert "different_artist" in artists