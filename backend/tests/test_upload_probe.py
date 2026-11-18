"""7A.2c S1 (spec §5 "Quick probe and metadata extraction run in bounded
workers ... Separate ... invalid audio ... probe-timeout"; §3 "Reject
unsupported MIME/extension combinations based on actual probe"; plan D15):
the upload probe runs only through ``run_capture`` with a timeout, maps every
failure to a typed item error, and records the detected metadata as versioned
JSON in which unknown is null, never 0."""

import json
import signal
import subprocess
from pathlib import Path

import pytest

from app.services.ffmpeg_runner import CaptureOverflow, CaptureResult, CaptureTimeout, FfmpegError
from app.services.upload_validation import (
    PROBE_TIMEOUT_S,
    ValidationFailed,
    ValidationInterrupted,
    probe_upload,
)

SECRET = "secret-dir-name"


def _probe_json(*, format_name="flac", codec="flac", duration="12.5", tags=None,
                streams=None, bit_rate="900000", sample_rate="44100", channels=2):
    audio = {"codec_type": "audio", "codec_name": codec, "sample_rate": sample_rate,
             "channels": channels}
    if duration is not None:
        audio["duration"] = duration
    if bit_rate is not None:
        audio["bit_rate"] = bit_rate
    return {
        "streams": streams if streams is not None else [audio],
        "format": {"format_name": format_name, "tags": tags or {}},
    }


class FakeRun:
    def __init__(self, *, result=None, raises=None):
        self.result, self.raises = result, raises
        self.calls = []

    def __call__(self, cmd, **kwargs):
        self.calls.append((cmd, kwargs))
        if self.raises is not None:
            raise self.raises
        return self.result


def _ok(payload) -> FakeRun:
    return FakeRun(result=CaptureResult(0, json.dumps(payload).encode(), ""))


def _source(tmp_path) -> Path:
    path = tmp_path / SECRET / "source"
    path.parent.mkdir()
    path.write_bytes(b"x")
    return path


def test_a_flac_upload_is_described_by_versioned_json(tmp_path):
    run = _ok(_probe_json(tags={
        "TITLE": "Airbag", "Artist": "Radiohead", "album": "OK Computer",
        "album_artist": "Radiohead", "date": "1997-05-21", "genre": "Rock",
        "track": "1/12", "disc": "1/1",
    }))

    detected = probe_upload(_source(tmp_path), run=run)

    assert detected == {
        "v": 1,
        "container": "flac",
        "codec": "flac",
        "mime": "audio/flac",
        "duration_s": 12.5,
        "bitrate_kbps": 900.0,
        "sample_rate_hz": 44100,
        "channels": 2,
        "has_album_art": False,
        "tags": {
            "title": "Airbag", "artist": "Radiohead", "album": "OK Computer",
            "album_artist": "Radiohead", "date": "1997-05-21", "year": 1997,
            "genre": "Rock", "track_number": 1, "disc_number": 1,
        },
    }


@pytest.mark.parametrize(
    "format_name, codec, mime",
    [
        ("flac", "flac", "audio/flac"),
        ("mp3", "mp3", "audio/mpeg"),
        ("wav", "pcm_s16le", "audio/wav"),
        ("wav", "pcm_s24le", "audio/wav"),
        ("wav", "pcm_f32le", "audio/wav"),
        ("mov,mp4,m4a,3gp,3g2,mj2", "aac", "audio/mp4"),
        ("mov,mp4,m4a,3gp,3g2,mj2", "alac", "audio/mp4"),
    ],
)
def test_the_mime_comes_from_the_probed_container_and_codec(tmp_path, format_name, codec, mime):
    detected = probe_upload(_source(tmp_path), run=_ok(_probe_json(format_name=format_name, codec=codec)))

    assert (detected["container"], detected["codec"], detected["mime"]) == (format_name, codec, mime)


@pytest.mark.parametrize(
    "format_name, codec",
    [
        ("ogg", "opus"),
        ("ogg", "vorbis"),
        ("matroska,webm", "flac"),  # a supported codec in an unsupported container
        ("wav", "pcm_u8"),
        ("mp3", "flac"),  # a container/codec pair that does not belong together
        ("flac", None),
    ],
)
def test_an_unsupported_container_or_codec_is_refused_for_good(tmp_path, format_name, codec):
    with pytest.raises(ValidationFailed) as caught:
        probe_upload(_source(tmp_path), run=_ok(_probe_json(format_name=format_name, codec=codec)))

    assert (caught.value.error.code, caught.value.error.retryable) == ("upload_unsupported_audio", False)


@pytest.mark.parametrize(
    "result",
    [
        CaptureResult(1, b"", "Invalid data found when processing input"),
        CaptureResult(0, b"not json", ""),
        CaptureResult(0, b"[]", ""),
        CaptureResult(0, json.dumps({"format": {"format_name": "image2"}}).encode(), ""),
        CaptureResult(0, json.dumps(_probe_json(streams=[
            {"codec_type": "video", "codec_name": "mjpeg", "disposition": {"attached_pic": 1}},
        ])).encode(), ""),
    ],
    ids=["exit-1", "not-json", "not-an-object", "no-streams", "no-audio-stream"],
)
def test_something_that_is_not_audio_is_invalid_for_good(tmp_path, result):
    with pytest.raises(ValidationFailed) as caught:
        probe_upload(_source(tmp_path), run=FakeRun(result=result))

    assert (caught.value.error.code, caught.value.error.retryable) == ("upload_invalid_audio", False)


def test_a_probe_that_outlives_its_timeout_is_a_retryable_probe_timeout(tmp_path):
    run = FakeRun(raises=CaptureTimeout("ffprobe timed out"))

    with pytest.raises(ValidationFailed) as caught:
        probe_upload(_source(tmp_path), run=run)

    assert (caught.value.error.code, caught.value.error.retryable) == ("probe_timeout", True)


@pytest.mark.parametrize(
    "run",
    [
        FakeRun(raises=FfmpegError("ffprobe not found")),
        FakeRun(result=CaptureResult(127, b"", "")),
        FakeRun(result=CaptureResult(126, b"", "")),
    ],
    ids=["not-found", "exit-127", "exit-126"],
)
def test_a_probe_tool_that_cannot_run_is_retryable_and_not_the_files_fault(tmp_path, run):
    with pytest.raises(ValidationFailed) as caught:
        probe_upload(_source(tmp_path), run=run)

    assert (caught.value.error.code, caught.value.error.retryable) == ("probe_unavailable", True)


def test_probe_output_over_its_bound_is_invalid_audio(tmp_path):
    with pytest.raises(ValidationFailed) as caught:
        probe_upload(_source(tmp_path), run=FakeRun(raises=CaptureOverflow("too much")))

    assert caught.value.error.code == "upload_invalid_audio"


def test_a_probe_killed_by_a_stop_or_cancel_is_an_interruption_not_a_verdict(tmp_path):
    with pytest.raises(ValidationInterrupted):
        probe_upload(_source(tmp_path), run=FakeRun(result=CaptureResult(-signal.SIGKILL, b"", "")))


def test_the_probe_runs_once_through_the_runner_with_a_timeout_and_bounded_output(tmp_path):
    source = _source(tmp_path)
    registry = object()
    run = _ok(_probe_json())

    probe_upload(source, run=run, registry=registry, job_id=("upload", 7), timeout_s=3)

    [(cmd, kwargs)] = run.calls
    assert cmd[0] == "ffprobe" and cmd[-1] == str(source)
    assert {"-show_streams", "-show_format"} <= set(cmd)
    assert kwargs["timeout_s"] == 3
    assert kwargs["registry"] is registry and kwargs["job_id"] == ("upload", 7)
    assert kwargs["low_priority"] is True
    assert 0 < kwargs["max_stdout_bytes"] <= 4 * 1024 * 1024


def test_the_default_timeout_is_bounded():
    assert 0 < PROBE_TIMEOUT_S <= 60


def test_unknown_values_are_null_never_zero(tmp_path):
    payload = _probe_json(duration="N/A", bit_rate=None, sample_rate="N/A", channels=None, tags={})
    payload["format"].pop("tags")

    detected = probe_upload(_source(tmp_path), run=_ok(payload))

    assert detected["duration_s"] is None
    assert detected["bitrate_kbps"] is None
    assert detected["sample_rate_hz"] is None
    assert detected["channels"] is None
    assert set(detected["tags"].values()) == {None}


def test_no_failure_message_names_the_path(tmp_path):
    for run in (
        FakeRun(result=CaptureResult(1, b"", f"/x/{SECRET}/source: Invalid data")),
        FakeRun(raises=CaptureTimeout(f"/x/{SECRET}/source")),
        FakeRun(raises=FfmpegError(f"ffprobe failed on /x/{SECRET}/source")),
        _ok(_probe_json(format_name="ogg", codec="opus")),
    ):
        with pytest.raises(ValidationFailed) as caught:
            probe_upload(_source_once(tmp_path, run), run=run)
        assert SECRET not in caught.value.error.message
        assert SECRET not in str(caught.value)


def _source_once(tmp_path, run) -> Path:
    folder = tmp_path / f"{SECRET}-{id(run)}"
    folder.mkdir()
    path = folder / "source"
    path.write_bytes(b"x")
    return path


@pytest.mark.requires_ffmpeg
def test_a_real_flac_is_probed_by_the_real_tool(tmp_path):
    path = tmp_path / "source"
    subprocess.run(
        ["ffmpeg", "-nostdin", "-v", "error", "-y", "-f", "lavfi",
         "-i", "sine=frequency=440:sample_rate=44100:duration=1",
         "-metadata", "title=Probe Me", "-c:a", "flac", "-f", "flac", str(path)],
        check=True,
    )

    detected = probe_upload(path)

    assert (detected["container"], detected["codec"], detected["mime"]) == ("flac", "flac", "audio/flac")
    assert detected["tags"]["title"] == "Probe Me"
    assert detected["sample_rate_hz"] == 44100
    assert detected["duration_s"] == pytest.approx(1.0, abs=0.05)
