"""Phase 6.5B.1b: how the fingerprint layer fails (spec §6.4 "Errors"; review
6.5-U06; coordinator decisions DEV-6.5-08 and on ``empty_fingerprint``).

The fingerprint layer has its own state, attempts, backoff and failure
reason. While the exact layer is settled the row's single attempts /
next_attempt_at / failure_reason columns are the fingerprint's, so:

- a decode error, timeout, unexpected kill, output or internal error, an
  unchanged missing master, or an unknown duration counts as one attempt with
  backoff 1 min, 1 h, then 1 day; the fourth marks the print ``failed`` (with the
  algorithm, so an algorithm change revisits it) and stores no blob;
- a fingerprint failure never touches the exact layer and never holds back
  matching;
- not attempts: a kill while the worker stops or through the closed
  registry, a missing fpcalc (fingerprint work pauses, logs once, exact work
  goes on), a busy database, a failure that raced a writer;
- once every track is in a final state, the worker idles.
"""

import logging
import sqlite3

import pytest

from app.services import audio_identity
from app.services.fingerprinter import FingerprintFailure, RawFingerprint
from app.services.identity_worker import TOOL_MISSING_RETRY_S
from tests.tool_call_capture import bound_to
from tests.identity_worker_fakes import (
    T0,
    VARIED_ITEMS,
    FakeClock,
    FakeCompute,
    FakeFingerprinter,
    bytes_digest,
    make_worker,
)
from tests.identity_worker_fixtures import add_track, identity, set_identity, sql
from tests.track_paths import set_track_path


@pytest.fixture
def music(tmp_path):
    root = tmp_path / "music"
    root.mkdir()
    return root


def _file(music, name="a.flac", content=b"audio bytes"):
    path = music / name
    path.write_bytes(content)
    return path


def _settled(db, path, **values):
    row = {"exact_state": "current", "exact_kind": "pcm_sha256", "exact_digest": bytes_digest(path),
           "sample_rate_hz": 44100, "channels": 2, "bits_per_sample": 16,
           "fp_state": "pending", "match_state": "current", "generation": 2}
    row.update(values)
    return add_track(db, path, identity=row)


def _failing(result, times=10):
    fp = FakeFingerprinter()
    fp.results.extend([result] * times)
    return fp


def _fp(db, uuid_id):
    row = identity(db, uuid_id)
    return (row["fp_state"], row["attempts"], row["next_attempt_at"], row["failure_reason"])


def _exact(db, uuid_id):
    row = identity(db, uuid_id)
    return (row["exact_state"], row["exact_kind"], row["exact_digest"], row["generation"])


def _fingerprint_row(db, uuid_id):
    return sql(db, "SELECT * FROM track_audio_fingerprint WHERE uuid_id = ?", (uuid_id,))


FAILURES = {
    "decode_error": FingerprintFailure("decode_error"),
    "timeout": FingerprintFailure("timeout"),
    "killed": FingerprintFailure("killed"),  # unexpected (e.g. the OOM killer)
    "output_error": FingerprintFailure("output_error"),
    "internal_error": FingerprintFailure("internal_error"),
    "master_missing": FingerprintFailure("master_missing"),
    "duration_unknown": RawFingerprint(VARIED_ITEMS, None),  # and trackmetadata.duration is NULL
}


@pytest.mark.parametrize("reason", sorted(FAILURES))
def test_a_failing_print_backs_off_then_fails_with_its_reason(db, music, reason, monkeypatch):
    # 6-5-L-03: the decoded duration is unknown too (the file is not real audio).
    monkeypatch.setattr(audio_identity, "measure_decoded_duration",
                        bound_to(audio_identity.measure_decoded_duration)(lambda *a, **k: None))
    path = _file(music)
    uuid_id = _settled(db, path)
    sql(db, "INSERT INTO track_audio_fingerprint (uuid_id, backend, algorithm, duration_s, item_count, data) "
            "VALUES (?, 'fpcalc', 'chromaprint-1', 9.0, 1, x'00000000')", (uuid_id,))
    exact_before = _exact(db, uuid_id)
    clock = FakeClock()
    fp = _failing(FAILURES[reason])
    worker = make_worker(db, clock=clock, fingerprinter=fp)

    worker.process_one()
    assert _fp(db, uuid_id) == ("pending", 1, T0 + 60, reason)
    assert worker.process_one().outcome == "idle"  # not due yet: no hot loop

    clock.advance(60)
    worker.process_one()
    assert _fp(db, uuid_id) == ("pending", 2, T0 + 60 + 3600, reason)

    clock.advance(3600)
    worker.process_one()
    assert _fp(db, uuid_id) == ("pending", 3, T0 + 60 + 3600 + 86400, reason)

    clock.advance(86400)
    worker.process_one()
    assert _fp(db, uuid_id) == ("failed", 4, None, reason)
    assert identity(db, uuid_id)["fp_algorithm"] == "chromaprint-2"
    assert _fingerprint_row(db, uuid_id) == []

    clock.advance(10**7)
    assert worker.process_one().outcome == "idle"
    assert len(fp.calls) == 4
    assert _exact(db, uuid_id) == exact_before  # the exact layer is never touched
    assert identity(db, uuid_id)["match_state"] == "current"


def test_a_print_in_backoff_never_holds_back_matching(db, music):
    uuid_id = _settled(db, _file(music))
    fp = _failing(FingerprintFailure("timeout"))
    worker = make_worker(db, fingerprinter=fp)
    worker.process_one()
    set_identity(db, uuid_id, match_state="pending")  # e.g. a matcher-version re-queue

    assert worker.process_one().outcome == "matched"
    assert identity(db, uuid_id)["match_state"] == "current"
    assert _fp(db, uuid_id)[:2] == ("pending", 1)


# --- not attempts --------------------------------------------------------------------------------------


def test_a_kill_while_the_worker_stops_is_not_an_attempt(db, music):
    uuid_id = _settled(db, _file(music))
    fp = _failing(FingerprintFailure("killed"), times=1)
    worker = make_worker(db, fingerprinter=fp)
    fp.mid = worker.request_stop

    assert worker.process_one().outcome == "stopped"
    assert _fp(db, uuid_id) == ("pending", 0, None, None)


def test_a_kill_through_the_closed_registry_is_not_an_attempt(db, music):
    uuid_id = _settled(db, _file(music))
    fp = _failing(FingerprintFailure("killed"), times=1)
    worker = make_worker(db, fingerprinter=fp)
    fp.mid = worker.registry.close

    worker.process_one()
    assert _fp(db, uuid_id) == ("pending", 0, None, None)


def test_a_stop_before_the_print_starts_runs_nothing(db, music):
    uuid_id = _settled(db, _file(music))
    fp = FakeFingerprinter()
    worker = make_worker(db, fingerprinter=fp)
    worker._stop.set()  # the stop landed between the loop check and the step

    worker.process_one()
    assert fp.calls == [] and _fp(db, uuid_id) == ("pending", 0, None, None)


def test_a_missing_fpcalc_pauses_fingerprints_but_not_exact_work(db, music, caplog):
    printed = _settled(db, _file(music, "a.flac"), priority=0)
    hashed_path = _file(music, "b.flac", b"other audio")
    hashed = add_track(db, hashed_path, identity={"priority": 1, "fp_state": "pending"})
    clock = FakeClock()
    fp = _failing(FingerprintFailure("tool_missing"), times=2)
    compute = FakeCompute()
    worker = make_worker(db, clock=clock, compute=compute, fingerprinter=fp)

    with caplog.at_level(logging.WARNING):
        first = worker.process_one()       # fpcalc missing: pause the fingerprint work
        second = worker.process_one()      # exact work goes on at once
        third = worker.process_one()       # the paused print is not retried yet
        calls_while_paused = len(fp.calls)
        clock.advance(TOOL_MISSING_RETRY_S)
        fourth = worker.process_one()      # retried once after the pause: still missing
        calls_after_retry = len(fp.calls)
        clock.advance(TOOL_MISSING_RETRY_S)
        fifth = worker.process_one()       # fpcalc is back

    assert first.outcome == "tool_missing" and first.delay_s == 0
    assert second.outcome == "written" and identity(db, hashed)["exact_digest"] == bytes_digest(hashed_path)
    assert third.outcome in ("idle", "matched") and calls_while_paused == 1
    assert fourth.outcome == "tool_missing" and calls_after_retry == 2
    assert fifth.outcome == "written" and identity(db, printed)["fp_state"] == "current"
    assert identity(db, printed)["attempts"] == 0
    tool_logs = [r for r in caplog.records if "fpcalc" in r.getMessage().lower()
                 or "fingerprint" in r.getMessage().lower()]
    assert len(tool_logs) == 1


def test_a_failure_that_raced_a_writer_is_not_an_attempt(db, music):
    uuid_id = _settled(db, _file(music))
    fp = _failing(FingerprintFailure("decode_error"), times=1)
    fp.mid = lambda: set_identity(db, uuid_id, generation=3)
    make_worker(db, fingerprinter=fp).process_one()
    assert _fp(db, uuid_id) == ("pending", 0, None, None)


def test_a_missing_master_whose_path_changed_retries_at_once(db, music):
    path = _file(music)
    uuid_id = _settled(db, path)
    moved = _file(music, "moved.flac")
    fp = _failing(FingerprintFailure("master_missing"), times=1)
    fp.mid = lambda: set_track_path(db, uuid_id, moved)
    worker = make_worker(db, fingerprinter=fp)

    worker.process_one()
    assert _fp(db, uuid_id) == ("pending", 0, None, None)
    worker.process_one()
    assert identity(db, uuid_id)["fp_state"] == "current"
    assert fp.paths() == [str(path), str(moved)]


def test_a_locked_database_is_not_an_attempt(db, music, monkeypatch):
    uuid_id = _settled(db, _file(music))
    worker = make_worker(db, fingerprinter=FakeFingerprinter())
    monkeypatch.setattr(db, "update_identity_if_unchanged", lambda *a, **k: (_ for _ in ()).throw(
        sqlite3.OperationalError("database is locked")))
    assert worker.process_one().outcome == "busy"
    assert _fp(db, uuid_id) == ("pending", 0, None, None)


def test_an_unexpected_exception_counts_against_the_print_not_the_exact_layer(db, music, monkeypatch):
    uuid_id = _settled(db, _file(music))
    exact_before = _exact(db, uuid_id)
    real = db.update_identity_if_unchanged
    calls = []

    def flaky(*args, **kwargs):
        calls.append(1)
        if len(calls) == 1:
            raise RuntimeError("boom")
        return real(*args, **kwargs)

    monkeypatch.setattr(db, "update_identity_if_unchanged", flaky)
    make_worker(db, fingerprinter=FakeFingerprinter()).process_one()

    assert _fp(db, uuid_id) == ("pending", 1, T0 + 60, "internal_error")
    assert _exact(db, uuid_id) == exact_before


# --- nothing spins -----------------------------------------------------------------------------------


def test_with_every_track_in_a_final_state_the_worker_idles(db, music):
    for i, (exact, fp_state) in enumerate([
        ("current", "too_short"), ("current", "low_information"), ("current", "failed"),
        ("current", "unavailable"), ("unsupported", "too_short"),
        ("failed", "pending"),  # an unreadable file: the print waits for the exact layer
    ]):
        add_track(db, _file(music, f"{i}.flac"), identity={
            "exact_state": exact, "fp_state": fp_state, "match_state": "current",
            "attempts": 3 if exact == "failed" else 0,
            "failure_reason": "decode_error" if exact == "failed" else None})
    fp, compute = FakeFingerprinter(), FakeCompute()
    worker = make_worker(db, fingerprinter=fp, compute=compute)

    results = [worker.process_one() for _ in range(3)]
    assert all(r.outcome == "idle" and r.delay_s > 0 for r in results)
    assert fp.calls == [] and compute.calls == []


def test_an_exception_before_the_layer_is_known_never_resets_a_settled_exact_layer(db, music, monkeypatch):
    # The subject read fails for a row that only has fingerprint work: the
    # failure must not be booked against (and so re-pend) the current exact layer.
    uuid_id = _settled(db, _file(music))
    exact_before = _exact(db, uuid_id)
    real = db.get_identity_subject
    calls = []

    def flaky(*args, **kwargs):
        calls.append(1)
        if len(calls) == 1:
            raise RuntimeError("boom")
        return real(*args, **kwargs)

    monkeypatch.setattr(db, "get_identity_subject", flaky)
    make_worker(db, fingerprinter=FakeFingerprinter()).process_one()

    assert _exact(db, uuid_id) == exact_before
    assert identity(db, uuid_id)["exact_state"] == "current"
    assert _fp(db, uuid_id) == ("pending", 1, T0 + 60, "internal_error")
