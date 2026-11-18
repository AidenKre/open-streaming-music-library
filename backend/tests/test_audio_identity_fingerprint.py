"""Phase 6.5B.1b: the fingerprint layer of the audio identity model (spec §4.1,
§4.2; review 6.5-U07; coordinator decision DEV-6.5-08 on an unknown duration).

``compute_fingerprint`` is the one function that turns a ``Fingerprinter``
result into a stored-or-not fingerprint layer: the worker and
``compute_identity`` both use it. A fake fingerprinter returns scripted raw
prints, so the classification comes from the real ``classify`` with
thresholds written here.
"""

import dataclasses
from pathlib import Path

import pytest

from app.config import settings
from app.services import audio_identity
from app.services.audio_identity import (
    FingerprintIdentity,
    FingerprintUnavailable,
    compute_fingerprint,
)
from app.services.duplicate_detection import MatcherParams
from app.services.ffmpeg_runner import CaptureOverflow, CaptureTimeout
from app.services.fingerprinter import FingerprintFailure, RawFingerprint
from app.services.identity_reasons import CaptureFailed

PARAMS = dataclasses.replace(MatcherParams.from_settings(settings), min_items=120, min_diversity=0.15)

# 200 items whose top 14 bits all differ: coarse diversity 1.0.
VARIED = tuple(i << 18 for i in range(200))
# 200 identical items: coarse diversity 1/200, far below 0.15.
FLAT = (0x12345678,) * 200


class FakeFingerprinter:
    name = "fakeprint"
    algorithm = "chromaprint-2"
    tool_version = "1.6.2"

    def __init__(self, result=None, raises=None):
        self.result = result
        self.raises = raises
        self.calls = []

    def fingerprint(self, path, *, max_seconds=120, registry=None, job_id=None, low_priority=False):
        self.calls.append({"path": path, "max_seconds": max_seconds, "registry": registry,
                           "job_id": job_id, "low_priority": low_priority})
        if self.raises is not None:
            raise self.raises
        return self.result


def _compute(result, **kwargs):
    fp = FakeFingerprinter(result)
    return compute_fingerprint(Path("/m/a.flac"), fp, params=PARAMS, **kwargs)


# --- classification (spec §4.2) ------------------------------------------------------------


def test_a_varied_print_is_current_with_its_items_duration_backend_and_algorithm():
    assert _compute(RawFingerprint(VARIED, 30.0)) == FingerprintIdentity(
        state="current", backend="fakeprint", algorithm="chromaprint-2", duration_s=30.0, items=VARIED,
    )


def test_a_flat_print_is_low_information_and_keeps_its_items():
    # "The fingerprint is stored but never used for matching."
    assert _compute(RawFingerprint(FLAT, 30.0)) == FingerprintIdentity(
        state="low_information", backend="fakeprint", algorithm="chromaprint-2", duration_s=30.0, items=FLAT,
    )


def test_a_print_under_the_minimum_is_too_short_and_keeps_nothing():
    # "too_short: fewer than FP_MIN_ITEMS items. No fingerprint is stored."
    assert _compute(RawFingerprint(VARIED[:119], 16.0)) == FingerprintIdentity(
        state="too_short", backend="fakeprint", algorithm="chromaprint-2", duration_s=None, items=(),
    )


def test_an_empty_fingerprint_failure_is_too_short_not_a_failure():
    # Coordinator decision: fpcalc exits 2 with "Empty fingerprint" on clips
    # under about 2.5 s; that is a final too_short, never retried.
    assert _compute(FingerprintFailure("empty_fingerprint")) == FingerprintIdentity(
        state="too_short", backend="fakeprint", algorithm="chromaprint-2", duration_s=None, items=(),
    )


@pytest.mark.parametrize("reason", [
    "master_missing", "tool_missing", "timeout", "killed", "decode_error", "output_error", "internal_error",
])
def test_any_other_failure_is_unavailable_with_its_reason(reason):
    assert _compute(FingerprintFailure(reason)) == FingerprintUnavailable(reason)


def test_a_fingerprinter_that_raises_is_an_internal_error():
    fp = FakeFingerprinter(raises=RuntimeError("/secret/path broke"))
    result = compute_fingerprint(Path("/m/a.flac"), fp, params=PARAMS)
    assert result == FingerprintUnavailable("internal_error")


# --- an unknown duration (DEV-6.5-08) -----------------------------------------------------------


def test_the_tools_duration_wins_over_the_known_one():
    assert _compute(RawFingerprint(VARIED, 30.0), known_duration_s=99.0).duration_s == 30.0


@pytest.mark.parametrize("state_items", [VARIED, FLAT], ids=["current", "low_information"])
def test_an_unknown_tool_duration_falls_back_to_the_tracks_known_duration(state_items):
    result = _compute(RawFingerprint(state_items, None), known_duration_s=31.5)
    assert isinstance(result, FingerprintIdentity) and result.duration_s == 31.5


@pytest.mark.parametrize("known", [None, 0.0, -1.0, float("nan")])
def test_with_no_known_duration_anywhere_the_print_is_not_stored(known, measured):
    # The stored row needs duration_s > 0; unknown is never written as 0.
    # 6-5-L-03: "anywhere" now includes the decoded duration, unknown here too.
    measured.value = None
    assert _compute(RawFingerprint(VARIED, None), known_duration_s=known) == FingerprintUnavailable(
        "duration_unknown"
    )
    assert len(measured.calls) == 1


# --- 6-5-L-03: the decoded duration when the tool and the track both lack one --------------------


class FakeMeasure:
    def __init__(self):
        self.value = 29.98
        self.raises = None
        self.calls = []

    def __call__(self, path, *, registry=None, job_id=None, low_priority=False):
        self.calls.append({"path": path, "registry": registry, "job_id": job_id,
                           "low_priority": low_priority})
        if self.raises is not None:
            raise self.raises
        return self.value


@pytest.fixture
def measured(monkeypatch):
    fake = FakeMeasure()
    monkeypatch.setattr(audio_identity, "measure_decoded_duration", fake)
    return fake


@pytest.mark.parametrize("state_items, state", [(VARIED, "current"), (FLAT, "low_information")])
@pytest.mark.parametrize("known", [None, 0.0, float("nan")])
def test_with_no_tool_or_track_duration_the_decoded_duration_is_stored(measured, state_items, state, known):
    result = _compute(RawFingerprint(state_items, None), known_duration_s=known)
    assert result == FingerprintIdentity(state, "fakeprint", "chromaprint-2", 29.98, state_items)


@pytest.mark.parametrize(
    "raw, known",
    [(RawFingerprint(VARIED, 30.0), None), (RawFingerprint(VARIED, None), 31.5),
     (RawFingerprint(VARIED[:10], None), None)],
    ids=["tool duration", "track duration", "too_short"],
)
def test_the_file_is_not_decoded_again_when_a_duration_is_known_or_not_needed(measured, raw, known):
    _compute(raw, known_duration_s=known)
    assert measured.calls == []


def test_the_decode_gets_the_file_and_the_callers_process_options(measured):
    registry, job_id = object(), object()
    fp = FakeFingerprinter(RawFingerprint(VARIED, None))
    compute_fingerprint(Path("/m/a.flac"), fp, params=PARAMS, registry=registry, job_id=job_id,
                        low_priority=True)
    assert measured.calls == [{"path": Path("/m/a.flac"), "registry": registry, "job_id": job_id,
                               "low_priority": True}]


@pytest.mark.parametrize(
    "error, reason",
    [(CaptureFailed("decode_error", 1), "decode_error"), (CaptureFailed("killed", -9), "killed"),
     (CaptureFailed("tool_missing", 127), "tool_missing"), (CaptureTimeout("slow"), "timeout"),
     (CaptureOverflow("big"), "output_error")],
)
def test_a_failed_decode_is_not_stored_and_keeps_its_reason(measured, error, reason):
    measured.raises = error
    assert _compute(RawFingerprint(VARIED, None)) == FingerprintUnavailable(reason)


def test_a_too_short_print_needs_no_duration():
    assert _compute(RawFingerprint(VARIED[:10], None)).state == "too_short"


def test_the_duration_unknown_reason_is_in_the_shared_vocabulary():
    from app.services import identity_reasons

    assert identity_reasons.REASON_DURATION_UNKNOWN == "duration_unknown"


# --- process options -----------------------------------------------------------------------------


def test_registry_job_and_priority_reach_the_fingerprinter():
    fp = FakeFingerprinter(RawFingerprint(VARIED, 30.0))
    registry = object()
    compute_fingerprint(Path("/m/a.flac"), fp, params=PARAMS, registry=registry, job_id=("identity", 7),
                        low_priority=True)
    [call] = fp.calls
    assert call == {"path": Path("/m/a.flac"), "max_seconds": 120, "registry": registry,
                    "job_id": ("identity", 7), "low_priority": True}


@pytest.mark.integration
def test_the_model_module_still_imports_without_the_fingerprinter_first():
    # audio_identity must not import the fingerprinter at module import time
    # (duplicate_detection imports audio_identity; fingerprinter imports
    # duplicate_detection): a cycle would break a fresh interpreter.
    import subprocess
    import sys

    code = "import app.services.audio_identity as a; assert a.compute_fingerprint"
    done = subprocess.run([sys.executable, "-c", code], cwd=Path(audio_identity.__file__).parents[2],
                          capture_output=True, text=True)
    assert done.returncode == 0, done.stderr


# --- compute_identity gains the fingerprint (S2) ---------------------------------------------

import struct  # noqa: E402

from app.services.audio_identity import (  # noqa: E402
    FINGERPRINT_COLUMNS,
    IDENTITY_COLUMNS,
    KIND_PCM,
    AudioIdentity,
    ExactAudioHash,
    compute_identity,
    identity_from_columns,
    identity_to_columns,
)
from app.services.ffmpeg_runner import CaptureResult, FfmpegError  # noqa: E402
from app.services.fingerprinter import FpcalcFingerprinter  # noqa: E402

EXACT = ExactAudioHash(KIND_PCM, "ab" * 32, 44100, 2, 16)


@pytest.fixture
def exact_only(monkeypatch):
    monkeypatch.setattr(audio_identity, "compute_exact", lambda path, codec, **kw: EXACT)
    monkeypatch.setattr(audio_identity, "tool_versions", lambda **kw: "ffmpeg 9.0.2")


def test_compute_identity_without_a_fingerprinter_has_no_fingerprint(exact_only):
    identity = compute_identity(Path("/m/a.flac"), "flac")
    assert identity.exact == EXACT and identity.fingerprint is None


def test_compute_identity_with_a_fingerprinter_computes_both_layers(exact_only):
    fp = FakeFingerprinter(RawFingerprint(VARIED, None))
    identity = compute_identity(Path("/m/a.flac"), "flac", fingerprinter=fp, known_duration_s=42.0)
    assert identity.exact == EXACT
    assert identity.fingerprint == FingerprintIdentity("current", "fakeprint", "chromaprint-2", 42.0, VARIED)


def test_compute_identity_forwards_process_options_to_the_fingerprinter(exact_only):
    fp = FakeFingerprinter(RawFingerprint(VARIED, 30.0))
    registry = object()
    compute_identity(Path("/m/a.flac"), "flac", fingerprinter=fp, registry=registry, job_id="w", low_priority=True)
    [call] = fp.calls
    assert (call["registry"], call["job_id"], call["low_priority"]) == (registry, "w", True)


def test_compute_identity_keeps_a_fingerprint_failure_as_unavailable(exact_only):
    fp = FakeFingerprinter(FingerprintFailure("timeout"))
    identity = compute_identity(Path("/m/a.flac"), "flac", fingerprinter=fp)
    assert identity.fingerprint == FingerprintUnavailable("timeout")


class TestToolVersionsWithAFingerprinter:
    @pytest.fixture(autouse=True)
    def _ffmpeg(self, monkeypatch):
        monkeypatch.setattr(audio_identity, "_tool_versions_cache", None)
        self.answers = [CaptureResult(0, b"ffmpeg version 9.0.2 Copyright\n", "")]

        def fake(cmd, **kwargs):
            answer = self.answers[0]
            if isinstance(answer, BaseException):
                raise answer
            return answer

        monkeypatch.setattr(audio_identity, "run_capture", fake)

    def test_the_fpcalc_version_is_appended(self):
        fp = FpcalcFingerprinter("/opt/fpcalc", "1.6.2", timeout_s=5)
        assert audio_identity.tool_versions(fingerprinter=fp) == "ffmpeg 9.0.2; fpcalc 1.6.2"

    def test_without_a_fingerprinter_it_is_ffmpeg_only(self):
        assert audio_identity.tool_versions() == "ffmpeg 9.0.2"
        assert audio_identity.tool_versions(fingerprinter=None) == "ffmpeg 9.0.2"

    def test_a_missing_ffmpeg_is_none_even_with_a_fingerprinter(self):
        # A missing tool is not a version change (the reconcile skips None).
        self.answers[0] = FfmpegError("ffmpeg not found")
        fp = FpcalcFingerprinter("/opt/fpcalc", "1.6.2", timeout_s=5)
        assert audio_identity.tool_versions(fingerprinter=fp) is None


# --- the serializer pair carries the fingerprint layer --------------------------------------------

SC25_FP_COLUMNS = {"fp_state", "fp_algorithm"}  # identity-table columns, from the spec
SC25_FINGERPRINT_TABLE = {"backend", "algorithm", "duration_s", "item_count", "data"}


def _identity(fingerprint):
    return AudioIdentity(exact=EXACT, tool_versions="ffmpeg 9.0.2; fpcalc 1.6.2", computed_at=7,
                         fingerprint=fingerprint)


def test_the_fingerprint_columns_cover_the_spec_columns():
    assert SC25_FP_COLUMNS <= set(FINGERPRINT_COLUMNS)
    # The fingerprint-table columns appear as fp_<name> (one flat column set).
    assert {f"fp_{c}" for c in SC25_FINGERPRINT_TABLE - {"algorithm"}} <= set(FINGERPRINT_COLUMNS)
    assert not set(FINGERPRINT_COLUMNS) & set(IDENTITY_COLUMNS)


def test_a_current_print_serializes_with_its_little_endian_blob():
    fp = FingerprintIdentity("current", "fpcalc", "chromaprint-2", 30.0, VARIED)
    columns = identity_to_columns(_identity(fp))
    assert set(columns) == set(IDENTITY_COLUMNS) | set(FINGERPRINT_COLUMNS)
    assert {k: columns[k] for k in FINGERPRINT_COLUMNS} == {
        "fp_state": "current", "fp_algorithm": "chromaprint-2", "fp_backend": "fpcalc",
        "fp_duration_s": 30.0, "fp_item_count": 200, "fp_data": struct.pack("<200I", *VARIED),
    }


def test_a_too_short_print_serializes_with_no_blob():
    fp = FingerprintIdentity("too_short", "fpcalc", "chromaprint-2", None, ())
    columns = identity_to_columns(_identity(fp))
    assert {k: columns[k] for k in FINGERPRINT_COLUMNS} == {
        "fp_state": "too_short", "fp_algorithm": "chromaprint-2", "fp_backend": "fpcalc",
        "fp_duration_s": None, "fp_item_count": None, "fp_data": None,
    }


@pytest.mark.parametrize("fingerprint", [None, FingerprintUnavailable("timeout")])
def test_no_computed_print_adds_no_fingerprint_columns(fingerprint):
    # The writer decides the pending/unavailable state; the serializer never claims one.
    assert set(identity_to_columns(_identity(fingerprint))) == set(IDENTITY_COLUMNS)


@pytest.mark.parametrize("fingerprint", [
    FingerprintIdentity("current", "fpcalc", "chromaprint-2", 30.0, VARIED),
    FingerprintIdentity("low_information", "fpcalc", "chromaprint-2", 12.5, FLAT),
    FingerprintIdentity("too_short", "fpcalc", "chromaprint-2", None, ()),
    None,
], ids=["current", "low_information", "too_short", "none"])
def test_round_trip_with_the_fingerprint(fingerprint):
    identity = _identity(fingerprint)
    assert identity_from_columns(identity_to_columns(identity)) == identity


@pytest.mark.parametrize("fp_state", ["pending", "unavailable", "failed"])
def test_a_stored_state_that_is_not_a_computed_print_reads_back_as_none(fp_state):
    row = {**identity_to_columns(_identity(None)), "fp_state": fp_state, "fp_algorithm": "chromaprint-2"}
    assert identity_from_columns(row).fingerprint is None


def test_a_current_print_without_its_blob_is_malformed():
    columns = identity_to_columns(_identity(FingerprintIdentity("current", "fpcalc", "chromaprint-2", 30.0, VARIED)))
    with pytest.raises(ValueError):
        identity_from_columns({**columns, "fp_data": None})
