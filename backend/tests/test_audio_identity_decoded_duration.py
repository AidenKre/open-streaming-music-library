"""Live-gate fix 6-5-L-03: the decoded duration of a file (spec §4.1: a print's
``duration_s`` is the "decoded full-track duration"; review 6.5-U09 / L10: a
file with no duration in its header is still matched through its fingerprint
duration).

``measure_decoded_duration`` decodes the file once through ``run_capture``
(``ffmpeg ... -progress pipe:1 -f null -``) and reads the final ``out_time_us``.
The process boundary is faked here, except in the last test, which decodes a
real FLAC written to a pipe (no duration in its header).
"""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest

from app.services import audio_identity
from app.services.audio_identity import measure_decoded_duration
from app.services.ffmpeg_runner import CaptureResult, CaptureTimeout, FfmpegProcessRegistry
from app.services.identity_reasons import CaptureFailed


def _block(out_time_us: str, progress: str) -> str:
    return (
        "bitrate=N/A\ntotal_size=N/A\n"
        f"out_time_us={out_time_us}\nout_time_ms={out_time_us}\nout_time=00:00:00.000000\n"
        f"speed=N/A\nprogress={progress}\n"
    )


class FakeRunner:
    def __init__(self, result: CaptureResult | None = None, error: BaseException | None = None):
        self.result = result
        self.error = error
        self.calls: list[tuple[list[str], dict]] = []

    def __call__(self, cmd, **kwargs):
        self.calls.append((list(cmd), kwargs))
        if self.error is not None:
            raise self.error
        return self.result


@pytest.fixture
def audio_file(tmp_path) -> Path:
    path = tmp_path / "Private Artist - Private Title.flac"
    path.write_bytes(b"x" * (3 * 1024 * 1024))  # 3 MB: scaled timeout 33 s
    return path


@pytest.fixture
def runner(monkeypatch):
    def install(stdout: str = "", returncode: int = 0, error: BaseException | None = None) -> FakeRunner:
        fake = FakeRunner(CaptureResult(returncode, stdout.encode(), ""), error)
        monkeypatch.setattr(audio_identity, "run_capture", fake)
        return fake

    return install


# --- reading the end time -------------------------------------------------------------------------


def test_the_final_out_time_is_the_duration_in_seconds(runner, audio_file):
    runner(_block("30000000", "end"))
    assert measure_decoded_duration(audio_file) == 30.0


def test_with_several_progress_blocks_the_last_one_wins(runner, audio_file):
    runner(_block("1500000", "continue") + _block("12000000", "continue") + _block("187654321", "end"))
    assert measure_decoded_duration(audio_file) == pytest.approx(187.654321)


@pytest.mark.parametrize("value", ["N/A", "0", "-23219", "", "abc", "1e9"])
def test_an_end_time_that_is_not_a_positive_number_is_unknown(runner, audio_file, value):
    # Unknown is never 0 (the stored print needs duration_s > 0).
    runner(_block(value, "end"))
    assert measure_decoded_duration(audio_file) is None


def test_a_positive_time_followed_by_an_unknown_final_time_is_unknown(runner, audio_file):
    runner(_block("12000000", "continue") + _block("N/A", "end"))
    assert measure_decoded_duration(audio_file) is None


def test_output_without_an_end_block_is_unknown(runner, audio_file):
    runner(_block("12000000", "continue"))
    assert measure_decoded_duration(audio_file) is None


@pytest.mark.parametrize("stdout", ["", "garbage\n\x00\xff", "progress=end\n"])
def test_unreadable_output_is_unknown(runner, audio_file, stdout):
    runner(stdout)
    assert measure_decoded_duration(audio_file) is None


# --- tool failures carry the shared reasons -------------------------------------------------------


@pytest.mark.parametrize(
    "returncode, reason", [(1, "decode_error"), (-9, "killed"), (127, "tool_missing")]
)
def test_a_failed_decode_raises_its_reason(runner, audio_file, returncode, reason):
    runner(_block("30000000", "end"), returncode=returncode)
    with pytest.raises(CaptureFailed) as exc:
        measure_decoded_duration(audio_file)
    assert exc.value.reason == reason


def test_a_runner_error_propagates(runner, audio_file):
    runner(error=CaptureTimeout("too slow"))
    with pytest.raises(CaptureTimeout):
        measure_decoded_duration(audio_file)


# --- the process ----------------------------------------------------------------------------------


def test_one_bounded_decode_of_the_first_audio_stream_with_the_callers_process_options(runner, audio_file):
    fake = runner(_block("30000000", "end"))
    registry = FfmpegProcessRegistry()
    job_id = object()

    measure_decoded_duration(audio_file, registry=registry, job_id=job_id, low_priority=True)

    [(cmd, kwargs)] = fake.calls
    assert cmd[0] == "ffmpeg"
    assert str(audio_file) in cmd
    assert cmd[cmd.index("-map") + 1] == "0:a:0"
    assert cmd[cmd.index("-f") + 1] == "null"
    assert cmd[cmd.index("-progress") + 1] == "pipe:1"
    assert cmd.index("-progress") < cmd.index("-i")  # a global option
    assert (kwargs["registry"], kwargs["job_id"], kwargs["low_priority"]) == (registry, job_id, True)
    assert kwargs["timeout_s"] == 33  # the shared scaled timeout for a 3 MB file
    assert 0 < kwargs["max_stdout_bytes"] <= 4 * 1024 * 1024


# --- the forced input format reaches the decoder (U09-B-06, owner's small item row 59) -----------
# An upload names its demuxer; the decode that measures a missing duration must be
# forced to it like every other process on staged bytes (protocol whitelist + -f).


def _input_options(cmd: list[str]) -> list[str]:
    return cmd[: cmd.index("-i")]


def _has_pair(options: list[str], key: str, value: str) -> bool:
    return any(options[i] == key and options[i + 1] == value for i in range(len(options) - 1))


def test_a_forced_format_is_passed_to_the_decode_before_its_input(runner, audio_file):
    fake = runner(_block("30000000", "end"))

    assert measure_decoded_duration(audio_file, input_format="flac") == 30.0

    [(cmd, _)] = fake.calls
    options = _input_options(cmd)
    assert _has_pair(options, "-f", "flac")
    assert _has_pair(options, "-protocol_whitelist", "file")


def test_without_a_forced_format_the_decode_names_no_demuxer(runner, audio_file):
    fake = runner(_block("30000000", "end"))

    measure_decoded_duration(audio_file)

    [(cmd, _)] = fake.calls
    assert "-f" not in _input_options(cmd) and "-protocol_whitelist" not in cmd


class _NoDurationFingerprinter:
    """A print with no tool duration, so ``compute_fingerprint`` must decode."""

    name = "fake"
    algorithm = "chromaprint-2"
    tool_version = "1"

    def __init__(self):
        self.calls: list[dict] = []

    def fingerprint(self, path, **kwargs):
        from app.services.fingerprinter import RawFingerprint

        self.calls.append(kwargs)
        return RawFingerprint(tuple(i << 18 for i in range(200)), None)  # 200 distinct keys: current


def test_compute_fingerprint_forwards_the_format_to_the_tool_and_to_the_duration_decode(runner, audio_file):
    from tests.fingerprint_fixtures import EXPLICIT

    fake = runner(_block("187000000", "end"))
    tool = _NoDurationFingerprinter()

    fp = audio_identity.compute_fingerprint(audio_file, tool, params=EXPLICIT, input_format="flac")

    assert (fp.state, fp.duration_s) == ("current", 187.0)
    assert [c.get("input_format") for c in tool.calls] == ["flac"]
    [(cmd, _)] = fake.calls
    assert _has_pair(_input_options(cmd), "-f", "flac")
    assert _has_pair(_input_options(cmd), "-protocol_whitelist", "file")


# --- a real file with no duration in its header ---------------------------------------------------


@pytest.mark.requires_ffmpeg
def test_a_flac_written_to_a_pipe_is_measured_by_decoding(tmp_path):
    normal = tmp_path / "tone.flac"
    headerless = tmp_path / "tone_streamed.flac"
    subprocess.run(
        ["ffmpeg", "-nostdin", "-v", "error", "-f", "lavfi", "-i",
         "sine=frequency=330:sample_rate=44100:duration=30", "-c:a", "flac", str(normal)],
        check=True,
    )
    with headerless.open("wb") as fh:
        subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-i", str(normal), "-f", "flac", "pipe:1"],
                       check=True, stdout=fh)
    # Precondition: the header really carries no duration.
    probed = subprocess.run(
        [shutil.which("ffprobe"), "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0",
         str(headerless)], check=True, capture_output=True, text=True,
    ).stdout.strip()
    assert probed in ("", "N/A")

    assert measure_decoded_duration(headerless) == pytest.approx(30.0, abs=0.05)
