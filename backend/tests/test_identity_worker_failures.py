"""Phase 6.5A.2d: how the identity worker fails (spec §6.4 "Errors"; review 6.5-U06).

- A decode error, a timeout or an unchanged missing master counts as an
  attempt, with backoff 1 min, 1 h, then 1 day; the fourth attempt marks the
  layer ``failed`` with its reason. Nothing retries in a hot loop.
- A missing master whose path or generation changed retries at once.
- Not attempts: a kill while the worker stops (an unexpected kill is one), a
  tool that cannot run (the loop pauses and logs once), busy/locked
  database errors (the loop pauses), a vanished row.
- Any other exception is logged with the uuid and the loop continues.
"""

import logging
import sqlite3

import pytest

from app.services.audio_identity import ExactUnavailable
from app.services.identity_worker import (
    BACKOFF_S,
    BUSY_RETRY_S,
    MAX_ATTEMPTS,
    TOOL_MISSING_RETRY_S,
)
from tests.identity_worker_fakes import T0, FakeClock, FakeCompute, bytes_digest, make_worker
from tests.identity_worker_fixtures import DIGEST_A, add_track, identity, sql
from tests.track_paths import set_track_path


@pytest.fixture
def music(tmp_path):
    root = tmp_path / "music"
    root.mkdir()
    return root


def _file(music, name, content=b"audio"):
    path = music / name
    path.write_bytes(content)
    return path


def _failing(reason, times=10):
    compute = FakeCompute()
    compute.results.extend([ExactUnavailable("failed", reason)] * times)
    return compute


def _state(db, uuid_id):
    row = identity(db, uuid_id)
    return (row["exact_state"], row["attempts"], row["next_attempt_at"], row["failure_reason"])


def test_the_backoff_and_attempt_limit_are_the_spec_values():
    assert BACKOFF_S == (60, 3600, 86400) and MAX_ATTEMPTS == 4


@pytest.mark.parametrize("reason", ["decode_error", "timeout", "probe_error", "output_error", "internal_error"])
def test_a_failing_file_backs_off_then_fails_with_its_reason(db, music, reason):
    uuid_id = add_track(db, _file(music, "a.flac"), identity={"exact_digest": DIGEST_A})
    clock = FakeClock()
    compute = _failing(reason)
    worker = make_worker(db, clock=clock, compute=compute)

    worker.process_one()
    assert _state(db, uuid_id) == ("pending", 1, T0 + 60, reason)
    assert identity(db, uuid_id)["exact_digest"] == DIGEST_A  # stale-but-safe digest kept

    # No hot loop: until the backoff ends nothing is computed.
    clock.advance(59)
    assert worker.process_one().delay_s > 0
    assert len(compute.calls) == 1

    clock.advance(1)
    worker.process_one()
    assert _state(db, uuid_id) == ("pending", 2, T0 + 60 + 3600, reason)

    clock.advance(3600)
    worker.process_one()
    assert _state(db, uuid_id) == ("pending", 3, T0 + 60 + 3600 + 86400, reason)

    clock.advance(86400)
    worker.process_one()
    assert _state(db, uuid_id) == ("failed", 4, None, reason)

    clock.advance(10 * 86400)
    worker.process_one()
    assert len(compute.calls) == 4


def test_an_unchanged_missing_master_converges_to_failed_without_a_hot_loop(db, music):
    uuid_id = add_track(db, music / "gone.flac")
    clock = FakeClock()
    compute = FakeCompute()
    worker = make_worker(db, clock=clock, compute=compute)

    for _ in range(5):
        worker.process_one()
    assert _state(db, uuid_id) == ("pending", 1, T0 + 60, "master_missing")
    assert len(compute.calls) <= 1

    clock.advance(60)
    worker.process_one()
    clock.advance(3600)
    worker.process_one()
    clock.advance(86400)
    worker.process_one()
    assert _state(db, uuid_id) == ("failed", 4, None, "master_missing")


def test_a_missing_master_whose_path_changed_retries_at_once(db, music):
    old = music / "old.flac"  # already gone
    new = _file(music, "new.flac")
    uuid_id = add_track(db, old)
    compute = FakeCompute()
    compute.mid = lambda: set_track_path(db, uuid_id, new)
    worker = make_worker(db, compute=compute)

    worker.process_one()
    assert _state(db, uuid_id) == ("pending", 0, None, None)
    worker.process_one()
    assert identity(db, uuid_id)["exact_digest"] == bytes_digest(new)


def test_a_missing_master_whose_generation_changed_retries_at_once(db, music):
    uuid_id = add_track(db, music / "late.flac", identity={"generation": 1})
    compute = FakeCompute()

    def arrive():  # the bytes land and a writer bumps the generation
        _file(music, "late.flac")
        sql(db, "UPDATE track_audio_identity SET generation = 2 WHERE uuid_id = ?", (uuid_id,))

    compute.mid = arrive
    worker = make_worker(db, compute=compute)

    worker.process_one()
    assert _state(db, uuid_id) == ("pending", 0, None, None)
    worker.process_one()
    assert identity(db, uuid_id)["exact_state"] == "current"


def test_a_failure_that_raced_a_writer_is_not_an_attempt(db, music):
    path = _file(music, "a.flac")
    uuid_id = add_track(db, path, identity={"generation": 1})
    compute = _failing("decode_error", times=1)
    compute.mid = lambda: sql(
        db, "UPDATE track_audio_identity SET generation = 2 WHERE uuid_id = ?", (uuid_id,))
    worker = make_worker(db, compute=compute)

    worker.process_one()
    assert _state(db, uuid_id) == ("pending", 0, None, None)
    worker.process_one()
    assert identity(db, uuid_id)["exact_state"] == "current"


# --- kills ---------------------------------------------------------------------------------


def test_a_kill_while_the_worker_stops_is_not_an_attempt(db, music):
    uuid_id = add_track(db, _file(music, "a.flac"))
    compute = _failing("killed", times=1)
    worker = make_worker(db, compute=compute)
    compute.mid = worker.request_stop

    worker.process_one()

    assert _state(db, uuid_id) == ("pending", 0, None, None)


def test_a_kill_through_the_closed_registry_is_not_an_attempt(db, music):
    # Shutdown closes the shared identity registry (killing the hash) before
    # it reaches the worker.
    uuid_id = add_track(db, _file(music, "a.flac"))
    compute = _failing("killed", times=1)
    worker = make_worker(db, compute=compute)
    compute.mid = worker.registry.close

    worker.process_one()

    assert _state(db, uuid_id) == ("pending", 0, None, None)


def test_an_unexpected_kill_is_an_attempt(db, music):
    # e.g. the out-of-memory killer: retrying forever would never end.
    uuid_id = add_track(db, _file(music, "a.flac"))
    worker = make_worker(db, compute=_failing("killed", times=1))

    worker.process_one()

    assert _state(db, uuid_id) == ("pending", 1, T0 + 60, "killed")


# --- a tool that cannot run ----------------------------------------------------------------


def test_a_missing_tool_burns_no_attempts_pauses_and_logs_once(db, music, caplog):
    first = add_track(db, _file(music, "a.flac"), identity={"priority": 0})
    second = add_track(db, _file(music, "b.flac"), identity={"priority": 1})
    clock = FakeClock()
    worker = make_worker(db, clock=clock, compute=_failing("tool_missing"))

    with caplog.at_level(logging.WARNING):
        results = [worker.process_one() for _ in range(3)]
        clock.advance(TOOL_MISSING_RETRY_S)
        results.append(worker.process_one())

    assert all(r.delay_s >= TOOL_MISSING_RETRY_S for r in results)
    assert _state(db, first) == _state(db, second) == ("pending", 0, None, None)
    tool_logs = [r for r in caplog.records if "tool" in r.getMessage().lower()]
    assert len(tool_logs) == 1


def test_the_tool_coming_back_resumes_work(db, music):
    path = _file(music, "a.flac")
    uuid_id = add_track(db, path)
    worker = make_worker(db, compute=_failing("tool_missing", times=1))

    worker.process_one()
    worker.process_one()

    assert identity(db, uuid_id)["exact_digest"] == bytes_digest(path)


# --- busy, vanished, unexpected exceptions --------------------------------------------------


def test_a_locked_database_pauses_the_loop_without_an_attempt(db, music, monkeypatch):
    uuid_id = add_track(db, _file(music, "a.flac"))
    worker = make_worker(db)
    monkeypatch.setattr(db, "update_identity_if_unchanged", lambda *a, **k: (_ for _ in ()).throw(
        sqlite3.OperationalError("database is locked")))

    result = worker.process_one()

    assert result.delay_s >= BUSY_RETRY_S
    assert _state(db, uuid_id) == ("pending", 0, None, None)


def test_a_locked_queue_read_pauses_the_loop(db, music, monkeypatch):
    add_track(db, _file(music, "a.flac"))
    worker = make_worker(db)
    monkeypatch.setattr(db, "next_identity_work", lambda *a, **k: (_ for _ in ()).throw(
        sqlite3.OperationalError("database is busy")))

    assert worker.process_one().delay_s >= BUSY_RETRY_S


def test_an_unexpected_exception_is_logged_and_the_loop_moves_on(db, music, caplog):
    bad = add_track(db, _file(music, "a.flac"), identity={"priority": 0})
    good_path = _file(music, "b.flac")
    good = add_track(db, good_path, identity={"priority": 1})
    compute = FakeCompute()
    compute.raises.append(RuntimeError("boom"))
    worker = make_worker(db, compute=compute)

    with caplog.at_level(logging.WARNING):
        worker.process_one()
        worker.process_one()

    assert [r for r in caplog.records if bad in r.getMessage()]
    assert _state(db, bad) == ("pending", 1, T0 + 60, "internal_error")
    assert identity(db, good)["exact_digest"] == bytes_digest(good_path)


def test_a_row_whose_failure_cannot_be_recorded_is_set_aside_not_spun_on(db, music, monkeypatch):
    bad = add_track(db, _file(music, "a.flac"), identity={"priority": 0})
    good = add_track(db, _file(music, "b.flac"), identity={"priority": 1})
    compute = FakeCompute()
    worker = make_worker(db, compute=compute)
    real_update = db.update_identity_if_unchanged

    def update(uuid_id, **kwargs):
        if uuid_id == bad:
            raise RuntimeError("cannot write this row")
        return real_update(uuid_id, **kwargs)

    monkeypatch.setattr(db, "update_identity_if_unchanged", update)

    for _ in range(4):
        worker.process_one()

    assert compute.paths().count(str(music / "a.flac")) == 1
    assert identity(db, good)["exact_state"] == "current"
    assert identity(db, bad)["exact_state"] == "pending"


def test_a_step_never_raises(db, music, monkeypatch):
    add_track(db, _file(music, "a.flac"))
    worker = make_worker(db)
    monkeypatch.setattr(db, "next_identity_work", lambda *a, **k: (_ for _ in ()).throw(ValueError("x")))
    result = worker.process_one()
    assert result.delay_s > 0


# --- the tag-write anomaly without a fingerprinter -----------------------------------------


def test_a_changed_digest_is_logged_even_without_a_fingerprinter(db, music, caplog):
    # A tag_write mark keeps the fingerprint state; with no fingerprinter that
    # state is 'unavailable', and the "a tag write did not change the audio"
    # check must still speak up. It never claims a fingerprinter exists.
    path = _file(music, "a.flac")
    uuid_id = add_track(db, path, identity={
        "exact_kind": "pcm_sha256", "exact_digest": DIGEST_A, "fp_state": "unavailable"})
    with caplog.at_level(logging.WARNING):
        make_worker(db).process_one()
    assert identity(db, uuid_id)["fp_state"] == "unavailable"
    warnings = [r.getMessage() for r in caplog.records if r.levelno >= logging.WARNING]
    assert len(warnings) == 1 and uuid_id in warnings[0] and str(path) not in warnings[0]
