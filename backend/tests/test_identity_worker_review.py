"""Phase 6.5A.2d in-piece review fixes (temp/orchestration/phase-6-5/6.5A.2d-review.md).

F1 a failure the worker records carries the tool versions, so an unchanged
   tool never revives a failed row at the next start.
F2 a row that cannot even be stat()ed backs off in the database, and a row
   set aside in memory makes the loop wait, never spin.
F3 a thread that could not start can still be stopped.
F5 a master whose bytes keep changing outside OSML is not re-decoded back
   to back.
F6 a busy database while recording a failure is the busy pause, not a
   set-aside.
"""

import sqlite3
import threading

import pytest

from app.services.audio_identity import ExactUnavailable
from app.services import identity_worker as identity_worker_mod
from app.services.identity_worker import BACKOFF_S, BUSY_RETRY_S, MAX_ATTEMPTS, reconcile_audio_identity
from tests.identity_worker_fakes import T0, TOOLS, FakeClock, FakeCompute, bytes_digest, make_worker
from tests.identity_worker_fixtures import add_track, identity, make_db


@pytest.fixture
def db(tmp_path):
    return make_db(tmp_path)


@pytest.fixture
def music(tmp_path):
    root = tmp_path / "music"
    root.mkdir()
    return root


def _file(music, name, content=b"audio"):
    path = music / name
    path.write_bytes(content)
    return path


@pytest.mark.parametrize("reason", ["decode_error", "master_missing"])
def test_f1_a_row_the_worker_failed_stays_failed_with_the_same_tools(db, music, reason):
    path = _file(music, "a.flac") if reason == "decode_error" else music / "gone.flac"
    uuid_id = add_track(db, path)
    clock = FakeClock()
    compute = FakeCompute()
    compute.results.extend([ExactUnavailable("failed", reason)] * MAX_ATTEMPTS)
    worker = make_worker(db, clock=clock, compute=compute)
    for _ in range(MAX_ATTEMPTS):
        worker.process_one()
        clock.advance(BACKOFF_S[-1])
    row = identity(db, uuid_id)
    assert (row["exact_state"], row["tool_versions"]) == ("failed", TOOLS)

    reconcile_audio_identity(db, tool_versions=TOOLS, fingerprinter_present=False)
    assert identity(db, uuid_id)["exact_state"] == "failed"

    reconcile_audio_identity(db, tool_versions="ffmpeg 10.0", fingerprinter_present=False)
    assert identity(db, uuid_id)["exact_state"] == "pending"


def test_f2_an_unreadable_master_backs_off_in_the_database(db, music, monkeypatch):
    path = _file(music, "a.flac")
    uuid_id = add_track(db, path)
    real_stat = identity_worker_mod.os.stat

    def stat(p, *args, **kwargs):
        if str(p) == str(path):
            raise PermissionError(13, "denied")
        return real_stat(p, *args, **kwargs)

    monkeypatch.setattr(identity_worker_mod.os, "stat", stat)
    clock = FakeClock()
    compute = FakeCompute()
    compute.results.extend([ExactUnavailable("failed", "decode_error")] * 5)
    worker = make_worker(db, clock=clock, compute=compute)

    for _ in range(5):
        worker.process_one()

    row = identity(db, uuid_id)
    assert (row["exact_state"], row["attempts"], row["next_attempt_at"]) == ("pending", 1, T0 + 60)


def test_f2_rows_set_aside_in_memory_never_make_the_loop_spin(db, music, monkeypatch):
    for i in range(100):
        add_track(db, _file(music, f"{i}.flac"))
    worker = make_worker(db)

    def broken(*args, **kwargs):
        raise RuntimeError("cannot write")

    monkeypatch.setattr(db, "update_identity_if_unchanged", broken)
    results = [worker.process_one() for _ in range(250)]

    assert all(r.delay_s > 0 for r in results)


def test_f2_a_row_set_aside_in_memory_comes_back_after_one_minute(db, music, monkeypatch):
    # Review r1 N16: the set-aside lasts the first backoff step (one minute),
    # no shorter (a spin) and no longer (a stuck row).
    uuid_id = add_track(db, _file(music, "a.flac"))
    clock = FakeClock()
    worker = make_worker(db, clock=clock)

    def broken(*args, **kwargs):
        raise RuntimeError("cannot write")

    monkeypatch.setattr(db, "update_identity_if_unchanged", broken)
    first = worker.process_one()
    assert (first.outcome, first.uuid_id, first.delay_s) == ("error", uuid_id, BUSY_RETRY_S)
    assert identity(db, uuid_id)["attempts"] == 0  # nothing reached the database

    clock.advance(59)
    assert worker.process_one().outcome == "idle"

    clock.advance(1)
    again = worker.process_one()
    assert (again.outcome, again.uuid_id) == ("error", uuid_id)


def test_f3_a_thread_that_could_not_start_can_still_be_stopped(db, monkeypatch):
    worker = make_worker(db)

    def cannot_start(self):
        raise RuntimeError("can't start new thread")

    monkeypatch.setattr(threading.Thread, "start", cannot_start)
    with pytest.raises(RuntimeError):
        worker.start()
    monkeypatch.undo()

    assert worker.stop(timeout=1) is True
    assert not worker.is_alive() and worker.done.done()


def test_f5_a_master_that_keeps_changing_is_not_redecoded_back_to_back(db, music):
    path = _file(music, "a.flac", b"v0")
    uuid_id = add_track(db, path)
    clock = FakeClock()
    compute = FakeCompute()
    worker = make_worker(db, clock=clock, compute=compute)
    counter = iter(range(1, 1000))

    def churn():
        path.write_bytes(b"v" + str(next(counter)).encode() * 3)

    for _ in range(5):
        compute.mid = churn
        worker.process_one()
    assert len(compute.calls) == 1  # set aside after the stat changed under it
    assert identity(db, uuid_id)["attempts"] == 0

    clock.advance(BACKOFF_S[0])
    compute.mid = None
    worker.process_one()
    assert identity(db, uuid_id)["exact_digest"] == bytes_digest(path)


def test_f5_a_writer_bumping_the_generation_lifts_the_set_aside(db, music):
    from app.database.database import Database

    path = _file(music, "a.flac", b"v0")
    uuid_id = add_track(db, path)
    compute = FakeCompute()
    worker = make_worker(db, compute=compute)
    compute.mid = lambda: path.write_bytes(b"replaced in place")  # before the mark
    worker.process_one()

    with db._connection(commit=True) as conn:  # the in-place writer's mark lands
        Database._mark_audio_identity_stale_in(conn, uuid_id, "tag_write")
    worker.process_one()

    assert identity(db, uuid_id)["exact_digest"] == bytes_digest(path)


def test_f6_a_busy_database_while_recording_a_failure_is_the_busy_pause(db, music, monkeypatch):
    uuid_id = add_track(db, _file(music, "a.flac"))
    compute = FakeCompute()
    compute.raises.append(RuntimeError("boom"))
    worker = make_worker(db, compute=compute)
    real_update = db.update_identity_if_unchanged
    calls = []

    def update(*args, **kwargs):
        calls.append(1)
        if len(calls) == 1:
            raise sqlite3.OperationalError("database is locked")
        return real_update(*args, **kwargs)

    monkeypatch.setattr(db, "update_identity_if_unchanged", update)
    result = worker.process_one()
    assert result.delay_s >= BUSY_RETRY_S

    worker.process_one()  # not set aside: the next step takes it again
    assert identity(db, uuid_id)["exact_state"] == "current"
