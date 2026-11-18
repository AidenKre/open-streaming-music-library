"""9D.1a (spec §7.6, §7.9, 9-U08b): the one path by which Last.fm request or
reply data reaches a log. It blanks the actual secret values of the request
wherever they appear (a session key that is not hex included), never logs the
body of an ``auth.*`` reply, logs at most 4 KiB of any other reply, and logs an
HTTP-client exception by its class only."""

import logging
from urllib.parse import quote, quote_plus

import pytest
from pydantic import SecretStr

from app.core.operator_log import operator_logger
from app.services.lastfm_config import LastfmConfig
from app.services.lastfm_log import (
    REPLY_EXCERPT_LIMIT,
    log_exception,
    log_request_failure,
    redact,
    request_secrets,
)
from tests import lastfm_secrets as planted
from tests.lastfm_secrets import assert_no_secret


def _config() -> LastfmConfig:
    return LastfmConfig(
        api_key=SecretStr(planted.API_KEY),
        api_secret=SecretStr(planted.API_SECRET),
        credential_key=SecretStr(planted.CREDENTIAL_KEY),
        settle_delay_s=60,
        min_request_gap_s=5,
    )


def _body() -> dict[str, str]:
    return {
        "method": "track.scrobble",
        "api_key": planted.API_KEY,
        "sk": planted.SESSION_KEY,
        "token": planted.TOKEN,
        "api_sig": planted.API_SIG,
        "artist[0]": "Björk",
    }


def _encoded_forms(secrets):
    forms = []
    for s in secrets:
        forms += [s, quote_plus(s), quote(s, safe="")]
    return forms


# ── request_secrets ─────────────────────────────────────────────────────────


def test_the_request_secrets_are_the_config_secrets_and_the_body_credentials():
    secrets = set(request_secrets(_config(), _body()))
    missing = [i for i, s in enumerate(planted.ALL) if s not in secrets]
    assert missing == [], f"planted secrets #{missing} are not listed"
    assert "Björk" not in secrets
    assert "track.scrobble" not in secrets


def test_request_secrets_works_without_a_body():
    secrets = set(request_secrets(_config(), None))
    expected = (planted.API_KEY, planted.API_SECRET, planted.CREDENTIAL_KEY)
    assert all(s in secrets for s in expected), "a config secret is not listed"


# ── redact ──────────────────────────────────────────────────────────────────


def test_every_secret_is_blanked_wherever_it_appears():
    text = " | ".join(
        [
            f"sk={planted.SESSION_KEY}&sk={planted.SESSION_KEY}{planted.SESSION_KEY}",
            f"<key>{planted.API_KEY}</key>",
            f"secret {planted.API_SECRET} again {planted.API_SECRET}",
            f"fernet {planted.CREDENTIAL_KEY}",
            f"token={planted.TOKEN}",
            f"api_sig={planted.API_SIG}",
            "artist=Björk",
        ]
    )

    out = redact(text, request_secrets(_config(), _body()))

    assert_no_secret(out, "redacted text", secrets=_encoded_forms(planted.ALL))
    assert "artist=Björk" in out
    assert "[redacted]" in out


def test_form_encoded_secrets_are_blanked_too():
    body = "&".join(f"{quote_plus(k)}={quote_plus(v)}" for k, v in _body().items())
    body += f"&secret={quote_plus(planted.API_SECRET)}&pct={quote(planted.SESSION_KEY, safe='')}"

    out = redact(body, request_secrets(_config(), _body()))

    assert_no_secret(out, "redacted body", secrets=_encoded_forms(planted.ALL))
    assert "artist%5B0%5D=Bj%C3%B6rk" in out


@pytest.mark.parametrize(
    "secret",
    [
        planted.SESSION_KEY,  # regex and %-format characters, not hex
        ".*",
        "%s%d{0}{}",
        "\\1\\g<0>",
        "$&",
    ],
)
def test_regex_and_format_characters_are_matched_literally(secret):
    text = f"a {secret} b {secret}"
    out = redact(text, [secret])
    assert_no_secret(out, "redacted text", secrets=[secret])
    assert out.startswith("a ") and " b " in out


def test_a_secret_inside_a_longer_one_does_not_expose_the_longer_one():
    long, short = "planted-outer-SECRET-value", "SECRET"
    out = redact(f"x {long} y {short} z", [short, long])
    assert_no_secret(out, "redacted text", secrets=[long, short, "planted-outer", "-value"])


@pytest.mark.parametrize("empty", [None, ""])
def test_empty_or_missing_secrets_are_ignored(empty):
    assert redact("plain text", [empty, planted.TOKEN]) == "plain text"


# ── log_request_failure ─────────────────────────────────────────────────────


def _reply_with_every_secret(padding: int = 0) -> str:
    return (
        "x" * padding
        + f"<lfm status='failed'><error code='13'>Invalid signature {planted.API_SIG} "
        + f"for {planted.API_KEY} sk {planted.SESSION_KEY} token {planted.TOKEN} "
        + f"secret {quote_plus(planted.API_SECRET)} key {planted.CREDENTIAL_KEY}</error></lfm>"
    )


def test_a_failed_request_is_logged_redacted_with_status_and_code(caplog):
    caplog.set_level(logging.DEBUG)

    log_request_failure(
        "track.scrobble",
        status=200,
        error_code=13,
        reply=_reply_with_every_secret(),
        secrets=request_secrets(_config(), _body()),
    )

    assert len(caplog.records) == 1
    record = caplog.records[0]
    assert record.name == operator_logger.name
    assert record.levelno == logging.WARNING
    message = record.getMessage()
    assert "track.scrobble" in message
    assert "200" in message and "13" in message
    assert "Invalid signature" in message
    assert record.exc_info is None
    assert_no_secret(caplog.text, "captured logs", secrets=_encoded_forms(planted.ALL))


def test_the_reply_excerpt_is_at_most_4_kib(caplog):
    caplog.set_level(logging.DEBUG)
    reply = "<lfm>" + "é" * 20_000 + "MARKER-AT-THE-END</lfm>"

    log_request_failure("track.scrobble", status=500, error_code=None, reply=reply, secrets=[])

    message = caplog.records[0].getMessage()
    assert REPLY_EXCERPT_LIMIT == 4096
    assert "MARKER-AT-THE-END" not in message
    assert len(message.encode("utf-8")) < 4096 + 512


def test_a_secret_cut_by_the_4_kib_limit_is_not_partly_shown(caplog):
    caplog.set_level(logging.DEBUG)
    # Every secret of the reply straddles the 4 KiB cut for some padding.
    for padding in range(3700, 4100):
        caplog.clear()
        log_request_failure(
            "track.scrobble",
            status=200,
            error_code=13,
            reply=_reply_with_every_secret(padding),
            secrets=request_secrets(_config(), _body()),
        )
        prefixes = [s[:12] for s in planted.ALL]
        assert_no_secret(caplog.text, f"captured logs (padding {padding})", secrets=prefixes)


def test_a_bytes_reply_that_is_not_utf8_is_still_redacted(caplog):
    caplog.set_level(logging.DEBUG)
    reply = b"\xff\xfe" + _reply_with_every_secret().encode("utf-8") + b"\xc3"

    log_request_failure(
        "track.updateNowPlaying", status=200, error_code=13, reply=reply,
        secrets=request_secrets(_config(), _body()),
    )

    assert len(caplog.records) == 1
    assert_no_secret(caplog.text, "captured logs", secrets=_encoded_forms(planted.ALL))


@pytest.mark.parametrize("method", ["auth.getToken", "auth.getSession", "AUTH.getSession"])
def test_an_auth_reply_body_is_never_logged(caplog, method):
    caplog.set_level(logging.DEBUG)
    reply = "<lfm status='ok'><session><name>planted-account</name><key>NOT-A-LISTED-SECRET-123</key></session></lfm>"

    log_request_failure(method, status=200, error_code=None, reply=reply, secrets=[])

    message = caplog.records[0].getMessage()
    assert method in message
    assert_no_secret(caplog.text, "captured logs", secrets=["NOT-A-LISTED-SECRET-123", "planted-account"])


def test_no_reply_logs_without_an_excerpt(caplog):
    caplog.set_level(logging.DEBUG)
    log_request_failure("track.scrobble", status=None, error_code=None, reply=None, secrets=[])
    assert len(caplog.records) == 1
    assert "track.scrobble" in caplog.records[0].getMessage()


# ── log_exception ───────────────────────────────────────────────────────────


class PlantedTransportError(Exception):
    pass


def test_an_http_exception_is_logged_by_its_class_only(caplog):
    caplog.set_level(logging.DEBUG)
    url = f"https://ws.audioscrobbler.com/2.0/?api_key={planted.API_KEY}&sk={planted.SESSION_KEY}"
    try:
        try:
            raise ValueError(f"inner {planted.TOKEN}")
        except ValueError as inner:
            raise PlantedTransportError(f"failed {url}") from inner
    except PlantedTransportError as exc:
        log_exception("track.scrobble", exc)

    assert len(caplog.records) == 1
    record = caplog.records[0]
    assert record.name == operator_logger.name
    assert record.exc_info is None
    assert "PlantedTransportError" in record.getMessage()
    assert "track.scrobble" in record.getMessage()
    assert "ws.audioscrobbler.com" not in caplog.text
    assert "ValueError" not in caplog.text
    assert_no_secret(caplog.text, "captured logs")


# ── review r1: more encoded forms ───────────────────────────────────────────

AWKWARD = "planted-SESSION key/+&<x>=ab\"'%"


@pytest.mark.parametrize(
    "form",
    [
        AWKWARD,
        quote_plus(AWKWARD),
        quote(AWKWARD, safe=""),
        quote(AWKWARD),  # "/" left as is
        quote(AWKWARD, safe="").replace("%2F", "%2f").replace("%3C", "%3c"),
        "planted-SESSION key/+&amp;&lt;x&gt;=ab&quot;&apos;%",  # XML escaped
        "planted-SESSION key/+&amp;&lt;x&gt;=ab\"'%",
    ],
)
def test_redact_blanks_partly_encoded_lowercase_and_xml_escaped_forms(form):
    out = redact(f"<lfm>{form}</lfm>", [AWKWARD])
    assert_no_secret(out, "redacted text", secrets=[form])


# 9-fix-r1 (9-R1-22): a reply cannot forge operator-log lines.


def _line_breaking(message: str) -> list[str]:
    import unicodedata

    return [c for c in message if unicodedata.category(c) in ("Cc", "Zl", "Zp")]


def test_r1_control_characters_in_a_reply_are_escaped_not_logged(caplog):
    caplog.set_level(logging.DEBUG)
    reply = "<lfm>bad\nERROR fake line\r\nWARNING other\x1b[31m  \x85\x00end</lfm>"

    log_request_failure("track.scrobble", status=500, error_code=None, reply=reply, secrets=[])

    message = caplog.records[0].getMessage()
    assert _line_breaking(message) == []
    assert "ERROR fake line" in message and "end</lfm>" in message


def test_r1_an_escaped_excerpt_still_respects_the_4_kib_limit(caplog):
    caplog.set_level(logging.DEBUG)

    log_request_failure("track.scrobble", status=500, error_code=None, reply="\x01" * 20_000, secrets=[])

    message = caplog.records[0].getMessage()
    assert _line_breaking(message) == []
    assert len(message.encode("utf-8")) < 4096 + 512


def test_r1_secrets_next_to_control_characters_are_still_redacted(caplog):
    caplog.set_level(logging.DEBUG)
    reply = f"<lfm>{planted.SESSION_KEY}\n{planted.API_KEY}</lfm>"

    log_request_failure(
        "track.scrobble", status=500, error_code=None, reply=reply,
        secrets=request_secrets(_config(), _body()),
    )

    assert_no_secret(caplog.text, "captured logs", secrets=_encoded_forms(planted.ALL))
