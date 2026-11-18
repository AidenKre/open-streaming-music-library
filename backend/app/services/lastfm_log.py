"""The one path by which Last.fm request and reply data reaches a log.

Every Last.fm request or reply datum, and every client exception, reaches a
log only through this module. Pass ``request_secrets(config, body)`` of the
request being logged as ``secrets``. Replies to ``auth.*`` methods are never
logged, other replies are redacted and cut to ``REPLY_EXCERPT_LIMIT`` bytes,
and an exception is logged by its class only (its message can hold a URL).
"""

import re
import unicodedata
from collections.abc import Iterable, Mapping
from urllib.parse import quote, quote_plus
from xml.sax.saxutils import escape

from app.core.operator_log import operator_logger
from app.services.lastfm_config import LastfmConfig

REPLY_EXCERPT_LIMIT = 4096
_BODY_CREDENTIALS = ("api_key", "sk", "token", "api_sig")


def request_secrets(config: LastfmConfig, body: Mapping[str, str] | None) -> list[str]:
    secrets = [
        config.api_key.get_secret_value(),
        config.api_secret.get_secret_value(),
        config.credential_key.get_secret_value(),
    ]
    for name in _BODY_CREDENTIALS:
        value = (body or {}).get(name)
        if value:
            secrets.append(value)
    return secrets


_PERCENT_ESCAPE = re.compile(r"(%[0-9A-Fa-f]{2})")


def _forms(secret: str) -> set[str]:
    return {
        secret,
        quote_plus(secret),
        quote(secret, safe=""),
        quote(secret),
        escape(secret),
        escape(secret, {'"': "&quot;", "'": "&apos;"}),
    }


def _pattern(form: str) -> re.Pattern[str]:
    """Match our own encoded form literally, with each %XX in either hex case."""
    parts = []
    for piece in _PERCENT_ESCAPE.split(form):
        if _PERCENT_ESCAPE.fullmatch(piece):
            parts.append("%" + "".join(f"[{c.lower()}{c.upper()}]" for c in piece[1:]))
        else:
            parts.append(re.escape(piece))
    return re.compile("".join(parts))


def redact(text: str, secrets: Iterable[str | None]) -> str:
    forms = {form for secret in secrets if secret for form in _forms(secret)}
    for form in sorted(forms, key=len, reverse=True):
        if "%" in form:
            text = _pattern(form).sub("[redacted]", text)
        else:
            text = text.replace(form, "[redacted]")
    return text


def _escape_controls(text: str) -> str:
    """Control and line/paragraph separator characters as \\xNN or \\uNNNN, so a reply
    cannot forge a log line."""
    return "".join(
        (f"\\x{ord(c):02x}" if ord(c) <= 0xFF else f"\\u{ord(c):04x}")
        if unicodedata.category(c) in ("Cc", "Zl", "Zp")
        else c
        for c in text
    )


def log_request_failure(
    method: str,
    *,
    status: int | None,
    error_code: int | None,
    reply: str | bytes | None,
    secrets: Iterable[str | None],
) -> None:
    if reply is None or method.lower().startswith("auth."):
        operator_logger.warning(
            "Last.fm %s failed: HTTP status %s, error code %s", method, status, error_code
        )
        return
    if isinstance(reply, bytes):
        reply = reply.decode("utf-8", errors="replace")
    excerpt = _escape_controls(redact(reply, secrets)).encode("utf-8")[:REPLY_EXCERPT_LIMIT]
    operator_logger.warning(
        "Last.fm %s failed: HTTP status %s, error code %s, reply: %s",
        method,
        status,
        error_code,
        excerpt.decode("utf-8", errors="ignore"),
    )


def log_exception(method: str, exc: BaseException) -> None:
    operator_logger.warning("Last.fm %s failed: %s", method, type(exc).__name__)
