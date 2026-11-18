from __future__ import annotations

import json
import subprocess
from pathlib import Path
from unittest.mock import patch

import pytest

import app.services.metadata as metadata
from app.services.ffmpeg_runner import (
    CaptureOverflow,
    CaptureResult,
    CaptureTimeout,
    FfmpegError,
    FfmpegProcessRegistry,
)


def _completed(args, returncode, stdout, stderr):
    """What ``run_capture`` returns for a finished probe (U05-A-06: the probes
    run through it, bounded)."""
    return CaptureResult(returncode=returncode, stdout=stdout.encode("utf-8"), stderr=stderr)


class TestGetTrackMetadata:
    def test_get_track_metadata__ffprobe_returns_none__returns_none(
        self, tmp_path: Path
    ):
        with patch("app.services.metadata.ffprobe_for_metadata", return_value=None):
            assert metadata.get_track_metadata(tmp_path / "song.mp3") is None

    def test_get_track_metadata__build_returns_none__returns_none(self, tmp_path: Path):
        with (
            patch(
                "app.services.metadata.ffprobe_for_metadata",
                return_value={"streams": [], "format": {}},
            ),
            patch("app.services.metadata.build_track_metadata", return_value=None),
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
                },
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
                    "genre": "Electronic",
                },
            },
        }

        with patch(
            "app.services.metadata.ffprobe_for_metadata",
            return_value=fake_ffprobe_response,
        ):
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

            assert track_metadata.codec == "aac"
            assert track_metadata.duration == 181.0
            assert track_metadata.bitrate_kbps == 256.0  # 256000 / 1000
            assert track_metadata.sample_rate_hz == 44100
            assert track_metadata.channels == 2
            assert track_metadata.has_album_art is True


class TestFfprobeForMetadata:
    def test_ffprobe_for_metadata__ffprobe_missing__returns_none(self):
        with patch(
            "app.services.ffmpeg_runner.subprocess.Popen", side_effect=FileNotFoundError
        ):
            assert metadata.ffprobe_for_metadata(Path("song.mp3")) is None

    def test_ffprobe_for_metadata__oserror__returns_none(self):
        with patch("app.services.ffmpeg_runner.subprocess.Popen", side_effect=OSError):
            assert metadata.ffprobe_for_metadata(Path("song.mp3")) is None

    def test_ffprobe_for_metadata__nonzero_exit_code__returns_none(
        self, tmp_path: Path
    ):
        with patch("app.services.metadata.run_capture", autospec=True) as subprocess_run:
            subprocess_run.return_value = _completed(
                args=["ffprobe"],
                returncode=1,
                stdout="",
                stderr="",
            )
            json_data = metadata.ffprobe_for_metadata(tmp_path / "empty.mp3")
            assert json_data is None

    def test_ffprobe_for_metadata__valid_file__returns_output_json(self):
        with patch("app.services.metadata.run_capture", autospec=True) as subprocess_run:
            fake_output_json = {
                "streams": [],
                "format": {
                    "tags": {
                        "title": "Test",
                        "artist": "Test",
                    }
                },
            }
            subprocess_run.return_value = _completed(
                args=["ffprobe"],
                returncode=0,
                stdout=json.dumps(fake_output_json),
                stderr="",
            )

            json_data = metadata.ffprobe_for_metadata(Path("test.mp3"))
            assert json_data is not None
            assert json_data == fake_output_json

    def test_ffprobe_for_metadata__invalid_json__returns_none(self):
        with patch("app.services.metadata.run_capture", autospec=True) as subprocess_run:
            subprocess_run.return_value = _completed(
                args=["ffprobe"],
                returncode=0,
                stdout="invalid json",
                stderr="",
            )
            json_data = metadata.ffprobe_for_metadata(Path("test.mp3"))
            assert json_data is None

    def test_ffprobe_for_metadata__empty_stdout__returns_empty_dict(self):
        with patch("app.services.metadata.run_capture", autospec=True) as subprocess_run:
            subprocess_run.return_value = _completed(
                args=["ffprobe"],
                returncode=0,
                stdout="",
                stderr="",
            )
            assert metadata.ffprobe_for_metadata(Path("test.mp3")) == {}


class TestTheMetadataProbesReadExitsLikeTheSharedRule:
    """Review of U05-A-06 (finding 4): an OSError while starting is "cannot
    run now". On Phase 8 any signal is "unreadable for now" (recovery's D1);
    the import quick check keeps the SIGKILL-only rule (test_ingestion)."""

    def test_a_sigkill_is_unavailable_for_now_when_asked(self):
        import signal

        with patch("app.services.metadata.run_capture", autospec=True,
                   return_value=_completed([], -signal.SIGKILL, "", "")):
            assert metadata.ffprobe_for_metadata(Path("a.flac")) is None
            with metadata.probe_unavailable_raises(), pytest.raises(metadata.ProbeUnavailable):
                metadata.ffprobe_for_metadata(Path("a.flac"))

    @pytest.mark.parametrize("sig", ["SIGSEGV", "SIGABRT", "SIGTERM"])
    def test_another_signal_is_unavailable_for_now_too(self, sig):
        """Phase 8: startup recovery's content rule (D1) deletes a leftover
        only when ffprobe refuses it, so a probe killed by any signal reads as
        unknown here (test_recovery_audio "crashed"); outside the block None."""
        import signal

        with patch("app.services.metadata.run_capture", autospec=True,
                   return_value=_completed([], -getattr(signal, sig), "", "")):
            assert metadata.ffprobe_for_metadata(Path("a.flac")) is None
            with metadata.probe_unavailable_raises(), pytest.raises(metadata.ProbeUnavailable):
                metadata.ffprobe_for_metadata(Path("a.flac"))

    def test_an_oserror_while_starting_is_unavailable_for_now(self):
        import errno

        error = OSError(errno.EMFILE, "Too many open files")
        with patch("app.services.metadata.run_capture", autospec=True, side_effect=error):
            assert metadata.ffprobe_for_metadata(Path("a.flac")) is None
            assert metadata.get_audio_bitrate_kbps(Path("a.flac")) is None
            with metadata.probe_unavailable_raises(), pytest.raises(metadata.ProbeUnavailable):
                metadata.ffprobe_for_metadata(Path("a.flac"))


class TestBuildTrackMetadata:
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
            },
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
            },
        }
        assert metadata.build_track_metadata(json_data) is None

    def test_build_track_metadata__audio_stream_missing_numeric_fields__returns_none(
        self,
    ):
        json_data = {
            "streams": [
                {
                    "codec_type": "audio",
                }
            ],
        }
        assert metadata.build_track_metadata(json_data) is None

    def test_build_track_metadata__no_stream_bit_rate__falls_back_to_format(self):
        # FLAC: ffprobe reports no stream-level bit_rate, only format.bit_rate.
        json_data = {
            "streams": [
                {
                    "codec_type": "audio",
                    "codec_name": "flac",
                    "duration": "60.0",
                    "sample_rate": "44100",
                    "channels": 2,
                }
            ],
            "format": {"bit_rate": "912345"},
        }
        track_metadata = metadata.build_track_metadata(json_data)
        assert track_metadata is not None
        assert track_metadata.bitrate_kbps == pytest.approx(912.345)

    def test_build_track_metadata__stream_bit_rate_preferred_over_format(self):
        json_data = {
            "streams": [
                {
                    "codec_type": "audio",
                    "codec_name": "mp3",
                    "duration": "60.0",
                    "bit_rate": "320000",
                    "sample_rate": "44100",
                    "channels": 2,
                }
            ],
            # Includes embedded art, so it's higher than the audio bitrate.
            "format": {"bit_rate": "350000"},
        }
        track_metadata = metadata.build_track_metadata(json_data)
        assert track_metadata is not None
        assert track_metadata.bitrate_kbps == pytest.approx(320.0)

    def test_build_track_metadata__unparseable_bit_rates__unknown(self):
        json_data = {
            "streams": [
                {
                    "codec_type": "audio",
                    "codec_name": "flac",
                    "duration": "60.0",
                    "bit_rate": "N/A",
                    "sample_rate": "44100",
                    "channels": 2,
                }
            ],
            "format": {"bit_rate": "N/A"},
        }
        track_metadata = metadata.build_track_metadata(json_data)
        assert track_metadata is not None
        assert track_metadata.bitrate_kbps is None

    def test_build_track_metadata__no_bit_rate_anywhere__unknown(self):
        json_data = {
            "streams": [
                {
                    "codec_type": "audio",
                    "codec_name": "flac",
                    "duration": "60.0",
                    "sample_rate": "44100",
                    "channels": 2,
                }
            ],
        }
        track_metadata = metadata.build_track_metadata(json_data)
        assert track_metadata is not None
        assert track_metadata.bitrate_kbps is None

    def test_build_track_metadata__reported_zero_bit_rate__kept_as_zero(self):
        # A real "0" from ffprobe is information, not "unknown": keep it, and
        # don't fall back to the container figure.
        json_data = {
            "streams": [
                {
                    "codec_type": "audio",
                    "codec_name": "pcm_s16le",
                    "duration": "60.0",
                    "bit_rate": "0",
                    "sample_rate": "44100",
                    "channels": 2,
                }
            ],
            "format": {"bit_rate": "1411200"},
        }
        track_metadata = metadata.build_track_metadata(json_data)
        assert track_metadata is not None
        assert track_metadata.bitrate_kbps == 0.0

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
                },
            ],
            "format": {
                "tags": {
                    "title": "Test",
                    "artist": "Test",
                }
            },
        }
        track_metadata = metadata.build_track_metadata(json_data)
        assert track_metadata is not None
        assert track_metadata.has_album_art is True

    def test_build_track_metadata__capitlized_tags__build_trackmetadata(self):
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
                    "TITLE": "Test",
                    "ARTIST": "Test",
                }
            },
        }

        track_metadata = metadata.build_track_metadata(json_data)
        assert track_metadata is not None
        assert track_metadata.title == "Test"
        assert track_metadata.artist == "Test"

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
    def test_build_track_metadata__date_tag_parsing(
        self, date_val: object, expected_year: int | None
    ):
        json_data = {
            "streams": [
                {
                    "codec_type": "audio",
                    "duration": "1",
                    "bit_rate": "1000",
                    "sample_rate": "1",
                    "channels": 1,
                }
            ],
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
    def test_build_track_metadata__track_tag_parsing(
        self, track_val: object, expected_track_number: int | None
    ):
        json_data = {
            "streams": [
                {
                    "codec_type": "audio",
                    "duration": "1",
                    "bit_rate": "1000",
                    "sample_rate": "1",
                    "channels": 1,
                }
            ],
            "format": {"tags": {"title": "T", "artist": "A", "track": track_val}},
        }
        track_metadata = metadata.build_track_metadata(json_data)
        assert track_metadata is not None
        assert track_metadata.track_number == expected_track_number


class TestExtractCoverArtBytes:
    # Pre-merge A3-04: the extraction runs through the bounded runner
    # (run_capture), so these fakes stand in for it, not for subprocess.run.
    # The answers are the ones the subprocess.run fakes pinned before.

    @staticmethod
    def _runner(monkeypatch, result=None, raises=None):
        def fake(cmd, **kwargs):
            if raises is not None:
                raise raises
            return result
        monkeypatch.setattr(metadata, "run_capture", fake)

    def test_returns_none_on_timeout(self, monkeypatch):
        self._runner(monkeypatch, raises=CaptureTimeout("ffmpeg timed out after 30s"))
        assert metadata.extract_cover_art_bytes(Path("/fake/file.mp3")) is None

    def test_returns_none_when_ffmpeg_not_found(self, monkeypatch):
        self._runner(monkeypatch, raises=FfmpegError("ffmpeg not found", category="not found"))
        assert metadata.extract_cover_art_bytes(Path("/fake/file.mp3")) is None

    def test_returns_none_on_nonzero_exit(self, monkeypatch):
        self._runner(monkeypatch, result=CaptureResult(1, b"", ""))
        assert metadata.extract_cover_art_bytes(Path("/fake/file.mp3")) is None

    def test_returns_bytes_on_success(self, monkeypatch):
        self._runner(monkeypatch, result=CaptureResult(0, b"\x89PNG fake image data", ""))
        assert metadata.extract_cover_art_bytes(Path("/fake/file.mp3")) == b"\x89PNG fake image data"

    def test_a_cover_over_the_output_bound_is_no_cover(self, monkeypatch):
        self._runner(monkeypatch, raises=CaptureOverflow("ffmpeg stdout exceeded 16777216 bytes"))
        assert metadata.extract_cover_art_bytes(Path("/fake/file.mp3")) is None


# --- pre-merge A3-04: the cover extraction on staged upload bytes is bounded ---------


def _ffmpeg_make(*args):
    subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-y", *args], check=True)


def _jpeg_count(data: bytes) -> int:
    return data.count(b"\xff\xd8\xff")


@pytest.mark.requires_ffmpeg
class TestCoverArtExtractionIsBounded:
    @pytest.fixture(scope="class")
    def files(self, tmp_path_factory):
        root = tmp_path_factory.mktemp("cover-bound")
        video = root / "video.m4a"  # an .m4a carrying a real video stream: 50 frames
        _ffmpeg_make("-f", "lavfi", "-i", "sine=frequency=440:duration=2",
                     "-f", "lavfi", "-i", "testsrc=size=128x128:rate=25:duration=2",
                     "-map", "0:a", "-map", "1:v", "-c:a", "aac", "-c:v", "mjpeg", "-f", "mp4", str(video))
        cover = root / "cover.m4a"  # an ordinary attached picture
        _ffmpeg_make("-f", "lavfi", "-i", "sine=frequency=440:duration=1",
                     "-f", "lavfi", "-i", "testsrc=size=128x128:rate=1:duration=1",
                     "-map", "0:a", "-map", "1:v", "-c:a", "aac", "-c:v", "mjpeg",
                     "-frames:v", "1", "-disposition:v", "attached_pic", "-f", "mp4", str(cover))
        return {"video": video, "cover": cover}

    def test_a_video_stream_gives_one_picture_not_the_whole_stream(self, files):
        data = metadata.extract_cover_art_bytes(files["video"], input_format="mov")
        assert data is not None and _jpeg_count(data) == 1

    def test_an_ordinary_cover_is_still_read(self, files):
        data = metadata.extract_cover_art_bytes(files["cover"], input_format="mov")
        assert data is not None and _jpeg_count(data) == 1

    def test_a_picture_larger_than_the_bound_is_no_cover(self, files, monkeypatch):
        monkeypatch.setattr(metadata, "COVER_ART_MAX_BYTES", 1024, raising=False)
        assert metadata.extract_cover_art_bytes(files["cover"], input_format="mov") is None

    def test_a_shutdown_kills_the_extraction(self, files):
        registry = FfmpegProcessRegistry()
        registry.close()  # shutting down: every run registered from now on is killed
        with metadata.probes_killed_by(registry):
            assert metadata.extract_cover_art_bytes(files["cover"], input_format="mov") is None


# --- U05-A-06: every probe here is bounded ---------------------------------------
# A fake ffprobe that never answers stands in for a hung tool (a stalled disk, a
# crafted file). Each probe must come back within the bound
# (audio_identity.PROBE_TIMEOUT_S, shortened for the test): "unreadable for now",
# never a hang, and never reported as a missing tool.


@pytest.mark.integration
class TestProbesAreBounded:
    @pytest.fixture(autouse=True)
    def _hanging(self, monkeypatch, tmp_path):
        from tests import hanging_ffprobe

        hanging_ffprobe.install(monkeypatch, tmp_path)
        hanging_ffprobe.shorten_bound(monkeypatch)
        self.audio = tmp_path / "song.flac"
        self.audio.write_bytes(b"not read: the fake never looks at it")

    def test_a_hung_metadata_probe_answers_none_within_the_bound(self):
        from tests.hanging_ffprobe import WITHIN_S, timed

        with timed() as elapsed:
            result = metadata.ffprobe_for_metadata(self.audio)

        assert elapsed() < WITHIN_S
        assert result is None

    def test_a_hung_metadata_probe_is_unavailable_for_now_when_asked(self):
        from tests.hanging_ffprobe import WITHIN_S, timed

        with timed() as elapsed:
            with metadata.probe_unavailable_raises(), pytest.raises(metadata.ProbeUnavailable) as raised:
                metadata.get_track_metadata(self.audio)

        assert elapsed() < WITHIN_S
        assert "not found" not in str(raised.value)

    def test_a_hung_bitrate_probe_answers_unknown_within_the_bound(self):
        from tests.hanging_ffprobe import WITHIN_S, timed

        with timed() as elapsed:
            result = metadata.get_audio_bitrate_kbps(self.audio)

        assert elapsed() < WITHIN_S
        assert result is None
