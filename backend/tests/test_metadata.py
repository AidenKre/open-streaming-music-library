from __future__ import annotations

import json
import subprocess
from pathlib import Path
from unittest.mock import patch

import pytest

import app.services.metadata as metadata

class TestGetTrackMetadata:
    def test_get_track_metadata__ffprobe_returns_none__returns_none(self, tmp_path: Path):
        with patch("app.services.metadata.ffprobe_for_metadata", return_value=None):
            assert metadata.get_track_metadata(tmp_path / "song.mp3") is None

    def test_get_track_metadata__build_returns_none__returns_none(self, tmp_path: Path):
        with patch("app.services.metadata.ffprobe_for_metadata", return_value={"streams": [], "format": {}}), patch(
            "app.services.metadata.build_track_metadata", return_value=None
        ):
            assert metadata.get_track_metadata(tmp_path / "song.mp3") is None

    def test_get_track_metadata__valid_file__returns_track_metadata(self):
        fake_ffprobe_response = {
            "streams": [
                {
                    "index": 0,
                    "codec_name": "aac",
                    "codec_long_name": "AAC (Advanced Audio Coding)",
                    "profile": "LC",
                    "codec_type": "audio",
                    "sample_rate": "44100",
                    "channels": 2,
                    "duration": "181.0",
                    "bit_rate": "256000",
                    "disposition": {
                        "attached_pic": 0,
                    },
                },
                {
                    "index": 1,
                    "codec_name": "mjpeg",
                    "codec_long_name": "Motion JPEG",
                    "profile": "Baseline",
                    "codec_type": "video",
                    "disposition": {
                        "attached_pic": 1,
                    },
                }
            ],
            "format": {
                "filename": "Test Artist - Test Album - 01 Test Title.m4a",
                "duration": "181.0",
                "bit_rate": "256000",
                "tags": {
                    "album_artist": "Test Album Artist",
                    "track": "1",
                    "artist": "Test Artist",
                    "album": "Test Album",
                    "date": "2021-06-01",
                    "title": "Test Title",
                    "genre": "Electronic"
                }
            }
        }

        with patch("app.services.metadata.ffprobe_for_metadata", return_value=fake_ffprobe_response):
            track_metadata = metadata.get_track_metadata(Path("test.mp3"))
            assert track_metadata is not None

            # Check expected fields from the test data above
            assert track_metadata.title == "Test Title"
            assert track_metadata.artist == "Test Artist"
            assert track_metadata.album == "Test Album"
            assert track_metadata.album_artist == "Test Album Artist"
            # Should parse the year from "date" tag
            assert track_metadata.year == 2021
            assert track_metadata.track_number == 1
            assert track_metadata.genre == "Electronic"
            assert track_metadata.duration == 181.0
            assert track_metadata.bitrate_kbps == 256.0  # 256000 / 1000
            assert track_metadata.sample_rate_hz == 44100
            assert track_metadata.channels == 2
            assert track_metadata.has_album_art is True

class TestFfprobeForMetadata:
    def test_ffprobe_for_metadata__ffprobe_missing__returns_none(self):
        with patch("app.services.metadata.subprocess.run", side_effect=FileNotFoundError):
            assert metadata.ffprobe_for_metadata(Path("song.mp3")) is None

    def test_ffprobe_for_metadata__oserror__returns_none(self):
        with patch("app.services.metadata.subprocess.run", side_effect=OSError):
            assert metadata.ffprobe_for_metadata(Path("song.mp3")) is None

    def test_ffprobe_for_metadata__nonzero_exit_code__returns_none(self, tmp_path: Path):
        with patch("app.services.metadata.subprocess.run") as subprocess_run:
            subprocess_run.return_value = subprocess.CompletedProcess(
                args=["ffprobe"],
                returncode=1,
                stdout="",
                stderr="",
            )
            json_data = metadata.ffprobe_for_metadata(tmp_path / "empty.mp3")
            assert json_data is None

    def test_ffprobe_for_metadata__valid_file__returns_output_json(self):
        with patch("app.services.metadata.subprocess.run") as subprocess_run:
            fake_output_json = {
                "streams": [],
                "format": {
                    "tags": {
                        "title": "Test",
                        "artist": "Test",
                    }
                }
            }
            subprocess_run.return_value = subprocess.CompletedProcess(
                args=["ffprobe"],
                returncode=0,
                stdout=json.dumps(fake_output_json),
                stderr="",
            )

            json_data = metadata.ffprobe_for_metadata(Path("test.mp3"))
            assert json_data is not None
            assert json_data == fake_output_json

    def test_ffprobe_for_metadata__invalid_json__returns_none(self):
        with patch("app.services.metadata.subprocess.run") as subprocess_run:
            subprocess_run.return_value = subprocess.CompletedProcess(
                args=["ffprobe"],
                returncode=0,
                stdout="invalid json",
                stderr="",
            )
            json_data = metadata.ffprobe_for_metadata(Path("test.mp3"))
            assert json_data is None

    def test_ffprobe_for_metadata__empty_stdout__returns_empty_dict(self):
        with patch("app.services.metadata.subprocess.run") as subprocess_run:
            subprocess_run.return_value = subprocess.CompletedProcess(
                args=["ffprobe"],
                returncode=0,
                stdout="",
                stderr="",
            )
            assert metadata.ffprobe_for_metadata(Path("test.mp3")) == {}

class TestBuildTrackMetadata:
    def test_build_track_metadata__none_json__returns_none(self):
        assert metadata.build_track_metadata(None) is None

    def test_build_track_metadata__empty_json__returns_none(self):
        assert metadata.build_track_metadata({}) is None

    def test_build_track_metadata__valid_json__returns_track_metadata(self):
        json_data = {
            "streams": [
                {
                    "codec_type": "audio",
                    "duration": "181.0",
                    "bit_rate": "256000",
                    "sample_rate": "44100",
                    "channels": 2,
                }
            ],
            "format": {
                "tags": {
                    "title": "Test",
                    "artist": "Test",
                }
            }
        }
        track_metadata = metadata.build_track_metadata(json_data)
        assert track_metadata is not None
        assert track_metadata.title == "Test"
        assert track_metadata.artist == "Test"

    def test_build_track_metadata__no_audio_stream__returns_none(self):
        json_data = {
            "streams": [
                {
                    "codec_type": "video",
                }
            ],
            "format": {
                "tags": {
                    "title": "Test",
                    "artist": "Test",
                }
            }
        }
        assert metadata.build_track_metadata(json_data) is None
    
    def test_build_track_metadata__audio_stream_missing_numeric_fields__returns_none(self):
        json_data = {
            "streams": [
                {
                    "codec_type": "audio",
                }
            ],
        }
        assert metadata.build_track_metadata(json_data) is None
    
    def test_build_track_metadata__has_album_art__track_metadata_has_album_art(self):
        json_data = {
            "streams": [
                {
                    "codec_type": "audio",
                    "duration": "181.0",
                    "bit_rate": "256000",
                    "sample_rate": "44100",
                    "channels": 2,
                },
                {
                    "disposition": {
                        "attached_pic": 1,
                    },
                }
            ],
            "format": {
                "tags": {
                    "title": "Test",
                    "artist": "Test",
                }
            }
        }
        track_metadata = metadata.build_track_metadata(json_data)
        assert track_metadata is not None
        assert track_metadata.has_album_art is True

    @pytest.mark.parametrize(
        ("date_val", "expected_year"),
        [
            ("2021-06-01", 2021),
            ("2021", 2021),
            ("", None),
            ("not-a-year", None),
            (None, None),
        ],
    )
    def test_build_track_metadata__date_tag_parsing(self, date_val: object, expected_year: int | None):
        json_data = {
            "streams": [{"codec_type": "audio", "duration": "1", "bit_rate": "1000", "sample_rate": "1", "channels": 1}],
            "format": {"tags": {"title": "T", "artist": "A", "date": date_val}},
        }
        track_metadata = metadata.build_track_metadata(json_data)
        assert track_metadata is not None
        assert track_metadata.year == expected_year

    @pytest.mark.parametrize(
        ("track_val", "expected_track_number"),
        [
            ("1", 1),
            ("1/12", 1),
            ("", None),
            ("A/12", None),
            (None, None),
        ],
    )
    def test_build_track_metadata__track_tag_parsing(self, track_val: object, expected_track_number: int | None):
        json_data = {
            "streams": [{"codec_type": "audio", "duration": "1", "bit_rate": "1000", "sample_rate": "1", "channels": 1}],
            "format": {"tags": {"title": "T", "artist": "A", "track": track_val}},
        }
        track_metadata = metadata.build_track_metadata(json_data)
        assert track_metadata is not None
        assert track_metadata.track_number == expected_track_number