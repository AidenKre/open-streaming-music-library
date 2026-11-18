"""9-fix-r1 (review 9-R1-01, 9-R1-40, 9-R1-21): the sender never loses an
answered outcome and never resends rows whose answer it knows; a row the
client refuses locally is settled ``failed`` instead of blocking the queue; a
row that turned 14 days old while the sender waited is not sent.

A write that cannot get SQLite's write lock (another writer holding it longer
than the busy timeout) is modelled by making the database method raise the
error SQLite raises then, so nothing waits in real time."""

import logging
import sqlite3

import pytest

from app.services.lastfm_sender import MAX_AGE_S
from tests.lastfm_fake import failed, ok_scrobbles, scrobble_result
from tests.lastfm_sender_rig import (
    NOW_S,
    WALL_MS,
    connect_user,
    execute,
    make_rig,
    queue_row,
    row,
    sent,
)

T1, T2, T3 = NOW_S - 300, NOW_S - 200, NOW_S - 100


@pytest.fixture
def rig(tmp_path):
    return make_rig(tmp_path)


@pytest.fixture
def ana(rig):
    return connect_user(rig, "ana")


def _lock_held(monkeypatch, rig, method, *, times, owner=None):
    """The next ``times`` calls of ``rig.db.<method>`` (for ``owner`` when given)
    fail as SQLite does when another writer holds the lock; later calls go through."""
    real = getattr(rig.db, method)
    failures = {"left": times}

    def flaky(*args, **kwargs):
        if failures["left"] > 0 and (owner is None or kwargs.get("owner_id") == owner):
            failures["left"] -= 1
            raise sqlite3.OperationalError("database is locked")
        return real(*args, **kwargs)

    monkeypatch.setattr(rig.db, method, flaky)
    return failures


def _status(rig, uuids):
    return [(row(rig, u)["status"], row(rig, u)["result_code"]) for u in uuids]


# ── 9-R1-01: an answered outcome is never lost and never resent ─────────────


def test_an_accepted_batch_whose_settle_write_fails_is_settled_later_and_never_resent(
    rig, ana, monkeypatch
):
    uuids = [queue_row(rig, ana, listened_at_s=t) for t in (T1, T2, T3)]
    rig.fake.queue(ok_scrobbles(3, 0, [scrobble_result(t) for t in (T1, T2, T3)]))
    _lock_held(monkeypatch, rig, "settle_lastfm_rows", times=1)

    rig.sender.run_pass()
    assert _status(rig, uuids) == [("pending", None)] * 3  # the write did not land

    rig.wall.advance_s(30)
    rig.sender.run_pass()

    assert len(rig.fake.requests) == 1
    assert _status(rig, uuids) == [("sent", None)] * 3
    assert {row(rig, u)["done_at"] for u in uuids} == {WALL_MS}  # the time of the answer


def test_while_the_write_keeps_failing_that_user_is_not_served_again(rig, ana, monkeypatch):
    uuids = [queue_row(rig, ana, listened_at_s=t) for t in (T1, T2)]
    rig.fake.queue(ok_scrobbles(2, 1, [scrobble_result(T1), scrobble_result(T2, 1)]))
    _lock_held(monkeypatch, rig, "settle_lastfm_rows", times=3)

    for _ in range(3):
        rig.sender.run_pass()
    assert len(rig.fake.requests) == 1
    assert _status(rig, uuids) == [("pending", None)] * 2

    rig.sender.run_pass()

    assert len(rig.fake.requests) == 1
    assert _status(rig, uuids) == [("sent", None), ("ignored", "1")]


def test_a_rejected_batch_whose_alone_marks_fail_is_never_resent_as_a_batch(
    rig, ana, monkeypatch
):
    uuids = [queue_row(rig, ana, listened_at_s=t) for t in (T1, T2, T3)]
    rig.fake.queue(failed(13))
    _lock_held(monkeypatch, rig, "mark_lastfm_alone", times=1)

    rig.sender.run_pass()
    rig.fake.queue(ok_scrobbles(1, 0, [scrobble_result(T1)]))
    rig.sender.run_pass()

    assert [s.timestamps for s in sent(rig)] == [[T1, T2, T3], [T1]]
    assert [row(rig, u)["alone"] for u in uuids] == [1, 1, 1]
    assert _status(rig, uuids) == [("sent", None), ("pending", None), ("pending", None)]


def test_a_row_rejected_alone_whose_write_fails_is_failed_later_and_never_resent(
    rig, ana, monkeypatch
):
    alone = queue_row(rig, ana, listened_at_s=T1, alone=True)
    rig.fake.queue(failed(13))
    _lock_held(monkeypatch, rig, "settle_lastfm_rows", times=1)

    rig.sender.run_pass()
    rig.sender.run_pass()

    assert len(rig.fake.requests) == 1
    assert _status(rig, [alone]) == [("failed", "13")]


def test_other_users_are_still_served_while_one_users_outcome_waits(rig, ana, monkeypatch):
    ben = connect_user(rig, "ben")
    ana_row = queue_row(rig, ana, listened_at_s=T1)
    queue_row(rig, ben, listened_at_s=T1)
    rig.fake.queue(ok_scrobbles(1, 0, [scrobble_result(T1)]), ok_scrobbles(1, 0, [scrobble_result(T1)]))
    lock = _lock_held(monkeypatch, rig, "settle_lastfm_rows", times=99, owner=ana)

    rig.sender.run_pass()
    later = queue_row(rig, ben, listened_at_s=T2)
    rig.fake.queue(ok_scrobbles(1, 0, [scrobble_result(T2)]))
    rig.sender.run_pass()

    assert len(rig.fake.requests) == 3
    assert sent(rig)[2].timestamps == [T2]
    assert _status(rig, [later]) == [("sent", None)]
    assert _status(rig, [ana_row]) == [("pending", None)]

    lock["left"] = 0
    rig.sender.run_pass()

    assert len(rig.fake.requests) == 3
    assert _status(rig, [ana_row]) == [("sent", None)]


# ── 9-R1-40: a row the client refuses locally is failed, the rest is sent ───


def test_a_row_the_client_refuses_is_failed_and_the_rest_of_the_batch_is_sent(rig, ana):
    first = queue_row(rig, ana, listened_at_s=T1)
    refused = queue_row(rig, ana, listened_at_s=T2, extra={"mbid": "not-a-scrobble-field"})
    last = queue_row(rig, ana, listened_at_s=T3)
    rig.fake.queue(ok_scrobbles(2, 0, [scrobble_result(T1), scrobble_result(T3)]))

    rig.sender.run_pass()

    assert [s.timestamps for s in sent(rig)] == [[T1, T3]]
    assert _status(rig, [first, refused, last]) == [("sent", None), ("failed", "invalid_row"), ("sent", None)]
    assert row(rig, refused)["done_at"] == WALL_MS


def test_a_row_that_is_not_valid_text_is_failed_and_does_not_block_the_queue(rig, ana):
    refused = "a0000000-0000-4000-8000-000000000001"
    execute(
        rig,
        "INSERT INTO scrobble_outbox (event_uuid, owner_id, payload, listened_at_s, created_at)"
        " VALUES (?, ?, ?, ?, ?)",
        (refused, ana, '{"artist": "A", "track": "\\ud800", "timestamp": %d}' % T1, T1, WALL_MS - 61_000),
    )
    good = queue_row(rig, ana, listened_at_s=T2)
    rig.fake.queue(ok_scrobbles(1, 0, [scrobble_result(T2)]))

    rig.sender.run_pass()

    assert [s.timestamps for s in sent(rig)] == [[T2]]
    assert _status(rig, [refused, good]) == [("failed", "invalid_row"), ("sent", None)]


def test_a_refused_row_alone_sends_nothing_and_is_not_a_rejection(rig, ana):
    refused = queue_row(rig, ana, listened_at_s=T1, alone=True, extra={"mbid": "x"})

    rig.sender.run_pass()

    assert rig.fake.requests == []
    assert _status(rig, [refused]) == [("failed", "invalid_row")]
    assert rig.state.is_running
    assert rig.sender.run_pass() is False


# ── 9-R1-21: the 14-day limit holds when the request goes out ───────────────


def test_a_row_that_turns_14_days_old_while_the_sender_waits_is_not_sent(rig, ana):
    aging = queue_row(rig, ana, listened_at_s=NOW_S - MAX_AGE_S + 100)
    young = queue_row(rig, ana, listened_at_s=T1)
    rig.gate_clock.on_wait.append(lambda _timeout: rig.wall.advance_s(200))
    rig.fake.queue(ok_scrobbles(1, 0, [scrobble_result(T1)]))

    rig.sender.run_pass()

    assert [s.timestamps for s in sent(rig)] == [[T1]]
    assert _status(rig, [young]) == [("sent", None)]
    rig.gate_clock.on_wait.clear()
    rig.sender.run_pass()
    assert _status(rig, [aging]) == [("dropped", "too_old")]


def test_a_kept_outcome_is_written_when_the_sender_stops(rig, ana, monkeypatch):
    """Review of 9-fix-r1-be #1: a clean stop (shutdown, restart) right after a
    failed settle write must not leave the accepted rows pending for the next
    process to resend."""
    uuids = [queue_row(rig, ana, listened_at_s=t) for t in (T1, T2)]
    rig.fake.queue(ok_scrobbles(2, 0, [scrobble_result(T1), scrobble_result(T2)]))
    _lock_held(monkeypatch, rig, "settle_lastfm_rows", times=1)
    rig.sender.run_pass()
    assert _status(rig, uuids) == [("pending", None)] * 2

    rig.sender.request_stop()  # stopped before its loop runs a single pass
    rig.sender.start()
    assert rig.sender.join(timeout=10)

    assert _status(rig, uuids) == [("sent", None)] * 2
    assert len(rig.fake.requests) == 1
    rig.new_sender().run_pass()  # the next process finds nothing to resend
    assert len(rig.fake.requests) == 1


def test_an_answer_still_unrecorded_at_stop_is_logged_once_as_an_error(rig, ana, monkeypatch, caplog):
    """Live gate 9-L-02 (accepted residue 9-R2-01): when the stop-time replay cannot
    record a known answer either, the rows stay pending and the next process may send
    them again. That is accepted; it is said once at ERROR, with no user text."""
    caplog.set_level(logging.DEBUG)
    uuids = [queue_row(rig, ana, listened_at_s=t, artist="Secret Artist", track="Secret Track")
             for t in (T1, T2)]
    rig.fake.queue(ok_scrobbles(2, 0, [scrobble_result(T1), scrobble_result(T2)]))
    _lock_held(monkeypatch, rig, "settle_lastfm_rows", times=2)  # the pass, then the stop replay
    rig.sender.run_pass()

    rig.sender.request_stop()
    rig.sender.start()
    assert rig.sender.join(timeout=10)

    assert _status(rig, uuids) == [("pending", None)] * 2
    errors = [r for r in caplog.records if r.levelno >= logging.ERROR]
    assert [r.name for r in errors] == ["uvicorn.error"]
    assert "may be sent to Last.fm again" in errors[0].getMessage()
    assert "Secret" not in caplog.text
    assert all(r.exc_info is None for r in caplog.records)


def test_a_stop_with_every_answer_recorded_logs_no_error(rig, ana, monkeypatch, caplog):
    caplog.set_level(logging.DEBUG)
    uuids = [queue_row(rig, ana, listened_at_s=T1)]
    rig.fake.queue(ok_scrobbles(1, 0, [scrobble_result(T1)]))
    _lock_held(monkeypatch, rig, "settle_lastfm_rows", times=1)
    rig.sender.run_pass()

    rig.sender.request_stop()
    rig.sender.start()
    assert rig.sender.join(timeout=10)

    assert _status(rig, uuids) == [("sent", None)]
    assert [r for r in caplog.records if r.levelno >= logging.ERROR] == []


def test_a_held_answer_is_not_relabelled_too_old_by_the_prune(rig, ana, monkeypatch):
    """Audit DR-F903-BE-B-01: a row Last.fm accepted in the last seconds before its
    14-day mark, whose answer could not be written, keeps that answer: the prune
    leaves out the owner whose answer is held, so the retry still finds the row
    pending; other users' old rows are still pruned."""
    t_edge = NOW_S - MAX_AGE_S + 5
    uuids = [queue_row(rig, ana, listened_at_s=t_edge)]
    bea = connect_user(rig, "bea", opted_in=False)  # never served: only the prune touches her row
    stale = queue_row(rig, bea, listened_at_s=t_edge)
    rig.fake.queue(ok_scrobbles(1, 0, [scrobble_result(t_edge)]))
    _lock_held(monkeypatch, rig, "settle_lastfm_rows", times=2)  # the answer, then the first retry
    rig.sender.run_pass()
    rig.wall.advance_s(30)  # the row is now more than 14 days old

    rig.sender.run_pass()  # the retry fails again
    assert _status(rig, [stale]) == [("dropped", "too_old")]  # other users' rows are still pruned
    rig.sender.run_pass()  # the retry lands

    assert _status(rig, uuids) == [("sent", None)]
    assert len(rig.fake.requests) == 1
