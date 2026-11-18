"""9D.2b (spec §7.8, review 9-U09b and the §3 9D fixture): which users the sender
serves, which rows go into a request, and that it reads them only after the gate
let it through. Injected clocks only; the fake Last.fm never opens a socket."""

import pytest

from tests.lastfm_fake import ok_scrobbles, scrobble_result
from tests.lastfm_sender_rig import (
    NOW_S,
    SETTLE_S,
    WALL_MS,
    connect_user,
    execute,
    make_rig,
    queue_row,
    row,
    rows,
    sent,
    session_key_for,
)


def ok_all(timestamps):
    timestamps = list(timestamps)
    return ok_scrobbles(len(timestamps), 0, [scrobble_result(t) for t in timestamps])


@pytest.fixture
def rig(tmp_path):
    return make_rig(tmp_path)


def test_a_settled_users_rows_go_out_in_one_signed_request_and_are_marked_sent(rig):
    ana = connect_user(rig, "ana")
    uuids = [
        queue_row(rig, ana, listened_at_s=NOW_S - 300, artist="Björk", track="Jóga",
                  extra={"album": "Homogenic", "duration": 305}),
        queue_row(rig, ana, listened_at_s=NOW_S - 200),
        queue_row(rig, ana, listened_at_s=NOW_S - 100),
    ]
    rig.fake.queue(ok_all([NOW_S - 300, NOW_S - 200, NOW_S - 100]))

    assert rig.sender.run_pass() is True

    [request] = sent(rig)
    assert request.method == "track.scrobble"
    assert request.sk == session_key_for("ana")
    assert request.timestamps == [NOW_S - 300, NOW_S - 200, NOW_S - 100]
    # The frozen payload goes out unchanged, field for field.
    assert request.fields[0] == {"artist": "Björk", "track": "Jóga", "timestamp": str(NOW_S - 300),
                                 "album": "Homogenic", "duration": "305"}
    for event_uuid in uuids:
        stored = row(rig, event_uuid)
        assert (stored["status"], stored["result_code"], stored["done_at"]) == ("sent", None, WALL_MS)


def test_rows_go_out_oldest_listen_first(rig):
    ana = connect_user(rig, "ana")
    for listened in (NOW_S - 100, NOW_S - 300, NOW_S - 200):
        queue_row(rig, ana, listened_at_s=listened)
    rig.fake.queue(ok_all([NOW_S - 300, NOW_S - 200, NOW_S - 100]))

    rig.sender.run_pass()

    assert sent(rig)[0].timestamps == [NOW_S - 300, NOW_S - 200, NOW_S - 100]


def test_nothing_goes_out_before_the_oldest_row_has_waited_the_settle_delay(rig):
    ana = connect_user(rig, "ana")
    queue_row(rig, ana, created_at=WALL_MS - SETTLE_S * 1000 + 1)

    assert rig.sender.run_pass() is False
    assert rig.fake.requests == []


def test_the_settle_delay_runs_from_the_oldest_row_and_newer_rows_do_not_extend_it(rig):
    ana = connect_user(rig, "ana")
    oldest = queue_row(rig, ana, listened_at_s=NOW_S - 50, created_at=WALL_MS - 40_000)
    rig.sender.run_pass()
    assert rig.fake.requests == []

    rig.wall.advance_s(20)  # the oldest row has now waited exactly the settle delay
    newer = queue_row(rig, ana, listened_at_s=NOW_S - 10, created_at=rig.wall.ms)
    rig.fake.queue(ok_all([NOW_S - 50, NOW_S - 10]))

    assert rig.sender.run_pass() is True

    # Never held back to fill a batch, nor until the newest row has settled.
    assert sent(rig)[0].timestamps == [NOW_S - 50, NOW_S - 10]
    assert row(rig, oldest)["status"] == row(rig, newer)["status"] == "sent"


def test_a_single_settled_listen_is_sent_alone_without_waiting_for_more(rig):
    ana = connect_user(rig, "ana")
    queue_row(rig, ana, listened_at_s=NOW_S - 70)
    rig.fake.queue(ok_all([NOW_S - 70]))

    rig.sender.run_pass()

    assert [s.timestamps for s in sent(rig)] == [[NOW_S - 70]]


def test_a_batch_of_51_goes_out_as_the_50_oldest_then_the_last_one(rig):
    ana = connect_user(rig, "ana")
    listens = [NOW_S - 1000 + i for i in range(51)]
    for listened in reversed(listens):
        queue_row(rig, ana, listened_at_s=listened)
    rig.fake.queue(ok_all(listens[:50]), ok_all(listens[50:]))

    rig.sender.run_pass()
    assert [s.timestamps for s in sent(rig)] == [listens[:50]]
    assert sum(r["status"] == "pending" for r in rows(rig, ana)) == 1

    rig.sender.run_pass()
    assert [s.timestamps for s in sent(rig)] == [listens[:50], listens[50:]]
    assert {r["status"] for r in rows(rig, ana)} == {"sent"}


def test_each_user_gets_their_own_request_with_their_own_key_and_rows(rig):
    ana = connect_user(rig, "ana")
    ben = connect_user(rig, "ben")
    queue_row(rig, ana, listened_at_s=NOW_S - 400)
    queue_row(rig, ben, listened_at_s=NOW_S - 300)
    queue_row(rig, ana, listened_at_s=NOW_S - 200)
    queue_row(rig, ben, listened_at_s=NOW_S - 100)
    rig.fake.queue(ok_all([NOW_S - 400, NOW_S - 200]), ok_all([NOW_S - 300, NOW_S - 100]))

    rig.sender.run_pass()

    assert [(s.sk, s.timestamps) for s in sent(rig)] == [
        (session_key_for("ana"), [NOW_S - 400, NOW_S - 200]),
        (session_key_for("ben"), [NOW_S - 300, NOW_S - 100]),
    ]
    assert {r["status"] for r in rows(rig)} == {"sent"}


def test_the_least_recently_served_user_goes_first(rig):
    ana = connect_user(rig, "ana")
    ben = connect_user(rig, "ben")
    queue_row(rig, ben, listened_at_s=NOW_S - 500)
    rig.fake.queue(ok_all([NOW_S - 500]))
    rig.sender.run_pass()

    queue_row(rig, ben, listened_at_s=NOW_S - 400)
    queue_row(rig, ana, listened_at_s=NOW_S - 300)
    rig.fake.queue(ok_all([NOW_S - 300]), ok_all([NOW_S - 400]))
    rig.sender.run_pass()

    assert [s.sk for s in sent(rig)] == [session_key_for("ben"), session_key_for("ana"), session_key_for("ben")]


def test_each_due_user_is_served_once_per_pass(rig):
    ana = connect_user(rig, "ana")
    listens = [NOW_S - 1000 + i for i in range(60)]
    for listened in listens:
        queue_row(rig, ana, listened_at_s=listened)
    rig.fake.queue(ok_all(listens[:50]))

    rig.sender.run_pass()

    assert len(sent(rig)) == 1


@pytest.mark.parametrize(
    "setup",
    [
        "not_opted_in",
        "needs_reconnect",
        "disabled",
        "being_deleted",
        "no_connection",
    ],
)
def test_a_user_who_must_not_be_served_gets_no_request(rig, setup):
    ana = connect_user(
        rig, "ana", opted_in=setup != "not_opted_in", needs_reconnect=setup == "needs_reconnect"
    )
    pending = queue_row(rig, ana)
    if setup == "disabled":
        execute(rig, "UPDATE users SET disabled_at = ? WHERE id = ?", (WALL_MS - 1, ana))
    if setup == "being_deleted":
        execute(rig, "UPDATE users SET deleting_at = ? WHERE id = ?", (WALL_MS - 1, ana))
    if setup == "no_connection":
        execute(rig, "DELETE FROM lastfm_connections WHERE owner_id = ?", (ana,))

    assert rig.sender.run_pass() is False

    assert rig.fake.requests == []
    assert row(rig, pending)["status"] == "pending"


def test_another_users_ineligibility_does_not_hold_back_an_eligible_user(rig):
    ana = connect_user(rig, "ana", opted_in=False)
    ben = connect_user(rig, "ben")
    queue_row(rig, ana, listened_at_s=NOW_S - 200)
    queue_row(rig, ben, listened_at_s=NOW_S - 100)
    rig.fake.queue(ok_all([NOW_S - 100]))

    rig.sender.run_pass()

    assert [s.sk for s in sent(rig)] == [session_key_for("ben")]


def test_a_listen_whose_time_has_not_come_waits(rig):
    ana = connect_user(rig, "ana")
    arrived = queue_row(rig, ana, listened_at_s=NOW_S - 100)
    future = queue_row(rig, ana, listened_at_s=NOW_S + 600)
    rig.fake.queue(ok_all([NOW_S - 100]))

    rig.sender.run_pass()

    assert sent(rig)[0].timestamps == [NOW_S - 100]
    assert row(rig, arrived)["status"] == "sent"
    assert row(rig, future)["status"] == "pending"


def test_a_user_with_only_future_listens_is_not_due(rig):
    ana = connect_user(rig, "ana")
    queue_row(rig, ana, listened_at_s=NOW_S + 600)

    assert rig.sender.run_pass() is False
    assert rig.fake.requests == []


# --- the gate first, then the read ----------------------------------------------------------


def _during_the_gate_wait(rig, action):
    rig.gate_clock.on_wait.append(lambda timeout: action())


def test_a_disconnect_during_the_gate_wait_sends_nothing(rig):
    ana = connect_user(rig, "ana")
    queue_row(rig, ana)
    _during_the_gate_wait(rig, lambda: rig.db.disconnect_lastfm(owner_id=ana))

    rig.sender.run_pass()

    assert rig.gate_clock.waits, "the first request after startup waits one gap"
    assert rig.fake.requests == []
    assert rows(rig, ana) == []


def test_a_cli_disable_during_the_gate_wait_sends_nothing(rig):
    ana = connect_user(rig, "ana")
    pending = queue_row(rig, ana)
    _during_the_gate_wait(
        rig, lambda: execute(rig, "UPDATE users SET disabled_at = ? WHERE id = ?", (WALL_MS, ana))
    )

    rig.sender.run_pass()

    assert rig.fake.requests == []
    assert row(rig, pending)["status"] == "pending"


def test_a_reconnect_flag_set_during_the_gate_wait_sends_nothing(rig):
    ana = connect_user(rig, "ana")
    pending = queue_row(rig, ana)
    _during_the_gate_wait(
        rig, lambda: execute(rig, "UPDATE lastfm_connections SET needs_reconnect = 1 WHERE owner_id = ?", (ana,))
    )

    rig.sender.run_pass()

    assert rig.fake.requests == []
    assert row(rig, pending)["status"] == "pending"


def test_a_stop_during_the_gate_wait_sends_nothing(rig):
    ana = connect_user(rig, "ana")
    pending = queue_row(rig, ana)
    _during_the_gate_wait(rig, lambda: rig.state.stop("test"))

    rig.sender.run_pass()

    assert rig.fake.requests == []
    assert row(rig, pending)["status"] == "pending"


def test_rows_queued_during_the_gate_wait_are_read_after_it(rig):
    ana = connect_user(rig, "ana")
    queue_row(rig, ana, listened_at_s=NOW_S - 200)
    _during_the_gate_wait(rig, lambda: queue_row(rig, ana, listened_at_s=NOW_S - 100))
    rig.fake.queue(ok_all([NOW_S - 200, NOW_S - 100]))

    rig.sender.run_pass()

    assert sent(rig)[0].timestamps == [NOW_S - 200, NOW_S - 100]


def test_a_stopped_server_sends_nothing(rig):
    ana = connect_user(rig, "ana")
    pending = queue_row(rig, ana)
    rig.state.stop("test")

    assert rig.sender.run_pass() is False
    assert rig.fake.requests == []
    assert row(rig, pending)["status"] == "pending"


# --- restart ----------------------------------------------------------------------------------


class Crash(BaseException):
    """The process dies after the request left and before its answer is recorded."""


def test_a_crash_between_sending_and_recording_leaves_the_rows_pending_and_the_next_start_resends(rig):
    ana = connect_user(rig, "ana")
    uuids = [queue_row(rig, ana, listened_at_s=NOW_S - 200), queue_row(rig, ana, listened_at_s=NOW_S - 100)]
    rig.fake.queue(Crash())
    with pytest.raises(Crash):
        rig.sender.run_pass()
    assert {row(rig, u)["status"] for u in uuids} == {"pending"}

    restarted = rig.new_sender()
    rig.fake.queue(ok_all([NOW_S - 200, NOW_S - 100]))
    assert restarted.run_pass() is True

    assert [s.timestamps for s in sent(rig)] == [[NOW_S - 200, NOW_S - 100]] * 2
    assert {row(rig, u)["status"] for u in uuids} == {"sent"}


# --- review r1 ----------------------------------------------------------------------------------


def test_r1_one_users_failure_neither_ends_the_pass_nor_starves_the_others(rig, caplog, monkeypatch):
    import logging

    caplog.set_level(logging.DEBUG)
    ana = connect_user(rig, "ana")
    ben = connect_user(rig, "ben")
    queue_row(rig, ana, listened_at_s=NOW_S - 200)
    queue_row(rig, ben, listened_at_s=NOW_S - 100)
    rig.fake.queue(ok_all([NOW_S - 100]))
    # An unexpected failure while serving ana. (A row the client refuses is no
    # longer one: 9-R1-40 settles it failed/invalid_row, test_lastfm_sender_settle.py.)
    real_read = rig.db.read_lastfm_batch

    def read(**kwargs):
        if kwargs["owner_id"] == ana:
            raise RuntimeError("detail-that-must-not-be-logged")
        return real_read(**kwargs)

    monkeypatch.setattr(rig.db, "read_lastfm_batch", read)

    rig.sender.run_pass()

    assert [s.sk for s in sent(rig)] == [session_key_for("ben")]
    errors = [r for r in caplog.records if r.levelno >= logging.ERROR]
    assert len(errors) == 1 and "RuntimeError" in errors[0].getMessage()
    assert "detail-that-must-not-be-logged" not in caplog.text
    assert all(r.exc_info is None for r in caplog.records)

    queue_row(rig, ben, listened_at_s=NOW_S - 50)
    rig.fake.queue(ok_all([NOW_S - 50]))
    rig.sender.run_pass()
    assert [s.sk for s in sent(rig)] == [session_key_for("ben")] * 2


def test_g3_an_alone_row_is_read_only_once_its_listen_time_has_arrived(rig):
    ana = connect_user(rig, "ana")
    threshold = NOW_S - 100
    younger = queue_row(rig, ana, listened_at_s=threshold + 1, alone=True)

    def read(listened_by_s):
        return rig.db.read_lastfm_batch(
            owner_id=ana, listened_by_s=listened_by_s, listened_since_s=NOW_S - 10_000, limit=50
        )

    assert read(threshold) is None  # the only row is younger than the threshold
    at_threshold = queue_row(rig, ana, listened_at_s=threshold, alone=True)
    batch = read(threshold)
    assert [u for u, _ in batch["rows"]] == [at_threshold]  # at the threshold: picked, younger one not
    past = read(threshold + 1)
    assert [u for u, _ in past["rows"]] == [at_threshold]  # alone rows go one at a time, oldest first
    execute(rig, "DELETE FROM scrobble_outbox WHERE event_uuid = ?", (at_threshold,))
    assert [u for u, _ in read(threshold + 1)["rows"]] == [younger]  # now at the threshold: picked
