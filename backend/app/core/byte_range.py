"""HTTP byte ranges: parsing one Range header and serving an open file as a
200 or 206 streaming response. Shared by the track stream and the upload preview."""

import os

from fastapi import HTTPException
from fastapi.responses import StreamingResponse


def parse_byte_range(range_header: str, file_size: int) -> tuple[int, int]:
    """Parse a single HTTP byte range and return ``(start, end)`` inclusive.

    Supports the three single-range forms from RFC 7233:
      ``bytes=start-end`` — explicit window
      ``bytes=start-``    — from ``start`` to EOF
      ``bytes=-N``        — the last ``N`` bytes (suffix range)

    A last position at or past EOF is clamped to the final byte (RFC 9110
    14.1.2). Anything else — multi-range requests, malformed values, a start at
    or past EOF — raises 416. The caller ignores a non-``bytes`` unit (14.2)
    before calling this.
    """
    if "," in range_header:
        # Multi-range responses require multipart/byteranges; we only serve
        # single ranges, so reject explicitly rather than serving the first.
        raise HTTPException(
            status_code=416,
            detail=f"Multi-range requests are not supported: {range_header}",
        )

    if "=" not in range_header:
        raise HTTPException(
            status_code=416, detail=f"Invalid Range Header: {range_header}"
        )

    rng = range_header.partition("=")[2].strip()
    # Exactly one "-" separator; partition guarantees that. The earlier
    # split("-") accepted "1-2-3" by silently dropping the tail.
    if rng.count("-") != 1:
        raise HTTPException(
            status_code=416, detail=f"Invalid Range Header: {range_header}"
        )
    start_s, end_s = rng.split("-")

    try:
        if not start_s and not end_s:
            # "bytes=-" — malformed.
            raise ValueError("empty range")
        if not start_s:
            # Suffix range: last N bytes.
            suffix_len = int(end_s)
            if suffix_len <= 0:
                raise ValueError("non-positive suffix length")
            if suffix_len >= file_size:
                start = 0
            else:
                start = file_size - suffix_len
            end = file_size - 1
        else:
            start = int(start_s)
            if start < 0:
                raise ValueError("negative start")
            end = int(end_s) if end_s else file_size - 1
            if end < 0:
                raise ValueError("negative end")
    except ValueError:
        raise HTTPException(
            status_code=416, detail=f"Invalid Range Header: {range_header}"
        )

    end = min(end, file_size - 1)
    if start >= file_size or start > end:
        raise HTTPException(
            status_code=416, detail=f"Range not satisfiable: {range_header}"
        )

    return start, end


def ranged_file_response(
    handle, *, media_type: str, range_header: str | None, headers: dict, chunk_size: int
) -> StreamingResponse:
    """Serve the open ``handle``. Takes ownership: the handle is closed after the
    body is streamed, and on any exception raised before the response is returned
    (for example a 416 from the range parser)."""
    f = handle
    try:
        file_size = os.fstat(f.fileno()).st_size

        # RFC 9110 14.2: a range unit we do not understand is ignored.
        unit, equals, _ = (range_header or "").partition("=")
        if equals and unit.strip().lower() != "bytes":
            range_header = None

        if not range_header:

            def iterfile(h):
                try:
                    while chunk := h.read(chunk_size):
                        yield chunk
                finally:
                    h.close()

            response = StreamingResponse(
                iterfile(f),
                media_type=media_type,
                headers={
                    "Accept-ranges": "bytes",
                    "Content-length": str(file_size),
                    **headers,
                },
            )
            f = None  # ownership transferred to the generator
            return response

        try:
            start, end = parse_byte_range(range_header, file_size)
        except HTTPException as exc:
            # RFC 9110 15.5.17: a refused range names the representation's size.
            exc.headers = {**(exc.headers or {}), "Content-Range": f"bytes */{file_size}"}
            raise
        content_length = end - start + 1
        f.seek(start)

        def iter_range(h, remaining_bytes):
            try:
                while remaining_bytes:
                    chunk = h.read(min(chunk_size, remaining_bytes))
                    if not chunk:
                        break
                    remaining_bytes -= len(chunk)
                    yield chunk
            finally:
                h.close()

        response = StreamingResponse(
            iter_range(f, content_length),
            status_code=206,
            media_type=media_type,
            headers={
                "Accept-ranges": "bytes",
                "Content-range": f"bytes {start}-{end}/{file_size}",
                "Content-length": str(content_length),
                **headers,
            },
        )
        f = None  # ownership transferred to the generator
        return response
    finally:
        if f is not None:
            f.close()
