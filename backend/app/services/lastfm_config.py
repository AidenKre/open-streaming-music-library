"""Last.fm operator settings, checked. Never puts a setting's value in a result."""

import base64
import ipaddress
import re
import unicodedata
from dataclasses import dataclass, field
from pathlib import Path
from urllib.parse import urlsplit

from cryptography.fernet import Fernet
from pydantic import SecretStr

from app.core.secret_file import (
    SecretFileUnreadable,
    read_secret_file,
    warn_if_group_or_world_readable,
)

DEFAULT_API_URL = "https://ws.audioscrobbler.com/2.0/"
APP_NAME_MAX = 100

_TRUE = {"true", "1", "yes", "on", "t", "y"}
_FALSE = {"false", "0", "no", "off", "f", "n"}


@dataclass(frozen=True)
class LastfmOff:
    switch_unparseable: bool


@dataclass(frozen=True)
class LastfmInvalid:
    setting: str
    problem: str


@dataclass(frozen=True)
class LastfmConfig:
    api_key: SecretStr = field(repr=False)
    api_secret: SecretStr = field(repr=False)
    credential_key: SecretStr = field(repr=False)
    settle_delay_s: int
    min_request_gap_s: int
    api_url: str = DEFAULT_API_URL
    insecure_api_url: bool = False
    app_name: str | None = None
    app_name_ignored: bool = False


def _whole_seconds(
    settings, name: str, default: int, low: int, high: int
) -> int | LastfmInvalid:
    text = (getattr(settings, name.lower()) or "").strip()
    if not text:
        return default
    if re.fullmatch(r"[0-9]{1,9}", text, re.ASCII):
        number = int(text)
        if low <= number <= high:
            return number
    return LastfmInvalid(name, f"must be a whole number of seconds from {low} to {high}")


def _check_secret(name: str, value: str) -> str | None:
    """The fixed problem text for a bad value, or None."""
    if name in ("LASTFM_API_KEY", "LASTFM_API_SECRET"):
        try:
            value.encode("utf-8")
        except UnicodeEncodeError:
            return "is not valid UTF-8 text"
    if name == "LASTFM_API_KEY":
        return None if len(value) == 32 else "must be 32 characters"
    if name == "LASTFM_API_SECRET":
        return None if value else "must not be empty"
    try:
        # Fernet alone accepts a lenient base64 decoding; require the canonical form.
        if base64.urlsafe_b64encode(base64.urlsafe_b64decode(value)) != value.encode("ascii"):
            raise ValueError
        Fernet(value)
    except Exception:
        return "is not a valid Fernet key"
    return None


def _secret(settings, name: str) -> str | LastfmInvalid:
    plain = getattr(settings, name.lower())
    plain = plain.get_secret_value() if plain is not None else ""
    if not plain.strip():
        plain = ""
    file_setting = f"{name}_FILE"
    file_value = (getattr(settings, file_setting.lower()) or "").strip()
    if plain and file_value:
        return LastfmInvalid(file_setting, f"is set together with {name}; set only one")
    if file_value:
        path = Path(file_value)
        try:
            value = read_secret_file(path)
        except SecretFileUnreadable as e:
            return LastfmInvalid(file_setting, str(e))
        warn_if_group_or_world_readable(path, "a Last.fm secret")
        reported = file_setting
    else:
        if not plain:
            return LastfmInvalid(name, "is not set")
        value, reported = plain, name
    problem = _check_secret(name, value)
    return LastfmInvalid(reported, problem) if problem else value


def _app_name(settings) -> tuple[str | None, bool]:
    """(name, ignored): a bad name is ignored, never fatal."""
    name = (settings.lastfm_app_name or "").strip()
    if not name:
        return None, False
    if len(name) > APP_NAME_MAX or any(
        unicodedata.category(c) in ("Cc", "Cs", "Cf", "Zl", "Zp") for c in name
    ):
        return None, True
    return name, False


def _is_loopback_url(url: str) -> bool:
    if not url.isprintable() or any(c.isspace() for c in url):
        return False
    try:
        parts = urlsplit(url)
        parts.port  # raises ValueError for a bad port
        if (
            parts.scheme not in ("http", "https")
            or parts.username is not None
            or parts.password is not None
            or parts.query
            or parts.fragment
        ):
            return False
        return ipaddress.ip_address(parts.hostname or "").is_loopback
    except ValueError:
        return False


def _api_url(settings) -> tuple[str, bool] | LastfmInvalid:
    url = (settings.osml_insecure_lastfm_api_url or "").strip()
    if not url:
        return DEFAULT_API_URL, False
    if _is_loopback_url(url):
        return url, True
    return LastfmInvalid(
        "OSML_INSECURE_LASTFM_API_URL",
        "must be an http(s) URL on a loopback IP address",
    )


def resolve_lastfm_config(settings) -> LastfmConfig | LastfmOff | LastfmInvalid:
    switch = (settings.lastfm_enabled or "").strip().lower()
    if switch in _FALSE or not switch:
        return LastfmOff(switch_unparseable=False)
    if switch not in _TRUE:
        return LastfmOff(switch_unparseable=True)

    secrets = [
        _secret(settings, name)
        for name in ("LASTFM_API_KEY", "LASTFM_API_SECRET", "LASTFM_CREDENTIAL_KEY")
    ]
    numbers = [
        _whole_seconds(settings, "LASTFM_SETTLE_DELAY_S", 60, 0, 3600),
        _whole_seconds(settings, "LASTFM_MIN_REQUEST_GAP_S", 5, 1, 30),
    ]
    url = _api_url(settings)
    app_name, app_name_ignored = _app_name(settings)
    for result in (*secrets, *numbers, url):
        if isinstance(result, LastfmInvalid):
            return result
    api_key, api_secret, credential_key = secrets
    settle, gap = numbers
    return LastfmConfig(
        api_key=SecretStr(api_key),
        api_secret=SecretStr(api_secret),
        credential_key=SecretStr(credential_key),
        settle_delay_s=settle,
        min_request_gap_s=gap,
        api_url=url[0],
        insecure_api_url=url[1],
        app_name=app_name,
        app_name_ignored=app_name_ignored,
    )
