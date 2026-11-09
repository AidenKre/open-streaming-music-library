"""SC-16b: bounded request bodies, and SC-22-safe validation errors.

Routes that read their body through :func:`bounded_body` must NOT declare a
Pydantic body parameter: FastAPI buffers the whole body (``await
request.body()``) before it solves any dependency, which would defeat the
cap. Such routes validate with ``Model.model_validate_json(raw)`` and map a
``ValidationError`` through :func:`validation_error_422`.
"""

from typing import Awaitable, Callable

from fastapi import HTTPException, Request
from pydantic import ValidationError

from app.core.api_errors import api_error


def bounded_body(max_bytes: int) -> Callable[[Request], Awaitable[bytes]]:
    """A dependency returning the raw request body, read while streaming with
    an enforced cap of ``max_bytes`` regardless of ``Content-Length``; a
    larger body is refused with 413 (SC-22 envelope, input never echoed)."""

    async def dependency(request: Request) -> bytes:
        body = bytearray()
        async for chunk in request.stream():
            if len(body) + len(chunk) > max_bytes:
                raise api_error(
                    413,
                    "request_too_large",
                    "Request body exceeds the size limit.",
                    retryable=False,
                )
            body.extend(chunk)
        return bytes(body)

    return dependency


def validation_error_422(error: ValidationError) -> HTTPException:
    """FastAPI's 422 list shape for ``error``, without the offending input
    values (SC-22)."""
    # Context can contain input values or validator exceptions; omit it too.
    details = error.errors(include_input=False, include_url=False, include_context=False)
    for item in details:
        item["loc"] = ("body", *item["loc"])
    return HTTPException(status_code=422, detail=details)
