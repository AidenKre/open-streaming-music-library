"""9D.2b (spec §7.9 kind 5, review 9-U09b): a rejected request of several rows
marks them ``alone`` and each is sent once more on its own; a row rejected on
its own is ``failed`` and never resent; ten rejected ``track.scrobble`` requests
in a row stop the server. Only a rejected scrobble adds to that count and only
an "ok" scrobble resets it."""

import pytest

from app.library import Library
from app.services.lastfm_accounts import LastfmAccounts
from app.services.user_cooldown import UserCooldown
from app.services.lastfm_errors import LastfmError
from app.services.lastfm_state import LastfmService
from tests.lastfm_fake import failed, ok_scrobbles, ok_token, scrobble_result
from tests.lastfm_sender_rig import (
    NOW_S,
    WALL_MS,
    connect_user,
    make_rig,
    queue_row,
    row,
    rows,
    sent,
    session_key_for,
)

T1, T2, T3 = NOW_S - 300, NOW_S - 200, NOW_S - 100


def ok_one(t):
    return ok_scrobbles(1, 0, [scrobble_result(t)])


@pytest.fixture
def rig(tmp_path):
    return make_rig(tmp_path)


@pytest.fixture
def ana(rig):
    return connect_user(rig, "ana")


def test_a_rejected_batch_is_resent_one_row_per_request(rig, ana):
    uuids = [queue_row(rig, ana, listened_at_s=t) for t in (T1, T2, T3)]
    rig.fake.queue(failed(13))

    rig.sender.run_pass()

    assert [(row(rig, u)["status"], row(rig, u)["alone"], row(rig, u)["attempts"]) for u in uuids] == [
        ("pending", 1, 0)
    ] * 3

    rig.fake.queue(ok_one(T1), ok_one(T2), ok_one(T3))
    for _ in range(3):
        rig.sender.run_pass()

    assert [s.timestamps for s in sent(rig)] == [[T1, T2, T3], [T1], [T2], [T3]]
    assert {row(rig, u)["status"] for u in uuids} == {"sent"}


def test_a_row_rejected_on_its_own_is_failed_with_the_code_and_never_resent(rig, ana):
    alone = queue_row(rig, ana, listened_at_s=T1, alone=True)
    rig.fake.queue(failed(13))

    rig.sender.run_pass()

    stored = row(rig, alone)
    assert (stored["status"], stored["result_code"], stored["done_at"]) == ("failed", "13", WALL_MS)
    assert rig.sender.run_pass() is False
    assert len(rig.fake.requests) == 1


def test_a_single_row_request_that_is_rejected_is_already_a_request_of_its_own(rig, ana):
    only = queue_row(rig, ana, listened_at_s=T1)
    rig.fake.queue(failed(6))

    rig.sender.run_pass()

    assert (row(rig, only)["status"], row(rig, only)["result_code"]) == ("failed", "6")
    assert len(rig.fake.requests) == 1


def test_a_batch_never_contains_an_alone_row(rig, ana):
    alone = queue_row(rig, ana, listened_at_s=T2, alone=True)
    queue_row(rig, ana, listened_at_s=T1)
    queue_row(rig, ana, listened_at_s=T3)
    rig.fake.queue(ok_one(T2), ok_scrobbles(2, 0, [scrobble_result(T1), scrobble_result(T3)]))

    rig.sender.run_pass()
    rig.sender.run_pass()

    assert [s.timestamps for s in sent(rig)] == [[T2], [T1, T3]]
    assert row(rig, alone)["status"] == "sent"


def test_an_alone_row_answered_try_later_stays_alone_with_one_more_attempt(rig, ana):
    alone = queue_row(rig, ana, listened_at_s=T1, alone=True, attempts=2)
    rig.fake.queue(failed(11))

    rig.sender.run_pass()

    assert (row(rig, alone)["status"], row(rig, alone)["alone"], row(rig, alone)["attempts"]) == ("pending", 1, 3)


def test_a_late_rejection_after_a_disconnect_changes_nothing(rig, ana):
    queue_row(rig, ana, listened_at_s=T1)
    queue_row(rig, ana, listened_at_s=T2)

    def disconnect_then_reject(request):
        rig.db.disconnect_lastfm(owner_id=ana)
        return failed(13)

    rig.fake.queue(disconnect_then_reject)

    rig.sender.run_pass()

    assert rows(rig, ana) == []


# --- ten rejected scrobble requests in a row ---------------------------------------------------


def _alone_rows(rig, owner, n, start=NOW_S - 1000):
    return [queue_row(rig, owner, listened_at_s=start + i, alone=True) for i in range(n)]


def _rejected_passes(rig, n):
    for _ in range(n):
        rig.fake.queue(failed(13))
        rig.sender.run_pass()


def test_ten_rejected_scrobble_requests_in_a_row_stop_the_server(rig, ana):
    uuids = _alone_rows(rig, ana, 11)
    _rejected_passes(rig, 9)
    assert rig.state.service is LastfmService.RUNNING

    _rejected_passes(rig, 1)

    assert rig.state.service is LastfmService.STOPPED
    assert len(rig.fake.requests) == 10
    assert row(rig, uuids[10])["status"] == "pending"
    assert rig.sender.run_pass() is False
    assert len(rig.fake.requests) == 10


def test_the_stop_is_decided_before_the_gate_lets_anything_else_out(rig, ana):
    _alone_rows(rig, ana, 10)
    busy_at_stop = []
    real_stop = rig.state.stop

    def stop(cause):
        busy_at_stop.append(rig.gate._busy)
        return real_stop(cause)

    rig.state.stop = stop
    _rejected_passes(rig, 10)

    assert busy_at_stop == [True]


def test_an_ok_scrobble_resets_the_count(rig, ana):
    _alone_rows(rig, ana, 20)
    _rejected_passes(rig, 9)
    rig.fake.queue(ok_one(NOW_S - 1000 + 9))
    rig.sender.run_pass()
    _rejected_passes(rig, 9)

    assert rig.state.service is LastfmService.RUNNING
    _rejected_passes(rig, 1)
    assert rig.state.service is LastfmService.STOPPED


def test_a_try_later_answer_neither_adds_to_nor_resets_the_count(rig, ana):
    _alone_rows(rig, ana, 12)
    _rejected_passes(rig, 9)
    rig.fake.queue(failed(11))
    rig.sender.run_pass()
    assert rig.state.service is LastfmService.RUNNING

    _rejected_passes(rig, 1)
    assert rig.state.service is LastfmService.STOPPED


def test_a_reconnect_answer_neither_adds_to_nor_resets_the_count(rig, ana):
    _alone_rows(rig, ana, 11)
    _rejected_passes(rig, 9)
    ben = connect_user(rig, "ben")
    queue_row(rig, ben, listened_at_s=NOW_S - 1)
    rig.fake.queue(failed(9), failed(13))  # ben has never been served: he goes first

    rig.sender.run_pass()

    assert [s.sk for s in sent(rig)[-2:]] == [session_key_for("ben"), session_key_for("ana")]
    assert rig.state.service is LastfmService.STOPPED


def _accounts(rig):
    return LastfmAccounts(
        rig.state, client=rig.client, gate=rig.gate,
        cooldown=UserCooldown(clock=rig.gate_clock), now_ms=rig.wall,
        notices=rig.sender.notices,
    )


def test_a_connect_answer_neither_resets_nor_adds_to_the_count(rig, ana):
    _alone_rows(rig, ana, 11)
    accounts = _accounts(rig)
    _rejected_passes(rig, 9)

    rig.fake.queue(ok_token("plantedApprovalToken-0123456789z"))
    accounts.connect(Library(rig.db, ana))  # an ok answer to another kind of call
    rig.gate_clock.advance(60)
    rig.fake.queue(failed(13))
    with pytest.raises(LastfmError):
        accounts.connect(Library(rig.db, ana))  # a rejected answer to another kind of call
    assert rig.state.service is LastfmService.RUNNING

    _rejected_passes(rig, 1)
    assert rig.state.service is LastfmService.STOPPED


@pytest.mark.parametrize("code", [1000, 99999999999999999999, -5])
def test_r1s_an_implausible_rejection_code_is_stored_as_unknown(rig, ana, code):
    alone = queue_row(rig, ana, listened_at_s=T1, alone=True)
    rig.fake.queue(failed(code))

    rig.sender.run_pass()

    assert (row(rig, alone)["status"], row(rig, alone)["result_code"]) == ("failed", "unknown")


def test_r1s_a_plausible_rejection_code_is_kept(rig, ana):
    alone = queue_row(rig, ana, listened_at_s=T1, alone=True)
    rig.fake.queue(failed(999))

    rig.sender.run_pass()

    assert row(rig, alone)["result_code"] == "999"
