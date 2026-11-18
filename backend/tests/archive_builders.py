"""Archive builders for the import-folder archive tests: tar / tar.gz via
``tarfile``, and stored RAR5 / RAR 2.9-4.x archives built by hand (no RAR
writer is available)."""

import io
import struct
import tarfile
import zlib
from pathlib import Path


def rar_vint(n: int) -> bytes:
    out = bytearray()
    while True:
        low, n = n & 0x7F, n >> 7
        out.append(low | (0x80 if n else 0))
        if not n:
            return bytes(out)


def rar5(members) -> tuple[bytes, list[int], int]:
    """A stored RAR5 archive: (bytes, offset of each member's header, offset
    of the end header)."""

    def header(body: bytes) -> bytes:
        size = rar_vint(len(body))
        return zlib.crc32(size + body).to_bytes(4, "little") + size + body

    v = rar_vint
    out = b"Rar!\x1a\x07\x01\x00" + header(v(1) + v(0) + v(0))
    offsets = []
    for name, data in members:
        raw = name.encode()
        body = (
            v(2) + v(0x0002) + v(len(data))  # file header, has a data area
            + v(0x0004) + v(len(data)) + v(0o100644)  # CRC present, size, mode
            + zlib.crc32(data).to_bytes(4, "little")
            + v(0) + v(1) + v(len(raw)) + raw  # stored, Unix, name
        )
        offsets.append(len(out))
        out += header(body) + data
    end = len(out)
    return out + header(v(5) + v(0) + v(0)), offsets, end


def rar4(members) -> tuple[bytes, list[int], int]:
    """A stored RAR 2.9-4.x archive, same shape as ``rar5``."""

    def block(kind: int, flags: int, rest: bytes) -> bytes:
        body = struct.pack("<BHH", kind, flags, 7 + len(rest)) + rest
        return struct.pack("<H", zlib.crc32(body) & 0xFFFF) + body

    out = b"Rar!\x1a\x07\x00" + block(0x73, 0, b"\0" * 6)
    offsets = []
    for name, data in members:
        raw = name.encode()
        rest = struct.pack(
            "<IIBIIBBHI", len(data), len(data), 3, zlib.crc32(data), 0x21, 20, 0x30, len(raw), 0o100644
        ) + raw
        offsets.append(len(out))
        out += block(0x74, 0x8000, rest) + data
    end = len(out)
    return out + block(0x7B, 0x4000, b""), offsets, end


def tar_info(name: str, data: bytes = b"", *, kind=tarfile.REGTYPE, linkname: str = "") -> tuple:
    info = tarfile.TarInfo(name)
    info.type = kind
    info.linkname = linkname
    info.size = len(data) if kind == tarfile.REGTYPE else 0
    return info, data


def write_tar(path: Path, entries, *, mode: str = "w") -> Path:
    """``entries``: (name, data) pairs or ``tar_info`` tuples; ``mode`` is the
    tarfile mode ("w", "w:gz", "w:xz", "w:bz2")."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(path, mode) as t:
        for entry in entries:
            info, data = entry if isinstance(entry[0], tarfile.TarInfo) else tar_info(*entry)
            t.addfile(info, io.BytesIO(data) if info.isreg() else None)
    return path


def write_rar(path: Path, members, *, build=rar5) -> Path:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(build(members)[0])
    return path
