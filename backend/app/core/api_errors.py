"""SC-22 typed API error envelope."""

import re

from fastapi import HTTPException


def api_error(status: int, code: str, message: str, *, retryable: bool, **extra) -> HTTPException:
    if re.fullmatch(r"[a-z][a-z0-9_]*", code) is None:
        raise ValueError("Error code must be lowercase snake_case")
    if {"error", "message", "retryable"}.intersection(extra):
        raise ValueError("Extra fields cannot override error envelope keys")
    return HTTPException(
        status_code=status,
        detail={"error": code, "message": message, "retryable": retryable, **extra},
    )
