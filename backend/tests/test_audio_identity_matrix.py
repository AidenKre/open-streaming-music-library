"""Phase 6.5 spec §8 fixture matrix, on real ffmpeg (``requires_ffmpeg``).

Expected groups come from ``tests/audio_fixtures.py``, written by hand from
how each file was generated (review 6.5-U02), never from ``compute_exact``.
Results recorded on ffmpeg 9.0.2 (2026-11-10), including the spec's "record
the result" row: a seekable MP3 with appended APEv2 + ID3v1 tags keeps the
packet digest of its source.
"""

from __future__ import annotations

import itertools

import pytest

from app.services.audio_identity import (
    ExactAudioHash,
    ExactUnavailable,
    compute_exact,
    compute_identity,
    exact_match,
)
from tests.audio_fixtures import build_identity_fixtures

pytestmark = pytest.mark.requires_ffmpeg


@pytest.fixture(scope="module")
def fixtures(tmp_path_factory):
    # One build per xdist worker and module, in that worker's own temp dir.
    return build_identity_fixtures(tmp_path_factory.mktemp("identity-fixtures"))


@pytest.fixture(scope="module")
def results(fixtures):
    return {name: compute_exact(fx.path, fx.codec_hint) for name, fx in fixtures.items()}


def test_every_file_gets_its_expected_kind(fixtures, results):
    for name, fx in fixtures.items():
        result = results[name]
        if fx.kind is None:
            continue
        assert isinstance(result, ExactAudioHash), (name, result)
        assert result.kind == fx.kind, name


def test_exact_equality_follows_the_expected_groups(fixtures, results):
    hashed = [name for name, fx in fixtures.items() if fx.group is not None]
    mismatches = []
    for a, b in itertools.combinations(hashed, 2):
        expected = fixtures[a].group == fixtures[b].group
        if exact_match(results[a], results[b]) != expected:
            mismatches.append((a, b, "expected match" if expected else "expected no match"))
    assert mismatches == []


@pytest.mark.parametrize(
    "a, b",
    [
        ("flac24.flac", "alac24.m4a"),
        ("flac24.flac", "wav24.wav"),
        ("flac16.flac", "alac16.m4a"),
        ("flac16.flac", "wav16.wav"),
        ("flac16.flac", "flac16_padded24.flac"),      # zero-padded 24 = 16
        ("flac24.flac", "flac24_retag.flac"),
        ("flac24.flac", "flac24_level0.flac"),
        ("flac24.flac", "flac24_remux.mka"),
        ("mp3_320.mp3", "mp3_320_retag.mp3"),
        ("mp3_128.mp3", "mp3_128_retag.mp3"),
        ("aac256.m4a", "aac256_retag.m4a"),
        ("mp3_320.mp3", "mp3_320_ape_id3v1.mp3"),     # recorded: same on 9.0.2
    ],
)
def test_named_spec_pairs_match(results, a, b):
    assert exact_match(results[a], results[b])


@pytest.mark.parametrize(
    "a, b",
    [
        ("flac24.flac", "flac16.flac"),               # 16-bit is a different quantization
        ("flac24.flac", "flac24_silence.flac"),       # +500 ms leading silence
        ("flac24.flac", "unrelated24.flac"),
        ("flac24.flac", "mp3_320.mp3"),               # lossy never exact-matches lossless
        ("mp3_320.mp3", "mp3_128.mp3"),
        ("mp3_320.mp3", "aac256.m4a"),
        ("flac24.flac", "wav_f32.wav"),               # float kind is separate
    ],
)
def test_named_spec_pairs_differ(results, a, b):
    assert not exact_match(results[a], results[b])


def test_padded_copy_reports_its_own_depth_but_the_same_digest(results):
    sixteen, padded = results["flac16.flac"], results["flac16_padded24.flac"]
    assert (sixteen.bits_per_sample, padded.bits_per_sample) == (16, 24)
    assert sixteen.digest == padded.digest


def test_pcm_parameters_are_the_stream_parameters(results):
    for name in ("flac24.flac", "alac24.m4a", "wav16.wav", "wav_f32.wav"):
        assert (results[name].sample_rate_hz, results[name].channels) == (44100, 2), name


def test_float_wav_is_the_float_kind(results):
    assert results["wav_f32.wav"].kind == "pcm_float_sha256"


def test_opus_is_unsupported(results):
    assert results["clip.opus"] == ExactUnavailable(state="unsupported", reason=None)


def test_corrupt_file_is_failed_with_a_path_free_reason(fixtures, results):
    result = results["corrupt.flac"]
    assert isinstance(result, ExactUnavailable) and result.state == "failed"
    assert result.reason in {"decode_error", "probe_error", "output_error"}
    assert str(fixtures["corrupt.flac"].path.parent) not in result.reason


def test_low_priority_with_a_registry_gives_the_same_digest(fixtures, results):
    from app.services.ffmpeg_runner import FfmpegProcessRegistry

    fx = fixtures["flac24.flac"]
    again = compute_exact(fx.path, fx.codec_hint, registry=FfmpegProcessRegistry(),
                          job_id="identity", low_priority=True)
    assert again == results["flac24.flac"]


def test_compute_identity_records_the_ffmpeg_version(fixtures, results):
    fx = fixtures["flac24.flac"]
    identity = compute_identity(fx.path, fx.codec_hint)
    assert identity.exact == results["flac24.flac"]
    assert identity.tool_versions is not None and identity.tool_versions.startswith("ffmpeg ")
