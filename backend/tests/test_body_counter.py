"""Phase 7A.2b S1 (plan D18, SC-16b): the one body counter, shared by
``bounded_body`` and the upload content stream. It counts the bytes actually
received, never a declared length, and refuses the first chunk that would
pass the cap before handing it on."""

import anyio
import pytest

from app.core.bounded_body import BodyTooLarge, capped_chunks


async def _chunks(*parts):
    for part in parts:
        yield part


def _collect(chunks, max_bytes):
    seen = []

    async def run():
        async for chunk in capped_chunks(chunks, max_bytes):
            seen.append(chunk)

    return seen, run


def test_chunks_up_to_the_cap_pass_through_unchanged():
    seen, run = _collect(_chunks(b"ab", b"", b"cde"), 5)

    anyio.run(run)

    assert seen == [b"ab", b"", b"cde"]


def test_the_chunk_that_passes_the_cap_is_refused_before_it_is_handed_on():
    seen, run = _collect(_chunks(b"ab", b"cd", b"e", b"never read"), 4)

    with pytest.raises(BodyTooLarge) as raised:
        anyio.run(run)

    assert seen == [b"ab", b"cd"]
    # The count is what actually arrived, including the refused chunk.
    assert raised.value.received == 5


def test_nothing_after_the_refused_chunk_is_read():
    reads = []

    async def source():
        for part in (b"abc", b"def", b"ghi"):
            reads.append(part)
            yield part

    _seen, run = _collect(source(), 4)

    with pytest.raises(BodyTooLarge):
        anyio.run(run)

    assert reads == [b"abc", b"def"]


def test_an_empty_body_under_a_zero_cap_is_fine_and_one_byte_is_not():
    seen, run = _collect(_chunks(), 0)
    anyio.run(run)
    assert seen == []

    _seen, run = _collect(_chunks(b"x"), 0)
    with pytest.raises(BodyTooLarge):
        anyio.run(run)
