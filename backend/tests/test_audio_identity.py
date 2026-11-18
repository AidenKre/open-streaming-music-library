"""Phase 6.5 spec §3 / review 6.5-U02: ``compute_exact`` (mocked process
boundary). The process-backed fixture matrix lives in
``test_audio_identity_matrix.py``."""

from __future__ import annotations

import json
import logging
from pathlib import Path

import pytest

from app.services import audio_identity
from app.services.audio_identity import (
    IDENTITY_COLUMNS,
    AudioIdentity,
    ExactAudioHash,
    ExactUnavailable,
    compute_exact,
    compute_identity,
    exact_match,
    identity_from_columns,
    identity_to_columns,
)
from app.services.ffmpeg_runner import (
    CaptureOverflow,
    CaptureResult,
    CaptureTimeout,
    FfmpegError,
    FfmpegProcessRegistry,
)

DIGEST = "ab" * 32


def _probe_json(**stream) -> bytes:
    return json.dumps({"streams": [stream] if stream else []}).encode()


class FakeRunner:
    """Stands in for ``run_capture``: answers ffprobe with ``probe`` and ffmpeg
    with ``hash_result`` (or raises ``hash_error``), recording every call."""

    def __init__(
        self,
        *,
        probe: CaptureResult | None = None,
        probe_error: BaseException | None = None,
        hash_result: CaptureResult | None = None,
        hash_error: BaseException | None = None,
    ):
        self.probe = probe or CaptureResult(
            0, _probe_json(sample_rate="44100", channels=2, bits_per_raw_sample="24", bits_per_sample=0), ""
        )
        self.probe_error = probe_error
        self.hash_result = hash_result or CaptureResult(0, f"SHA256={DIGEST}\n".encode(), "")
        self.hash_error = hash_error
        self.calls: list[tuple[list[str], dict]] = []

    def __call__(self, cmd, **kwargs):
        self.calls.append((list(cmd), kwargs))
        if cmd[0] == "ffprobe":
            if self.probe_error is not None:
                raise self.probe_error
            return self.probe
        if cmd[0] == "ffmpeg":
            if self.hash_error is not None:
                raise self.hash_error
            return self.hash_result
        raise AssertionError(f"unexpected command {cmd[0]!r}")

    def ffmpeg_cmds(self):
        return [cmd for cmd, _ in self.calls if cmd[0] == "ffmpeg"]


@pytest.fixture
def audio_file(tmp_path) -> Path:
    path = tmp_path / "Some Artist - Private Title.flac"
    path.write_bytes(b"not really audio; the process boundary is mocked")
    return path


@pytest.fixture
def runner(monkeypatch):
    def install(**kwargs) -> FakeRunner:
        fake = FakeRunner(**kwargs)
        monkeypatch.setattr(audio_identity, "run_capture", fake)
        return fake

    return install


def _expected_hash_cmd(path: Path, codec: str) -> list[str]:
    # The spec §3 command, verbatim.
    return ["ffmpeg", "-v", "error", "-i", str(path), "-map", "0:a:0",
            "-c:a", codec, "-f", "hash", "-hash", "sha256", "-"]


# --- kind selection and command lines ---------------------------------------

@pytest.mark.parametrize(
    "codec_hint, ffmpeg_codec, kind",
    [
        ("flac", "pcm_s32le", "pcm_sha256"),
        ("alac", "pcm_s32le", "pcm_sha256"),
        ("wav", "pcm_s32le", "pcm_sha256"),
        ("pcm_s16le", "pcm_s32le", "pcm_sha256"),
        ("pcm_s24le", "pcm_s32le", "pcm_sha256"),
        # Plan D19: float is checked before the integer lossless set
        # (pcm_f32le is in LOSSLESS_CODECS; pcm_f64le is in neither set).
        ("pcm_f32le", "pcm_f64le", "pcm_float_sha256"),
        ("pcm_f64le", "pcm_f64le", "pcm_float_sha256"),
        ("mp3", "copy", "packets_sha256"),
        ("aac", "copy", "packets_sha256"),
    ],
)
def test_each_codec_class_runs_the_spec_command(runner, audio_file, codec_hint, ffmpeg_codec, kind):
    fake = runner()
    result = compute_exact(audio_file, codec_hint)
    assert isinstance(result, ExactAudioHash)
    assert result.kind == kind
    assert result.digest == DIGEST
    assert fake.ffmpeg_cmds() == [_expected_hash_cmd(audio_file, ffmpeg_codec)]


@pytest.mark.parametrize("codec_hint", ["flac", "pcm_f32le", "mp3"])
def test_never_resamples_or_remixes(runner, audio_file, codec_hint):
    fake = runner()
    compute_exact(audio_file, codec_hint)
    for cmd, _ in fake.calls:
        assert "-ar" not in cmd and "-ac" not in cmd and "-af" not in cmd and "-filter:a" not in cmd


@pytest.mark.parametrize("codec_hint", ["opus", "vorbis", "pcm_s32le", "dts", "", None])
def test_unknown_codecs_are_unsupported_without_running_anything(runner, audio_file, codec_hint):
    fake = runner()
    result = compute_exact(audio_file, codec_hint)
    assert result == ExactUnavailable(state="unsupported", reason=None)
    assert fake.calls == []


def test_process_options_are_forwarded_to_every_call(runner, audio_file):
    fake = runner()
    registry = FfmpegProcessRegistry()
    compute_exact(audio_file, "flac", registry=registry, job_id="identity", low_priority=True)
    assert len(fake.calls) >= 1
    for _cmd, kwargs in fake.calls:
        assert kwargs["registry"] is registry
        assert kwargs["job_id"] == "identity"
        assert kwargs["low_priority"] is True
        assert kwargs["timeout_s"] > 0
        assert kwargs["max_stdout_bytes"] > 0


def test_defaults_are_normal_priority_without_registry(runner, audio_file):
    fake = runner()
    compute_exact(audio_file, "flac")
    for _cmd, kwargs in fake.calls:
        assert kwargs.get("low_priority", False) is False
        assert kwargs.get("registry") is None


# --- stream parameters ------------------------------------------------------

def test_pcm_parameters_come_from_the_first_audio_stream(runner, audio_file):
    fake = runner(probe=CaptureResult(
        0, _probe_json(sample_rate="96000", channels=6, bits_per_raw_sample="24", bits_per_sample=0), ""))
    result = compute_exact(audio_file, "flac")
    assert (result.sample_rate_hz, result.channels, result.bits_per_sample) == (96000, 6, 24)
    probe_cmd = next(cmd for cmd, _ in fake.calls if cmd[0] == "ffprobe")
    assert "a:0" in probe_cmd  # the same stream the hash maps (0:a:0)
    assert str(audio_file) in probe_cmd


def test_wav_bits_fall_back_to_bits_per_sample(runner, audio_file):
    # ffprobe reports bits_per_raw_sample N/A for 16-bit WAV.
    runner(probe=CaptureResult(
        0, _probe_json(sample_rate="44100", channels=2, bits_per_raw_sample="N/A", bits_per_sample=16), ""))
    result = compute_exact(audio_file, "pcm_s16le")
    assert result.bits_per_sample == 16


def test_unknown_bits_are_none_not_zero(runner, audio_file):
    runner(probe=CaptureResult(0, _probe_json(sample_rate="44100", channels=2, bits_per_sample=0), ""))
    result = compute_exact(audio_file, "flac")
    assert isinstance(result, ExactAudioHash)
    assert result.bits_per_sample is None


def test_lossy_keeps_rate_and_channels_informational(runner, audio_file):
    runner(probe=CaptureResult(0, _probe_json(sample_rate="48000", channels=1, bits_per_sample=0), ""))
    result = compute_exact(audio_file, "aac")
    assert result.kind == "packets_sha256"
    assert (result.sample_rate_hz, result.channels) == (48000, 1)
    assert result.bits_per_sample is None


@pytest.mark.parametrize(
    "stream",
    [
        {"channels": 2},                                  # no rate
        {"sample_rate": "44100"},                         # no channels
        {"sample_rate": "0", "channels": 2},              # zero = unknown, not a value
        {"sample_rate": "N/A", "channels": 2},
        {"sample_rate": "44100", "channels": 0},
    ],
)
def test_pcm_with_unknown_rate_or_channels_fails_as_probe_error(runner, audio_file, stream):
    fake = runner(probe=CaptureResult(0, _probe_json(**stream), ""))
    result = compute_exact(audio_file, "flac")
    assert result == ExactUnavailable(state="failed", reason="probe_error")
    assert fake.ffmpeg_cmds() == []


def test_lossy_with_unknown_rate_still_hashes_with_none(runner, audio_file):
    runner(probe=CaptureResult(0, _probe_json(channels=2), ""))
    result = compute_exact(audio_file, "mp3")
    assert isinstance(result, ExactAudioHash)
    assert result.sample_rate_hz is None and result.channels == 2


# --- failures are values with fixed, path-free reasons -----------------------

def test_missing_master_is_master_missing_without_running_anything(runner, tmp_path):
    fake = runner()
    result = compute_exact(tmp_path / "gone.flac", "flac")
    assert result == ExactUnavailable(state="failed", reason="master_missing")
    assert fake.calls == []


@pytest.mark.parametrize(
    "kwargs, reason",
    [
        ({"probe_error": FfmpegError("ffprobe not found")}, "tool_missing"),
        ({"hash_error": FfmpegError("ffmpeg not found")}, "tool_missing"),
        ({"hash_error": FfmpegError("ffmpeg failed to start: Permission denied")}, "tool_missing"),
        ({"probe_error": CaptureTimeout("timed out")}, "timeout"),
        ({"hash_error": CaptureTimeout("timed out")}, "timeout"),
        ({"probe": CaptureResult(1, b"", "/x/y.flac: Invalid data found when processing input")}, "decode_error"),
        ({"hash_result": CaptureResult(183, b"", "/x/y.flac: Invalid data")}, "decode_error"),
        ({"hash_result": CaptureResult(-6, b"", "")}, "decode_error"),
        ({"probe": CaptureResult(0, b"not json", "")}, "probe_error"),
        ({"probe": CaptureResult(0, _probe_json(), "")}, "probe_error"),  # no audio stream
        ({"hash_result": CaptureResult(0, b"MD5=abcd\n", "")}, "output_error"),
        ({"hash_result": CaptureResult(0, b"SHA256=xyz\n", "")}, "output_error"),
        ({"hash_result": CaptureResult(0, b"", "")}, "output_error"),
        ({"hash_error": CaptureOverflow("too much")}, "output_error"),
        ({"probe_error": CaptureOverflow("too much")}, "output_error"),
    ],
)
def test_failures_become_failed_values(runner, audio_file, kwargs, reason):
    runner(**kwargs)
    result = compute_exact(audio_file, "flac")
    assert result == ExactUnavailable(state="failed", reason=reason)


def test_an_unexpected_exception_is_a_failed_value_not_a_raise(runner, audio_file):
    runner(hash_error=RuntimeError(f"boom at {audio_file}"))
    result = compute_exact(audio_file, "flac")
    assert result == ExactUnavailable(state="failed", reason="internal_error")


def test_digest_is_normalized_to_lowercase_hex(runner, audio_file):
    runner(hash_result=CaptureResult(0, f"SHA256={'AB' * 32}\n".encode(), ""))
    result = compute_exact(audio_file, "flac")
    assert result.digest == "ab" * 32


def test_no_path_or_tag_text_reaches_a_reason_or_a_log_line(runner, audio_file, caplog):
    secret_dir = audio_file.parent
    runner(hash_result=CaptureResult(1, b"", f"{audio_file}: Invalid data found; title=Private Title"))
    with caplog.at_level(logging.DEBUG, logger="app"):
        result = compute_exact(audio_file, "flac")
    assert result.state == "failed"
    for text in [result.reason or "", caplog.text]:
        assert "Private Title" not in text
        assert "Some Artist" not in text
        assert str(secret_dir) not in text


def test_unexpected_exception_text_is_not_logged(runner, audio_file, caplog):
    runner(hash_error=OSError(2, "No such file", str(audio_file)))
    with caplog.at_level(logging.DEBUG, logger="app"):
        result = compute_exact(audio_file, "flac")
    assert result.state == "failed"
    assert "Private Title" not in caplog.text and str(audio_file.parent) not in caplog.text


# --- matching rule (spec §3) -------------------------------------------------

def _h(kind="pcm_sha256", digest=DIGEST, rate=44100, channels=2, bits=24):
    return ExactAudioHash(kind=kind, digest=digest, sample_rate_hz=rate, channels=channels, bits_per_sample=bits)


class TestExactMatch:
    def test_same_kind_digest_and_parameters_match(self):
        assert exact_match(_h(), _h())

    def test_bits_per_sample_is_informational(self):
        # A 16-bit file and its zero-padded 24-bit copy hold the same audio.
        assert exact_match(_h(bits=16), _h(bits=24))
        assert exact_match(_h(bits=None), _h(bits=24))

    def test_a_different_digest_never_matches(self):
        assert not exact_match(_h(), _h(digest="cd" * 32))

    def test_a_different_kind_never_matches_even_with_the_same_digest(self):
        assert not exact_match(_h(kind="pcm_sha256"), _h(kind="pcm_float_sha256"))
        assert not exact_match(_h(kind="pcm_sha256"), _h(kind="packets_sha256"))

    @pytest.mark.parametrize("kind", ["pcm_sha256", "pcm_float_sha256"])
    def test_pcm_kinds_need_equal_rate_and_channels(self, kind):
        assert not exact_match(_h(kind=kind, rate=44100), _h(kind=kind, rate=48000))
        assert not exact_match(_h(kind=kind, channels=2), _h(kind=kind, channels=1))

    @pytest.mark.parametrize("kind", ["pcm_sha256", "pcm_float_sha256"])
    def test_pcm_unknown_parameters_never_match(self, kind):
        assert not exact_match(_h(kind=kind, rate=None), _h(kind=kind, rate=None))
        assert not exact_match(_h(kind=kind, channels=None), _h(kind=kind, channels=None))

    def test_packets_ignore_reported_stream_parameters(self):
        a = _h(kind="packets_sha256", rate=24000, channels=2, bits=None)
        b = _h(kind="packets_sha256", rate=48000, channels=1, bits=None)
        assert exact_match(a, b)
        assert exact_match(_h(kind="packets_sha256", rate=None), _h(kind="packets_sha256", rate=None))

    def test_unavailable_never_matches(self):
        failed = ExactUnavailable(state="failed", reason="decode_error")
        unsupported = ExactUnavailable(state="unsupported", reason=None)
        assert not exact_match(failed, failed)
        assert not exact_match(unsupported, unsupported)
        assert not exact_match(_h(), failed)
        assert not exact_match(unsupported, _h())


# --- compute_identity and the SC-25 serializer --------------------------------

# Spec §6.1 ``track_audio_identity`` columns, copied from the spec (not from
# the module under test).
SC25_IDENTITY_TABLE_COLUMNS = {
    "uuid_id", "generation", "exact_state", "exact_kind", "exact_digest",
    "sample_rate_hz", "channels", "bits_per_sample", "fp_state", "fp_algorithm",
    "match_state", "matcher_version", "failure_reason", "attempts", "next_attempt_at",
    "priority", "stat_size", "stat_mtime_ns", "stat_inode", "computed_at", "tool_versions",
}


class TestComputeIdentity:
    def test_wraps_the_exact_layer_with_tool_versions_and_time(self, runner, audio_file, monkeypatch):
        fake = runner()
        monkeypatch.setattr(audio_identity, "tool_versions", lambda **kwargs: "ffmpeg 9.0.2")
        monkeypatch.setattr(audio_identity.time, "time", lambda: 1_700_000_000.7)
        identity = compute_identity(audio_file, "flac")
        assert isinstance(identity, AudioIdentity)
        assert identity.exact == ExactAudioHash("pcm_sha256", DIGEST, 44100, 2, 24)
        assert identity.tool_versions == "ffmpeg 9.0.2"
        assert identity.computed_at == 1_700_000_000
        assert fake.ffmpeg_cmds() == [_expected_hash_cmd(audio_file, "pcm_s32le")]

    def test_forwards_process_options(self, runner, audio_file, monkeypatch):
        fake = runner()
        monkeypatch.setattr(audio_identity, "tool_versions", lambda **kwargs: None)
        registry = FfmpegProcessRegistry()
        compute_identity(audio_file, "mp3", registry=registry, job_id="w", low_priority=True)
        assert fake.calls and all(
            kw["registry"] is registry and kw["job_id"] == "w" and kw["low_priority"] is True
            for _cmd, kw in fake.calls
        )

    def test_a_failure_is_still_an_identity_value(self, runner, audio_file, monkeypatch):
        runner(hash_error=FfmpegError("ffmpeg not found"))
        monkeypatch.setattr(audio_identity, "tool_versions", lambda **kwargs: None)
        identity = compute_identity(audio_file, "flac")
        assert identity.exact == ExactUnavailable(state="failed", reason="tool_missing")
        assert identity.tool_versions is None


class TestToolVersions:
    @pytest.fixture(autouse=True)
    def _fresh_cache(self, monkeypatch):
        monkeypatch.setattr(audio_identity, "_tool_versions_cache", None)

    def test_parses_the_ffmpeg_version_line(self, monkeypatch):
        calls = []

        def fake(cmd, **kwargs):
            calls.append(cmd)
            return CaptureResult(0, b"ffmpeg version 9.0.2 Copyright (c) 2000-2026 the FFmpeg developers\nbuilt with clang\n", "")

        monkeypatch.setattr(audio_identity, "run_capture", fake)
        assert audio_identity.tool_versions() == "ffmpeg 9.0.2"
        assert calls == [["ffmpeg", "-version"]]
        assert audio_identity.tool_versions() == "ffmpeg 9.0.2"
        assert len(calls) == 1  # cached after a success

    def test_a_missing_or_failing_tool_is_none_and_not_cached(self, monkeypatch):
        answers = [FfmpegError("ffmpeg not found"), CaptureResult(1, b"", "x"), CaptureResult(0, b"garbage", "")]

        def fake(cmd, **kwargs):
            answer = answers.pop(0)
            if isinstance(answer, BaseException):
                raise answer
            return answer

        monkeypatch.setattr(audio_identity, "run_capture", fake)
        assert audio_identity.tool_versions() is None
        assert audio_identity.tool_versions() is None
        assert audio_identity.tool_versions() is None
        assert answers == []  # each call retried: failures are not cached


class TestSerializer:
    def test_column_set_is_part_of_the_sc25_table(self):
        assert set(IDENTITY_COLUMNS) <= SC25_IDENTITY_TABLE_COLUMNS
        assert {"exact_state", "exact_kind", "exact_digest", "sample_rate_hz", "channels",
                "bits_per_sample", "failure_reason", "computed_at", "tool_versions"} <= set(IDENTITY_COLUMNS)
        assert len(IDENTITY_COLUMNS) == len(set(IDENTITY_COLUMNS))

    def test_a_hash_serializes_as_current(self):
        identity = AudioIdentity(exact=_h(bits=16), tool_versions="ffmpeg 9.0.2", computed_at=123)
        assert identity_to_columns(identity) == {
            "exact_state": "current", "exact_kind": "pcm_sha256", "exact_digest": DIGEST,
            "sample_rate_hz": 44100, "channels": 2, "bits_per_sample": 16,
            "failure_reason": None, "computed_at": 123, "tool_versions": "ffmpeg 9.0.2",
        }

    @pytest.mark.parametrize(
        "exact", [ExactUnavailable(state="failed", reason="timeout"), ExactUnavailable(state="unsupported", reason=None)]
    )
    def test_unavailable_serializes_without_digest(self, exact):
        columns = identity_to_columns(AudioIdentity(exact=exact, tool_versions=None, computed_at=5))
        assert columns["exact_state"] == exact.state
        assert columns["failure_reason"] == exact.reason
        assert columns["exact_kind"] is None and columns["exact_digest"] is None
        assert columns["sample_rate_hz"] is None and columns["channels"] is None and columns["bits_per_sample"] is None
        assert set(columns) == set(IDENTITY_COLUMNS)

    @pytest.mark.parametrize(
        "exact",
        [
            _h(),
            _h(kind="pcm_float_sha256", bits=32),
            _h(kind="packets_sha256", rate=None, channels=None, bits=None),
            ExactUnavailable(state="failed", reason="decode_error"),
            ExactUnavailable(state="unsupported", reason=None),
        ],
    )
    def test_round_trip(self, exact):
        identity = AudioIdentity(exact=exact, tool_versions="ffmpeg 9.0.2", computed_at=99)
        assert identity_from_columns(identity_to_columns(identity)) == identity

    def test_from_columns_ignores_other_table_columns(self):
        columns = identity_to_columns(AudioIdentity(exact=_h(), tool_versions=None, computed_at=1))
        row = {**columns, "uuid_id": "u", "generation": 3, "fp_state": "pending", "priority": 0}
        assert identity_from_columns(row).exact == _h()

    @pytest.mark.parametrize(
        "change",
        [
            {"exact_state": "pending"},                  # a storage state, not a computed identity
            {"exact_state": "bogus"},
            {"exact_kind": "md5"},
            {"exact_digest": None},
            {"exact_kind": None},
        ],
    )
    def test_from_columns_rejects_rows_that_are_not_a_computed_identity(self, change):
        columns = identity_to_columns(AudioIdentity(exact=_h(), tool_versions=None, computed_at=1))
        with pytest.raises(ValueError):
            identity_from_columns({**columns, **change})


def test_review_r3_a_kill_is_reported_as_killed_not_as_a_decode_error(runner, audio_file):
    # registry.kill / shutdown SIGKILLs the hash; that says nothing about the
    # file, so the worker must be able to tell it apart from a corrupt file.
    runner(hash_result=CaptureResult(-9, b"", ""))
    assert compute_exact(audio_file, "flac") == ExactUnavailable(state="failed", reason="killed")
    runner(probe=CaptureResult(-9, b"", ""))
    assert compute_exact(audio_file, "flac") == ExactUnavailable(state="failed", reason="killed")


def test_review_r3_other_signals_stay_decode_errors(runner, audio_file):
    runner(hash_result=CaptureResult(-11, b"", ""))  # a decoder crash on a bad file
    assert compute_exact(audio_file, "flac") == ExactUnavailable(state="failed", reason="decode_error")


@pytest.mark.parametrize("returncode", [126, 127])
@pytest.mark.parametrize("stage", ["probe", "hash"])
def test_6_5a2d_a_tool_that_cannot_run_is_tool_missing_not_a_decode_error(runner, audio_file, stage, returncode):
    # With the low-priority prefix, `nice` exits 126 (cannot execute) or 127
    # (not found) when the tool is on PATH but cannot run. That says nothing
    # about the file: the worker must not burn the file's attempts on it.
    failed = CaptureResult(returncode, b"", "nice: ffmpeg: Permission denied")
    runner(**({"probe": failed} if stage == "probe" else {"hash_result": failed}))
    assert compute_exact(audio_file, "flac", low_priority=True) == ExactUnavailable(
        state="failed", reason="tool_missing"
    )
