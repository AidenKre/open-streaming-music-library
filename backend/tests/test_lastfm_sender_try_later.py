"""9D.2b (spec §7.9 kind 2, review 9-U09b): a try-later answer keeps the rows
pending with one more attempt (a failure to connect at all costs none), the
tenth attempt drops a row as ``too_many_tries``, and the gate's wait holds the
next request: 1 minute, then 5, reset by an answer that is not try-later."""

import httpx
import pytest

from tests.lastfm_fake import failed, ok_scrobbles, scrobble_result, xml_reply
from tests.lastfm_sender_rig import (
    GAP_S,
    NOW_S,
    WALL_MS,
    connect_user,
    make_rig,
    queue_row,
    row,
    rows,
)

T1, T2 = NOW_S - 200, NOW_S - 100

TRY_LATER = {
    "error 8": lambda: failed(8),
    "error 11": lambda: failed(11),
    "error 16": lambda: failed(16),
    "error 29": lambda: failed(29),
    "HTTP 502": lambda: xml_reply("<html>bad gateway</html>", status=502),
    "HTTP 429": lambda: xml_reply("", status=429),
    "unreadable 200": lambda: xml_reply("not xml at all <"),
    "read timeout": lambda: httpx.ReadTimeout("timed out"),
}


@pytest.fixture
def rig(tmp_path):
    return make_rig(tmp_path)


@pytest.fixture
def ana(rig):
    return connect_user(rig, "ana")


@pytest.mark.parametrize("answer", TRY_LATER.values(), ids=TRY_LATER.keys())
def test_a_try_later_answer_keeps_the_rows_pending_with_one_more_attempt(rig, ana, answer):
    uuids = [queue_row(rig, ana, listened_at_s=T1), queue_row(rig, ana, listened_at_s=T2, attempts=3)]
    rig.fake.queue(answer())

    assert rig.sender.run_pass() is True

    assert [(row(rig, u)["status"], row(rig, u)["attempts"], row(rig, u)["done_at"]) for u in uuids] == [
        ("pending", 1, None),
        ("pending", 4, None),
    ]


@pytest.mark.parametrize("error", [httpx.ConnectError("refused"), httpx.ConnectTimeout("no route")], ids=str)
def test_a_failure_to_connect_at_all_costs_no_attempt(rig, ana, error):
    pending = queue_row(rig, ana, attempts=9)
    rig.fake.queue(error)

    rig.sender.run_pass()

    assert (row(rig, pending)["status"], row(rig, pending)["attempts"]) == ("pending", 9)


def test_the_tenth_try_drops_the_row_as_too_many_tries(rig, ana):
    ninth = queue_row(rig, ana, listened_at_s=T1, attempts=8)
    tenth = queue_row(rig, ana, listened_at_s=T2, attempts=9)
    rig.fake.queue(failed(11))

    rig.sender.run_pass()

    assert (row(rig, ninth)["status"], row(rig, ninth)["attempts"]) == ("pending", 9)
    dropped = row(rig, tenth)
    assert (dropped["status"], dropped["result_code"], dropped["attempts"], dropped["done_at"]) == (
        "dropped", "too_many_tries", 10, WALL_MS,
    )


def test_ten_try_later_answers_in_a_row_drop_a_row_and_nothing_more_is_sent_for_it(rig, ana):
    pending = queue_row(rig, ana)
    for _ in range(10):
        rig.fake.queue(failed(16))
        rig.sender.run_pass()

    assert len(rig.fake.requests) == 10
    assert (row(rig, pending)["status"], row(rig, pending)["result_code"]) == ("dropped", "too_many_tries")
    assert rig.sender.run_pass() is False
    assert len(rig.fake.requests) == 10


def test_the_gate_holds_the_next_request_one_minute_then_five_and_an_ok_resets_it(rig, ana):
    queue_row(rig, ana, listened_at_s=T1)
    rig.fake.queue(failed(11), xml_reply("", status=503), ok_scrobbles(1, 0, [scrobble_result(T1)]))
    for _ in range(3):
        rig.sender.run_pass()
    queue_row(rig, ana, listened_at_s=T2)
    rig.fake.queue(ok_scrobbles(1, 0, [scrobble_result(T2)]))
    rig.sender.run_pass()

    assert rig.gate_clock.waits == [GAP_S, 60, 300, GAP_S]
    assert {r["status"] for r in rows(rig, ana)} == {"sent"}


def test_a_late_try_later_answer_after_a_disconnect_changes_nothing(rig, ana):
    queue_row(rig, ana)

    def disconnect_then_fail(request):
        rig.db.disconnect_lastfm(owner_id=ana)
        return failed(11)

    rig.fake.queue(disconnect_then_fail)

    rig.sender.run_pass()

    assert rows(rig, ana) == []
