"""9D.1c: reading Last.fm's XML replies (spec §7.8, 9-U09 client).

"Replies are parsed with `defusedxml` (DTDs forbidden), matching names
case-insensitively. If a body fails to parse, characters that are illegal in
XML are removed and it is parsed once more." A body that still cannot be read
is a try-later answer (§7.9 kind 2).
"""

import pytest

from app.services.lastfm_client import AnswerKind, LastfmClient
from tests import lastfm_secrets as planted
from tests.lastfm_fake import FakeLastfm, make_config, ok_now_playing, ok_session, ok_token, xml_reply


def _client(fake: FakeLastfm) -> LastfmClient:
    return LastfmClient(make_config(), transport=fake.transport)


def test_a_token_is_read_from_an_ok_reply():
    fake = FakeLastfm(ok_token("cf45fe5a3e3cebe168480a086d7fe481"))

    result = _client(fake).get_token()

    assert result.answer.kind is AnswerKind.OK
    assert result.answer.http_status == 200
    assert result.token == "cf45fe5a3e3cebe168480a086d7fe481"


def test_a_session_is_read_from_an_ok_reply():
    fake = FakeLastfm(ok_session("MyLastFMUsername", "d580d57f32848f5dcf574d1ce18d78b2"))

    result = _client(fake).get_session(planted.TOKEN)

    assert result.answer.kind is AnswerKind.OK
    assert result.account_name == "MyLastFMUsername"
    assert result.session_key == "d580d57f32848f5dcf574d1ce18d78b2"


def test_now_playing_ok_is_ok():
    fake = FakeLastfm(ok_now_playing())

    answer = _client(fake).update_now_playing(planted.SESSION_KEY, {"artist": "A", "track": "T"})

    assert answer.kind is AnswerKind.OK


def test_names_and_status_are_matched_case_insensitively():
    fake = FakeLastfm(
        xml_reply('<LFM Status="OK"><Session><NAME>someone</NAME><Key>k1</Key></Session></LFM>')
    )

    result = _client(fake).get_session(planted.TOKEN)

    assert result.answer.kind is AnswerKind.OK
    assert (result.account_name, result.session_key) == ("someone", "k1")


@pytest.mark.parametrize(
    "body",
    [
        # An internal entity: a DTD-free parser would substitute it.
        '<?xml version="1.0"?><!DOCTYPE lfm [<!ENTITY t "fromdtd">]>'
        '<lfm status="ok"><token>&t;</token></lfm>',
        # A bare DOCTYPE: still a DTD, still refused.
        '<?xml version="1.0"?><!DOCTYPE lfm><lfm status="ok"><token>abc</token></lfm>',
        # An external entity.
        '<?xml version="1.0"?><!DOCTYPE lfm [<!ENTITY x SYSTEM "file:///etc/hosts">]>'
        '<lfm status="ok"><token>&x;</token></lfm>',
        # Billion laughs.
        '<?xml version="1.0"?><!DOCTYPE lfm [<!ENTITY a "aaaaaaaaaa">'
        '<!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;"><!ENTITY c "&b;&b;&b;&b;&b;&b;&b;&b;&b;&b;">'
        '<!ENTITY d "&c;&c;&c;&c;&c;&c;&c;&c;&c;&c;">]><lfm status="ok"><token>&d;</token></lfm>',
    ],
    ids=["internal entity", "bare doctype", "external entity", "billion laughs"],
)
def test_a_reply_with_a_dtd_is_refused(body):
    fake = FakeLastfm(xml_reply(body))

    result = _client(fake).get_token()

    assert result.answer.kind is AnswerKind.TRY_LATER
    assert result.token is None
    assert len(fake.requests) == 1


def test_illegal_xml_characters_are_stripped_on_a_second_parse():
    # Raw control characters (Last.fm has been seen to echo them) break a strict parser.
    fake = FakeLastfm(
        xml_reply(
            '<?xml version="1.0" encoding="utf-8"?>\n<lfm status="ok"><session>'
            "<name>so\x01me\x08o\x1fne\x00</name><key>k\x0b2</key></session></lfm>"
        )
    )

    result = _client(fake).get_session(planted.TOKEN)

    assert result.answer.kind is AnswerKind.OK
    assert result.account_name == "someone"
    assert result.session_key == "k2"
    assert len(fake.requests) == 1


def test_legal_whitespace_characters_survive_the_retry():
    fake = FakeLastfm(
        xml_reply('<lfm status="ok"><session><name>a\tb\x01</name><key>k</key></session></lfm>')
    )

    result = _client(fake).get_session(planted.TOKEN)

    assert result.account_name == "a\tb"


@pytest.mark.parametrize(
    "body",
    [
        "",
        "not xml at all",
        "<lfm status='ok'><token>abc</token>",  # truncated
        "<html><body>Bad gateway</body></html>",
        '<lfm status="ok"></lfm>',  # ok but no token
        '<lfm status="ok"><token></token></lfm>',  # ok but an empty token
        '<lfm status="ok"><token>  </token></lfm>',
        '<lfm><token>abc</token></lfm>',  # no status
        '<lfm status="maybe"><token>abc</token></lfm>',
    ],
    ids=["empty", "text", "truncated", "html", "no token", "empty token", "blank token", "no status", "odd status"],
)
def test_a_200_that_cannot_be_read_as_a_token_is_try_later(body):
    fake = FakeLastfm(xml_reply(body))

    result = _client(fake).get_token()

    assert result.answer.kind is AnswerKind.TRY_LATER
    assert result.answer.http_status == 200
    assert result.token is None


@pytest.mark.parametrize(
    "session",
    [
        "<session><name>someone</name></session>",
        "<session><key>k</key></session>",
        "<session><name>someone</name><key></key></session>",
        "",
    ],
    ids=["no key", "no name", "empty key", "no session"],
)
def test_an_ok_session_reply_without_a_name_and_key_is_try_later(session):
    fake = FakeLastfm(xml_reply(f'<lfm status="ok">{session}</lfm>'))

    result = _client(fake).get_session(planted.TOKEN)

    assert result.answer.kind is AnswerKind.TRY_LATER
    assert result.session_key is None and result.account_name is None


def test_the_answer_reprs_never_show_a_token_or_session_key():
    fake = FakeLastfm(ok_token(planted.TOKEN), ok_session("someone", planted.SESSION_KEY))
    client = _client(fake)

    token = client.get_token()
    session = client.get_session(planted.TOKEN)

    planted.assert_secret_equal(token.token, planted.TOKEN, "token")
    planted.assert_secret_equal(session.session_key, planted.SESSION_KEY, "session key")
    for shown in (repr(token), str(token), repr(session), str(session)):
        planted.assert_no_secret(shown, "a repr")


# --- review r1 (C1/S1, C6): replies that must never escape the client ----------


@pytest.mark.parametrize(
    "encoding", ["bogus", "utf-7", "shift_jis", "utf-32", "rot13", "hex", "idna", "punycode", "undefined"]
)
@pytest.mark.parametrize(
    ("body", "kind"),
    [
        ('<lfm status="ok"><token>abc</token></lfm>', AnswerKind.OK),
        ('<lfm status="failed"><error code="11">x</error></lfm>', AnswerKind.TRY_LATER),
        ('<lfm status="failed"><error code="26">x</error></lfm>', AnswerKind.STOP),
    ],
    ids=["ok", "try later", "stop"],
)
def test_a_reply_declaring_an_unusable_encoding_is_read_as_utf8_on_the_retry(encoding, body, kind):
    fake = FakeLastfm(xml_reply(f'<?xml version="1.0" encoding="{encoding}"?>{body}'))

    result = _client(fake).get_token()

    assert result.answer.kind is kind


def test_numeric_references_to_illegal_characters_are_stripped_on_the_retry():
    fake = FakeLastfm(
        xml_reply('<lfm status="ok"><session><name>so&#1;me&#x1F;one&#0;</name><key>k&#x0b;2</key></session></lfm>')
    )

    result = _client(fake).get_session(planted.TOKEN)

    assert result.answer.kind is AnswerKind.OK
    assert (result.account_name, result.session_key) == ("someone", "k2")


def test_numeric_references_to_legal_characters_are_kept():
    fake = FakeLastfm(
        xml_reply('<lfm status="ok"><session><name>Bj&#246;rk&#x1;&#38;Co</name><key>k</key></session></lfm>')
    )

    result = _client(fake).get_session(planted.TOKEN)

    assert result.account_name == "Björk&Co"
