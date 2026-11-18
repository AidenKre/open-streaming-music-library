"""9D.1c: the Last.fm simulator for the deferred live gate (spec §7.14 "End to end").

`tests/lastfm_simulator.py` is a loopback HTTP server with a control interface
to approve tokens. These tests exercise its request handling and control as
plain functions, and the real client against it through an in-process
transport. No test here starts the server or binds a port.
"""

import json
from urllib.parse import urlencode

import pytest
from pydantic import SecretStr

from app.services.lastfm_client import AnswerKind, LastfmClient, RowOutcome, RowStatus
from tests import lastfm_secrets as planted
from tests import lastfm_simulator
from tests.lastfm_fake import make_config
from tests.lastfm_simulator import Simulator

NOW = 1_800_000_000
SENT = RowOutcome(RowStatus.SENT, None)


def _sim():
    return Simulator(planted.API_KEY, planted.API_SECRET, clock=lambda: NOW)


def _client(sim, **config):
    return LastfmClient(make_config(**config), transport=sim.transport())


def _connect(sim, client, account="alice"):
    token = client.get_token().token
    sim.approve(token, account)
    return client.get_session(token).session_key


def test_the_browser_approval_flow():
    sim = _sim()
    client = _client(sim)

    token = client.get_token()
    assert token.answer.kind is AnswerKind.OK and token.token

    not_yet = client.get_session(token.token)
    assert not_yet.answer.kind is AnswerKind.REJECTED and not_yet.answer.error_code == 14

    sim.approve(token.token, "alice")
    session = client.get_session(token.token)
    assert session.answer.kind is AnswerKind.OK
    assert session.account_name == "alice" and session.session_key

    used = client.get_session(token.token)
    assert used.answer.kind is AnswerKind.REJECTED and used.answer.error_code == 15


def test_an_unknown_token_is_expired():
    sim = _sim()

    result = _client(sim).get_session("not-a-token-the-simulator-issued")

    assert result.answer.error_code == 15


def test_a_batch_of_tricky_rows_is_accepted_and_recorded_exactly():
    # The simulator checks the signature with its own code: the client and the
    # simulator agreeing on twelve tricky rows is a second, independent check.
    sim = _sim()
    client = _client(sim)
    key = _connect(sim, client)
    names = [
        ("Guns N’ Roses", "Sweet Child O’ Mine"),
        ("Simon & Garfunkel", "a=b&c=d"),
        ("C+C Music Factory", "100% [live]"),
        ("Sigur Rós", "Hoppípolla"),
        ("坂本龍一", "戦場のメリークリスマス"),
        ("Emoji 🎵 Band", "🔥"),
        ("AC/DC", "T.N.T."),
        ("Кино", "Группа крови"),
        ("Björk", "Jóga"),
        ("Mötley Crüe", "Dr. Feelgood"),
        ("Daft Punk", "One More Time"),
        ("Various", "Track 12"),
    ]
    rows = [
        {"artist": a, "track": t, "timestamp": NOW - 3600 + i, "album": "Hits & Co", "albumArtist": "VA"}
        for i, (a, t) in enumerate(names)
    ]

    result = client.scrobble(key, rows)

    assert result.answer.kind is AnswerKind.OK
    assert result.rows == (SENT,) * 12
    recorded = sim.scrobbles["alice"]
    assert [(s["artist"], s["track"], s["timestamp"]) for s in recorded] == [
        (r["artist"], r["track"], str(r["timestamp"])) for r in rows
    ]
    assert all(s["albumArtist"] == "VA" and s["album"] == "Hits & Co" for s in recorded)


def test_two_accounts_keep_their_own_scrobbles():
    sim = _sim()
    client = _client(sim)
    alice = _connect(sim, client, "alice")
    carol = _connect(sim, client, "carol")

    client.scrobble(alice, [{"artist": "A", "track": "for alice", "timestamp": NOW - 100}])
    client.scrobble(carol, [{"artist": "C", "track": "for carol", "timestamp": NOW - 100}])

    assert [s["track"] for s in sim.scrobbles["alice"]] == ["for alice"]
    assert [s["track"] for s in sim.scrobbles["carol"]] == ["for carol"]


def test_a_wrong_shared_secret_is_error_13():
    sim = _sim()
    client = _client(sim, api_secret=SecretStr("a-different-made-up-secret"))

    assert client.get_token().answer.error_code == 13


def test_a_wrong_api_key_is_error_10():
    sim = _sim()
    client = _client(sim, api_key=SecretStr("x" * 32))

    answer = client.get_token().answer

    assert answer.kind is AnswerKind.STOP and answer.error_code == 10


def test_a_revoked_application_is_error_9():
    sim = _sim()
    client = _client(sim)
    key = _connect(sim, client)

    sim.revoke("alice")
    result = client.scrobble(key, [{"artist": "A", "track": "T", "timestamp": NOW - 100}])
    now_playing = client.update_now_playing(key, {"artist": "A", "track": "T"})

    assert result.answer.kind is AnswerKind.RECONNECT
    assert now_playing.kind is AnswerKind.RECONNECT


def test_forced_failures_are_answered_in_order_then_normal_service_resumes():
    sim = _sim()
    client = _client(sim)
    key = _connect(sim, client)
    sim.fail_next(code=16)
    sim.fail_next(http_status=502)
    sim.fail_next(code=26)

    answers = [client.update_now_playing(key, {"artist": "A", "track": "T"}).kind for _ in range(4)]

    assert answers == [AnswerKind.TRY_LATER, AnswerKind.TRY_LATER, AnswerKind.STOP, AnswerKind.OK]


def test_a_rejected_title_rejects_the_whole_request():
    sim = _sim()
    client = _client(sim)
    key = _connect(sim, client)
    sim.reject_title("Bad Title")
    rows = [
        {"artist": "A", "track": "Good", "timestamp": NOW - 200},
        {"artist": "A", "track": "Bad Title", "timestamp": NOW - 100},
    ]

    batch = client.scrobble(key, rows)
    alone = client.scrobble(key, rows[:1])

    assert batch.answer.kind is AnswerKind.REJECTED
    assert alone.answer.kind is AnswerKind.OK
    assert [s["track"] for s in sim.scrobbles["alice"]] == ["Good"]


def test_bad_metadata_and_bad_timestamps_are_ignored_per_row():
    sim = _sim()
    client = _client(sim)
    key = _connect(sim, client)
    rows = [
        {"artist": "Unknown Artist", "track": "T", "timestamp": NOW - 100},
        {"artist": "A", "track": "old", "timestamp": NOW - 15 * 86400},
        {"artist": "A", "track": "future", "timestamp": NOW + 2 * 86400},
        {"artist": "A", "track": "fine", "timestamp": NOW - 50},
    ]

    result = client.scrobble(key, rows)

    assert result.answer.kind is AnswerKind.OK
    assert [r.status for r in result.rows] == [
        RowStatus.IGNORED,
        RowStatus.IGNORED,
        RowStatus.IGNORED,
        RowStatus.SENT,
    ]
    assert result.rows[0].code == 1
    assert [s["track"] for s in sim.scrobbles["alice"]] == ["fine"]


def test_more_than_fifty_rows_is_refused():
    sim = _sim()
    form = {"method": "track.scrobble", "api_key": planted.API_KEY, "sk": "x"}
    for i in range(51):
        form.update({f"artist[{i}]": "A", f"track[{i}]": "T", f"timestamp[{i}]": str(NOW)})
    form["api_sig"] = "0" * 32

    status, body = sim.handle(list(form.items()))

    assert b'status="failed"' in body


def test_every_request_is_recorded_with_its_method():
    sim = _sim()
    client = _client(sim)
    key = _connect(sim, client)
    client.update_now_playing(key, {"artist": "A", "track": "T"})

    assert [r["method"] for r in sim.requests] == [
        "auth.getToken",
        "auth.getSession",
        "track.updateNowPlaying",
    ]


def test_the_control_interface_approves_a_token_as_a_plain_function():
    sim = _sim()
    client = _client(sim)
    token = client.get_token().token

    status, body = sim.handle_control("POST", "/control/approve", urlencode({"token": token, "account": "alice"}).encode())
    assert status == 200
    status, body = sim.handle_control("GET", "/control/requests", b"")
    assert status == 200
    assert [r["method"] for r in json.loads(body)] == ["auth.getToken"]

    assert client.get_session(token).account_name == "alice"


def test_the_control_interface_drives_revoke_failures_and_rejections():
    sim = _sim()
    client = _client(sim)
    key = _connect(sim, client)

    assert sim.handle_control("POST", "/control/fail", b"code=11")[0] == 200
    assert client.update_now_playing(key, {"artist": "A", "track": "T"}).kind is AnswerKind.TRY_LATER
    assert sim.handle_control("POST", "/control/reject-title", b"title=Nope")[0] == 200
    assert client.scrobble(key, [{"artist": "A", "track": "Nope", "timestamp": NOW - 1}]).answer.kind is AnswerKind.REJECTED
    assert sim.handle_control("POST", "/control/revoke", b"account=alice")[0] == 200
    assert client.update_now_playing(key, {"artist": "A", "track": "T"}).kind is AnswerKind.RECONNECT
    status, body = sim.handle_control("GET", "/control/scrobbles", b"")
    assert status == 200 and json.loads(body) == {}
    assert sim.handle_control("GET", "/control/nothing-here", b"")[0] == 404


@pytest.mark.parametrize("host", ["0.0.0.0", "10.0.0.1", "192.168.1.2", "::", "example.com", "localhost.evil", ""])
def test_the_server_refuses_to_bind_anything_but_loopback(host):
    with pytest.raises(ValueError):
        lastfm_simulator.loopback_host(host)


@pytest.mark.parametrize("host", ["127.0.0.1", "127.0.0.2", "::1"])
def test_loopback_addresses_are_accepted(host):
    assert lastfm_simulator.loopback_host(host) == host


def test_main_refuses_a_non_loopback_host_before_binding(monkeypatch):
    monkeypatch.setenv("SIMULATOR_API_KEY", planted.API_KEY)
    monkeypatch.setenv("SIMULATOR_API_SECRET", planted.API_SECRET)

    def no_bind(*args, **kwargs):
        raise AssertionError("tried to bind")

    monkeypatch.setattr(lastfm_simulator, "make_server", no_bind)

    with pytest.raises(SystemExit) as caught:
        lastfm_simulator.main(["--host", "0.0.0.0", "--port", "0"])
    assert caught.value.code != 0


def test_main_refuses_to_start_without_its_made_up_credentials(monkeypatch):
    monkeypatch.delenv("SIMULATOR_API_KEY", raising=False)
    monkeypatch.delenv("SIMULATOR_API_SECRET", raising=False)
    monkeypatch.setattr(lastfm_simulator, "make_server", lambda *a, **k: pytest.fail("tried to bind"))

    with pytest.raises(SystemExit) as caught:
        lastfm_simulator.main(["--port", "0"])
    assert caught.value.code != 0


# --- review r1 (S5): the server answers only requests addressed to loopback ----


@pytest.mark.parametrize("header", ["127.0.0.1:8765", "127.0.0.1", "[::1]:8765", "[::1]"])
def test_a_loopback_host_header_is_served(header):
    assert lastfm_simulator.host_header_allowed(header) is True


@pytest.mark.parametrize(
    "header", ["evil.example", "evil.example:8765", "localhost:8765", "", None, "127.0.0.1.evil.example", "[::1]x"]
)
def test_any_other_host_header_is_refused(header):
    # A DNS-rebinding page arrives with its own name in Host.
    assert lastfm_simulator.host_header_allowed(header) is False
