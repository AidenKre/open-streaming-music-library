"""9D.2b (spec §7.3, §7.8 pass step 1, review 9-U09b): terminal rows are kept 30
days and then deleted; pending rows whose listen is more than 14 days old are
dropped as ``too_old``. Server-wide, every pass, before anything is sent."""

import pytest

from tests.lastfm_fake import ok_scrobbles, scrobble_result
from tests.lastfm_sender_rig import (
    DAY_MS,
    DAY_S,
    NOW_S,
    WALL_MS,
    connect_user,
    make_rig,
    queue_row,
    row,
    sent,
)


@pytest.fixture
def rig(tmp_path):
    return make_rig(tmp_path)


@pytest.mark.parametrize("status,code", [("sent", None), ("ignored", "1"), ("failed", "13"), ("dropped", "no_answer")])
def test_a_terminal_row_is_kept_30_days_then_deleted(rig, status, code):
    ana = connect_user(rig, "ana")
    kept = queue_row(rig, ana, status=status, code=code, done_at=WALL_MS - 30 * DAY_MS)
    gone = queue_row(rig, ana, status=status, code=code, done_at=WALL_MS - 30 * DAY_MS - 1)

    rig.sender.run_pass()

    assert row(rig, kept) is not None
    assert row(rig, gone) is None


def test_a_pending_row_is_never_deleted_by_the_30_day_rule(rig):
    ana = connect_user(rig, "ana", opted_in=False)
    pending = queue_row(rig, ana, listened_at_s=NOW_S - 13 * DAY_S, created_at=WALL_MS - 40 * DAY_MS)

    rig.sender.run_pass()

    assert row(rig, pending)["status"] == "pending"


def test_a_listen_more_than_14_days_old_is_dropped_too_old_and_not_sent(rig):
    ana = connect_user(rig, "ana")
    old = queue_row(rig, ana, listened_at_s=NOW_S - 14 * DAY_S - 1)
    edge = queue_row(rig, ana, listened_at_s=NOW_S - 14 * DAY_S)
    rig.fake.queue(ok_scrobbles(1, 0, [scrobble_result(NOW_S - 14 * DAY_S)]))

    rig.sender.run_pass()

    stored = row(rig, old)
    assert (stored["status"], stored["result_code"], stored["done_at"]) == ("dropped", "too_old", WALL_MS)
    assert [s.timestamps for s in sent(rig)] == [[NOW_S - 14 * DAY_S]]
    assert row(rig, edge)["status"] == "sent"


def test_the_retention_rules_cover_every_user_whether_served_or_not(rig):
    ana = connect_user(rig, "ana", needs_reconnect=True)
    ben = connect_user(rig, "ben", opted_in=False)
    old_ana = queue_row(rig, ana, listened_at_s=NOW_S - 20 * DAY_S)
    old_ben = queue_row(rig, ben, listened_at_s=NOW_S - 20 * DAY_S)
    done_ben = queue_row(rig, ben, status="sent", done_at=WALL_MS - 31 * DAY_MS)

    rig.sender.run_pass()

    assert row(rig, old_ana)["status"] == row(rig, old_ben)["status"] == "dropped"
    assert row(rig, done_ben) is None
    assert rig.fake.requests == []


def test_retention_runs_while_the_server_is_stopped(rig):
    ana = connect_user(rig, "ana")
    old = queue_row(rig, ana, listened_at_s=NOW_S - 15 * DAY_S)
    done = queue_row(rig, ana, status="sent", done_at=WALL_MS - 31 * DAY_MS)
    rig.state.stop("test")

    rig.sender.run_pass()

    assert row(rig, old)["status"] == "dropped"
    assert row(rig, done) is None


def test_a_too_old_row_is_itself_deleted_30_days_after_it_was_dropped(rig):
    ana = connect_user(rig, "ana", opted_in=False)
    old = queue_row(rig, ana, listened_at_s=NOW_S - 15 * DAY_S)
    rig.sender.run_pass()
    assert row(rig, old)["status"] == "dropped"

    rig.wall.advance_s(30 * DAY_S)
    rig.sender.run_pass()
    assert row(rig, old) is not None

    rig.wall.advance_s(1)
    rig.sender.run_pass()
    assert row(rig, old) is None
