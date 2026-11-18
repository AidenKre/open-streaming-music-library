"""A listen carried end to end (pre-merge C1-01): ``POST /history`` through the
real outbox hook into ``scrobble_outbox``, then one ``ScrobbleSender.run_pass``
over the app's own database and Last.fm state to the request the in-process
fake of Last.fm receives. The same for Now Playing through its route.

Two users with different made-up session keys: each listen and each notice
reaches only its own user's account, with exactly that user's track fields.
The two halves are otherwise tested only against each test's idea of the
other (the outbox tests read the stored payload, the sender tests seed their
own rows). Nothing here opens a socket; every value is made up."""

from urllib.parse import parse_qsl

import pytest

from app.services.lastfm_now_playing import NowPlayingNotices
from app.services.lastfm_sender import ScrobbleSender
from tests.lastfm_fake import ok_now_playing, ok_scrobbles, scrobble_result
from tests.lastfm_outbox_helpers import listen, outbox, outbox_rig, post
from tests.lastfm_routes import BASE, admin_id, clean_env, second_user, seed_connection
from tests.lastfm_sender_rig import SETTLE_S, WallClock, add_track

ADMIN_KEY = "made-up-session-key-of-the-admin"
BEA_KEY = "made-up-session-key-of-bea"


@pytest.fixture(autouse=True)
def _clean(monkeypatch):
    clean_env(monkeypatch)


def _form(request) -> dict:
    return dict(parse_qsl(request.content.decode("utf-8"), keep_blank_values=True, strict_parsing=True))


def _scrobble_answer(request):
    """An "accepted" answer naming the one row the request carried."""
    return ok_scrobbles(1, 0, [scrobble_result(int(_form(request)["timestamp[0]"]))])


def _sender(rig, *, wall_ms: int) -> ScrobbleSender:
    """A sender over the app's own database, Last.fm state, client, gate and notices."""
    return ScrobbleSender(
        rig.db,
        rig.state,
        client=rig.accounts.client,
        gate=rig.accounts.gate,
        notices=rig.accounts.notices,
        settle_delay_s=SETTLE_S,
        now_ms=WallClock(wall_ms),
    )


def _two_connected_users(rig):
    # The sender listens to the holder's own notices, as at startup.
    rig.accounts.notices = NowPlayingNotices(clock=rig.gate_clock)
    admin = admin_id(rig)
    bea, bea_headers = second_user(rig)
    seed_connection(rig, admin, session_key=ADMIN_KEY, opted_in=True)
    seed_connection(rig, bea, session_key=BEA_KEY, opted_in=True)
    return admin, bea, bea_headers


def _by_key(requests) -> dict:
    forms = [_form(request) for request in requests]
    by_key = {form["sk"]: form for form in forms}
    assert len(by_key) == len(forms), "each request carries a different user's key"
    return by_key


def test_two_users_listens_reach_only_their_own_session_keys(open_app_client, tmp_path):
    with outbox_rig(open_app_client) as rig:
        admin, bea, bea_headers = _two_connected_users(rig)
        admin_track = add_track(rig, tmp_path, admin, title="Airbag", artist="Radiohead",
                                album="OK Computer", album_artist=None)
        bea_track = add_track(rig, tmp_path, bea, title="Teardrop", artist="Massive Attack",
                              album="Mezzanine Compiled", album_artist="Various Artists")
        admin_at = rig.wall.ms - 900_000
        bea_at = rig.wall.ms - 600_500
        post(rig, [listen(admin_track, admin_at)])
        post(rig, [listen(bea_track, bea_at, seconds_played=150.0, track_length=299.4)],
             headers=bea_headers)
        assert len(outbox(rig)) == 2
        rig.fake.queue(_scrobble_answer, _scrobble_answer)

        sender = _sender(rig, wall_ms=rig.wall.ms + SETTLE_S * 1000 + 1)
        assert sender.run_pass() is True

        assert [_form(r)["method"] for r in rig.fake.requests] == ["track.scrobble"] * 2
        by_key = _by_key(rig.fake.requests)
        assert set(by_key) == {ADMIN_KEY, BEA_KEY}
        admin_form, bea_form = by_key[ADMIN_KEY], by_key[BEA_KEY]
        assert {k: v for k, v in admin_form.items() if k.endswith("[0]")} == {
            "artist[0]": "Radiohead",
            "track[0]": "Airbag",
            "album[0]": "OK Computer",
            "duration[0]": "284",
            "timestamp[0]": str(admin_at // 1000),
        }
        assert {k: v for k, v in bea_form.items() if k.endswith("[0]")} == {
            "artist[0]": "Massive Attack",
            "track[0]": "Teardrop",
            "album[0]": "Mezzanine Compiled",
            "albumArtist[0]": "Various Artists",
            "duration[0]": "300",
            "timestamp[0]": str(bea_at // 1000),
        }
        for form in (admin_form, bea_form):
            assert not any(k.endswith("[1]") for k in form), "one row per request"

        rows = {row["owner_id"]: row for row in outbox(rig)}
        assert set(rows) == {admin, bea}
        assert [rows[o]["status"] for o in (admin, bea)] == ["sent", "sent"]


def test_two_users_now_playing_reaches_only_their_own_session_keys(open_app_client, tmp_path):
    with outbox_rig(open_app_client) as rig:
        admin, bea, bea_headers = _two_connected_users(rig)
        admin_track = add_track(rig, tmp_path, admin, duration=284.2, title="Airbag",
                                artist="Radiohead", album="OK Computer", album_artist=None)
        bea_track = add_track(rig, tmp_path, bea, duration=299.4, title="Teardrop",
                              artist="Massive Attack", album="Mezzanine Compiled",
                              album_artist="Various Artists")
        sender = _sender(rig, wall_ms=rig.wall.ms)
        rig.fake.queue(ok_now_playing(), ok_now_playing())

        path = f"{BASE}/now-playing"
        assert rig.client.post(path, json={"track_uuid": admin_track}).status_code == 202
        assert rig.client.post(path, json={"track_uuid": bea_track}, headers=bea_headers).status_code == 202
        assert sender.run_pass() is True

        assert [_form(r)["method"] for r in rig.fake.requests] == ["track.updateNowPlaying"] * 2
        by_key = _by_key(rig.fake.requests)
        assert set(by_key) == {ADMIN_KEY, BEA_KEY}
        track_fields = ("artist", "track", "album", "albumArtist", "duration")
        assert {k: v for k, v in by_key[ADMIN_KEY].items() if k in track_fields} == {
            "artist": "Radiohead", "track": "Airbag", "album": "OK Computer", "duration": "285",
        }
        assert {k: v for k, v in by_key[BEA_KEY].items() if k in track_fields} == {
            "artist": "Massive Attack", "track": "Teardrop", "album": "Mezzanine Compiled",
            "albumArtist": "Various Artists", "duration": "300",
        }
        assert outbox(rig) == []
