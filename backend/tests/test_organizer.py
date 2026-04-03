from __future__ import annotations

from pathlib import Path
from unittest.mock import Mock, patch

import pytest

import app.services.organizer as organizer
from app.services.cover_art_manager import CoverArtAddResult
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
    def _create_organizing_moving_organizer(
        self,
        music_dir: Path,
        *,
        add_to_database=lambda x: True,
        add_cover_art=None,
        remove_cover_art=None,
    ):
        ctx = organizer.OrganizerContext(
            music_library_dir=music_dir,
            should_organize_files=True,
            should_copy_files=False,
            add_to_database=add_to_database,
            add_cover_art=add_cover_art,
            remove_cover_art=remove_cover_art,
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
            ({"duration": 1.0, "artist": "artist", "album": "album", "album_artist": "album_artist"}, "album_artist/album"),
        ],
        ids=[
            "album-and-artist",
            "artist-only",
            "no-artist-or-album",
            "album-artist"
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

    def test_organize_file__move_failure__cleans_up_new_cover_art(self, tmp_path: Path):
        music_dir = Path(tmp_path / "music")
        add_cover_art = Mock(return_value=CoverArtAddResult(cover_art_id=7, was_created=True))
        remove_cover_art = Mock(return_value=True)
        organize = self._create_organizing_moving_organizer(
            music_dir=music_dir,
            add_cover_art=add_cover_art,
            remove_cover_art=remove_cover_art,
        )

        file_path = tmp_path / "file.mp3"
        file_path.touch()
        file_path.write_bytes(b"dataaaaaaaaaa")

        with (
            patch("app.services.organizer.get_track_metadata") as get_track_metadata,
            patch("app.services.organizer.extract_cover_art_bytes", return_value=b"art"),
            patch("app.services.organizer.move_file", return_value=False),
        ):
            get_track_metadata.return_value = TrackMetaData(
                duration=1.0,
                artist="artist",
                has_album_art=True,
            )

            result = organize.organize_file(file_path=file_path)

        assert result is False
        add_cover_art.assert_called_once_with(b"art")
        remove_cover_art.assert_called_once_with(7)

    def test_organize_file__database_failure__rolls_back_file_and_cover_art(self, tmp_path: Path):
        music_dir = Path(tmp_path / "music")
        add_cover_art = Mock(return_value=CoverArtAddResult(cover_art_id=11, was_created=True))
        remove_cover_art = Mock(return_value=True)
        organize = self._create_organizing_moving_organizer(
            music_dir=music_dir,
            add_to_database=lambda _: False,
            add_cover_art=add_cover_art,
            remove_cover_art=remove_cover_art,
        )

        file_path = tmp_path / "file.mp3"
        file_path.touch()
        file_path.write_bytes(b"dataaaaaaaaaa")

        with (
            patch("app.services.organizer.get_track_metadata") as get_track_metadata,
            patch("app.services.organizer.extract_cover_art_bytes", return_value=b"art"),
        ):
            get_track_metadata.return_value = TrackMetaData(
                duration=1.0,
                artist="artist",
                has_album_art=True,
            )

            result = organize.organize_file(file_path=file_path)

        destination_path = music_dir / "artist" / "file.mp3"
        assert result is False
        assert file_path.exists()
        assert not destination_path.exists()
        remove_cover_art.assert_called_once_with(11)

    def test_organize_file__database_failure__does_not_remove_reused_cover_art(self, tmp_path: Path):
        music_dir = Path(tmp_path / "music")
        remove_cover_art = Mock(return_value=True)
        organize = self._create_organizing_moving_organizer(
            music_dir=music_dir,
            add_to_database=lambda _: False,
            add_cover_art=lambda _: CoverArtAddResult(cover_art_id=22, was_created=False),
            remove_cover_art=remove_cover_art,
        )

        file_path = tmp_path / "file.mp3"
        file_path.touch()
        file_path.write_bytes(b"dataaaaaaaaaa")

        with (
            patch("app.services.organizer.get_track_metadata") as get_track_metadata,
            patch("app.services.organizer.extract_cover_art_bytes", return_value=b"art"),
        ):
            get_track_metadata.return_value = TrackMetaData(
                duration=1.0,
                artist="artist",
                has_album_art=True,
            )

            result = organize.organize_file(file_path=file_path)

        assert result is False
        remove_cover_art.assert_not_called()
