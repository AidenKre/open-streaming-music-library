from __future__ import annotations

from operator import add
from pathlib import Path
from unittest.mock import patch

import pytest

import app.services.organizer as organizer
from app.models.track_meta_data import TrackMetaData

class TestMoveFile:
    def test_move_file__source_does_not_exist__does_not_move_file(self, tmp_path: Path):
        file_path = tmp_path / "does_not_exist.mp3"

        destination_dir = tmp_path / "destination"
        file_destination_path = tmp_path / destination_dir / "does_not_exist.mp3"

        result =organizer.move_file(file_path, file_destination_path)

        assert result is False
        assert not file_destination_path.is_file()
        assert not destination_dir.is_dir()
    
    def test_move_file__source_does_exist__moves_files(self, tmp_path: Path):
        file_path = tmp_path / "file.mp3"
        file_path.touch()
        file_path.write_bytes(b"fake")

        destination_dir = Path(tmp_path / "music")
        destination_path = Path(destination_dir / "file.mp3")
        result = organizer.move_file(file_path, destination_path)
        
        assert result is True
        assert destination_dir.is_dir()
        assert destination_path.is_file()
    
class TestOrganizer:
    def _create_organizing_moving_organizer(self, music_dir: Path):
        ctx = organizer.OrganizerContext(
            music_library_dir=music_dir,
            should_organize_files=True,
            should_copy_files=False,
            add_to_database=lambda x: True,
        )
        return organizer.Organizer(ctx)
    
    def _create_nonorganizing_organizer(self, music_dir: Path):
        ctx = organizer.OrganizerContext(
            music_library_dir=music_dir,
            should_organize_files=False,
            should_copy_files=False,
            add_to_database=lambda x: True,
        )
        return organizer.Organizer(ctx)
    
    def test_organize_file__organizing_moving_source_does_not_exist__does_not_organize(self, tmp_path: Path):
        music_dir = Path(tmp_path / "music")
        organize = self._create_organizing_moving_organizer(music_dir=music_dir)
        file_path = tmp_path / "input/fake_file.mp3"

        result = organize.organize_file(file_path=file_path)

        assert result is False
        assert not music_dir.exists()
        assert not (tmp_path / "input").exists()
    
    def test_organize_file__organizing_moving_empty_song__does_not_organize(self, tmp_path: Path):
        music_dir = Path(tmp_path / "music")
        organize = self._create_organizing_moving_organizer(music_dir=music_dir)

        file_path = tmp_path / "file.mp3"
        file_path.touch()
        file_path.write_bytes(b"dataaaaa")

        with patch("app.services.organizer.get_track_metadata") as get_track_metadata:
            with patch.object(TrackMetaData, "is_empty", return_value=True):
                trackmetadata = TrackMetaData()
                get_track_metadata.return_value = trackmetadata

                result = organize.organize_file(file_path=file_path)

                assert result is False
                assert not music_dir.exists()
                assert not Path(music_dir / "file.mp3").exists()

    @pytest.mark.parametrize(
        "trackmeta_kwargs, expected_subdir",
        [
            ({"duration": 1.0, "artist": "artist", "album": "album"}, "artist/album"),
            ({"duration": 1.0, "artist": "artist"}, "artist"),
            ({"duration": 1.0}, ""),
        ],
        ids=[
            "album-and-artist",
            "artist-only",
            "no-artist-or-album",
        ]
    )
    def test_organize_file__organizing_moving_various_scenarios(self, tmp_path: Path, trackmeta_kwargs, expected_subdir):
        music_dir = Path(tmp_path / "music")
        organize = self._create_organizing_moving_organizer(music_dir=music_dir)
        
        file_path = tmp_path / "file.mp3"
        file_path.touch()
        file_path.write_bytes(b"dataaaaaaaaaa")

        with patch("app.services.organizer.get_track_metadata") as get_track_metadata:
            trackmetadata = TrackMetaData(**trackmeta_kwargs)
            get_track_metadata.return_value = trackmetadata

            result = organize.organize_file(file_path=file_path)

            assert result is True

            if expected_subdir:
                organized_dir = music_dir / expected_subdir
            else:
                organized_dir = music_dir

            assert Path(organized_dir).is_dir()
            organized_file_path = Path(organized_dir / "file.mp3")
            assert organized_file_path.is_file()
