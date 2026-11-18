"""Shared helpers for the ZIP expansion tests (7A.2d S1/S2 and later steps)."""

import itertools
import stat
import struct
import warnings
import zipfile
from types import SimpleNamespace
from dataclasses import dataclass
from pathlib import Path

from app.services.storage_ledger import StorageLedger
from app.services.upload_limits import UploadLimits
from app.services.upload_receipt import ReceiptFiles
from app.services.upload_zip import ZipExpander
from tests.identity_worker_fixtures import sql
from tests.upload_validation_fixtures import BOOT, make_worker, stage_item

_zip_counter = itertools.count(1)


def tiny_limits(**overrides) -> UploadLimits:
    """UploadLimits with tiny archive caps (members 8, audio 4, member 1000 B, expanded 4000 B, ratio 10) and generous unrelated fields."""
    values = dict(
        max_files_per_batch=100,
        max_file_bytes=10**9,
        max_batch_bytes=10**9,
        max_expanded_bytes_per_batch=4000,
        max_expanded_member_bytes=1000,
        max_audio_items_per_batch=4,
        max_archive_members=8,
        max_compression_ratio=10,
        receives=100,
        staged_quota_bytes=10**10,
        receives_per_user=100,
        user_staged_quota_bytes=10**10,
    )
    values.update(overrides)
    return UploadLimits(**values)


@dataclass
class Entry:
    """One archive member: name, data, and optional zip header overrides (is_dir adds a trailing slash)."""

    name: str
    data: bytes = b""
    compress_type: int = zipfile.ZIP_STORED
    external_attr: int | None = None
    create_system: int = 3
    flag_bits: int = 0
    is_dir: bool = False


def _central_records(raw: bytes, zf: zipfile.ZipFile):
    """Yield the byte offset of each central-directory record, in infolist order."""
    pos = zf.start_dir
    for _ in zf.infolist():
        assert raw[pos:pos + 4] == b"PK\x01\x02"
        yield pos
        n, m, k = struct.unpack_from("<HHH", raw, pos + 28)
        pos += 46 + n + m + k


def build_zip(path, entries) -> Path:
    """Write ``entries`` (Entry list) to ``path`` via ZipInfo.writestr, patch encrypted flags into the raw bytes (zipfile resets them), and verify flags/attrs/compression read back as requested."""
    path = Path(path)
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        with zipfile.ZipFile(path, "w") as zf:
            for e in entries:
                name = e.name + "/" if e.is_dir and not e.name.endswith("/") else e.name
                info = zipfile.ZipInfo(name)
                info.compress_type = e.compress_type
                info.create_system = e.create_system
                if e.external_attr is not None:
                    info.external_attr = e.external_attr
                elif e.is_dir:
                    info.external_attr = (stat.S_IFDIR | 0o755) << 16
                zf.writestr(info, b"" if e.is_dir else e.data)
    if any(e.flag_bits for e in entries):
        raw = bytearray(path.read_bytes())
        with zipfile.ZipFile(path) as zf:
            infos = zf.infolist()
            for e, info, rec in zip(entries, infos, _central_records(bytes(raw), zf)):
                if not e.flag_bits:
                    continue
                for off in (info.header_offset + 6, rec + 8):
                    (cur,) = struct.unpack_from("<H", raw, off)
                    struct.pack_into("<H", raw, off, cur | e.flag_bits)
        path.write_bytes(bytes(raw))
    with zipfile.ZipFile(path) as zf:
        for e, info in zip(entries, zf.infolist()):
            assert info.flag_bits & e.flag_bits == e.flag_bits, "flag_bits did not survive"
            assert info.compress_type == e.compress_type
            if e.external_attr is not None:
                assert info.external_attr == e.external_attr
                assert info.create_system == e.create_system
    return path


def patch_eocd_count(path, count: int) -> None:
    """Overwrite the end-of-central-directory entry counts with ``count`` (central directory itself untouched)."""
    path = Path(path)
    raw = bytearray(path.read_bytes())
    pos = raw.rfind(b"PK\x05\x06")
    assert pos >= 0
    struct.pack_into("<HH", raw, pos + 8, count, count)
    path.write_bytes(bytes(raw))


def corrupt_member_data(path, name) -> None:
    """Flip one byte of ``name``'s stored data in place so reading it fails the CRC check (STORED members only)."""
    path = Path(path)
    raw = bytearray(path.read_bytes())
    with zipfile.ZipFile(path) as zf:
        info = zf.getinfo(name)
    nlen, elen = struct.unpack_from("<HH", raw, info.header_offset + 26)
    start = info.header_offset + 30 + nlen + elen
    assert info.compress_type == zipfile.ZIP_STORED and info.file_size > 0
    raw[start] ^= 0xFF
    path.write_bytes(bytes(raw))


def stage_zip(db, root, tmp_path, entries, **kw) -> dict:
    """Build a zip outside ``root`` and stage it as a received ``album.zip`` item (dict: owner_id, item_uuid, batch_uuid, source)."""
    built = build_zip(Path(tmp_path) / f"src-{next(_zip_counter)}.zip", entries)
    return stage_item(db, root, content=built.read_bytes(), filename="album.zip", **kw)


def make_ledger(db, tmp_path, *, free=10**12, boot_id=BOOT) -> StorageLedger:
    """A real StorageLedger with no floor and a fake disk reporting ``free`` bytes."""
    return StorageLedger(db, path=tmp_path, floor_bytes=0, boot_id=boot_id,
                         disk_usage=lambda p: SimpleNamespace(free=free))


class LedgerSpy:
    """Wraps a ledger: records every reserve(**kw) in ``reserves`` and delegates everything else."""

    def __init__(self, ledger):
        self._ledger = ledger
        self.reserves: list[dict] = []

    def reserve(self, **kw):
        self.reserves.append(kw)
        return self._ledger.reserve(**kw)

    def __getattr__(self, name):
        return getattr(self._ledger, name)


def make_expander(db, root, tmp_path, *, limits=None, ledger=None, files=None, boot_id=BOOT, chunk_size=7) -> ZipExpander:
    """A ZipExpander with tiny limits, a free-disk ledger and a small chunk size by default."""
    lim = limits or tiny_limits()
    return ZipExpander(db, uploads_root=root, boot_id=boot_id,
                       ledger=ledger or make_ledger(db, tmp_path, boot_id=boot_id),
                       limits=lambda: lim, files=files, chunk_size=chunk_size)


def zip_worker(db, root, tmp_path, *, expander=None, **worker_kw):
    """An UploadValidationWorker whose zip_handler is ``expander`` (default: make_expander)."""
    return make_worker(db, root, zip_handler=expander or make_expander(db, root, tmp_path), **worker_kw)


def files_under(root) -> set[Path]:
    """Every regular file under ``root``; asserts there is no symlink anywhere beneath it."""
    root = Path(root)
    found = set()
    for p in root.rglob("*"):
        assert not p.is_symlink(), f"symlink under root: {p}"
        if p.is_file():
            found.add(p)
    return found


def children_of(db, staged) -> list[dict]:
    """The child upload_items rows of ``staged`` ordered by member_order_key (plain SQL)."""
    return sql(db, "SELECT * FROM upload_items WHERE owner_id=? AND parent_item_uuid=? ORDER BY member_order_key",
               (staged["owner_id"], staged["item_uuid"]))


class FailingFiles(ReceiptFiles):
    """ReceiptFiles that raises ``exc`` from ``op`` ("write_block" or "rename") when it reaches the ``nth`` member (1-based, counted by open_part)."""

    def __init__(self, op, exc, nth=2):
        self.op, self.exc, self.nth, self.opened, self.renames = op, exc, nth, 0, 0

    def open_part(self, path):
        self.opened += 1
        return super().open_part(path)

    def write_block(self, handle, block):
        if self.op == "write_block" and self.opened == self.nth:
            raise self.exc
        super().write_block(handle, block)

    def rename(self, source, target):
        self.renames += 1
        if self.op == "rename" and self.renames == self.nth:
            raise self.exc
        super().rename(source, target)


def corrupt_local_name(path, name) -> None:
    """Change one byte of ``name`` in its local file header only, so zipfile.open raises BadZipFile (central directory still matches)."""
    path = Path(path)
    raw = bytearray(path.read_bytes())
    with zipfile.ZipFile(path) as zf:
        info = zf.getinfo(name)
    raw[info.header_offset + 30] ^= 0x01
    path.write_bytes(bytes(raw))


class CallbackFiles(ReceiptFiles):
    """ReceiptFiles that calls ``callback()`` once, at the first write_block of the ``nth`` member (1-based, counted by open_part), then writes normally."""

    def __init__(self, callback=None, nth=2):
        self.callback, self.nth, self.opened, self.fired = callback, nth, 0, False

    def open_part(self, path):
        self.opened += 1
        return super().open_part(path)

    def write_block(self, handle, block):
        if not self.fired and self.opened == self.nth and self.callback is not None:
            self.fired = True
            self.callback()
        super().write_block(handle, block)


class HookFiles(ReceiptFiles):
    """ReceiptFiles with hooks: ``write_hook(member_no, first_write)`` runs before each write_block (may raise), ``remove_hook(path)`` before each remove (may raise)."""

    def __init__(self, write_hook=None, remove_hook=None):
        self.write_hook, self.remove_hook, self.opened, self._seen = write_hook, remove_hook, 0, set()

    def open_part(self, path):
        self.opened += 1
        return super().open_part(path)

    def write_block(self, handle, block):
        if self.write_hook is not None:
            first = self.opened not in self._seen
            self._seen.add(self.opened)
            self.write_hook(self.opened, first)
        super().write_block(handle, block)

    def remove(self, path):
        if self.remove_hook is not None:
            self.remove_hook(path)
        super().remove(path)


def unrecorded_files(db, root) -> set[Path]:
    """Files under ``root`` that no upload_items row records as its source_path."""
    recorded = {Path(r["source_path"]) for r in sql(db, "SELECT source_path FROM upload_items") if r["source_path"]}
    return files_under(root) - recorded
