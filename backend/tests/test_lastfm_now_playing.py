"""9D.2c (spec §7.10, review 9-U10 Now Playing): at most one waiting notice per
user in memory, the newest wins; the sender sends it through the gate as
``track.updateNowPlaying`` after re-reading the user and the track inside the
gate, or discards it silently (replaced, foreign or unknown track, field rules,
ineligible user, waited 10 seconds, server not running). Injected clocks only;
the fake Last.fm never opens a socket."""

import sqlite3
import uuid

import pytest

from app.models import Track, TrackMetaData
from app.services.lastfm_now_playing import NOTICE_MAX_WAIT_S, NowPlayingNotices
from tests.lastfm_fake import FakeClock, ok_now_playing, xml_reply
from tests.lastfm_sender_rig import (
    GAP_S,
    WALL_MS,
    connect_user,
    execute,
    make_rig,
    session_key_for,
)

SIGNING = {"method", "sk", "api_key", "api_sig"}


@pytest.fixture
def rig(tmp_path):
    return make_rig(tmp_path)


def add_track(rig, tmp_path, owner, *, duration=284.2, **tags) -> str:
    """A live track of ``owner`` with exactly these four tags (default: a real song)."""
    folder = tmp_path / f"music-{owner}"
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / f"{uuid.uuid4().hex}.flac"
    path.write_bytes(b"not really flac")
    track = Track(
        file_path=path,
        metadata=TrackMetaData(codec="flac", duration=284.0, bitrate_kbps=900.0,
                               sample_rate_hz=44100, channels=2, title="Airbag", artist="Radiohead"),
    )
    assert rig.db.add_track(track, owner_id=owner)
    values = {"title": "Airbag", "artist": "Radiohead", "album": "OK Computer", "album_artist": None}
    values.update(tags)
    conn = sqlite3.connect(rig.db.context.database_path)
    try:
        conn.execute(
            "UPDATE trackmetadata SET title = ?, artist = ?, album = ?, album_artist = ?, duration = ?"
            " WHERE uuid_id = ?",
            (values["title"], values["artist"], values["album"], values["album_artist"], duration,
             track.uuid_id),
        )
        conn.commit()
    finally:
        conn.close()
    return track.uuid_id


def track_fields(rig, index=-1) -> dict:
    """The track fields of a captured request (everything but the signing fields)."""
    return {k: v for k, v in rig.fake.form(index) if k not in SIGNING}


def method(rig, index=-1) -> str:
    return dict(rig.fake.form(index))["method"]


def sk(rig, index=-1) -> str:
    return dict(rig.fake.form(index))["sk"]


# --- the holder ------------------------------------------------------------------------


def test_one_notice_per_user_the_newest_replaces_it_and_every_put_wakes_the_sender():
    wakes = []
    notices = NowPlayingNotices(clock=FakeClock(), wake=lambda: wakes.append(1))

    notices.put(1, "first")
    notices.put(1, "second")
    notices.put(2, "other")

    assert len(notices) == 2
    assert sorted((n.owner_id, n.track_uuid) for n in notices.waiting()) == [(1, "second"), (2, "other")]
    assert len(wakes) == 3


def test_drop_removes_only_that_users_notice():
    notices = NowPlayingNotices(clock=FakeClock())
    notices.put(1, "a")
    notices.put(2, "b")

    notices.drop(1)
    notices.drop(3)  # nothing waiting: harmless

    assert [(n.owner_id, n.track_uuid) for n in notices.waiting()] == [(2, "b")]


def test_a_notice_that_has_waited_ten_seconds_is_discarded():
    clock = FakeClock()
    notices = NowPlayingNotices(clock=clock)
    notices.put(1, "a")

    clock.advance(NOTICE_MAX_WAIT_S - 0.001)
    assert len(notices.waiting()) == 1

    clock.advance(0.001)
    assert notices.waiting() == []
    assert len(notices) == 0  # gone from memory, not only hidden


def test_only_the_current_notice_can_be_claimed_and_only_once():
    notices = NowPlayingNotices(clock=FakeClock())
    notices.put(1, "old")
    [old] = notices.waiting()
    notices.put(1, "new")
    [new] = notices.waiting()

    assert notices.claim(old) is False  # replaced: never sent
    assert notices.claim(new) is True
    assert len(notices) == 0
    assert notices.claim(new) is False


def test_a_dropped_notice_cannot_be_claimed():
    # The ten seconds are enforced by waiting() before the gate and by the gate's bound
    # (the sender passes the notice's remaining life as max_wait_s); claim checks identity
    # only, so a notice the gate let through within its life is sent (DEV-9D2c-02).
    notices = NowPlayingNotices(clock=FakeClock())
    notices.put(1, "a")
    [dropped] = notices.waiting()
    notices.drop(1)

    assert notices.claim(dropped) is False
    assert len(notices) == 0


def test_the_senders_notices_wake_the_sender(rig):
    rig.sender.notices.put(1, "a")

    assert rig.sender._wake.is_set()  # the shared worker base's wake-up: the next pass runs at once


# --- the sender sends it -----------------------------------------------------------------


def test_a_waiting_notice_goes_out_as_track_update_now_playing_with_the_owners_track(rig, tmp_path):
    ana = connect_user(rig, "ana")
    track = add_track(rig, tmp_path, ana)
    rig.sender.notices.put(ana, track)
    rig.fake.queue(ok_now_playing())

    assert rig.sender.run_pass() is True

    assert len(rig.fake.requests) == 1
    assert method(rig) == "track.updateNowPlaying"
    assert sk(rig) == session_key_for("ana")
    # §7.7 step 5's fields and the length rounded up; no timestamp.
    assert track_fields(rig) == {"artist": "Radiohead", "track": "Airbag", "album": "OK Computer",
                                 "duration": "285"}
    assert len(rig.sender.notices) == 0


@pytest.mark.parametrize(
    "tags, expected",
    [
        # A deliberately bad but real tag is sent as it is; Last.fm judges it (live gate case).
        ({"artist": "Unknown Artist", "title": "Track 1", "album": None},
         {"artist": "Unknown Artist", "track": "Track 1", "duration": "285"}),
        # Punctuation is user content, sent unchanged.
        ({"artist": "Simon & Garfunkel", "title": "Don’t Stop / Go + 100% [live]", "album": "Bookends"},
         {"artist": "Simon & Garfunkel", "track": "Don’t Stop / Go + 100% [live]", "album": "Bookends",
          "duration": "285"}),
        # The album artist stands in for an empty artist; it then equals the artist and is not repeated.
        ({"artist": "  ", "album_artist": "Björk"},
         {"artist": "Björk", "track": "Airbag", "album": "OK Computer", "duration": "285"}),
        # A compilation: "VA" is never sent as the album artist.
        ({"artist": "Daft Punk", "title": "One More Time", "album": "Hits", "album_artist": "VA"},
         {"artist": "Daft Punk", "track": "One More Time", "album": "Hits", "duration": "285"}),
        ({"album_artist": "Various Artists (2001)"},
         {"artist": "Radiohead", "track": "Airbag", "album": "OK Computer",
          "albumArtist": "Various Artists", "duration": "285"}),
    ],
    ids=["unknown-artist", "punctuation", "album-artist-stands-in", "va", "various-artists"],
)
def test_the_fields_follow_the_scrobble_rules(rig, tmp_path, tags, expected):
    ana = connect_user(rig, "ana")
    rig.sender.notices.put(ana, add_track(rig, tmp_path, ana, **tags))
    rig.fake.queue(ok_now_playing())

    rig.sender.run_pass()

    assert track_fields(rig) == expected


def test_an_unknown_length_sends_no_duration(rig, tmp_path):
    ana = connect_user(rig, "ana")
    rig.sender.notices.put(ana, add_track(rig, tmp_path, ana, duration=None))
    rig.fake.queue(ok_now_playing())

    rig.sender.run_pass()

    assert track_fields(rig) == {"artist": "Radiohead", "track": "Airbag", "album": "OK Computer"}


@pytest.mark.parametrize(
    "tags",
    [
        {"artist": None, "album_artist": None},
        {"title": "   "},
        {"artist": "", "album_artist": "Various Artists"},
        {"title": "x" * 1025},
        {"album": "bad\x07album"},
    ],
    ids=["no-artist", "no-title", "only-various-artists", "too-long", "control-character"],
)
def test_a_track_the_field_rules_refuse_sends_nothing(rig, tmp_path, tags):
    ana = connect_user(rig, "ana")
    rig.sender.notices.put(ana, add_track(rig, tmp_path, ana, **tags))

    assert rig.sender.run_pass() is False

    assert rig.fake.requests == []
    assert len(rig.sender.notices) == 0


def test_only_the_newest_notice_of_a_user_is_sent(rig, tmp_path):
    ana = connect_user(rig, "ana")
    first = add_track(rig, tmp_path, ana, title="First")
    second = add_track(rig, tmp_path, ana, title="Second")
    rig.sender.notices.put(ana, first)
    rig.sender.notices.put(ana, second)
    rig.fake.queue(ok_now_playing())

    rig.sender.run_pass()

    assert len(rig.fake.requests) == 1
    assert track_fields(rig)["track"] == "Second"


def test_each_user_gets_their_own_request_with_their_own_key_one_gap_apart(rig, tmp_path):
    ana = connect_user(rig, "ana")
    ben = connect_user(rig, "ben")
    rig.sender.notices.put(ana, add_track(rig, tmp_path, ana, title="Ana's"))
    rig.gate_clock.advance(0.001)  # oldest notice first
    rig.sender.notices.put(ben, add_track(rig, tmp_path, ben, title="Ben's"))
    times = []

    def answer(request):
        times.append(rig.gate_clock.now)
        return ok_now_playing()

    rig.fake.queue(answer, answer)

    rig.sender.run_pass()

    assert [(sk(rig, i), track_fields(rig, i)["track"]) for i in (0, 1)] == [
        (session_key_for("ana"), "Ana's"), (session_key_for("ben"), "Ben's")]
    assert times[1] - times[0] >= GAP_S


def test_another_users_track_or_an_unknown_one_sends_nothing(rig, tmp_path):
    ana = connect_user(rig, "ana")
    ben = connect_user(rig, "ben")
    anas_track = add_track(rig, tmp_path, ana)
    rig.sender.notices.put(ben, anas_track)

    assert rig.sender.run_pass() is False
    rig.sender.notices.put(ben, str(uuid.uuid4()))
    assert rig.sender.run_pass() is False

    assert rig.fake.requests == []
    assert len(rig.sender.notices) == 0


@pytest.mark.parametrize("setup", ["not_opted_in", "needs_reconnect", "no_connection", "disabled", "being_deleted"])
def test_a_user_who_must_not_be_sent_for_gets_no_request(rig, tmp_path, setup):
    ana = connect_user(rig, "ana", opted_in=setup != "not_opted_in", needs_reconnect=setup == "needs_reconnect")
    track = add_track(rig, tmp_path, ana)
    if setup == "disabled":
        execute(rig, "UPDATE users SET disabled_at = ? WHERE id = ?", (WALL_MS - 1, ana))
    if setup == "being_deleted":
        execute(rig, "UPDATE users SET deleting_at = ? WHERE id = ?", (WALL_MS - 1, ana))
    if setup == "no_connection":
        execute(rig, "DELETE FROM lastfm_connections WHERE owner_id = ?", (ana,))
    rig.sender.notices.put(ana, track)

    assert rig.sender.run_pass() is False

    assert rig.fake.requests == []
    assert len(rig.sender.notices) == 0


# --- read inside the gate ------------------------------------------------------------------


def _during_the_gate_wait(rig, action):
    rig.gate_clock.on_wait.append(lambda timeout: action())


@pytest.mark.parametrize(
    "change",
    [
        "DELETE FROM lastfm_connections WHERE owner_id = ?",
        "UPDATE lastfm_connections SET opted_in = 0 WHERE owner_id = ?",
        "UPDATE lastfm_connections SET needs_reconnect = 1 WHERE owner_id = ?",
        "UPDATE users SET disabled_at = 1 WHERE id = ?",
    ],
    ids=["disconnect", "opt-out", "reconnect-flag", "cli-disable"],
)
def test_a_change_during_the_gate_wait_is_seen_and_nothing_is_sent(rig, tmp_path, change):
    ana = connect_user(rig, "ana")
    rig.sender.notices.put(ana, add_track(rig, tmp_path, ana))
    _during_the_gate_wait(rig, lambda: execute(rig, change, (ana,)))

    rig.sender.run_pass()

    assert rig.gate_clock.waits, "the first request after startup waits one gap"
    assert rig.fake.requests == []


def test_a_notice_dropped_during_the_gate_wait_is_not_sent(rig, tmp_path):
    ana = connect_user(rig, "ana")
    rig.sender.notices.put(ana, add_track(rig, tmp_path, ana))
    _during_the_gate_wait(rig, lambda: rig.sender.notices.drop(ana))

    rig.sender.run_pass()

    assert rig.fake.requests == []


def test_a_notice_replaced_during_the_gate_wait_is_not_sent_and_the_newer_one_is(rig, tmp_path):
    ana = connect_user(rig, "ana")
    rig.sender.notices.put(ana, add_track(rig, tmp_path, ana, title="Old"))
    newer = add_track(rig, tmp_path, ana, title="New")
    _during_the_gate_wait(rig, lambda: rig.sender.notices.put(ana, newer))

    rig.sender.run_pass()
    assert rig.fake.requests == []

    rig.gate_clock.on_wait.clear()
    rig.fake.queue(ok_now_playing())
    rig.sender.run_pass()

    assert [track_fields(rig, i)["track"] for i in range(len(rig.fake.requests))] == ["New"]


# --- ten seconds -----------------------------------------------------------------------------


def test_a_notice_younger_than_ten_seconds_is_sent(rig, tmp_path):
    ana = connect_user(rig, "ana")
    rig.sender.notices.put(ana, add_track(rig, tmp_path, ana))
    rig.gate_clock.advance(NOTICE_MAX_WAIT_S - 0.5)
    rig.fake.queue(ok_now_playing())

    rig.sender.run_pass()

    assert len(rig.fake.requests) == 1


def test_a_notice_that_has_waited_ten_seconds_is_discarded_by_the_sender(rig, tmp_path):
    ana = connect_user(rig, "ana")
    rig.sender.notices.put(ana, add_track(rig, tmp_path, ana))
    rig.gate_clock.advance(NOTICE_MAX_WAIT_S)

    assert rig.sender.run_pass() is False

    assert rig.fake.requests == []
    assert len(rig.sender.notices) == 0


def test_a_notice_the_gate_cannot_let_through_within_ten_seconds_is_discarded(rig, tmp_path):
    ana = connect_user(rig, "ana")
    ben = connect_user(rig, "ben")
    rig.sender.notices.put(ana, add_track(rig, tmp_path, ana))
    rig.gate_clock.advance(0.001)
    rig.sender.notices.put(ben, add_track(rig, tmp_path, ben))
    # Ana's request gets a try-later answer: the gate then holds everything for 60 s.
    rig.fake.queue(xml_reply("busy", status=503))

    rig.sender.run_pass()

    assert len(rig.fake.requests) == 1  # Ben's notice never went out
    assert len(rig.sender.notices) == 0
    assert all(w is not None and w <= NOTICE_MAX_WAIT_S for w in rig.gate_clock.waits)

    rig.gate_clock.advance(120)
    rig.sender.run_pass()
    assert len(rig.fake.requests) == 1  # and it is not sent later either


def test_a_server_that_is_not_running_sends_no_notice_and_keeps_none(rig, tmp_path):
    ana = connect_user(rig, "ana")
    rig.sender.notices.put(ana, add_track(rig, tmp_path, ana))
    rig.state.stop("test")

    assert rig.sender.run_pass() is False

    assert rig.fake.requests == []
    assert len(rig.sender.notices) == 0
