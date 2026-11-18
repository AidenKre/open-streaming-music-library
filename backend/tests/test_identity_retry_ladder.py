"""The retry ladder of both identity layers (spec §6.4 "Errors", sign-off DEV-6.5-14).

A failure that counts as an attempt waits 1 min after the 1st failure, 1 h
after the 2nd and 1 day after the 3rd; only the 4th failure marks the layer
``failed``. The same ladder holds for the exact layer and the fingerprint
layer, including an unknown fingerprint duration. The expected waits are
written out here, not read from the module under test.
"""

import pytest

from app.services import audio_identity
from app.services.audio_identity import ExactUnavailable
from app.services.fingerprinter import FingerprintFailure, RawFingerprint
from tests.identity_worker_fakes import (
    T0,
    VARIED_ITEMS,
    FakeClock,
    FakeCompute,
    FakeFingerprinter,
    bytes_digest,
    make_worker,
)
from tests.identity_worker_fixtures import add_track, identity, make_db

WAITS = (60, 3600, 86400)


@pytest.fixture
def db(tmp_path):
    return make_db(tmp_path)


@pytest.fixture
def music(tmp_path):
    root = tmp_path / "music"
    root.mkdir()
    return root


def _file(music, name="a.flac", content=b"audio bytes"):
    path = music / name
    path.write_bytes(content)
    return path


def _exact(db, uuid_id):
    row = identity(db, uuid_id)
    return (row["exact_state"], row["attempts"], row["next_attempt_at"], row["failure_reason"])


def _fp(db, uuid_id):
    row = identity(db, uuid_id)
    return (row["fp_state"], row["attempts"], row["next_attempt_at"], row["failure_reason"])


def _walk_ladder(worker, clock, read, uuid_id, reason, final_state):
    """Drive four failures; assert each wait, no compute before it is due, and
    ``failed`` only after the last. Returns how many computes ran."""
    start = clock()
    worker.process_one()
    expected_at = start + WAITS[0]
    assert read(uuid_id) == ("pending", 1, expected_at, reason)
    for n, wait in enumerate(WAITS[1:], start=2):
        clock.now = expected_at - 1  # one second early: nothing is due
        assert worker.process_one().outcome == "idle"
        clock.now = expected_at
        worker.process_one()
        expected_at += wait
        assert read(uuid_id) == ("pending", n, expected_at, reason)
    clock.now = expected_at - 1
    assert worker.process_one().outcome == "idle"  # the 1-day wait is really waited
    clock.now = expected_at
    worker.process_one()
    assert read(uuid_id) == (final_state, 4, None, reason)


@pytest.mark.parametrize("reason", ["decode_error", "timeout", "internal_error"])
def test_the_exact_layer_waits_a_minute_an_hour_and_a_day_then_fails(db, music, reason):
    uuid_id = add_track(db, _file(music))
    clock = FakeClock()
    compute = FakeCompute()
    compute.results.extend([ExactUnavailable("failed", reason)] * 10)
    worker = make_worker(db, clock=clock, compute=compute)

    _walk_ladder(worker, clock, lambda u: _exact(db, u), uuid_id, reason, "failed")

    clock.advance(10 * 86400)
    for _ in range(3):  # the settled row is matched once, then nothing is due
        worker.process_one()
    assert worker.process_one().outcome == "idle"
    assert len(compute.calls) == 4


def test_an_unchanged_missing_master_walks_the_whole_ladder(db, music):
    uuid_id = add_track(db, music / "gone.flac")
    clock = FakeClock()
    compute = FakeCompute()
    worker = make_worker(db, clock=clock, compute=compute)

    _walk_ladder(worker, clock, lambda u: _exact(db, u), uuid_id, "master_missing", "failed")


@pytest.mark.parametrize(
    "result, reason",
    [
        (FingerprintFailure("decode_error"), "decode_error"),
        (FingerprintFailure("timeout"), "timeout"),
        (RawFingerprint(VARIED_ITEMS, None), "duration_unknown"),  # trackmetadata.duration is NULL
    ],
)
def test_the_fingerprint_layer_waits_a_minute_an_hour_and_a_day_then_fails(db, music, result, reason, monkeypatch):
    # 6-5-L-03: the decoded duration is unknown too (the file is not real audio).
    monkeypatch.setattr(audio_identity, "measure_decoded_duration", lambda *a, **k: None)
    path = _file(music)
    uuid_id = add_track(db, path, identity={
        "exact_state": "current", "exact_kind": "pcm_sha256", "exact_digest": bytes_digest(path),
        "sample_rate_hz": 44100, "channels": 2, "bits_per_sample": 16,
        "fp_state": "pending", "match_state": "current", "generation": 2,
    })
    clock = FakeClock()
    fp = FakeFingerprinter()
    fp.results.extend([result] * 10)
    worker = make_worker(db, clock=clock, fingerprinter=fp)

    _walk_ladder(worker, clock, lambda u: _fp(db, u), uuid_id, reason, "failed")

    clock.advance(10 * 86400)
    assert worker.process_one().outcome == "idle"
    assert len(fp.calls) == 4
    assert identity(db, uuid_id)["exact_state"] == "current"


def test_the_ladder_starts_from_the_clock_not_from_a_fixed_epoch(db, music):
    uuid_id = add_track(db, _file(music))
    clock = FakeClock(T0 + 12345)
    compute = FakeCompute()
    compute.results.extend([ExactUnavailable("failed", "timeout")] * 4)
    worker = make_worker(db, clock=clock, compute=compute)

    worker.process_one()

    assert _exact(db, uuid_id) == ("pending", 1, T0 + 12345 + 60, "timeout")
