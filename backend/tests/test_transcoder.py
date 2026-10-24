from __future__ import annotations

import subprocess
from pathlib import Path
from unittest.mock import patch

import pytest

from app.services.transcoder import (
    SourceAudioParams,
    TranscodeResult,
    probe_available_encoders,
    transcode,
    transcode_to_aac_m4a,
)


class _FakeProc:
    def __init__(self, returncode, stderr=b"", output_path=None):
        self.returncode = returncode
        self._stderr = stderr
        self._output_path = output_path
        self.pid = 4242

    def communicate(self, timeout=None):
        if self._output_path is not None:
            self._output_path.write_bytes(b"fake-audio")
        return (b"", self._stderr)

    def kill(self):
        pass


def _fake_ffmpeg_success(cmd, **kwargs):
    return _FakeProc(returncode=0, output_path=Path(cmd[-1]))


def _fake_ffmpeg_failure(cmd, **kwargs):
    return _FakeProc(returncode=1, stderr=b"boom")


class TestTranscode:
    def test_transcode__unsupported_codec__raises_value_error(self, tmp_path):
        with pytest.raises(ValueError):
            transcode(tmp_path / "src.flac", tmp_path / "dst.ogg", "vorbis")

    def test_transcode__lossy_codec_missing_bitrate__raises_value_error(self, tmp_path):
        with pytest.raises(ValueError):
            transcode(tmp_path / "src.flac", tmp_path / "dst.mp3", "mp3")

    def test_transcode__lossless_codec_no_bitrate__does_not_raise(self, tmp_path):
        source = tmp_path / "src.wav"
        source.write_bytes(b"x")
        dest = tmp_path / "dst.flac"
        with patch("app.services.ffmpeg_runner.subprocess.Popen", side_effect=_fake_ffmpeg_success):
            result = transcode(source, dest, "flac")
        assert result == TranscodeResult(ok=True)
        assert dest.exists()

    def test_transcode__success__renames_temp_onto_dest(self, tmp_path):
        source = tmp_path / "src.flac"
        source.write_bytes(b"x")
        dest = tmp_path / "dst.m4a"
        with patch("app.services.ffmpeg_runner.subprocess.Popen", side_effect=_fake_ffmpeg_success):
            result = transcode(source, dest, "aac", bitrate_kbps=192)
        assert result.ok is True
        assert dest.exists()
        assert not dest.with_suffix(dest.suffix + ".partial").exists()

    def test_transcode__ffmpeg_failure__returns_not_ok_with_stderr(self, tmp_path):
        source = tmp_path / "src.flac"
        source.write_bytes(b"x")
        dest = tmp_path / "dst.mp3"
        with patch("app.services.ffmpeg_runner.subprocess.Popen", side_effect=_fake_ffmpeg_failure):
            result = transcode(source, dest, "mp3", bitrate_kbps=320)
        assert result.ok is False
        assert "boom" in result.stderr

    def test_transcode__strip_video_true__adds_vn_flag(self, tmp_path):
        source = tmp_path / "src.flac"
        source.write_bytes(b"x")
        dest = tmp_path / "dst.m4a"
        with patch(
            "app.services.ffmpeg_runner.subprocess.Popen", side_effect=_fake_ffmpeg_success
        ) as run:
            transcode(source, dest, "aac", bitrate_kbps=192, strip_video=True)
        cmd = run.call_args[0][0]
        assert "-vn" in cmd

    def test_transcode__strip_video_false__omits_vn_flag(self, tmp_path):
        source = tmp_path / "src.flac"
        source.write_bytes(b"x")
        dest = tmp_path / "dst.m4a"
        with patch(
            "app.services.ffmpeg_runner.subprocess.Popen", side_effect=_fake_ffmpeg_success
        ) as run:
            transcode(source, dest, "aac", bitrate_kbps=192, strip_video=False)
        cmd = run.call_args[0][0]
        assert "-vn" not in cmd

    def test_transcode__source_params__mirrors_sample_fmt_rate_channels(self, tmp_path):
        source = tmp_path / "src.flac"
        source.write_bytes(b"x")
        dest = tmp_path / "dst.flac"
        params = SourceAudioParams(sample_fmt="s32", sample_rate_hz=48000, channels=2)
        with patch(
            "app.services.ffmpeg_runner.subprocess.Popen", side_effect=_fake_ffmpeg_success
        ) as run:
            transcode(source, dest, "flac", source_params=params)
        cmd = run.call_args[0][0]
        assert "-sample_fmt" in cmd and "s32" in cmd
        assert "-ar" in cmd and "48000" in cmd
        assert "-ac" in cmd and "2" in cmd

    def test_transcode__no_source_params__omits_mirrored_flags(self, tmp_path):
        source = tmp_path / "src.flac"
        source.write_bytes(b"x")
        dest = tmp_path / "dst.flac"
        with patch(
            "app.services.ffmpeg_runner.subprocess.Popen", side_effect=_fake_ffmpeg_success
        ) as run:
            transcode(source, dest, "flac")
        cmd = run.call_args[0][0]
        assert "-sample_fmt" not in cmd
        assert "-ar" not in cmd
        assert "-ac" not in cmd


class TestTranscodeToAacM4a:
    def test_transcode_to_aac_m4a__delegates_to_transcode(self, tmp_path):
        source = tmp_path / "src.flac"
        source.write_bytes(b"x")
        dest = tmp_path / "dst.m4a"
        with patch(
            "app.services.ffmpeg_runner.subprocess.Popen", side_effect=_fake_ffmpeg_success
        ) as run:
            ok = transcode_to_aac_m4a(source, dest, 192)
        assert ok is True
        cmd = run.call_args[0][0]
        assert "-vn" in cmd
        assert "-b:a" in cmd and "192k" in cmd

    def test_transcode_to_aac_m4a__ffmpeg_failure__returns_false(self, tmp_path):
        source = tmp_path / "src.flac"
        source.write_bytes(b"x")
        dest = tmp_path / "dst.m4a"
        with patch("app.services.ffmpeg_runner.subprocess.Popen", side_effect=_fake_ffmpeg_failure):
            ok = transcode_to_aac_m4a(source, dest, 192)
        assert ok is False


class TestProbeAvailableEncoders:
    _SAMPLE_STDOUT = (
        b"Encoders:\n"
        b" V..... libx264              libx264 H.264\n"
        b" A..... aac                  AAC (Advanced Audio Coding)\n"
        b" A..... flac                 FLAC (Free Lossless Audio Codec)\n"
        b" A..... libmp3lame           MP3 (MPEG audio layer 3)\n"
    )

    def test_probe_available_encoders__full_output__returns_matching_codecs(self):
        with patch("app.services.transcoder.subprocess.run") as run:
            run.return_value = subprocess.CompletedProcess(
                args=["ffmpeg"], returncode=0, stdout=self._SAMPLE_STDOUT, stderr=b""
            )
            available = probe_available_encoders()
        assert available == frozenset({"aac", "flac", "mp3"})

    def test_probe_available_encoders__missing_encoder__excluded_from_result(self):
        stdout_without_mp3 = b" A..... aac    AAC\n A..... flac   FLAC\n"
        with patch("app.services.transcoder.subprocess.run") as run:
            run.return_value = subprocess.CompletedProcess(
                args=["ffmpeg"], returncode=0, stdout=stdout_without_mp3, stderr=b""
            )
            available = probe_available_encoders()
        assert available == frozenset({"aac", "flac"})
        assert "mp3" not in available

    def test_probe_available_encoders__ffmpeg_not_found__returns_empty(self):
        with patch("app.services.transcoder.subprocess.run", side_effect=FileNotFoundError):
            assert probe_available_encoders() == frozenset()

    def test_probe_available_encoders__ffmpeg_timeout__returns_empty(self):
        with patch(
            "app.services.transcoder.subprocess.run",
            side_effect=subprocess.TimeoutExpired(cmd="ffmpeg", timeout=10),
        ):
            assert probe_available_encoders() == frozenset()

    def test_probe_available_encoders__nonzero_exit__returns_empty(self):
        with patch("app.services.transcoder.subprocess.run") as run:
            run.return_value = subprocess.CompletedProcess(
                args=["ffmpeg"], returncode=1, stdout=b"", stderr=b""
            )
            assert probe_available_encoders() == frozenset()
