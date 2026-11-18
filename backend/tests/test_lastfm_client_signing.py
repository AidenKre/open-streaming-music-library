"""9D.1c: request bodies and their signatures (spec §7.8 "Signing", §7.14, 9-U09 client).

The expected signature is rebuilt here from the decoded request body with the
algorithm written out from the authentication spec §8, independent of the
client's code: every pair except `api_sig`, sorted by name in byte order,
name then value over the raw UTF-8 values, the secret appended, MD5 in hex.
"""

import hashlib

import pytest

from app.services.lastfm_client import LastfmClient, RowRefused, sign
from tests import lastfm_secrets as planted
from tests.lastfm_fake import (
    FakeLastfm,
    make_config,
    ok_now_playing,
    ok_scrobbles,
    ok_session,
    scrobble_result,
)

# A made-up shared secret with characters a sloppy signer would mangle.
SECRET = "made-up secret & + % = [x] ’é漢🎵"

# §7.14's list: curly apostrophe, ampersand, plus, percent, '=', brackets,
# a space, accented and non-Latin text and an emoji.
NASTY = [
    ("Guns N’ Roses", "Sweet Child O’ Mine"),
    ("Simon & Garfunkel", "The Sound of Silence"),
    ("C+C Music Factory", "Gonna Make You Sweat (Everybody Dance Now)"),
    ("100% Pure", "50% = half"),
    ("[Brackets]", "a=b&c=d"),
    ("Sigur Rós", "Hoppípolla"),
    ("坂本龍一", "戦場のメリークリスマス"),
    ("Кино", "Группа крови"),
    ("Emoji 🎵 Band", "🔥 Fire 🔥"),
    ("AC/DC", "T.N.T."),
    ("Björk", "Jóga"),
    ("Mötley Crüe", "Kickstart My Heart"),
]


def _expected_signature(pairs: list[tuple[str, str]], secret: str) -> str:
    signed = [(name, value) for name, value in pairs if name != "api_sig"]
    signed.sort(key=lambda pair: pair[0].encode("utf-8"))
    base = b"".join(name.encode("utf-8") + value.encode("utf-8") for name, value in signed)
    return hashlib.md5(base + secret.encode("utf-8")).hexdigest()


def _client(fake: FakeLastfm, secret: str = SECRET) -> LastfmClient:
    from pydantic import SecretStr

    return LastfmClient(make_config(api_secret=SecretStr(secret)), transport=fake.transport)


def _rows():
    rows = []
    for index, (artist, track) in enumerate(NASTY):
        row = {"artist": artist, "track": track, "timestamp": 1700000000 + index}
        if index == 3:
            row["album"] = "Album & Co ’25"
            row["albumArtist"] = "Various Artists"
        if index == 7:
            row["duration"] = 241
        rows.append(row)
    return rows


def test_a_batch_of_twelve_tricky_rows_is_signed_over_the_decoded_body():
    rows = _rows()
    assert len(rows) > 10
    fake = FakeLastfm(
        ok_scrobbles(len(rows), 0, [scrobble_result(r["timestamp"]) for r in rows])
    )

    _client(fake).scrobble(planted.SESSION_KEY, rows)

    pairs = fake.form()
    sent = dict(pairs)
    assert sent["api_sig"] == _expected_signature(pairs, SECRET)
    assert sent["method"] == "track.scrobble"
    planted.assert_secret_equal(sent["sk"], planted.SESSION_KEY, "sk")
    planted.assert_secret_equal(sent["api_key"], planted.API_KEY, "api_key")


def test_rows_are_indexed_from_zero_with_every_index_written():
    rows = _rows()
    fake = FakeLastfm(
        ok_scrobbles(len(rows), 0, [scrobble_result(r["timestamp"]) for r in rows])
    )

    _client(fake).scrobble(planted.SESSION_KEY, rows)

    sent = dict(fake.form())
    for index, row in enumerate(rows):
        assert sent[f"artist[{index}]"] == row["artist"]
        assert sent[f"track[{index}]"] == row["track"]
        assert sent[f"timestamp[{index}]"] == str(row["timestamp"])
    assert sent["album[3]"] == "Album & Co ’25"
    assert sent["albumArtist[3]"] == "Various Artists"
    assert sent["duration[7]"] == "241"
    # Only the fields the rows carry: nothing empty, nothing invented.
    assert "album[0]" not in sent and "albumArtist[0]" not in sent and "duration[0]" not in sent
    assert not any(name.startswith(("chosenByUser", "mbid", "trackNumber")) for name in sent)
    assert "artist" not in sent and "artist[12]" not in sent


def test_byte_order_puts_index_ten_before_index_one_and_album_artist_before_album():
    # A signer that sorts naturally ("artist[1]" < "artist[10]" numerically) or
    # case-insensitively ("album[0]" < "albumArtist[0]") computes a different value.
    rows = _rows()
    fake = FakeLastfm(
        ok_scrobbles(len(rows), 0, [scrobble_result(r["timestamp"]) for r in rows])
    )

    _client(fake).scrobble(planted.SESSION_KEY, rows)

    pairs = fake.form()
    def natural_key(pair):
        base, _, index = pair[0].partition("[")
        return (base.lower(), int(index.rstrip("]")) if index else -1)

    def case_blind_key(pair):
        return pair[0].lower()

    signed = [p for p in pairs if p[0] != "api_sig"]
    for wrong_key in (natural_key, case_blind_key):
        wrong_order = sorted(signed, key=wrong_key)
        assert wrong_order != sorted(signed, key=lambda p: p[0].encode("utf-8"))
        wrong_base = "".join(n + v for n, v in wrong_order) + SECRET
        assert dict(pairs)["api_sig"] != hashlib.md5(wrong_base.encode("utf-8")).hexdigest()
    assert dict(pairs)["api_sig"] == _expected_signature(pairs, SECRET)


def test_now_playing_is_signed_and_carries_no_timestamp_or_index():
    fake = FakeLastfm(ok_now_playing())
    track = {
        "artist": "Guns N’ Roses",
        "track": "a=b&c=d [live] 100% 🎵",
        "album": "坂本 & Co",
        "albumArtist": "Various Artists",
        "duration": 356,
    }

    _client(fake).update_now_playing(planted.SESSION_KEY, track)

    pairs = fake.form()
    sent = dict(pairs)
    assert sent["method"] == "track.updateNowPlaying"
    assert sent["api_sig"] == _expected_signature(pairs, SECRET)
    assert {k: sent[k] for k in track} == {k: str(v) for k, v in track.items()}
    assert "timestamp" not in sent
    assert not any("[" in name for name in sent)


def test_get_session_sends_the_token_and_is_signed():
    fake = FakeLastfm(ok_session("someone", "k"))

    _client(fake).get_session(planted.TOKEN)

    pairs = fake.form()
    sent = dict(pairs)
    assert sorted(sent) == ["api_key", "api_sig", "method", "token"]
    assert sent["method"] == "auth.getSession"
    planted.assert_secret_equal(sent["token"], planted.TOKEN, "token")
    assert sent["api_sig"] == _expected_signature(pairs, SECRET)


def test_sign_matches_the_written_out_algorithm():
    params = {"b": "2", "a": "1 & ’", "B": "Ω", "a[10]": "x", "a[1]": "y"}
    assert sign(params, SECRET) == _expected_signature(list(params.items()), SECRET)
    # api_sig itself is never part of what is signed.
    assert sign({**params, "api_sig": "zzz"}, SECRET) == sign(params, SECRET)


@pytest.mark.parametrize("count", [0, 51])
def test_a_batch_outside_one_to_fifty_rows_is_refused_without_a_request(count):
    fake = FakeLastfm()
    rows = [{"artist": "A", "track": "T", "timestamp": 1700000000 + i} for i in range(count)]

    with pytest.raises(ValueError):
        _client(fake).scrobble(planted.SESSION_KEY, rows)

    assert fake.requests == []


def test_fifty_rows_are_one_request():
    rows = [{"artist": "A", "track": f"T{i}", "timestamp": 1700000000 + i} for i in range(50)]
    fake = FakeLastfm(ok_scrobbles(50, 0, [scrobble_result(r["timestamp"]) for r in rows]))

    _client(fake).scrobble(planted.SESSION_KEY, rows)

    assert len(fake.requests) == 1
    assert dict(fake.form())["track[49]"] == "T49"


@pytest.mark.parametrize(
    "row",
    [
        {"artist": "A", "track": "T", "timestamp": 1, "api_key": "x"},
        {"artist": "A", "track": "T", "timestamp": 1, "sk": "x"},
        {"artist": "A", "track": "T", "timestamp": 1, "chosenByUser": "1"},
        {"artist": "A", "track": "T"},
    ],
    ids=["api_key", "sk", "chosenByUser", "no timestamp"],
)
def test_a_row_with_an_unknown_field_or_no_timestamp_is_refused(row):
    fake = FakeLastfm()

    with pytest.raises(ValueError) as caught:
        _client(fake).scrobble(planted.SESSION_KEY, [row])

    assert fake.requests == []
    planted.assert_no_secret(str(caught.value), "the error message")


@pytest.mark.parametrize(
    "track",
    [
        {"artist": "A", "track": "T", "timestamp": 1},
        {"artist": "A", "track": "T", "method": "auth.getSession"},
    ],
    ids=["timestamp", "method"],
)
def test_now_playing_refuses_fields_it_does_not_send(track):
    fake = FakeLastfm()

    with pytest.raises(ValueError):
        _client(fake).update_now_playing(planted.SESSION_KEY, track)

    assert fake.requests == []


# --- review r1 (S2): text that cannot be sent is refused before any request ----


@pytest.mark.parametrize(
    "call, expected",
    [
        (lambda c: c.scrobble(planted.SESSION_KEY, [{"artist": "A\ud800", "track": "T", "timestamp": 1}]),
         RowRefused),
        (lambda c: c.scrobble(planted.SESSION_KEY, [{"artist": "A", "track": "T", "album": "\udcff", "timestamp": 1}]),
         RowRefused),
        (lambda c: c.update_now_playing(planted.SESSION_KEY, {"artist": "A", "track": "T\ud83d"}), ValueError),
        (lambda c: c.scrobble("sk\ud800", [{"artist": "A", "track": "T", "timestamp": 1}]), ValueError),
        (lambda c: c.get_session("tok\udcff"), ValueError),
    ],
    ids=["artist", "album", "now playing", "session key", "token"],
)
def test_a_value_that_is_not_valid_text_is_refused_without_a_request(call, expected):
    fake = FakeLastfm()

    with pytest.raises(ValueError) as caught:
        call(_client(fake))

    assert fake.requests == []
    # never a UnicodeError carrying the value; a scrobble row is refused as RowRefused (9-R1-40),
    # every other value as a plain ValueError
    assert type(caught.value) is expected
    assert "\ud800" not in str(caught.value) and "\udcff" not in str(caught.value)
    assert caught.value.__context__ is None and caught.value.__cause__ is None
    planted.assert_no_secret(str(caught.value), "the error message")
