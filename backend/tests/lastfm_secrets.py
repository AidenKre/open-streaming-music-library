"""Made-up Last.fm secrets for tests, and a leak check that never prints them.

No value here is a real Last.fm credential. A failing check reports only
"secret leaked into <where>", so a test failure message cannot itself print
the secret (pytest's assertion diff would).
"""

from collections.abc import Iterable

import base64

# 32 characters, deliberately not hex.
API_KEY = "plantedApiKey-ZZ-not-a-real-key!"
API_SECRET = "planted-shared-secret-Q9%s{0}.*"
# Deterministic (pytest-xdist workers must collect the same parameters).
CREDENTIAL_KEY = base64.urlsafe_b64encode(b"planted-credential-key-32-bytes!").decode("ascii")
# A session key that is not hex, with regex and format characters in it.
SESSION_KEY = "planted-SESSION_key.+*?[](){}%d\\"
TOKEN = "plantedApprovalToken-0123456789z"
API_SIG = "plantedsignature00000000000000ff"

assert len(API_KEY) == 32

ALL = (API_KEY, API_SECRET, CREDENTIAL_KEY, SESSION_KEY, TOKEN, API_SIG)


def assert_no_secret(text: str, where: str, secrets: Iterable[str] = ALL) -> None:
    __tracebackhide__ = True
    for index, secret in enumerate(secrets):
        if secret and secret in text:
            raise AssertionError(f"secret #{index} leaked into {where}")


def assert_secret_equal(actual, expected: str, what: str) -> None:
    """Equality without pytest's diff, which would print both values."""
    __tracebackhide__ = True
    if actual != expected:
        raise AssertionError(f"{what} differs from the planted value")


def valid_env(**overrides: str) -> dict[str, str]:
    """A complete, valid enabled configuration as environment variables."""
    env = {
        "LASTFM_ENABLED": "true",
        "LASTFM_API_KEY": API_KEY,
        "LASTFM_API_SECRET": API_SECRET,
        "LASTFM_CREDENTIAL_KEY": CREDENTIAL_KEY,
        # 9D.2b: no app test starts a sender whose client would use the real
        # Last.fm URL; the sender's own app tests turn it on with a fake class.
        "ENABLE_LASTFM_SENDER": "false",
    }
    env.update(overrides)
    return env


LASTFM_ENV = (
    "LASTFM_ENABLED",
    "LASTFM_API_KEY",
    "LASTFM_API_KEY_FILE",
    "LASTFM_API_SECRET",
    "LASTFM_API_SECRET_FILE",
    "LASTFM_CREDENTIAL_KEY",
    "LASTFM_CREDENTIAL_KEY_FILE",
    "LASTFM_SETTLE_DELAY_S",
    "LASTFM_MIN_REQUEST_GAP_S",
    "LASTFM_APP_NAME",
    "OSML_INSECURE_LASTFM_API_URL",
)
