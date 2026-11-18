"""9D.2b (spec §7.6, §7.9 kinds 3 and 4, review 9-U09b): error 9 sets that
user's ``needs_reconnect`` and nobody else's; a session key that will not
decrypt does the same without a request; errors 10 and 26 stop the server and
nothing more goes out. Rows stay pending in every case."""

import pytest

from app.services.lastfm_state import LastfmService
from tests.lastfm_fake import failed, ok_scrobbles, scrobble_result
from tests.lastfm_sender_rig import (
    NOW_S,
    bind,
    connect_user,
    connection,
    make_rig,
    queue_row,
    row,
    sent,
    session_key_for,
)


@pytest.fixture
def rig(tmp_path):
    return make_rig(tmp_path)


def _state(rig, owner):
    found = connection(rig, owner)
    return (found["opted_in"], found["needs_reconnect"])


def test_error_9_sets_needs_reconnect_for_that_user_only_and_keeps_the_rows(rig):
    ana = connect_user(rig, "ana")
    ben = connect_user(rig, "ben")
    ana_row = queue_row(rig, ana, listened_at_s=NOW_S - 200)
    ben_row = queue_row(rig, ben, listened_at_s=NOW_S - 100)
    rig.fake.queue(failed(9), ok_scrobbles(1, 0, [scrobble_result(NOW_S - 100)]))

    rig.sender.run_pass()

    assert _state(rig, ana) == (1, 1)  # opted_in kept: two separate facts
    assert _state(rig, ben) == (1, 0)
    assert (row(rig, ana_row)["status"], row(rig, ana_row)["attempts"]) == ("pending", 0)
    assert row(rig, ben_row)["status"] == "sent"


def test_a_user_who_needs_reconnecting_is_not_served_again_until_they_reconnect(rig):
    ana = connect_user(rig, "ana")
    pending = queue_row(rig, ana)
    rig.fake.queue(failed(9))
    rig.sender.run_pass()

    assert rig.sender.run_pass() is False
    assert len(rig.fake.requests) == 1

    # Reconnecting the same account repairs the connection and keeps the opt-in.
    from tests.lastfm_sender_rig import execute

    execute(rig, "UPDATE lastfm_connections SET needs_reconnect = 0 WHERE owner_id = ?", (ana,))
    rig.fake.queue(ok_scrobbles(1, 0, [scrobble_result(NOW_S - 3600)]))
    assert rig.sender.run_pass() is True
    assert row(rig, pending)["status"] == "sent"


def test_a_late_error_9_for_a_connection_replaced_meanwhile_leaves_the_new_one_alone(rig):
    ana = connect_user(rig, "ana")
    queue_row(rig, ana)

    def rebind_then_fail(request):
        bind(rig, ana, session_key=session_key_for("ana-new"))
        return failed(9)

    rig.fake.queue(rebind_then_fail)

    rig.sender.run_pass()

    assert _state(rig, ana) == (1, 0)


def test_a_session_key_that_will_not_decrypt_sets_needs_reconnect_and_sends_nothing(rig):
    ana = connect_user(rig, "ana", session_key_enc="gAAAAA-not-a-fernet-token-under-this-key")
    ben = connect_user(rig, "ben")
    pending = queue_row(rig, ana, listened_at_s=NOW_S - 200)
    queue_row(rig, ben, listened_at_s=NOW_S - 100)
    rig.fake.queue(ok_scrobbles(1, 0, [scrobble_result(NOW_S - 100)]))

    rig.sender.run_pass()

    assert [s.sk for s in sent(rig)] == [session_key_for("ben")]
    assert _state(rig, ana) == (1, 1)
    assert row(rig, pending)["status"] == "pending"


@pytest.mark.parametrize("code", [10, 26])
def test_errors_10_and_26_stop_the_server_and_nothing_more_goes_out(rig, code):
    ana = connect_user(rig, "ana")
    ben = connect_user(rig, "ben")
    ana_row = queue_row(rig, ana, listened_at_s=NOW_S - 200)
    ben_row = queue_row(rig, ben, listened_at_s=NOW_S - 100)
    rig.fake.queue(failed(code))

    rig.sender.run_pass()

    assert rig.state.service is LastfmService.STOPPED
    assert len(rig.fake.requests) == 1  # ben's request never went out
    assert (row(rig, ana_row)["status"], row(rig, ana_row)["attempts"]) == ("pending", 0)
    assert row(rig, ben_row)["status"] == "pending"
    assert _state(rig, ana) == (1, 0)

    rig.wall.advance_s(3600)
    assert rig.sender.run_pass() is False
    assert len(rig.fake.requests) == 1


def test_r1_a_late_error_9_for_the_old_key_after_a_same_account_repair_changes_nothing(rig):
    from app.services.lastfm_crypto import encrypt
    from tests import lastfm_secrets as planted
    from tests.lastfm_sender_rig import execute

    ana = connect_user(rig, "ana")
    queue_row(rig, ana)

    def repair_then_fail(request):
        # Complete for the same account: same connection_id, a new key, needs_reconnect cleared.
        execute(
            rig,
            "UPDATE lastfm_connections SET session_key_enc = ?, needs_reconnect = 0 WHERE owner_id = ?",
            (encrypt(planted.CREDENTIAL_KEY, session_key_for("ana-repaired")), ana),
        )
        return failed(9)

    rig.fake.queue(repair_then_fail)

    rig.sender.run_pass()

    assert _state(rig, ana) == (1, 0)
