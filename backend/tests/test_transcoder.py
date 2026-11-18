from __future__ import annotations

import subprocess
from pathlib import Path
from unittest.mock import patch

import pytest

from app.services.ffmpeg_runner import run_ffmpeg
from app.services.transcoder import (
    SourceAudioParams,
    TranscodeResult,
    probe_available_encoders,
    transcode,
    transcode_to_aac_m4a,
)
from tests.tool_call_capture import tool_call


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

    @staticmethod
    def _cmd_for(tmp_path, codec, bitrate=None, **kwargs):
        source = tmp_path / "src.flac"
        source.write_bytes(b"x")
        dest = tmp_path / f"dst.{ {'aac': 'm4a', 'alac': 'm4a'}.get(codec, codec) }"
        with patch(
            "app.services.ffmpeg_runner.subprocess.Popen", side_effect=_fake_ffmpeg_success
        ) as run:
            assert transcode(source, dest, codec, bitrate, **kwargs).ok
        return run.call_args[0][0]

    @staticmethod
    def _flag_value(cmd, flag):
        assert cmd.count(flag) == 1, cmd
        return cmd[cmd.index(flag) + 1]

    def test_transcode__source_params__mirrors_sample_fmt_rate_channels(self, tmp_path):
        params = SourceAudioParams(bits_per_sample=24, sample_rate_hz=48000, channels=2)
        cmd = self._cmd_for(tmp_path, "flac", source_params=params)
        assert self._flag_value(cmd, "-sample_fmt") == "s32"
        assert self._flag_value(cmd, "-ar") == "48000"
        assert self._flag_value(cmd, "-ac") == "2"

    @pytest.mark.parametrize("codec,bits,expected", [
        ("flac", 16, "s16"),
        ("flac", 8, "s16"),
        ("flac", 24, "s32"),
        ("flac", 32, "s32"),
        ("alac", 16, "s16p"),
        ("alac", 24, "s32p"),
        ("alac", 32, "s32p"),
    ])
    def test_transcode__lossless_target__bits_map_to_encoder_sample_fmt(
        self, tmp_path, codec, bits, expected
    ):
        params = SourceAudioParams(bits_per_sample=bits, sample_rate_hz=96000, channels=2)
        cmd = self._cmd_for(tmp_path, codec, source_params=params)
        assert self._flag_value(cmd, "-sample_fmt") == expected
        # The sample format goes on the output side, after the codec flags.
        assert cmd.index("-sample_fmt") > cmd.index("-c:a")
        assert cmd[-1].endswith(".partial")

    @pytest.mark.parametrize("codec,bitrate", [("aac", 256), ("mp3", 320)])
    def test_transcode__lossy_target__never_gets_sample_fmt(self, tmp_path, codec, bitrate):
        params = SourceAudioParams(bits_per_sample=24, sample_rate_hz=44100, channels=2)
        cmd = self._cmd_for(tmp_path, codec, bitrate, source_params=params)
        assert "-sample_fmt" not in cmd
        assert self._flag_value(cmd, "-ar") == "44100"

    @pytest.mark.parametrize("codec", ["flac", "alac"])
    def test_transcode__unknown_bits__no_sample_fmt(self, tmp_path, codec):
        params = SourceAudioParams(bits_per_sample=None, sample_rate_hz=44100, channels=1)
        cmd = self._cmd_for(tmp_path, codec, source_params=params)
        assert "-sample_fmt" not in cmd
        assert self._flag_value(cmd, "-ac") == "1"

    @pytest.mark.parametrize("codec,bitrate,art_flags", [
        ("aac", 256, ["-c:v", "copy", "-disposition:v:0", "attached_pic"]),
        ("alac", None, ["-c:v", "copy", "-disposition:v:0", "attached_pic"]),
        ("flac", None, ["-c:v", "copy"]),
        ("mp3", 320, ["-c:v", "copy", "-id3v2_version", "3"]),
    ])
    def test_transcode__conversion_keeps_art__per_codec_art_flags(
        self, tmp_path, codec, bitrate, art_flags
    ):
        cmd = self._cmd_for(tmp_path, codec, bitrate, strip_video=False)
        assert "-vn" not in cmd
        start = cmd.index("-c:v")
        assert cmd[start:start + len(art_flags)] == art_flags
        assert cmd.count("-c:v") == 1

    @pytest.mark.parametrize("codec,bitrate", [
        ("aac", 256), ("alac", None), ("flac", None), ("mp3", 320),
    ])
    def test_transcode__streaming_strips_video__no_art_flags(self, tmp_path, codec, bitrate):
        cmd = self._cmd_for(tmp_path, codec, bitrate, strip_video=True)
        assert cmd.count("-vn") == 1
        assert "-c:v" not in cmd
        assert "-disposition:v:0" not in cmd
        assert "-id3v2_version" not in cmd

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
        # The streaming path: no art flags, no source-param mirroring.
        assert cmd == [
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
            "-i", str(source),
            "-vn",
            "-c:a", "aac", "-f", "mp4", "-movflags", "+faststart",
            "-b:a", "192k",
            str(tmp_path / "dst.m4a.partial"),
        ]
        assert dest.exists()

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


class TestTranscodeFailureLog:
    """Other-issues row 61: a failed transcode goes through the module's logger
    with the target codec and the error type only: ffmpeg's text names the
    source file and its tags, so it stays in TranscodeResult.stderr. A run of
    failures of one kind (a warm-up failing for every track) warns once; the
    repeats are at debug level until a transcode succeeds again."""

    LOGGER = "app.services.transcoder"

    @pytest.fixture(autouse=True)
    def _fresh_failure_memory(self, monkeypatch):
        import app.services.transcoder as transcoder

        monkeypatch.setattr(transcoder, "_failures_warned", set())

    def _fail(self, monkeypatch, source):
        import app.services.transcoder as transcoder
        from app.services.ffmpeg_runner import FfmpegError

        stderr = f"{source}: Invalid data; TITLE=Secret Song"

        def failing_run(cmd, out, **kwargs):
            tool_call(run_ffmpeg, cmd, out, **kwargs)
            raise FfmpegError(f"ffmpeg exited 1: {stderr}", stderr)

        monkeypatch.setattr(transcoder, "run_ffmpeg", failing_run)
        return stderr

    def _succeed(self, monkeypatch):
        import app.services.transcoder as transcoder

        def succeeding_run(cmd, out, **kwargs):
            tool_call(run_ffmpeg, cmd, out, **kwargs)
            Path(out).write_bytes(b"x")

        monkeypatch.setattr(transcoder, "run_ffmpeg", succeeding_run)

    def _lines(self, caplog):
        return [(r.levelname, r.getMessage()) for r in caplog.records if r.name == self.LOGGER]

    def test_a_failed_transcode_logs_its_codec_and_error_type_only(
        self, tmp_path, monkeypatch, caplog, capsys
    ):
        source = tmp_path / "Artist" / "Secret Song.flac"
        source.parent.mkdir()
        source.write_bytes(b"audio")
        stderr = self._fail(monkeypatch, source)

        with caplog.at_level("DEBUG", logger=self.LOGGER):
            result = transcode(source, tmp_path / "out.m4a", "aac", 192)

        assert (result.ok, result.stderr) == (False, stderr)
        assert self._lines(caplog) == [("WARNING", "transcode to aac failed: FfmpegError")]
        assert capsys.readouterr().out == ""  # no print

    def test_failures_of_one_kind_warn_once_until_a_transcode_succeeds(
        self, tmp_path, monkeypatch, caplog
    ):
        source = tmp_path / "song.flac"
        source.write_bytes(b"audio")

        with caplog.at_level("DEBUG", logger=self.LOGGER):
            self._fail(monkeypatch, source)
            for _ in range(3):
                transcode(source, tmp_path / "out.m4a", "aac", 192)
            transcode(source, tmp_path / "out.mp3", "mp3", 192)  # another codec warns
            self._succeed(monkeypatch)
            transcode(source, tmp_path / "out.m4a", "aac", 192)
            self._fail(monkeypatch, source)
            transcode(source, tmp_path / "out.m4a", "aac", 192)

        assert [level for level, _ in self._lines(caplog)] == [
            "WARNING", "DEBUG", "DEBUG", "WARNING", "WARNING",
        ]
