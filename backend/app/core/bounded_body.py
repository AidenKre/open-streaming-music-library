"""SC-16b: bounded request bodies, and SC-22-safe validation errors.

Routes must NOT declare a Pydantic body parameter: FastAPI buffers the whole
body (``await request.body()``) before it solves any dependency, which would
defeat the cap. A route takes its JSON body through :func:`json_body` instead,
which reads it with :func:`bounded_body`, validates it with
``Model.model_validate_json(raw)`` and maps a ``ValidationError`` through
:func:`validation_error_422`.

:func:`capped_chunks` is the one byte counter; ``bounded_body`` and the upload
content stream both use it.

A client that disconnects while ``bounded_body`` is reading ends the request
quietly: one INFO line, status 499, no traceback, and the route never runs.
"""

from typing import AsyncIterator, Awaitable, Callable, TypeVar

from fastapi import Depends, HTTPException, Request
from pydantic import BaseModel, ValidationError
from starlette.requests import ClientDisconnect

from app.core.api_errors import api_error
from app.core.operator_log import operator_logger


Model = TypeVar("Model", bound=BaseModel)

# The cap on the JSON body of the warm-up, quality setting, track edit and job
# routes (SC-16b).
JSON_BODY_LIMIT = 64 * 1024


class BodyTooLarge(Exception):
    def __init__(self, received: int):
        super().__init__("body exceeds the size limit")
        self.received = received


async def capped_chunks(chunks: AsyncIterator[bytes], max_bytes: int) -> AsyncIterator[bytes]:
    """Pass ``chunks`` through while the bytes actually received stay within
    ``max_bytes``. The first chunk that would pass the cap is not yielded: it
    raises :class:`BodyTooLarge` and nothing further is pulled from the source."""
    received = 0
    async for chunk in chunks:
        received += len(chunk)
        if received > max_bytes:
            raise BodyTooLarge(received)
        yield chunk


def bounded_body(max_bytes: int) -> Callable[[Request], Awaitable[bytes]]:
    """A dependency returning the raw request body, read while streaming with
    an enforced cap of ``max_bytes`` regardless of ``Content-Length``; a
    larger body is refused with 413 (SC-22 envelope, input never echoed)."""

    async def dependency(request: Request) -> bytes:
        body = bytearray()
        try:
            async for chunk in capped_chunks(request.stream(), max_bytes):
                body.extend(chunk)
        except BodyTooLarge:
            raise api_error(
                413,
                "request_too_large",
                "Request body exceeds the size limit.",
                retryable=False,
            ) from None
        except ClientDisconnect:
            operator_logger.info("client went away before its request body was read")
            raise HTTPException(status_code=499, detail="client closed request") from None
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


def json_body(model: type[Model], max_bytes: int) -> Callable[..., Awaitable[Model]]:
    """A dependency returning the request body as ``model``: read through
    :func:`bounded_body` with a cap of ``max_bytes`` (413), then validated
    (a 422 through :func:`validation_error_422`)."""

    async def dependency(raw: bytes = Depends(bounded_body(max_bytes))) -> Model:
        try:
            return model.model_validate_json(raw)
        except ValidationError as exc:
            raise validation_error_422(exc) from None

    return dependency
