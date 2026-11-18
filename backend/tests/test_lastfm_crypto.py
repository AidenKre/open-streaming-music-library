"""9D.1a (spec §7.6, 9-U08b): session keys and approval tokens are stored with
Fernet under ``LASTFM_CREDENTIAL_KEY``. A value that will not decrypt raises one
typed error that carries no secret, no chained cause and no context."""

import logging

import pytest
from cryptography.fernet import Fernet

from app.services.lastfm_crypto import (
    CredentialKeyInvalid,
    CredentialUndecryptable,
    decrypt,
    encrypt,
)
from tests import lastfm_secrets as planted
from tests.lastfm_secrets import assert_no_secret, assert_secret_equal

OTHER_KEY = "b3RoZXItcGxhbnRlZC1jcmVkZW50aWFsLWtleS0zMiE="  # 32 made-up bytes


def _assert_clean(exc: BaseException, extra=()):
    __tracebackhide__ = True
    assert exc.__cause__ is None, "a cause is chained"
    assert exc.__context__ is None, "the original error stays reachable"
    for text, where in ((str(exc), "str(exc)"), (repr(exc), "repr(exc)"), (str(exc.args), "exc.args")):
        assert_no_secret(text, where, secrets=[*extra, *planted.ALL, OTHER_KEY])


@pytest.mark.parametrize("value", [planted.SESSION_KEY, planted.TOKEN, "", "ünïcødé ✓ 🎵"])
def test_a_value_round_trips(value):
    token = encrypt(planted.CREDENTIAL_KEY, value)
    assert_secret_equal(decrypt(planted.CREDENTIAL_KEY, token), value, "decrypted value")


def test_the_stored_form_is_ascii_text_without_the_plaintext_and_never_repeats():
    first = encrypt(planted.CREDENTIAL_KEY, planted.SESSION_KEY)
    second = encrypt(planted.CREDENTIAL_KEY, planted.SESSION_KEY)

    assert isinstance(first, str) and first.isascii()
    assert first != second
    assert_no_secret(first + second, "the stored form")


def test_a_value_under_another_key_is_undecryptable():
    token = encrypt(OTHER_KEY, planted.SESSION_KEY)
    with pytest.raises(CredentialUndecryptable) as info:
        decrypt(planted.CREDENTIAL_KEY, token)
    _assert_clean(info.value, [token])


@pytest.mark.parametrize(
    "token",
    [
        "",
        "planted-not-a-token",
        "ünïcødé",
        "gAAAAA" + "A" * 80,
    ],
)
def test_a_malformed_value_is_undecryptable(token):
    with pytest.raises(CredentialUndecryptable) as info:
        decrypt(planted.CREDENTIAL_KEY, token)
    _assert_clean(info.value, [token] if token else [])


def test_a_tampered_value_is_undecryptable():
    token = encrypt(planted.CREDENTIAL_KEY, planted.SESSION_KEY)
    tampered = token[:-6] + ("AAAAAA" if not token.endswith("AAAAAA") else "BBBBBB")
    with pytest.raises(CredentialUndecryptable) as info:
        decrypt(planted.CREDENTIAL_KEY, tampered)
    _assert_clean(info.value)


def test_a_plaintext_that_is_not_utf8_is_undecryptable():
    token = Fernet(planted.CREDENTIAL_KEY.encode()).encrypt(b"\xff\xfe planted").decode()
    with pytest.raises(CredentialUndecryptable) as info:
        decrypt(planted.CREDENTIAL_KEY, token)
    _assert_clean(info.value)


@pytest.mark.parametrize("bad_key", ["planted-bad-fernet-key", "", planted.CREDENTIAL_KEY[:-4]])
def test_a_bad_key_raises_a_typed_error_without_the_key(bad_key):
    with pytest.raises(CredentialKeyInvalid) as info:
        encrypt(bad_key, planted.SESSION_KEY)
    _assert_clean(info.value, [bad_key] if bad_key else [])
    with pytest.raises(CredentialKeyInvalid) as info:
        decrypt(bad_key, "planted-not-a-token")
    _assert_clean(info.value, [bad_key] if bad_key else [])


def test_failures_log_nothing(caplog):
    caplog.set_level(logging.DEBUG)
    for call in (
        lambda: decrypt(planted.CREDENTIAL_KEY, "planted-not-a-token"),
        lambda: decrypt(OTHER_KEY, encrypt(planted.CREDENTIAL_KEY, planted.SESSION_KEY)),
        lambda: encrypt("planted-bad-fernet-key", planted.SESSION_KEY),
    ):
        with pytest.raises((CredentialUndecryptable, CredentialKeyInvalid)):
            call()
    assert caplog.records == []


# ── review r1: no hidden context, no untyped escape ─────────────────────────


@pytest.mark.parametrize(
    "call",
    [
        lambda: decrypt(planted.CREDENTIAL_KEY, "planted-not-a-token"),
        lambda: decrypt(planted.CREDENTIAL_KEY, "ünïcødé"),
        lambda: decrypt(
            planted.CREDENTIAL_KEY,
            Fernet(planted.CREDENTIAL_KEY.encode()).encrypt(b"\xff planted").decode(),
        ),
        lambda: decrypt("planted-bad-fernet-key", "x"),
        lambda: encrypt("planted-bad-fernet-key", "x"),
    ],
)
def test_errors_keep_no_context(call):
    with pytest.raises((CredentialUndecryptable, CredentialKeyInvalid)) as info:
        call()
    assert info.value.__context__ is None, "the original error stays reachable"


def test_a_plaintext_that_cannot_be_encoded_raises_without_it():
    plaintext = "planted\ud800surrogate"
    with pytest.raises(ValueError) as info:
        encrypt(planted.CREDENTIAL_KEY, plaintext)
    assert not isinstance(info.value, UnicodeError), "the encode error carries the plaintext"
    assert info.value.__context__ is None and info.value.__cause__ is None
    assert_no_secret(str(info.value) + repr(info.value), "the error", secrets=["planted\ud800surrogate", "surrogate"])
