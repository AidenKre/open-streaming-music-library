"""9D.2c (spec §7.10, §7.9, §7.8 gate; review 9-U10): a Now Playing notice is
never retried, and of Last.fm's answers only error 9 (that user's
``needs_reconnect``), errors 10/26 (``stopped``) and a try-later answer (the
gate's wait) have an effect. It shares the gate with scrobbles: the gap holds
between the two kinds, and neither starves the other. Injected clocks only."""

import httpx
import pytest

from app.services.lastfm_now_playing import NOTICE_MAX_WAIT_S
from tests.lastfm_fake import failed, ok_now_playing, ok_scrobbles, scrobble_result, xml_reply
from tests.lastfm_sender_rig import (
    GAP_S,
    NOW_S,
    bind,
    connect_user,
    connection,
    make_rig,
    queue_row,
    row,
    session_key_for,
)
from tests.test_lastfm_now_playing import add_track, method, sk


@pytest.fixture
def rig(tmp_path):
    return make_rig(tmp_path)


def ok_one(timestamp):
    return ok_scrobbles(1, 0, [scrobble_result(timestamp)])


def methods(rig) -> list[str]:
    return [method(rig, i) for i in range(len(rig.fake.requests))]


def timed(rig, reply):
    """A reply that records the gate clock's time when the request went out."""
    times = []

    def answer(request):
        times.append(rig.gate_clock.now)
        return reply() if callable(reply) else reply

    return answer, times


# --- never retried -----------------------------------------------------------------------


@pytest.mark.parametrize(
    "reply",
    [
        lambda: xml_reply("busy", status=503),
        lambda: httpx.ConnectError("no route"),
        lambda: failed(16),
        lambda: failed(6),
        lambda: failed(9),
        lambda: ok_now_playing(),
    ],
    ids=["http-503", "network", "error-16", "rejected-6", "error-9", "ok"],
)
def test_a_notice_is_sent_once_whatever_the_answer(rig, tmp_path, reply):
    ana = connect_user(rig, "ana")
    rig.sender.notices.put(ana, add_track(rig, tmp_path, ana))
    rig.fake.queue(reply())

    rig.sender.run_pass()
    for _ in range(3):
        rig.gate_clock.advance(4000)  # past any try-later wait
        rig.sender.run_pass()

    assert len(rig.fake.requests) == 1
    assert len(rig.sender.notices) == 0


# --- the three effects ----------------------------------------------------------------------


def test_error_9_sets_only_that_users_needs_reconnect_and_keeps_the_opt_in(rig, tmp_path):
    ana = connect_user(rig, "ana")
    ben = connect_user(rig, "ben")
    rig.sender.notices.put(ana, add_track(rig, tmp_path, ana))
    rig.fake.queue(failed(9))

    rig.sender.run_pass()

    assert (connection(rig, ana)["needs_reconnect"], connection(rig, ana)["opted_in"]) == (1, 1)
    assert connection(rig, ben)["needs_reconnect"] == 0


def test_error_9_does_not_touch_a_connection_bound_while_the_request_was_out(rig, tmp_path):
    ana = connect_user(rig, "ana")
    rig.sender.notices.put(ana, add_track(rig, tmp_path, ana))

    def rebound_meanwhile(request):
        bind(rig, ana, session_key=session_key_for("ana-again"))
        return failed(9)

    rig.fake.queue(rebound_meanwhile)

    rig.sender.run_pass()

    assert connection(rig, ana)["needs_reconnect"] == 0


def test_a_key_that_will_not_decrypt_sets_needs_reconnect_and_sends_nothing(rig, tmp_path):
    ana = connect_user(rig, "ana", session_key_enc="not-a-fernet-token")
    rig.sender.notices.put(ana, add_track(rig, tmp_path, ana))

    rig.sender.run_pass()

    assert rig.fake.requests == []
    assert (connection(rig, ana)["needs_reconnect"], connection(rig, ana)["opted_in"]) == (1, 1)


@pytest.mark.parametrize("code", [10, 26])
def test_errors_10_and_26_stop_the_server_and_nothing_more_goes_out(rig, tmp_path, code):
    ana = connect_user(rig, "ana")
    pending = queue_row(rig, ana, listened_at_s=NOW_S - 100)
    rig.sender.notices.put(ana, add_track(rig, tmp_path, ana))
    rig.fake.queue(failed(code))

    rig.sender.run_pass()

    assert not rig.state.is_running
    assert methods(rig) == ["track.updateNowPlaying"]
    assert row(rig, pending)["status"] == "pending"


def test_a_try_later_answer_makes_the_next_scrobble_wait_the_gates_hold(rig, tmp_path):
    ana = connect_user(rig, "ana")
    queue_row(rig, ana, listened_at_s=NOW_S - 100)
    rig.sender.notices.put(ana, add_track(rig, tmp_path, ana))
    notice_reply, notice_times = timed(rig, lambda: xml_reply("busy", status=503))
    scrobble_reply, scrobble_times = timed(rig, lambda: ok_one(NOW_S - 100))
    rig.fake.queue(notice_reply, scrobble_reply)

    rig.sender.run_pass()

    assert methods(rig) == ["track.updateNowPlaying", "track.scrobble"]
    assert scrobble_times[0] - notice_times[0] >= 60  # the first try-later wait


@pytest.mark.parametrize("reply", [lambda: failed(6), lambda: ok_now_playing()], ids=["rejected", "ok"])
def test_now_playing_answers_never_touch_the_ten_rejections_count(rig, tmp_path, reply):
    ana = connect_user(rig, "ana")
    track = add_track(rig, tmp_path, ana)
    # Nine rejected track.scrobble requests in a row.
    for i in range(9):
        queue_row(rig, ana, listened_at_s=NOW_S - 1000 + i)
        rig.fake.queue(failed(13))
        rig.sender.run_pass()
        rig.gate_clock.advance(GAP_S)
    assert rig.state.is_running
    # Ten Now Playing answers of this kind: neither a stop nor a reset.
    for _ in range(10):
        rig.sender.notices.put(ana, track)
        rig.fake.queue(reply())
        rig.sender.run_pass()
        rig.gate_clock.advance(GAP_S)
    assert rig.state.is_running
    # The tenth rejected track.scrobble stops the server.
    queue_row(rig, ana, listened_at_s=NOW_S - 500)
    rig.fake.queue(failed(13))
    rig.sender.run_pass()

    assert not rig.state.is_running


def test_a_notice_is_not_a_serve_and_does_not_change_who_is_served_first(rig, tmp_path):
    ana = connect_user(rig, "ana")
    ben = connect_user(rig, "ben")
    queue_row(rig, ana, listened_at_s=NOW_S - 300)
    rig.sender.notices.put(ben, add_track(rig, tmp_path, ben))
    rig.fake.queue(ok_now_playing(), ok_one(NOW_S - 300))
    rig.sender.run_pass()  # ana served once; ben only had a notice

    queue_row(rig, ana, listened_at_s=NOW_S - 200)
    queue_row(rig, ben, listened_at_s=NOW_S - 100)
    rig.fake.queue(ok_one(NOW_S - 100), ok_one(NOW_S - 200))
    rig.gate_clock.advance(GAP_S)
    rig.sender.run_pass()

    assert [sk(rig, i) for i in (2, 3)] == [session_key_for("ben"), session_key_for("ana")]


# --- sharing the gate with scrobbles ----------------------------------------------------------


def test_a_notice_and_a_scrobble_batch_go_out_at_least_one_gap_apart(rig, tmp_path):
    ana = connect_user(rig, "ana")
    queue_row(rig, ana, listened_at_s=NOW_S - 100)
    rig.sender.notices.put(ana, add_track(rig, tmp_path, ana))
    notice_reply, notice_times = timed(rig, ok_now_playing)
    scrobble_reply, scrobble_times = timed(rig, lambda: ok_one(NOW_S - 100))
    rig.fake.queue(notice_reply, scrobble_reply)

    assert rig.sender.run_pass() is True

    assert methods(rig) == ["track.updateNowPlaying", "track.scrobble"]
    assert scrobble_times[0] - notice_times[0] >= GAP_S


def test_a_scrobble_and_a_later_notice_go_out_at_least_one_gap_apart(rig, tmp_path):
    ana = connect_user(rig, "ana")
    queue_row(rig, ana, listened_at_s=NOW_S - 100)
    scrobble_reply, scrobble_times = timed(rig, lambda: ok_one(NOW_S - 100))
    notice_reply, notice_times = timed(rig, ok_now_playing)
    rig.fake.queue(scrobble_reply, notice_reply)
    rig.sender.run_pass()

    rig.sender.notices.put(ana, add_track(rig, tmp_path, ana))
    rig.sender.run_pass()

    assert methods(rig) == ["track.scrobble", "track.updateNowPlaying"]
    assert notice_times[0] - scrobble_times[0] >= GAP_S


def _answer(request):
    """ok for either kind: a scrobble's one row by its timestamp, or a Now Playing."""
    body = dict(httpx.QueryParams(request.content.decode()))
    if body["method"] == "track.scrobble":
        return ok_one(int(body["timestamp[0]"]))
    return ok_now_playing()


def _three_due_users_and_a_listener(rig, tmp_path):
    users = [connect_user(rig, name) for name in ("ana", "ben", "cid")]
    for i, owner in enumerate(users):
        queue_row(rig, owner, listened_at_s=NOW_S - 300 + i)
    dee = connect_user(rig, "dee")
    return users, dee, add_track(rig, tmp_path, dee)


def test_notices_arriving_while_users_are_served_go_out_between_scrobble_requests(rig, tmp_path):
    users, dee, track = _three_due_users_and_a_listener(rig, tmp_path)
    rig.sender.notices.put(dee, track)

    def new_notice_while_a_scrobble_waits(timeout):
        if len(rig.sender.notices) == 0:
            rig.sender.notices.put(dee, track)

    rig.gate_clock.on_wait.append(new_notice_while_a_scrobble_waits)
    rig.fake.queue(*[_answer] * 10)

    rig.sender.run_pass()

    kinds = ["S" if m == "track.scrobble" else "N" for m in methods(rig)]
    assert kinds.count("S") == 3  # every due user served in this pass
    assert "".join(kinds).startswith("NSNSNS")  # a notice between scrobble requests
    assert all(w is not None and w <= NOTICE_MAX_WAIT_S for w in rig.gate_clock.waits)


def test_a_user_sending_notices_all_the_time_cannot_hold_back_scrobbles(rig, tmp_path):
    users, dee, track = _three_due_users_and_a_listener(rig, tmp_path)
    rig.sender.notices.put(dee, track)
    rig.gate_clock.on_wait.append(lambda timeout: rig.sender.notices.put(dee, track))
    rig.fake.queue(*[_answer] * 10)

    rig.sender.run_pass()

    assert methods(rig).count("track.scrobble") == 3
