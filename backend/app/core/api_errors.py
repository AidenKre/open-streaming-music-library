"""SC-22 typed API error envelope, and the error carrier the services raise."""

import re
from collections.abc import Iterator
from contextlib import contextmanager

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


class ApiError(Exception):
    """An SC-22 error a service raises. Each feature has its own subclass
    (UploadError, DeletionError, LastfmError) and its own codes; a route turns
    it into its HTTP answer with ``to_http()``, usually through ``answer_errors``."""

    def __init__(self, status, code, message, *, retryable, headers=None, **extra):
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message
        self.retryable = retryable
        self.headers = headers
        self.extra = extra

    def to_http(self) -> HTTPException:
        exc = api_error(
            self.status,
            self.code,
            self.message,
            retryable=self.retryable,
            **self.extra,
        )
        if self.headers:
            exc.headers = dict(self.headers)
        return exc


@contextmanager
def answer_errors(kind: type[ApiError], *, keep_cause: bool = True) -> Iterator[None]:
    """Run a route's service call: an error of ``kind`` leaves as its SC-22 HTTP
    answer. With ``keep_cause=False`` the service error is not chained to it."""
    try:
        yield
    except kind as exc:
        if keep_cause:
            raise exc.to_http() from exc
        raise exc.to_http() from None
