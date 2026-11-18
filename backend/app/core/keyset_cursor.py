"""Opaque keyset cursors shared by every keyset list.

A cursor is a base64url-encoded JSON array holding the last row's sort key.
Keys must hold only bounded values (ints, finite floats, UUIDs, bounded strings); see review
7-R1-03. Malformed cursors are a 422 invalid_cursor (SC-22 envelope).
"""

import base64
import binascii
import json
import math
from uuid import UUID

from fastapi import HTTPException

from app.core.api_errors import api_error


def invalid_cursor() -> HTTPException:
    return api_error(
        422, "invalid_cursor", "The page cursor is not valid.", retryable=False
    )


# Real cursors are well under 200 characters.
MAX_CURSOR_CHARS = 512


def encode_cursor(key: list) -> str:
    raw = json.dumps(key, separators=(",", ":")).encode()
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def decode_cursor(text: str, kinds: tuple[str, ...]) -> tuple:
    """Decode a cursor whose key has the given kinds ("int", "float" (finite),
    "str", "uuid"; "str?" also allows null: a key too long to carry, resolved by
    the caller from the cursor's own row). Anything malformed is a 422
    invalid_cursor."""
    if len(text) > MAX_CURSOR_CHARS:
        raise invalid_cursor()
    try:
        raw = base64.b64decode(
            text + "=" * (-len(text) % 4), altchars=b"-_", validate=True
        )
        key = json.loads(raw)
    except (binascii.Error, ValueError, UnicodeError, RecursionError):
        raise invalid_cursor() from None
    if not isinstance(key, list) or len(key) != len(kinds):
        raise invalid_cursor()
    out = []
    for value, kind in zip(key, kinds):
        if kind == "int" and type(value) is int and -(2**63) <= value < 2**63:
            out.append(value)
        elif kind == "float" and type(value) is float and math.isfinite(value):
            out.append(value)
        elif kind == "str?" and value is None:
            out.append(None)
        elif kind in ("str", "str?") and isinstance(value, str):
            try:
                value.encode("utf-8")  # a lone surrogate would break sqlite3
            except UnicodeEncodeError:
                raise invalid_cursor() from None
            out.append(value)
        elif kind == "uuid" and isinstance(value, str):
            try:
                out.append(str(UUID(value)))
            except ValueError:
                raise invalid_cursor() from None
        else:
            raise invalid_cursor()
    return tuple(out)


def page_rows(rows: list[dict], limit: int, key_of) -> tuple[list[dict], str | None]:
    """Rows were fetched with limit + 1: trim to the page and cursor the last
    returned row only when more rows exist."""
    page = rows[:limit]
    next_after = encode_cursor(key_of(page[-1])) if len(rows) > limit else None
    return page, next_after
