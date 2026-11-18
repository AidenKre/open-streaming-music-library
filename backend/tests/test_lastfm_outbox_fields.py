"""9D.2a (spec §7.7 steps 5 and 6 and the frozen payload, 9-U09 subscriber
part).

Step 5: after trimming, ``artist`` is the track's artist, or the album artist
when the artist is empty and the album artist is not a various-artists marker
(``va`` in any case, or anything containing "various artists"); ``artist`` and
``track`` are non-empty; no field is longer than 1,024 characters; none has a
control character. Never a filename or a placeholder.

Step 6: the listen start is at most 24 hours ahead of the server clock.

Payload: ``artist``, ``track``, ``timestamp``, and only when non-empty
``album``; ``albumArtist`` only when it differs from ``artist`` (compared
exactly), omitted when it is ``va``, exactly ``Various Artists`` when it
contains that phrase.

Every case posts through the real ``POST /history`` and reads the row back;
the expected payloads are written out by hand."""

import pytest

from tests.lastfm_routes import clean_env
from tests.lastfm_outbox_helpers import TIMESTAMP, queue as _queue

DAY_MS = 86_400_000


@pytest.fixture(autouse=True)
def _clean(monkeypatch):
    clean_env(monkeypatch)


# ── step 5: what is sent ─────────────────────────────────────────────────────


def _expect(artist="Radiohead", track="Airbag", **optional):
    payload = {"artist": artist, "track": track, "timestamp": TIMESTAMP}
    payload.update(optional)
    payload["duration"] = 284
    return payload


@pytest.mark.parametrize(
    ("tags", "expected"),
    [
        pytest.param({}, _expect(album="OK Computer"), id="every-tag"),
        pytest.param({"title": " Airbag ", "artist": "\tRadiohead  ", "album": "  OK Computer\n"},
                     _expect(album="OK Computer"), id="trimmed"),
        pytest.param({"artist": " Radiohead　"}, _expect(album="OK Computer"), id="unicode-space-trimmed"),
        # The album artist stands in for an empty artist ...
        pytest.param({"artist": "", "album_artist": "Radiohead"}, _expect(album="OK Computer"), id="aa-for-empty"),
        pytest.param({"artist": None, "album_artist": "Radiohead"}, _expect(album="OK Computer"), id="aa-for-null"),
        pytest.param({"artist": "   ", "album_artist": " Radiohead "}, _expect(album="OK Computer"),
                     id="aa-for-blank"),
        # ... and is sent only when it differs from the artist.
        pytest.param({"album_artist": "Radiohead"}, _expect(album="OK Computer"), id="aa-same-omitted"),
        pytest.param({"album_artist": " Radiohead\t"}, _expect(album="OK Computer"), id="aa-same-after-trim"),
        pytest.param({"album_artist": "Thom Yorke"}, _expect(album="OK Computer", albumArtist="Thom Yorke"),
                     id="aa-different"),
        pytest.param({"album_artist": "radiohead"}, _expect(album="OK Computer", albumArtist="radiohead"),
                     id="aa-differs-in-case-only"),
        # Various-artists markers.
        pytest.param({"album_artist": "VA"}, _expect(album="OK Computer"), id="aa-VA-omitted"),
        pytest.param({"album_artist": " va "}, _expect(album="OK Computer"), id="aa-va-omitted"),
        pytest.param({"album_artist": "Various Artists"},
                     _expect(album="OK Computer", albumArtist="Various Artists"), id="aa-various"),
        pytest.param({"album_artist": "  VARIOUS ARTISTS "},
                     _expect(album="OK Computer", albumArtist="Various Artists"), id="aa-various-upper"),
        pytest.param({"album_artist": "Various Artists of the 90s"},
                     _expect(album="OK Computer", albumArtist="Various Artists"), id="aa-contains-various"),
        pytest.param({"album_artist": "Vast"}, _expect(album="OK Computer", albumArtist="Vast"), id="aa-not-va"),
        # Empty optional fields are left out.
        pytest.param({"album": ""}, _expect(), id="album-empty"),
        pytest.param({"album": None}, _expect(), id="album-null"),
        pytest.param({"album": " \t "}, _expect(), id="album-blank"),
        pytest.param({"album_artist": ""}, _expect(album="OK Computer"), id="aa-empty"),
        pytest.param({"album_artist": "  "}, _expect(album="OK Computer"), id="aa-blank"),
        # Real names with the characters other scrobblers got wrong are kept exactly.
        pytest.param({"artist": "Simon & Garfunkel", "title": "Mrs. Robinson", "album": "Bookends"},
                     _expect("Simon & Garfunkel", "Mrs. Robinson", album="Bookends"), id="ampersand"),
        pytest.param({"artist": "Guns N’ Roses", "title": "Don’t Cry", "album": "Use Your Illusion I"},
                     _expect("Guns N’ Roses", "Don’t Cry", album="Use Your Illusion I"), id="curly-apostrophe"),
        pytest.param({"artist": "AC/DC", "title": "T.N.T.", "album": "High Voltage"},
                     _expect("AC/DC", "T.N.T.", album="High Voltage"), id="slash"),
        pytest.param({"artist": "Sigur Rós", "title": "Hoppípolla", "album": "Takk..."},
                     _expect("Sigur Rós", "Hoppípolla", album="Takk..."), id="accented"),
        pytest.param({"artist": "坂本龍一", "title": "戦場のメリークリスマス", "album": "音楽図鑑"},
                     _expect("坂本龍一", "戦場のメリークリスマス", album="音楽図鑑"), id="non-latin"),
        pytest.param({"artist": "Unknown Artist", "title": "Track 01"},
                     _expect("Unknown Artist", "Track 01", album="OK Computer"), id="bad-entry-sent-as-tagged"),
        pytest.param({"title": "x" * 1024}, _expect(track="x" * 1024, album="OK Computer"), id="title-1024"),
        pytest.param({"title": "x" * 1024 + "  "}, _expect(track="x" * 1024, album="OK Computer"),
                     id="title-1024-after-trim"),
    ],
)
def test_the_payload_holds_the_trimmed_tags_by_the_rules(open_app_client, tmp_path, tags, expected):
    assert _queue(open_app_client, tmp_path, tags=tags) == expected


@pytest.mark.parametrize(
    "tags",
    [
        pytest.param({"artist": ""}, id="no-artist"),
        pytest.param({"artist": None}, id="null-artist"),
        pytest.param({"artist": " \t "}, id="blank-artist"),
        pytest.param({"artist": "", "album_artist": "VA"}, id="artist-empty-aa-VA"),
        pytest.param({"artist": "", "album_artist": " va "}, id="artist-empty-aa-va"),
        pytest.param({"artist": "", "album_artist": "Various Artists"}, id="artist-empty-aa-various"),
        pytest.param({"artist": None, "album_artist": "various artists vol. 2"}, id="artist-null-aa-contains"),
        pytest.param({"artist": "", "album_artist": ""}, id="artist-and-aa-empty"),
        pytest.param({"title": ""}, id="no-title"),
        pytest.param({"title": None}, id="null-title"),
        pytest.param({"title": "   "}, id="blank-title"),
        pytest.param({"title": "x" * 1025}, id="title-1025"),
        pytest.param({"artist": "x" * 1025}, id="artist-1025"),
        pytest.param({"album": "x" * 1025}, id="album-1025"),
        pytest.param({"album_artist": "x" * 1025}, id="album-artist-1025"),
        pytest.param({"title": "Air\x00bag"}, id="nul"),
        pytest.param({"title": "Air\nbag"}, id="newline-inside"),
        pytest.param({"artist": "Radio\thead"}, id="tab-inside"),
        pytest.param({"album": "OK\x07Computer"}, id="bell-in-album"),
        pytest.param({"album_artist": "Thom\x1bYorke"}, id="escape-in-album-artist"),
        pytest.param({"title": "Air\x7fbag"}, id="delete"),
        pytest.param({"title": "Air\x85bag"}, id="c1-control"),
    ],
)
def test_a_listen_that_cannot_be_described_is_not_queued(open_app_client, tmp_path, tags):
    assert _queue(open_app_client, tmp_path, tags=tags) is None


# ── step 6: not far in the future ────────────────────────────────────────────

WALL_MS = 1_800_000_000_000


@pytest.mark.parametrize(
    ("occurred_at", "timestamp"),
    [
        (WALL_MS + DAY_MS, 1_800_086_400),         # exactly 24 hours ahead
        (WALL_MS, 1_800_000_000),
        (WALL_MS - 20 * DAY_MS, 1_798_272_000),    # old listens are the sender's to drop
    ],
)
def test_a_listen_up_to_24_hours_ahead_is_queued(open_app_client, tmp_path, occurred_at, timestamp):
    payload = _queue(open_app_client, tmp_path, occurred_at=occurred_at)

    assert payload is not None and payload["timestamp"] == timestamp


@pytest.mark.parametrize("occurred_at", [WALL_MS + DAY_MS + 1, WALL_MS + 2 * DAY_MS, 253402300799999])
def test_a_listen_more_than_24_hours_ahead_is_not_queued(open_app_client, tmp_path, occurred_at):
    assert _queue(open_app_client, tmp_path, occurred_at=occurred_at) is None


# Review r1 F3 (lead decision): trimming is Python's ``str.strip()``, which also
# removes the separator controls U+001C..U+001F and U+0085 at the ends; a control
# character left inside a field still refuses the listen (see above).
def test_r1_separator_controls_at_the_ends_are_trimmed_like_spaces(open_app_client, tmp_path):
    tags = {"title": "Airbag\x1f", "artist": "\x85Radiohead\x1c", "album": "OK Computer\x1e"}

    assert _queue(open_app_client, tmp_path, tags=tags) == _expect(album="OK Computer")
