"""Phase 6.5B.1a (spec §4.1, §4.2; review 6.5-U07): the fingerprinter module,
with the process boundary mocked. Real ``fpcalc`` runs live in
``test_fingerprinter_fpcalc.py`` (``requires_fpcalc``)."""

from __future__ import annotations

import json
import logging
from dataclasses import replace
from pathlib import Path

import pytest

from app.config import Settings
from app.services import fingerprinter
from app.services.duplicate_detection import MatcherParams
from app.services.ffmpeg_runner import (
    CaptureOverflow,
    CaptureResult,
    CaptureTimeout,
    FfmpegError,
    FfmpegProcessRegistry,
    ToolOptions,
    run_capture,
)
from app.services.fingerprinter import (
    FP_CURRENT,
    FP_LOW_INFORMATION,
    FP_TOO_SHORT,
    MAX_FINGERPRINT_ITEMS,
    REASON_DECODE_ERROR,
    REASON_EMPTY_FINGERPRINT,
    REASON_INTERNAL_ERROR,
    REASON_KILLED,
    REASON_MASTER_MISSING,
    REASON_OUTPUT_ERROR,
    REASON_TIMEOUT,
    REASON_TOOL_MISSING,
    Fingerprinter,
    FPCALC_MAX_STDOUT_BYTES,
    FingerprintFailure,
    FpcalcFingerprinter,
    RawFingerprint,
    classify,
    detect_fingerprinter,
    fpcalc_version_supported,
    pack_fingerprint,
    probe_fpcalc_version,
    unpack_fingerprint,
)

U32_MAX = 0xFFFFFFFF


# --- blob (little-endian uint32) -------------------------------------------


def test_pack_writes_little_endian_uint32_items():
    blob = pack_fingerprint([1, 0x01020304, U32_MAX, 0])

    assert blob == bytes([1, 0, 0, 0, 4, 3, 2, 1, 255, 255, 255, 255, 0, 0, 0, 0])


def test_unpack_reads_little_endian_uint32_items():
    blob = bytes([1, 0, 0, 0, 4, 3, 2, 1, 255, 255, 255, 255])

    assert unpack_fingerprint(blob) == (1, 0x01020304, U32_MAX)


def test_round_trip_at_the_value_and_size_limits():
    items = tuple((0, U32_MAX, 1, U32_MAX - 1, 0x80000000)[i % 5] for i in range(MAX_FINGERPRINT_ITEMS))

    blob = pack_fingerprint(items)

    assert len(blob) == 4 * MAX_FINGERPRINT_ITEMS
    assert unpack_fingerprint(blob) == items


def test_empty_round_trips():
    assert pack_fingerprint(()) == b""
    assert unpack_fingerprint(b"") == ()


def test_max_items_covers_a_120_second_print_with_headroom():
    # ~8.1 items/s nominal (7.4-7.9 measured on fpcalc 1.6.2) over 120 s is
    # under 1000 items; the cap must not reject a real print.
    assert MAX_FINGERPRINT_ITEMS >= 120 * 9


@pytest.mark.parametrize("bad", [[-1], [U32_MAX + 1], [1, 2, 1 << 40]])
def test_pack_rejects_values_outside_uint32(bad):
    with pytest.raises(ValueError):
        pack_fingerprint(bad)


def test_pack_rejects_more_than_the_maximum_items():
    with pytest.raises(ValueError):
        pack_fingerprint([0] * (MAX_FINGERPRINT_ITEMS + 1))


@pytest.mark.parametrize("length", [1, 2, 3, 5, 4099])
def test_unpack_rejects_a_blob_that_is_not_whole_items(length):
    with pytest.raises(ValueError):
        unpack_fingerprint(b"\x00" * length)


def test_unpack_rejects_more_than_the_maximum_items():
    with pytest.raises(ValueError):
        unpack_fingerprint(b"\x00" * 4 * (MAX_FINGERPRINT_ITEMS + 1))


# --- result types ------------------------------------------------------------


def test_result_types_are_immutable_values():
    raw = RawFingerprint(items=(1, 2), duration_s=30.0)
    failure = FingerprintFailure(reason="timeout")

    assert raw == RawFingerprint(items=(1, 2), duration_s=30.0)
    assert failure == FingerprintFailure(reason="timeout")
    with pytest.raises(AttributeError):
        raw.items = ()  # type: ignore[misc]
    with pytest.raises(AttributeError):
        failure.reason = "x"  # type: ignore[misc]


# --- classification (spec §4.2) ----------------------------------------------

COARSE_SHIFT = 18  # top 14 bits of a uint32


def _params(**overrides) -> MatcherParams:
    base = MatcherParams(
        max_offset=24, min_overlap=120, min_items=120, min_diversity=0.15,
        strong=0.90, possible=0.85, duration_tolerance_s=3.0, duration_tolerance_frac=0.02,
    )
    return replace(base, **overrides)


def _print(n_items: int, n_coarse_keys: int, *, low_bit_noise: bool = False) -> RawFingerprint:
    """``n_items`` items cycling through ``n_coarse_keys`` distinct top-14-bit
    keys. With ``low_bit_noise`` every item also gets distinct low 18 bits, so
    the full 32-bit values are all unique while the coarse keys are not."""
    items = []
    for i in range(n_items):
        value = (i % n_coarse_keys) << COARSE_SHIFT
        if low_bit_noise:
            value |= i & ((1 << COARSE_SHIFT) - 1)
        items.append(value)
    return RawFingerprint(items=tuple(items), duration_s=30.0)


def test_the_classification_states_are_the_spec_names():
    assert (FP_TOO_SHORT, FP_LOW_INFORMATION, FP_CURRENT) == ("too_short", "low_information", "current")


def test_a_varied_print_with_enough_items_is_current():
    assert classify(_print(221, 150), _params()) == FP_CURRENT


def test_fewer_than_min_items_is_too_short():
    assert classify(_print(119, 119), _params()) == FP_TOO_SHORT


def test_exactly_min_items_is_long_enough():
    assert classify(_print(120, 120), _params()) == FP_CURRENT


def test_too_short_wins_over_low_information():
    assert classify(_print(50, 1), _params()) == FP_TOO_SHORT


def test_min_items_comes_from_the_parameters():
    raw = _print(200, 200)

    assert classify(raw, _params(min_items=201)) == FP_TOO_SHORT
    assert classify(raw, _params(min_items=200)) == FP_CURRENT


def test_a_constant_print_is_low_information():
    # Silence and a steady tone: one item repeated (measured on fpcalc 1.6.2).
    assert classify(_print(221, 1), _params()) == FP_LOW_INFORMATION


def test_diversity_just_below_the_threshold_is_low_information():
    # 17 coarse keys / 120 items = 0.1417 < 0.15
    assert classify(_print(120, 17), _params()) == FP_LOW_INFORMATION


def test_diversity_at_the_threshold_is_current():
    # 18 coarse keys / 120 items = 0.15, not below 0.15
    assert classify(_print(120, 18), _params()) == FP_CURRENT


def test_diversity_counts_coarse_keys_not_full_32_bit_values():
    # Hiss in the low bits makes every 32-bit value unique; the top 14 bits
    # still repeat, so this is low information (spec §4.2).
    raw = _print(221, 2, low_bit_noise=True)
    assert len(set(raw.items)) == 221

    assert classify(raw, _params()) == FP_LOW_INFORMATION


def test_min_diversity_comes_from_the_parameters():
    raw = _print(200, 40)  # 0.2

    assert classify(raw, _params(min_diversity=0.21)) == FP_LOW_INFORMATION
    assert classify(raw, _params(min_diversity=0.2)) == FP_CURRENT


# --- FpcalcFingerprinter: parsing (process boundary mocked) ------------------

from tests.tool_call_capture import tool_call

EXE = "/opt/tools/fpcalc"


class FakeRunner:
    """Stands in for ``run_capture``: returns ``result`` (or raises ``error``)
    and records every call."""

    def __init__(self, result: CaptureResult | None = None, error: BaseException | None = None):
        self.result = result
        self.error = error
        self.calls: list[tuple[list[str], dict]] = []

    def __call__(self, cmd, **kwargs):
        self.calls.append((list(cmd), tool_call(run_capture, cmd, **kwargs)))
        if self.error is not None:
            raise self.error
        return self.result


def _ok(stdout: bytes | str, stderr: str = "") -> CaptureResult:
    if isinstance(stdout, str):
        stdout = stdout.encode()
    return CaptureResult(0, stdout, stderr)


def _json(duration, items) -> bytes:
    return json.dumps({"duration": duration, "fingerprint": items}).encode()


@pytest.fixture
def audio_file(tmp_path) -> Path:
    path = tmp_path / "Some Artist - Private Title.flac"
    path.write_bytes(b"not really audio; the process boundary is mocked")
    return path


@pytest.fixture
def runner(monkeypatch):
    fake = FakeRunner(_ok(_json(30.0, [1, 2, 3])))
    monkeypatch.setattr(fingerprinter, "run_capture", fake)
    return fake


def _fp(timeout_s: float = 45.0) -> FpcalcFingerprinter:
    return FpcalcFingerprinter(EXE, "1.6.2", timeout_s=timeout_s)


def test_identity_fields_name_the_backend_algorithm_and_version():
    fp = _fp()

    assert fp.name == "fpcalc"
    assert fp.algorithm == "chromaprint-2"
    assert fp.tool_version == "1.6.2"
    assert isinstance(fp, Fingerprinter)


def test_runs_fpcalc_raw_json_length_120_on_the_file(runner, audio_file):
    _fp().fingerprint(audio_file)

    [(cmd, kwargs)] = runner.calls
    assert cmd == [EXE, "-raw", "-json", "-algorithm", "2", "-length", "120", str(audio_file)]
    assert kwargs["timeout_s"] == 45.0


def test_max_seconds_sets_the_length(runner, audio_file):
    _fp().fingerprint(audio_file, max_seconds=60)

    [(cmd, _)] = runner.calls
    assert cmd[cmd.index("-length") + 1] == "60"


def test_a_relative_path_is_passed_absolute_so_it_never_reads_as_an_option(runner, tmp_path, monkeypatch):
    (tmp_path / "-length.flac").write_bytes(b"x")
    monkeypatch.chdir(tmp_path)

    _fp().fingerprint(Path("-length.flac"))

    [(cmd, _)] = runner.calls
    assert cmd[-1] == str(tmp_path / "-length.flac")
    assert not cmd[-1].startswith("-")


def test_stdout_is_bounded_but_fits_a_maximal_print(runner, audio_file):
    _fp().fingerprint(audio_file)

    [(_, kwargs)] = runner.calls
    widest = len(_json(1234567.25, [0xFFFFFFFF] * MAX_FINGERPRINT_ITEMS))
    assert widest <= kwargs["max_stdout_bytes"] <= 256 * 1024


def test_registry_job_and_priority_are_passed_through(runner, audio_file):
    registry = FfmpegProcessRegistry()

    _fp().fingerprint(audio_file, options=ToolOptions(registry=registry, job_id="identity-7", low_priority=True))

    [(_, kwargs)] = runner.calls
    assert kwargs["registry"] is registry
    assert kwargs["job_id"] == "identity-7"
    assert kwargs["low_priority"] is True


def test_defaults_are_no_registry_and_normal_priority(runner, audio_file):
    _fp().fingerprint(audio_file)

    [(_, kwargs)] = runner.calls
    assert kwargs.get("registry") is None
    assert kwargs.get("job_id") is None
    assert kwargs.get("low_priority", False) is False


def test_parses_items_and_the_reported_duration(runner, audio_file):
    runner.result = _ok(b'{"duration": 30.00, "fingerprint": [558758263,3779983735,0,4294967295]}\n')

    raw = _fp().fingerprint(audio_file)

    assert raw == RawFingerprint(items=(558758263, 3779983735, 0, 4294967295), duration_s=30.0)
    assert isinstance(raw.items, tuple)


def test_an_integer_duration_is_accepted_as_seconds(runner, audio_file):
    runner.result = _ok(_json(215, [7]))

    raw = _fp().fingerprint(audio_file)

    assert raw == RawFingerprint(items=(7,), duration_s=215.0)
    assert isinstance(raw.duration_s, float)


def test_the_full_track_duration_is_kept_beyond_the_fingerprinted_window(runner, audio_file):
    # fpcalc reports the decoded track duration (150 s), not the 120 s window.
    runner.result = _ok(_json(150.0, [1] * 948))

    raw = _fp().fingerprint(audio_file)

    assert raw.duration_s == 150.0
    assert len(raw.items) == 948


def test_signed_items_are_read_as_uint32(runner, audio_file):
    # fpcalc -signed (pg_acoustid style) prints int32; mask to uint32.
    runner.result = _ok(_json(30.0, [-1, -2147483648, -2, 5]))

    raw = _fp().fingerprint(audio_file)

    assert raw.items == (0xFFFFFFFF, 0x80000000, 0xFFFFFFFE, 5)


def test_a_maximal_print_is_accepted(runner, audio_file):
    runner.result = _ok(_json(120.0, [3] * MAX_FINGERPRINT_ITEMS))

    raw = _fp().fingerprint(audio_file)

    assert len(raw.items) == MAX_FINGERPRINT_ITEMS


def test_stderr_warnings_on_a_clean_exit_do_not_fail(runner, audio_file):
    runner.result = _ok(_json(30.0, [1, 2]), stderr="WARNING: something odd\n")

    assert _fp().fingerprint(audio_file) == RawFingerprint(items=(1, 2), duration_s=30.0)


# --- FpcalcFingerprinter: failures are typed, fixed and path-free -------------

SECRET_STDERR = "ERROR: secret-stderr-text /Users/someone/Music/Private Title.flac"
SECRET_STDOUT = "secret-stdout-text"


def test_the_failure_reasons_are_fixed_names():
    assert (
        REASON_MASTER_MISSING, REASON_TOOL_MISSING, REASON_TIMEOUT, REASON_KILLED,
        REASON_DECODE_ERROR, REASON_EMPTY_FINGERPRINT, REASON_OUTPUT_ERROR, REASON_INTERNAL_ERROR,
    ) == (
        "master_missing", "tool_missing", "timeout", "killed",
        "decode_error", "empty_fingerprint", "output_error", "internal_error",
    )


def test_a_missing_file_fails_without_running_the_tool(runner, tmp_path):
    result = _fp().fingerprint(tmp_path / "gone.flac")

    assert result == FingerprintFailure(REASON_MASTER_MISSING)
    assert runner.calls == []


def test_a_directory_is_not_a_master(runner, tmp_path):
    assert _fp().fingerprint(tmp_path) == FingerprintFailure(REASON_MASTER_MISSING)
    assert runner.calls == []


@pytest.mark.parametrize(
    "error, reason",
    [
        (FfmpegError("fpcalc not found"), REASON_TOOL_MISSING),
        (CaptureTimeout("fpcalc timed out after 45s"), REASON_TIMEOUT),
        (CaptureOverflow("fpcalc stdout exceeded 1 bytes"), REASON_OUTPUT_ERROR),
        (RuntimeError("boom " + SECRET_STDOUT), REASON_INTERNAL_ERROR),
        (OSError("disk " + SECRET_STDOUT), REASON_INTERNAL_ERROR),
    ],
)
def test_runner_errors_become_typed_failures(runner, audio_file, error, reason):
    runner.error = error

    assert _fp().fingerprint(audio_file) == FingerprintFailure(reason)


@pytest.mark.parametrize(
    "returncode, stderr, reason",
    [
        (2, "ERROR: Could not open the input file (Invalid data found when processing input)\n", REASON_DECODE_ERROR),
        (2, "ERROR: Error reading from the audio source (Invalid data found when processing input)\n"
            "ERROR: Empty fingerprint\n", REASON_DECODE_ERROR),
        (1, "", REASON_DECODE_ERROR),
        (-15, "", REASON_DECODE_ERROR),
        (-9, "", REASON_KILLED),
        # A clip under ~2.5 s: fpcalc decodes fine but has nothing to print.
        (2, "ERROR: Empty fingerprint\n", REASON_EMPTY_FINGERPRINT),
    ],
)
def test_a_failed_exit_is_classified(runner, audio_file, returncode, stderr, reason):
    runner.result = CaptureResult(returncode, b"", stderr)

    assert _fp().fingerprint(audio_file) == FingerprintFailure(reason)


def test_a_failed_exit_with_plausible_stdout_is_still_a_failure(runner, audio_file):
    runner.result = CaptureResult(2, _json(30.0, [1, 2, 3]), "ERROR: Could not open the input file\n")

    assert _fp().fingerprint(audio_file) == FingerprintFailure(REASON_DECODE_ERROR)


def test_an_empty_fingerprint_on_a_clean_exit_is_empty_fingerprint(runner, audio_file):
    runner.result = _ok(_json(1.5, []))

    assert _fp().fingerprint(audio_file) == FingerprintFailure(REASON_EMPTY_FINGERPRINT)


@pytest.mark.parametrize(
    "stdout",
    [
        b"",
        b"   \n",
        b"not json " + SECRET_STDOUT.encode(),
        b"\xff\xfe\x00 invalid utf-8",
        b"[1, 2, 3]",
        b'"a string"',
        b"null",
        b'{"duration": 30.0}',
        b'{"fingerprint": [1, 2]}',
        b'{"duration": 30.0, "fingerprint": "AQAAT0mUaEkSRZEGAA"}',
        b'{"duration": 30.0, "fingerprint": {"0": 1}}',
        b'{"duration": 30.0, "fingerprint": null}',
        b'{"duration": 30.0, "fingerprint": [1, 2]}{"duration": 30.0, "fingerprint": [1, 2]}',
        b'{"duration": 30.0, "fingerprint": [1, 2' ,
    ],
)
def test_malformed_output_is_an_output_error(runner, audio_file, stdout):
    runner.result = _ok(stdout)

    assert _fp().fingerprint(audio_file) == FingerprintFailure(REASON_OUTPUT_ERROR)


@pytest.mark.parametrize(
    "item",
    [
        2**32,              # one past uint32
        -(2**31) - 1,       # one past int32
        2**64,
        -(2**63),
        True,
        False,
        1.5,
        1.0,
        "1",
        None,
        [1],
        {"v": 1},
    ],
)
def test_an_item_outside_int32_and_uint32_or_not_an_integer_is_an_output_error(runner, audio_file, item):
    runner.result = _ok(json.dumps({"duration": 30.0, "fingerprint": [1, item, 2]}))

    assert _fp().fingerprint(audio_file) == FingerprintFailure(REASON_OUTPUT_ERROR)


def test_a_huge_integer_literal_is_an_output_error(runner, audio_file):
    runner.result = _ok(b'{"duration": 30.0, "fingerprint": [1, ' + b"9" * 5000 + b"]}")

    assert _fp().fingerprint(audio_file) == FingerprintFailure(REASON_OUTPUT_ERROR)


def test_more_than_the_maximum_items_is_an_output_error(runner, audio_file):
    runner.result = _ok(_json(120.0, [3] * (MAX_FINGERPRINT_ITEMS + 1)))

    assert _fp().fingerprint(audio_file) == FingerprintFailure(REASON_OUTPUT_ERROR)


@pytest.mark.parametrize(
    "duration",
    [b"-1", b"-0.5", b"NaN", b"Infinity", b"-Infinity", b"true", b'"30.0"', b"null", b"[30]", b"1e400", b"1" + b"0" * 400],
)
def test_a_duration_that_is_negative_or_not_a_finite_number_is_an_output_error(runner, audio_file, duration):
    runner.result = _ok(b'{"duration": ' + duration + b', "fingerprint": [1, 2, 3]}')

    assert _fp().fingerprint(audio_file) == FingerprintFailure(REASON_OUTPUT_ERROR)


def _failure_cases():
    """(runner result or error) pairs covering every failure branch."""
    return [
        CaptureResult(2, b"", SECRET_STDERR),
        CaptureResult(2, b"", "ERROR: Empty fingerprint\n"),
        CaptureResult(-9, SECRET_STDOUT.encode(), SECRET_STDERR),
        CaptureResult(0, b"not json " + SECRET_STDOUT.encode(), SECRET_STDERR),
        CaptureResult(0, json.dumps({"duration": 30.0, "fingerprint": [SECRET_STDOUT]}).encode(), ""),
        FfmpegError("fpcalc failed to start: " + SECRET_STDERR, SECRET_STDERR),
        CaptureTimeout("timed out " + SECRET_STDERR),
        CaptureOverflow("overflow " + SECRET_STDERR),
        RuntimeError(SECRET_STDERR),
    ]


@pytest.mark.parametrize("case", _failure_cases())
def test_failures_never_leak_the_path_or_tool_output(runner, audio_file, caplog, case):
    if isinstance(case, BaseException):
        runner.error = case
    else:
        runner.result = case

    with caplog.at_level(logging.DEBUG, logger="app.services.fingerprinter"):
        result = _fp().fingerprint(audio_file)

    assert isinstance(result, FingerprintFailure)
    text = caplog.text + result.reason
    for secret in ("Private Title", "secret-stderr-text", "secret-stdout-text", str(audio_file.parent)):
        assert secret not in text
    # The failure is logged once with its fixed reason.
    assert any(result.reason in r.getMessage() for r in caplog.records)


def test_a_missing_file_log_has_no_path(runner, tmp_path, caplog):
    with caplog.at_level(logging.DEBUG, logger="app.services.fingerprinter"):
        _fp().fingerprint(tmp_path / "Private Title.flac")

    assert "Private Title" not in caplog.text
    assert str(tmp_path) not in caplog.text


# --- fpcalc version probe and minimum (spec §4.1: pin 1.5+) -------------------


@pytest.mark.parametrize(
    "stdout, version",
    [
        ("fpcalc version 1.6.2 (FFmpeg Lavc63.1.102 Lavf63.1.102 SwR7.1.102)\n", "1.6.2"),
        ("fpcalc version 1.5.1 (FFmpeg Lavc58.134.100 Lavf58.76.100 SwR3.9.100)\n", "1.5.1"),
        ("fpcalc version 1.4.3\n", "1.4.3"),
        ("fpcalc version 1.5.0-dev (FFmpeg Lavc59)\n", "1.5.0"),
        ("fpcalc version 1.10\n", "1.10"),
    ],
)
def test_the_version_probe_reads_real_version_lines(runner, stdout, version):
    runner.result = _ok(stdout)

    assert probe_fpcalc_version(EXE) == version
    [(cmd, kwargs)] = runner.calls
    assert cmd == [EXE, "-version"]
    assert 0 < kwargs["timeout_s"] <= 30
    assert kwargs["max_stdout_bytes"] <= 64 * 1024


@pytest.mark.parametrize(
    "result",
    [
        CaptureResult(0, b"", ""),
        CaptureResult(0, b"Usage: fpcalc [OPTIONS] FILE [FILE...]\n", ""),
        CaptureResult(0, b"fpcalc version unknown\n", ""),
        CaptureResult(0, b"\xff\xfe garbage", ""),
        CaptureResult(1, b"fpcalc version 1.6.2\n", ""),
        CaptureResult(-9, b"", ""),
    ],
)
def test_an_unrecognised_or_failed_probe_is_none(runner, result):
    runner.result = result

    assert probe_fpcalc_version(EXE) is None


@pytest.mark.parametrize(
    "error", [FfmpegError("fpcalc not found"), CaptureTimeout("t"), CaptureOverflow("o"), RuntimeError("x")]
)
def test_a_probe_that_cannot_run_is_none_and_never_raises(runner, error):
    runner.error = error

    assert probe_fpcalc_version(EXE) is None


@pytest.mark.parametrize(
    "version, supported",
    [
        ("1.5", True),
        ("1.5.0", True),
        ("1.5.1", True),
        ("1.6.2", True),
        ("1.10", True),   # numeric, not lexicographic
        ("1.10.0", True),
        ("2.0.0", True),
        ("1.4.99", False),
        ("1.4.3", False),
        ("1.4", False),
        ("0.9.9", False),
        ("", False),
        ("1", False),
        ("one.five", False),
    ],
)
def test_the_minimum_supported_version_is_1_5(version, supported):
    assert fpcalc_version_supported(version) is supported


# --- detect_fingerprinter (spec §4.1 "Selection"; plan O6 / DEV-6.5-05) -------

VERSION_162 = "fpcalc version 1.6.2 (FFmpeg Lavc63.1.102 Lavf63.1.102 SwR7.1.102)\n"


def _executable(path: Path) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("#!/bin/sh\nexit 0\n")
    path.chmod(0o755)
    return path


@pytest.fixture
def path_dir(tmp_path, monkeypatch) -> Path:
    """An empty directory that is the whole of PATH."""
    d = tmp_path / "path-bin"
    d.mkdir()
    monkeypatch.setenv("PATH", str(d))
    return d


@pytest.fixture
def version_runner(runner):
    runner.result = _ok(VERSION_162)
    return runner


def _settings(**overrides) -> Settings:
    return Settings(_env_file=None, **overrides)


@pytest.fixture(autouse=False)
def clean_env(monkeypatch):
    for var in ("AUDIO_FINGERPRINT_BACKEND", "FPCALC_PATH", "FPCALC_TIMEOUT_S"):
        monkeypatch.delenv(var, raising=False)


@pytest.mark.parametrize("mode", ["auto", "fpcalc"])
def test_fpcalc_on_path_is_selected(clean_env, path_dir, version_runner, mode, caplog):
    exe = _executable(path_dir / "fpcalc")

    with caplog.at_level(logging.INFO, logger="app.services.fingerprinter"):
        fp = detect_fingerprinter(_settings(audio_fingerprint_backend=mode, fpcalc_timeout_s=33))

    assert isinstance(fp, FpcalcFingerprinter)
    assert fp.executable == str(exe)
    assert fp.tool_version == "1.6.2"
    assert fp.timeout_s == 33
    [(cmd, _)] = version_runner.calls
    assert cmd == [str(exe), "-version"]
    assert "fpcalc" in caplog.text and "1.6.2" in caplog.text


def test_off_selects_nothing_and_runs_nothing(clean_env, path_dir, version_runner, caplog):
    _executable(path_dir / "fpcalc")

    with caplog.at_level(logging.INFO, logger="app.services.fingerprinter"):
        assert detect_fingerprinter(_settings(audio_fingerprint_backend="off")) is None

    assert version_runner.calls == []
    assert "off" in caplog.text


def test_ffmpeg_is_not_supported_in_this_build(clean_env, path_dir, version_runner, caplog):
    # DEV-6.5-05: the ffmpeg chromaprint backend is skipped; forcing it
    # resolves to no fingerprinter, even when fpcalc is available.
    _executable(path_dir / "fpcalc")

    with caplog.at_level(logging.INFO, logger="app.services.fingerprinter"):
        assert detect_fingerprinter(_settings(audio_fingerprint_backend="ffmpeg")) is None

    assert version_runner.calls == []
    assert "not supported" in caplog.text


@pytest.mark.parametrize("mode, level", [("auto", logging.INFO), ("fpcalc", logging.WARNING)])
def test_no_fpcalc_resolves_to_none(clean_env, path_dir, version_runner, mode, level, caplog):
    # auto: fpcalc first, then (ffmpeg, not built) nothing. Forced fpcalc
    # missing is a configuration problem and logs a warning. The auto line is an
    # operator line (app.core.operator_log), so capture every logger.
    with caplog.at_level(logging.INFO):
        assert detect_fingerprinter(_settings(audio_fingerprint_backend=mode)) is None

    assert version_runner.calls == []
    assert [r for r in caplog.records if r.levelno >= level]


@pytest.mark.parametrize("mode", ["auto", "fpcalc"])
def test_fpcalc_path_wins_over_path(clean_env, path_dir, version_runner, tmp_path, mode):
    _executable(path_dir / "fpcalc")
    configured = _executable(tmp_path / "tools" / "fpcalc-1.6")

    fp = detect_fingerprinter(_settings(audio_fingerprint_backend=mode, fpcalc_path=configured))

    assert fp.executable == str(configured)
    [(cmd, _)] = version_runner.calls
    assert cmd[0] == str(configured)


def test_fpcalc_path_is_an_executable_path_never_a_shell_string(clean_env, path_dir, version_runner, tmp_path):
    configured = _executable(tmp_path / "odd dir; touch pwned" / "fp calc $(x)")

    fp = detect_fingerprinter(_settings(fpcalc_path=configured))

    assert fp.executable == str(configured)
    [(cmd, _)] = version_runner.calls
    assert cmd == [str(configured), "-version"]


def test_a_relative_fpcalc_path_is_made_absolute(clean_env, path_dir, version_runner, tmp_path, monkeypatch):
    configured = _executable(tmp_path / "tools" / "fpcalc")
    monkeypatch.chdir(tmp_path)

    fp = detect_fingerprinter(_settings(fpcalc_path=Path("tools/fpcalc")))

    assert fp.executable == str(configured)


@pytest.mark.parametrize("kind", ["missing", "directory", "not_executable"])
@pytest.mark.parametrize("mode", ["auto", "fpcalc"])
def test_a_bad_fpcalc_path_gives_none_with_a_log_and_no_path_fallback(
    clean_env, path_dir, version_runner, tmp_path, caplog, kind, mode
):
    _executable(path_dir / "fpcalc")  # would be found on PATH; must not be used
    configured = tmp_path / "Private Tools" / "fpcalc"
    if kind == "directory":
        configured.mkdir(parents=True)
    elif kind == "not_executable":
        configured.parent.mkdir(parents=True)
        configured.write_text("#!/bin/sh\n")
        configured.chmod(0o644)

    with caplog.at_level(logging.INFO, logger="app.services.fingerprinter"):
        fp = detect_fingerprinter(_settings(audio_fingerprint_backend=mode, fpcalc_path=configured))

    assert fp is None
    assert version_runner.calls == []
    assert [r for r in caplog.records if r.levelno >= logging.WARNING and "FPCALC_PATH" in r.getMessage()]
    assert "Private Tools" not in caplog.text


@pytest.mark.parametrize("stdout", ["fpcalc version 1.4.3\n", "nonsense\n"])
def test_an_old_or_unknown_version_gives_none_with_a_log(clean_env, path_dir, version_runner, stdout, caplog):
    _executable(path_dir / "fpcalc")
    version_runner.result = _ok(stdout)

    with caplog.at_level(logging.INFO, logger="app.services.fingerprinter"):
        assert detect_fingerprinter(_settings()) is None

    assert [r for r in caplog.records if r.levelno >= logging.WARNING]


def test_a_probe_that_fails_to_run_gives_none(clean_env, path_dir, version_runner):
    _executable(path_dir / "fpcalc")
    version_runner.result = None
    version_runner.error = FfmpegError("fpcalc failed to start")

    assert detect_fingerprinter(_settings()) is None


@pytest.mark.requires_chmod_denial
def test_an_unreadable_fpcalc_path_directory_gives_none_instead_of_raising(
    clean_env, path_dir, version_runner, tmp_path, caplog
):
    locked = tmp_path / "locked"
    configured = _executable(locked / "fpcalc")
    locked.chmod(0o000)
    try:
        with caplog.at_level(logging.INFO, logger="app.services.fingerprinter"):
            fp = detect_fingerprinter(_settings(fpcalc_path=configured))
    finally:
        locked.chmod(0o755)

    assert fp is None
    assert version_runner.calls == []
    assert "FPCALC_PATH" in caplog.text


@pytest.mark.parametrize("max_seconds", [0, -5, 121, 10_000])
def test_a_window_beyond_the_120_second_item_cap_is_refused_without_running(runner, audio_file, max_seconds):
    assert _fp().fingerprint(audio_file, max_seconds=max_seconds) == FingerprintFailure(REASON_INTERNAL_ERROR)
    assert runner.calls == []


@pytest.mark.parametrize("duration", [b"0", b"0.0", b"0.00", b"-0.0"])
def test_a_zero_duration_is_unknown_and_the_print_is_kept(runner, audio_file, duration):
    # fpcalc reports the container duration; a stream-written FLAC (no
    # duration in its header) prints "duration": 0.00 next to a valid print
    # (review F1). Unknown is None, never 0, and the print is not thrown away.
    runner.result = _ok(b'{"duration": ' + duration + b', "fingerprint": [1, 2, 3]}')

    assert _fp().fingerprint(audio_file) == RawFingerprint(items=(1, 2, 3), duration_s=None)


# --- review round 1 (6.5B.1a-review.md F2, F3, F4, F6) -------------------------


def test_deeply_nested_json_is_an_output_error(runner, audio_file):
    # F2: json.loads raises RecursionError (not a ValueError) between 8000
    # and 10000 levels on CPython 3.12; 11000 levels still fit the stdout cap.
    depth = 11000
    assert 2 * depth + 64 < FPCALC_MAX_STDOUT_BYTES
    runner.result = _ok(b'{"duration": 30.0, "fingerprint": ' + b"[" * depth + b"]" * depth + b"}")

    assert _fp().fingerprint(audio_file) == FingerprintFailure(REASON_OUTPUT_ERROR)


@pytest.mark.parametrize("returncode", [126, 127])
def test_a_tool_that_cannot_execute_is_tool_missing(runner, audio_file, returncode):
    # F3: with the low-priority prefix, `nice` exits 126 (cannot execute) or
    # 127 (not found) when fpcalc exists on PATH but cannot run. fpcalc
    # itself only exits 0, 1 or 2.
    runner.result = CaptureResult(returncode, b"", "nice: fpcalc: No such file or directory\n")

    assert _fp().fingerprint(audio_file, options=ToolOptions(low_priority=True)) \
        == FingerprintFailure(REASON_TOOL_MISSING)


def test_the_algorithm_is_passed_explicitly_so_the_label_is_a_guarantee(runner, audio_file):
    # F4: algorithm "chromaprint-2" is stored on every row; don't rely on
    # fpcalc's default.
    _fp().fingerprint(audio_file)

    [(cmd, _)] = runner.calls
    assert cmd[cmd.index("-algorithm") + 1] == "2"
    assert cmd.index("-algorithm") < len(cmd) - 1  # before the file


def test_fpcalc_found_through_a_relative_path_entry_is_made_absolute(
    clean_env, version_runner, tmp_path, monkeypatch
):
    # F6: shutil.which returns a relative path for a relative PATH entry.
    exe = _executable(tmp_path / "relbin" / "fpcalc")
    monkeypatch.chdir(tmp_path)
    monkeypatch.setenv("PATH", "relbin")

    fp = detect_fingerprinter(_settings())

    assert fp.executable == str(exe)
