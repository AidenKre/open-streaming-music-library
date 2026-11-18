"""7A.2d S2 (spec §5 "ZIP"): "Use stream counters for actual expanded limits
and compression ratio, fail on CRC/corruption, and cancel safely. ...
Advertised sizes cannot bypass actual counters." ``copy_member`` counts the
bytes it actually reads, never a declared size."""

import hashlib
import zlib
import zipfile

import pytest

from app.services.upload_validation import ValidationFailed
from app.services.upload_zip import copy_member
from tests.upload_zip_fixtures import Entry, build_zip, corrupt_member_data

BIG = 10**9


class Source:
    """Fake reader: serves ``total`` bytes (None = endless) in requested pieces."""

    def __init__(self, total=None, fill=b"x"):
        self.total, self.fill, self.served = total, fill, 0

    def __call__(self, n):
        assert self.served < 10**6, "reader was not stopped"
        if self.total is not None:
            n = min(n, self.total - self.served)
        self.served += n
        return self.fill * n


class Sink:
    def __init__(self):
        self.blocks = []

    def __call__(self, block):
        self.blocks.append(bytes(block))

    @property
    def size(self):
        return sum(map(len, self.blocks))


def _run(src, sink=None, **kw):
    args = dict(compressed_bytes=BIG, member_cap=BIG, budget_left=BIG, ratio=1, chunk_size=4)
    args.update(kw)
    return copy_member(src, sink or Sink(), **args)


def _fails(code, src, **kw):
    sink = Sink()
    with pytest.raises(ValidationFailed) as ei:
        _run(src, sink, **kw)
    err = ei.value.error
    assert err.code == code and err.retryable is False
    assert "/" not in err.message
    return sink


def test_copy_totals_and_sha():
    data = bytes(range(37))
    pos = [0]

    def read(n):
        out = data[pos[0]:pos[0] + n]
        pos[0] += len(out)
        return out

    sink = Sink()
    total, digest = _run(read, sink, chunk_size=4)
    assert total == 37 and digest == hashlib.sha256(data).hexdigest()
    assert b"".join(sink.blocks) == data
    assert all(len(b) <= 4 for b in sink.blocks)


def test_empty_member():
    assert _run(Source(0)) == (0, hashlib.sha256(b"").hexdigest())


@pytest.mark.parametrize("kw,code,cap", [
    (dict(member_cap=20), "upload_archive_member_too_large", 20),
    (dict(budget_left=20), "upload_archive_expanded_too_large", 20),
    (dict(compressed_bytes=2, ratio=10), "upload_archive_ratio_exceeded", 20),
    (dict(compressed_bytes=0, ratio=20), "upload_archive_ratio_exceeded", 20),
])
def test_actual_counters_stop_writes(kw, code, cap):
    src = Source(None)  # endless: no declared size can bound it
    sink = _fails(code, src, **kw)
    assert sink.size <= cap + 4


@pytest.mark.parametrize("kw", [
    dict(member_cap=20), dict(budget_left=20), dict(compressed_bytes=2, ratio=10),
])
def test_boundary_equal_passes(kw):
    total, _ = _run(Source(20), **kw)
    assert total == 20
    with pytest.raises(ValidationFailed):
        _run(Source(21), **kw)


@pytest.mark.parametrize("exc", [zipfile.BadZipFile("secret.flac"), zlib.error("secret"), EOFError("secret")])
def test_read_errors_are_corrupt(exc):
    calls = [0]

    def read(n):
        calls[0] += 1
        if calls[0] > 1:
            raise exc
        return b"abcd"

    with pytest.raises(ValidationFailed) as ei:
        _run(read)
    assert ei.value.error.code == "upload_archive_corrupt"
    assert ei.value.error.retryable is False
    assert "secret" not in ei.value.error.message


def test_real_crc_failure(tmp_path):
    p = build_zip(tmp_path / "c.zip", [Entry("a.flac", b"0123456789" * 5)])
    corrupt_member_data(p, "a.flac")
    with zipfile.ZipFile(p) as zf:
        info = zf.getinfo("a.flac")
        with zf.open(info) as h:
            with pytest.raises(ValidationFailed) as ei:
                _run(h.read, compressed_bytes=info.compress_size, ratio=10, chunk_size=16)
    assert ei.value.error.code == "upload_archive_corrupt"


def test_intact_zip_member_copies(tmp_path):
    data = b"0123456789" * 5
    p = build_zip(tmp_path / "c.zip", [Entry("a.flac", data)])
    with zipfile.ZipFile(p) as zf, zf.open("a.flac") as h:
        total, digest = _run(h.read, compressed_bytes=len(data), ratio=1, chunk_size=16)
    assert (total, digest) == (50, hashlib.sha256(data).hexdigest())


class Stop(Exception):
    pass


def test_between_propagates_and_stops_writes():
    calls = [0]

    def between():
        calls[0] += 1
        if calls[0] == 3:
            raise Stop

    sink = Sink()
    with pytest.raises(Stop):
        _run(Source(100), sink, between=between)
    assert calls[0] == 3 and len(sink.blocks) == 2


def test_between_called_before_each_read():
    events = []
    src = Source(8)

    def read(n):
        events.append("r")
        return src(n)

    _run(read, between=lambda: events.append("b"))
    assert events[:4] == ["b", "r", "b", "r"]
