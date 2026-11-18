"""9D.2a (spec §7.7 step 3 and the payload's ``duration``, 9-U09 subscriber
part): Last.fm's rule, which is not OSML's qualified play. With a known
``track_length`` the track is longer than 30 seconds and ``seconds_played`` is
at least ``min(track_length / 2, 240)``; with an unknown length at least 240
seconds were played and the payload has no ``duration``. An unknown
``seconds_played`` never qualifies (unknown is not zero, and not "enough").
``duration`` is the length rounded up to a whole second.

Every case posts through the real ``POST /history`` and reads the row back;
the expected payloads are written out by hand."""

import pytest

from tests.lastfm_outbox_helpers import TIMESTAMP, queue
from tests.lastfm_routes import clean_env


@pytest.fixture(autouse=True)
def _clean(monkeypatch):
    clean_env(monkeypatch)


# ── step 3: Last.fm's threshold ──────────────────────────────────────────────


@pytest.mark.parametrize(
    ("track_length", "seconds_played", "duration"),
    [
        (30.3, 15.15, 31),     # a 30.3-second track at exactly half
        (30.3, 30.3, 31),
        (31.0, 15.5, 31),
        (200.0, 100.0, 200),   # exactly half
        (480.0, 240.0, 480),   # half and the cap meet
        (600.0, 240.0, 600),   # the 240 s cap, not half
        (600.0, 300.0, 600),
        (1200.0, 240.0, 1200),
        (284.01, 200.0, 285),  # duration rounds up
        (200.999, 200.0, 201),
        (284.0, 9999.0, 284),  # more than the length (a rewind) still counts
    ],
)
def test_a_listen_over_the_threshold_is_queued_with_its_duration_rounded_up(
    open_app_client, tmp_path, track_length, seconds_played, duration
):
    payload = queue(open_app_client, tmp_path, track_length=track_length, seconds_played=seconds_played)

    assert payload == {
        "artist": "Radiohead", "track": "Airbag", "timestamp": TIMESTAMP,
        "album": "OK Computer", "duration": duration,
    }


@pytest.mark.parametrize(
    ("track_length", "seconds_played"),
    [
        (30.0, 30.0),       # 30 s is not longer than 30 s
        (30.0, 240.0),
        (29.0, 29.0),
        (30.3, 15.14),      # just under half of 30.3
        (31.0, 15.49),
        (200.0, 99.99),
        (480.0, 239.99),
        (600.0, 239.9),     # under the cap although well into the track
        (1200.0, 239.0),
        (200.0, 0.0),
        (200.0, None),      # unknown time played never qualifies
    ],
)
def test_a_listen_under_the_threshold_is_not_queued(open_app_client, tmp_path, track_length, seconds_played):
    assert queue(open_app_client, tmp_path, track_length=track_length, seconds_played=seconds_played) is None


@pytest.mark.parametrize("seconds_played", [240.0, 240.5, 4000.0])
def test_an_unknown_length_queues_from_240_seconds_without_a_duration(open_app_client, tmp_path, seconds_played):
    payload = queue(open_app_client, tmp_path, track_length=None, seconds_played=seconds_played)

    assert payload == {"artist": "Radiohead", "track": "Airbag", "timestamp": TIMESTAMP, "album": "OK Computer"}


@pytest.mark.parametrize("seconds_played", [239.99, 120.0, 0.0, None])
def test_an_unknown_length_under_240_seconds_is_not_queued(open_app_client, tmp_path, seconds_played):
    assert queue(open_app_client, tmp_path, track_length=None, seconds_played=seconds_played) is None


