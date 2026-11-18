"""9D.2b (spec §7.9 kind 1, review 9-U09b): an "ok" reply settles every row of
the request, matched by timestamp; nothing is resent after an "ok"; a late
answer only touches rows that still exist and are still pending."""

import json

import pytest

from tests.lastfm_fake import ok_scrobbles, scrobble_result, xml_reply
from tests.lastfm_sender_rig import (
    NOW_S,
    WALL_MS,
    bind,
    connect_user,
    make_rig,
    queue_row,
    row,
    rows,
    sent,
)

T1, T2, T3 = NOW_S - 300, NOW_S - 200, NOW_S - 100


@pytest.fixture
def rig(tmp_path):
    return make_rig(tmp_path)


@pytest.fixture
def ana(rig):
    return connect_user(rig, "ana")


def _three(rig, owner):
    return [queue_row(rig, owner, listened_at_s=t) for t in (T1, T2, T3)]


def _outcomes(rig, uuids):
    return [(row(rig, u)["status"], row(rig, u)["result_code"]) for u in uuids]


def test_ignored_rows_keep_lastfms_code_and_the_others_are_sent(rig, ana):
    uuids = _three(rig, ana)
    rig.fake.queue(ok_scrobbles(2, 1, [scrobble_result(T1), scrobble_result(T2, 1), scrobble_result(T3)]))

    rig.sender.run_pass()

    assert _outcomes(rig, uuids) == [("sent", None), ("ignored", "1"), ("sent", None)]
    assert {row(rig, u)["done_at"] for u in uuids} == {WALL_MS}


def test_a_reordered_reply_is_matched_by_timestamp(rig, ana):
    uuids = _three(rig, ana)
    rig.fake.queue(ok_scrobbles(2, 1, [scrobble_result(T3, 5), scrobble_result(T1), scrobble_result(T2)]))

    rig.sender.run_pass()

    assert _outcomes(rig, uuids) == [("sent", None), ("sent", None), ("ignored", "5")]


def test_rows_with_the_same_timestamp_are_matched_in_the_order_sent(rig, ana):
    first = queue_row(rig, ana, listened_at_s=T1, track="First")
    second = queue_row(rig, ana, listened_at_s=T1, track="Second")
    rig.fake.queue(ok_scrobbles(1, 1, [scrobble_result(T1), scrobble_result(T1, 3)]))

    rig.sender.run_pass()

    order = [f["track"] for f in sent(rig)[0].fields]
    by_track = {"First": first, "Second": second}
    assert _outcomes(rig, [by_track[order[0]], by_track[order[1]]]) == [("sent", None), ("ignored", "3")]


def test_a_row_the_reply_does_not_mention_is_dropped_and_never_resent(rig, ana):
    uuids = _three(rig, ana)
    rig.fake.queue(ok_scrobbles(2, 0, [scrobble_result(T1), scrobble_result(T3)]))

    rig.sender.run_pass()
    assert _outcomes(rig, uuids) == [("sent", None), ("dropped", "no_answer"), ("sent", None)]

    rig.wall.advance_s(3600)
    assert rig.sender.run_pass() is False
    assert len(rig.fake.requests) == 1


def test_an_unknown_ignored_code_is_kept_as_it_came(rig, ana):
    [only] = [queue_row(rig, ana, listened_at_s=T1)]
    rig.fake.queue(ok_scrobbles(0, 1, [scrobble_result(T1, 99)]))

    rig.sender.run_pass()

    assert _outcomes(rig, [only]) == [("ignored", "99")]


def test_an_unreadable_ignored_code_is_ignored_with_code_unknown(rig, ana):
    only = queue_row(rig, ana, listened_at_s=T1)
    rig.fake.queue(ok_scrobbles(0, 1, [scrobble_result(T1, "x")]))

    rig.sender.run_pass()

    assert _outcomes(rig, [only]) == [("ignored", "unknown")]


def test_corrected_names_in_the_reply_are_never_stored(rig, ana):
    only = queue_row(rig, ana, listened_at_s=T1, artist="Artist", track="Original")
    before = row(rig, only)["payload"]
    corrected = (
        '<lfm status="ok"><scrobbles accepted="1" ignored="0"><scrobble>'
        '<track corrected="1">Corrected</track><artist corrected="1">Other</artist>'
        f'<timestamp>{T1}</timestamp><ignoredMessage code="0"></ignoredMessage>'
        "</scrobble></scrobbles></lfm>"
    )
    rig.fake.queue(xml_reply(corrected))

    rig.sender.run_pass()

    assert row(rig, only)["status"] == "sent"
    assert row(rig, only)["payload"] == before
    assert json.loads(before)["track"] == "Original"


def test_a_late_answer_after_a_disconnect_changes_nothing(rig, ana):
    _three(rig, ana)

    def disconnect_then_answer(request):
        rig.db.disconnect_lastfm(owner_id=ana)
        return ok_scrobbles(3, 0, [scrobble_result(t) for t in (T1, T2, T3)])

    rig.fake.queue(disconnect_then_answer)

    rig.sender.run_pass()

    assert len(rig.fake.requests) == 1
    assert rows(rig, ana) == []


def test_a_late_answer_after_a_disconnect_and_reconnect_leaves_the_new_rows_pending(rig, ana):
    _three(rig, ana)
    fresh: list[str] = []

    def reconnect_then_answer(request):
        rig.db.disconnect_lastfm(owner_id=ana)
        bind(rig, ana)
        fresh.append(queue_row(rig, ana, listened_at_s=T2))
        return ok_scrobbles(3, 0, [scrobble_result(t) for t in (T1, T2, T3)])

    rig.fake.queue(reconnect_then_answer)

    rig.sender.run_pass()

    assert [(r["event_uuid"], r["status"], r["done_at"]) for r in rows(rig, ana)] == [(fresh[0], "pending", None)]


def test_an_answer_only_settles_rows_still_pending(rig, ana):
    uuids = _three(rig, ana)

    def settle_one_meanwhile(request):
        from tests.lastfm_sender_rig import execute

        execute(
            rig,
            "UPDATE scrobble_outbox SET status = 'dropped', result_code = 'too_old', done_at = 1"
            " WHERE event_uuid = ?",
            (uuids[0],),
        )
        return ok_scrobbles(2, 1, [scrobble_result(T1, 1), scrobble_result(T2), scrobble_result(T3)])

    rig.fake.queue(settle_one_meanwhile)

    rig.sender.run_pass()

    assert _outcomes(rig, uuids) == [("dropped", "too_old"), ("sent", None), ("sent", None)]
    assert row(rig, uuids[0])["done_at"] == 1


@pytest.mark.parametrize("code", [1000, 123456789012345678901234567890, -1])
def test_r1s_an_implausible_ignored_code_is_stored_as_unknown(rig, ana, code):
    only = queue_row(rig, ana, listened_at_s=T1)
    rig.fake.queue(ok_scrobbles(0, 1, [scrobble_result(T1, code)]))

    rig.sender.run_pass()

    assert _outcomes(rig, [only]) == [("ignored", "unknown")]
