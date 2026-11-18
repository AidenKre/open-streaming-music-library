"""Import-folder archives (sign-off DEV-7-14 point 1): an archive dropped in an
import folder gets the same inspection as an uploaded ZIP before anything is
extracted. A ZIP goes through ``upload_zip.inspect_archive`` itself; tar,
tar.gz and RAR are listed by libarchive, headers only, and every entry goes
through the same ``upload_zip.check_member`` rules. The extension decides the
reader: a file whose real format differs from its name is invalid.

The limits differ from uploads (owner, 2026-11-17: "no limits on archives,
just like we have no limits on files"): ``ImportArchiveLimits`` has no size or
audio-count cap, only the bomb guards (compression ratio, entry count) and the
disk rule (the reservation and the free-disk floor). What is not bounded by
size is bounded by shape: every member is unpacked flat into a folder of its
own, the names of every format share one budget, and at most
``CONCURRENT_UNPACKS`` archives are inspected and copied at once."""

import errno
import functools
import gzip
import os
import re
import shutil
import tarfile
import threading
import uuid
import zipfile
import zlib
from contextlib import contextmanager, nullcontext
from dataclasses import dataclass
from pathlib import Path

import libarchive
from libarchive.exception import ArchiveError

from app.config import Settings
from app.core.operator_log import operator_logger
from app.services import upload_errors as errors
from app.services.import_outcome import file_identity
from app.services.path_sanitize import PathEscapesRoot, assert_within
from app.services.storage_ledger import IMPORT_UNPACK, InsufficientStorage
from app.services.upload_validation import ValidationFailed
from app.services.upload_zip import (
    CENTRAL_DIRECTORY_BYTES_PER_MEMBER, ArchivePlan, Member, check_batch_totals, check_member, copy_member,
    inspect_archive, is_other_audio, is_transient_read_error,
)


# The smallest allocation unit assumed (APFS/ext4); larger clusters (exFAT) are read from the disk.
_MIN_BLOCK = 4096
_UPLOAD_ONLY_SETTINGS = ("upload_max_archive_members", "upload_max_audio_items_per_batch",
                         "upload_max_expanded_member_bytes", "upload_max_expanded_bytes_per_batch")


@dataclass(frozen=True)
class ImportArchiveLimits:
    """The checks an import-folder archive goes through; the shared code
    reads None as no cap. Only the bomb guards: the entry count (an archive
    built to overwhelm the server with tiny files) and the compression ratio."""
    max_archive_members: int
    max_compression_ratio: int
    max_expanded_member_bytes: int | None = None
    max_expanded_bytes_per_batch: int | None = None
    max_audio_items_per_batch: int | None = None
    # The ZIP central directory read before ZipFile parses it, per allowed
    # entry: at the 100,000 guard that is ~100 MiB (the upload bound, 4 KiB,
    # would be ~400 MiB), and still fits names of several hundred characters.
    central_directory_bytes_per_member: int = 1024


def import_archive_limits(settings: Settings) -> ImportArchiveLimits:
    return ImportArchiveLimits(max_archive_members=settings.import_archive_max_entries,
                               max_compression_ratio=settings.upload_max_compression_ratio)


def upload_only_settings_notice(settings: Settings) -> None:
    """At startup: one line naming the upload limits the operator set that no
    longer reach import folders, so the change is never silent."""
    names = [n.upper() for n in _UPLOAD_ONLY_SETTINGS if n in settings.model_fields_set]
    if names:
        operator_logger.warning(
            "An upload limit is set that applies to uploaded ZIPs only (%s): archives in import"
            " folders have no size or count limit and are guarded only against bombs"
            " (IMPORT_ARCHIVE_MAX_ENTRIES, UPLOAD_MAX_COMPRESSION_RATIO) and by the free-disk floor.",
            ", ".join(names))


def disk_cost(declared: int, block: int = _MIN_BLOCK) -> int:
    """What unpacking one member of ``declared`` bytes may take from the disk:
    its data rounded up to a block, a block for its inode and one for the
    folder of its own. With no count cap, many tiny files would otherwise
    cost unreserved disk."""
    return -(-declared // block) * block + 2 * block


def _block_size(path) -> int:
    """The disk's allocation unit at ``path``, at least 4 KiB."""
    try:
        return max(_MIN_BLOCK, os.statvfs(path).f_frsize)
    except (OSError, AttributeError):
        return _MIN_BLOCK


def _name_budget(limits) -> int:
    """The total name bytes an archive may hold: a ZIP's central-directory
    bound, applied to tar and RAR names too (their per-name 64 KiB cap alone
    would let names take gigabytes of memory at the entry guard)."""
    return limits.max_archive_members * getattr(limits, "central_directory_bytes_per_member",
                                                 CENTRAL_DIRECTORY_BYTES_PER_MEMBER)


@dataclass(frozen=True)
class _Reader:
    """How libarchive opens a file, and which filters it must then report:
    libarchive passes data it cannot decode through untouched (a plain tar
    named .tar.gz would otherwise be read). Only the one format reader is
    enabled, so no other format can outbid it."""
    format_name: str
    filter_name: str
    filters: tuple[bytes, ...]


_EXTENSIONS = (".tar", ".tar.gz", ".rar")
_TAR_READERS = {
    ".tar": _Reader("tar", "none", ()),
    ".tar.gz": _Reader("tar", "gzip", (b"gzip",)),
}
# A RAR is read with the reader its signature names (libarchive-c resolves "rar5" itself).
_RAR_READERS = {
    b"Rar!\x1a\x07\x00": _Reader("rar", "none", ()),       # RAR 1.5-4.x
    b"Rar!\x1a\x07\x01\x00": _Reader("rar5", "none", ()),  # RAR5
}
# The tar header walk stops at this many headers per allowed member.
HEADERS_PER_MEMBER = 4


_SPECIAL_HEADER_MAX = 64 * 1024
_META_TYPES = (tarfile.GNUTYPE_LONGNAME, tarfile.GNUTYPE_LONGLINK, tarfile.XHDTYPE, tarfile.XGLTYPE,
               tarfile.SOLARIS_XHDTYPE)
_NO_DATA_TYPES = (tarfile.LNKTYPE, tarfile.SYMTYPE, tarfile.CHRTYPE, tarfile.BLKTYPE, tarfile.DIRTYPE,
                  tarfile.FIFOTYPE)
_CHUNK = 1024 * 1024
_ZERO_BLOCK = bytes(512)
_TAR_RECORD = 10240  # tar's default record size


def _is_path(source) -> bool:
    return isinstance(source, (str, os.PathLike))


def _name(source) -> str:
    """The lower-cased file name of a path or of an open file."""
    return Path(source if _is_path(source) else source.name).name.lower()


def _ext(name: str) -> str | None:
    return next((ext for ext in _EXTENSIONS if name.endswith(ext)), None)


def _reader(f, ext: str) -> _Reader:
    """The libarchive reader for an open file: by its extension, or for a
    RAR by its signature (a file without one is invalid)."""
    if ext != ".rar":
        return _TAR_READERS[ext]
    f.seek(0)
    head = f.read(8)
    for signature, reader in _RAR_READERS.items():
        if head.startswith(signature):
            return reader
    raise ValidationFailed(errors.upload_archive_invalid())


def inspect(source, limits, *, should_stop=None) -> ArchivePlan:
    """The archive's plan (its audio members, the count of skipped entries),
    or ``ValidationFailed`` with the same refusals as an uploaded ZIP.
    ``source`` is a path, or a binary file already open (read, not closed).
    ``should_stop()`` abandons a tar walk or a listing with ``ArchiveStopped``."""
    name = _name(source)
    if name.endswith(".zip"):
        return inspect_archive(source, limits)
    ext = _ext(name)
    if ext is None:
        raise ValidationFailed(errors.upload_archive_invalid())
    try:
        with open(source, "rb", buffering=0) if _is_path(source) else nullcontext(source) as f:
            return _list(f, ext, limits, should_stop)
    except (ArchiveError, OSError, ValueError, EOFError, zlib.error, tarfile.TarError) as exc:
        if is_transient_read_error(exc):
            raise ValidationFailed(errors.upload_validation_failed()) from None
        raise ValidationFailed(errors.upload_archive_invalid()) from None


def _walk_tar(f, *, gz: bool, size: int, budget: int, max_headers: int, name_budget: int,
              should_stop=None) -> None:
    """Walks the tar headers in Python before libarchive sees the file.
    libarchive reads a long-name or pax body into memory whole, so a special
    header over 64 KiB is refused; it also stops at the first end-of-archive
    marker, so anything but zero padding after it (a second tar appended)
    would hide entries from the plan; and an entry type without data that
    declares data would make libarchive and this walk disagree on where the
    next header is. The work is bounded: the declared data by the ratio
    budget, the headers by their count and (on their own) by the budget,
    the special headers' bodies (long names, pax records) by the name budget,
    and ``should_stop()`` is checked per header and per chunk read."""
    def stop_check():
        if should_stop is not None and should_stop():
            raise ArchiveStopped()

    f.seek(0)
    stream = gzip.GzipFile(fileobj=f, mode="rb") if gz else f
    total, headers, names, next_size = 0, 0, 0, None

    def read(n):
        data = b""
        while len(data) < n:
            chunk = stream.read(min(n - len(data), _CHUNK))
            if not chunk:
                break
            data += chunk
        return data

    while True:
        stop_check()
        block = read(512)
        if not block:  # no end marker: nothing can follow it (the completeness check ran first)
            return
        if len(block) < 512:
            raise ValidationFailed(errors.upload_archive_invalid())
        if block == _ZERO_BLOCK:
            break
        headers += 1
        if headers > max_headers:
            raise ValidationFailed(errors.upload_archive_too_many_members())
        if headers * 512 > budget + _TAR_RECORD:  # one record free: a small archive's headers
            raise ValidationFailed(errors.upload_archive_ratio_exceeded())
        info = tarfile.TarInfo.frombuf(block, "utf-8", "surrogateescape")
        declared = info.size if next_size is None or info.type in _META_TYPES else next_size
        if info.type in _META_TYPES:
            if declared > _SPECIAL_HEADER_MAX:
                raise ValidationFailed(errors.upload_archive_invalid())
            names += declared
            if names > name_budget:
                raise ValidationFailed(errors.upload_archive_too_many_members())
        elif info.type in _NO_DATA_TYPES and declared > 0:
            raise ValidationFailed(errors.upload_archive_invalid())
        total += declared
        if total > budget:
            raise ValidationFailed(errors.upload_archive_ratio_exceeded())
        padded = -(-declared // 512) * 512
        if info.type == tarfile.XHDTYPE:  # a pax "size" record overrides the next entry's
            body = read(padded)
            found = re.search(rb"(?:^|\n)\d+ size=(\d+)\n", body[:declared])
            next_size = int(found.group(1)) if found else None
            continue
        if info.type not in _META_TYPES:
            next_size = None
        if not gz:  # a plain file: seek over the data
            if f.seek(padded, os.SEEK_CUR) > size:
                raise ValidationFailed(errors.upload_archive_invalid())
            continue
        while padded:
            stop_check()
            got = len(read(min(padded, _CHUNK)))
            if not got:
                raise ValidationFailed(errors.upload_archive_invalid())
            padded -= got
    # The zero padding to the record size is bounded too: the budget plus one read.
    trailing = 0
    while chunk := stream.read(_CHUNK):
        trailing += len(chunk)
        if chunk.count(0) != len(chunk):
            raise ValidationFailed(errors.upload_archive_invalid())
        if trailing > budget + _CHUNK:
            raise ValidationFailed(errors.upload_archive_ratio_exceeded())


def _list(f, ext: str, limits, should_stop=None) -> ArchivePlan:
    """The Python pre-checks first (the RAR signature, the tar header walk),
    so libarchive never parses what they refuse. Then one pass over the
    headers; moving to the next header lets libarchive skip the data, so
    nothing is decompressed beyond what the ratio allows. Tar and RAR give no
    per-entry compressed size, so the ratio is checked for the whole archive:
    the declared sizes of every entry so far against the file's size, at each
    header before the next one is read. The names count against the name
    budget, and ``should_stop()`` is checked per entry."""
    size = os.fstat(f.fileno()).st_size
    name_budget = _name_budget(limits)
    budget = limits.max_compression_ratio * max(size, 1)
    reader = _reader(f, ext)
    if ext != ".rar":
        _walk_tar(f, gz=ext == ".tar.gz", size=size, budget=budget,
                  max_headers=HEADERS_PER_MEMBER * limits.max_archive_members, name_budget=name_budget,
                  should_stop=should_stop)
    seen: set[str] = set()
    candidates: list[Member] = []
    skipped = other_audio = declared_total = names = 0
    os.lseek(f.fileno(), 0, os.SEEK_SET)
    with libarchive.fd_reader(f.fileno(), format_name=reader.format_name,
                              filter_name=reader.filter_name) as archive:
        for index, entry in enumerate(archive):
            if should_stop is not None and should_stop():
                raise ArchiveStopped()
            if index == 0:
                _check_reader(archive, reader)
            if index >= limits.max_archive_members:
                raise ValidationFailed(errors.upload_archive_too_many_members())
            if not isinstance(entry.pathname, str):  # missing or not decodable
                raise ValidationFailed(errors.upload_archive_invalid())
            names += len(entry.pathname.encode("utf-8", "surrogatepass"))
            if names > name_budget:
                raise ValidationFailed(errors.upload_archive_too_many_members())
            declared = entry.size or 0
            unsafe = entry.islnk or not (entry.isreg or entry.isdir)  # links, devices, fifos, sockets
            name = check_member(entry.pathname, is_dir=entry.isdir, declared=declared, compressed=None,
                                limits=limits, seen=seen,
                                refused=errors.upload_archive_unsafe_member() if unsafe else None)
            declared_total += declared
            if declared_total > budget:
                raise ValidationFailed(errors.upload_archive_ratio_exceeded())
            if name is not None:
                candidates.append(Member(index, name, declared, size))
            elif not entry.isdir:
                skipped += 1
                other_audio += is_other_audio(entry.pathname)
        _check_reader(archive, reader)  # also an archive without entries
    check_batch_totals(candidates, limits)
    return ArchivePlan(tuple(candidates), skipped, other_audio)


def _check_reader(archive, reader: _Reader) -> None:
    if tuple(archive.filter_names) != reader.filters:
        raise ValidationFailed(errors.upload_archive_invalid())


# --- the reserved, bounded unpack ----------------------------------------------

_PREFIX = "upload_archive_"
REFUSAL_CODES = frozenset({
    "invalid", "corrupt", "unsafe_path", "unsafe_member", "encrypted", "unsupported_compression",
    "duplicate_names", "nested", "too_many_members", "too_many_audio", "member_too_large",
    "expanded_too_large", "ratio_exceeded",
})
# A member name the disk cannot hold (too long, or bytes the filesystem rejects).
_UNWRITABLE_NAME = frozenset({errno.ENAMETOOLONG, errno.EILSEQ, errno.EINVAL})
_UNPACK_DIR = re.compile(r"unpack-[0-9a-f]{32}")
_OWNER_DIR = re.compile(r"u[0-9]+")
# Archives inspected and copied at once, all owners together: a large
# archive's listing takes hundreds of MiB, and up to 16 ingest threads run.
CONCURRENT_UNPACKS = 2
_unpack_slots = threading.BoundedSemaphore(CONCURRENT_UNPACKS)
_SLOT_POLL_S = 0.5


@contextmanager
def _unpack_slot(should_stop):
    """One of the shared slots; while waiting, a stop gives up with ``ArchiveStopped``."""
    slots = _unpack_slots  # read at call time
    if not slots.acquire(blocking=False):
        while True:
            if should_stop():
                raise ArchiveStopped()
            if slots.acquire(timeout=_SLOT_POLL_S):
                break
    try:
        yield
    finally:
        slots.release()


class _Coded(Exception):
    def __init__(self, code):
        super().__init__(code)
        self.code = code


class ArchiveRefused(_Coded):
    """Final: the same bytes would be refused again (``code`` in REFUSAL_CODES).
    ``remembered``: refused earlier, unchanged since, and not inspected again."""

    def __init__(self, code, *, remembered=False):
        super().__init__(code)
        self.remembered = remembered


class ArchiveNoSpace(_Coded):
    """Environmental: insufficient_storage, free_space_unknown or disk_full."""


class ArchiveWriteFailed(_Coded):
    """Environmental: writing an entry failed for another reason."""

    def __init__(self, code="write_failed"):
        super().__init__(code)


class ArchiveStopped(Exception):
    """The server is stopping; the unpack was abandoned."""


@dataclass(frozen=True)
class Unpacked:
    folder: Path
    files: tuple[Path, ...]  # the audio entries, in plan order (one per planned member)
    other_audio: int = 0     # skipped entries with audio the server does not import


@functools.cache
def default_limits() -> ImportArchiveLimits:
    """The settings' defaults (no environment read): the limits of an
    unpacker built without the server's settings."""
    return import_archive_limits(Settings.model_construct())


def _code(exc: ValidationFailed) -> str:
    """The short refusal code; anything unexpected is 'invalid', so only the
    thirteen known codes ever reach a log line."""
    code = exc.error.code.removeprefix(_PREFIX)
    return code if code in REFUSAL_CODES else "invalid"


class ArchiveUnpacker:
    """Unpacks one owner's import-folder archives: inspected first, the worst
    case (the audio entries' ``disk_cost``) reserved for the copy, only the
    audio entries written, each into a folder of its own (``<position>/<file
    name>``: no tree from the archive's paths) inside a fresh folder that
    never outlives the ``with`` block.
    A refusal is remembered by the file's identity and the limits in effect,
    so an unchanged archive is not inspected again on every scan."""

    def __init__(self, *, owner_id, ledger, limits, chunk_size=1024 * 1024):
        self._owner_id = owner_id
        self._ledger = ledger  # None: no reservation (unit tests only)
        self._limits = limits
        self._chunk_size = chunk_size
        self._refused: dict = {}  # archive path -> (identity, limits, code)

    @property
    def owner_id(self):
        return self._owner_id

    def remembered(self, archive) -> bool:
        """Whether this unchanged archive was refused under the current
        limits: the caller can skip it without reading it."""
        return self._known(archive, file_identity(archive), self._limits()) is not None

    def byte_budget(self, size: int) -> int:
        """The most an archive of ``size`` bytes may expand to under the current limits."""
        return self._limits().max_compression_ratio * max(size, 1)

    def header_cap(self) -> int:
        """The most tar headers a walk reads under the current limits."""
        return HEADERS_PER_MEMBER * self._limits().max_archive_members

    def _known(self, archive, identity, limits) -> str | None:
        known = self._refused.get(archive)
        if identity is not None and known is not None and known[:2] == (identity, limits):
            return known[2]
        return None

    @contextmanager
    def unpack(self, archive, workspace_dir: Path, *, should_stop):
        limits = self._limits()
        identity = file_identity(archive)
        code = self._known(archive, identity, limits)
        if code is not None:
            raise ArchiveRefused(code, remembered=True)
        with _unpack_slot(should_stop):  # the import of the members runs outside it
            folder, files, other_audio = self._unpack(archive, identity, limits, workspace_dir, should_stop)
        try:
            self._refused.pop(archive, None)
            yield Unpacked(folder, files, other_audio)
        finally:
            shutil.rmtree(folder, ignore_errors=True)

    def _unpack(self, archive, identity, limits, workspace_dir, should_stop):
        """Inspect, reserve, copy: ``(folder, files, other_audio)``. The
        reservation covers the copy only and is released when it ends: once
        the bytes are on disk the free space shows them, so holding it through
        the import would count them twice. On failure the folder is removed
        first, so the release never frees bytes still on disk."""
        try:
            # Opened once: the copy reads the very file that was inspected.
            source = open(archive, "rb", buffering=0)
        except OSError as exc:
            # Environmental: tried again later, not remembered.
            if is_transient_read_error(exc):
                raise ArchiveWriteFailed("read_failed") from None
            raise self._refuse(archive, identity, limits, "invalid") from None
        with source:
            try:
                plan = inspect(source, limits, should_stop=should_stop)
            except ValidationFailed as exc:
                if exc.error.retryable:  # environmental, never remembered
                    raise ArchiveWriteFailed("read_failed") from None
                raise self._refuse(archive, identity, limits, _code(exc)) from None
            reservation = folder = None
            try:
                try:
                    workspace_dir.mkdir(parents=True, exist_ok=True)
                    block = _block_size(workspace_dir)
                    nbytes = sum(disk_cost(m.declared_bytes, block) for m in plan.members)
                    if self._ledger is not None:
                        try:
                            reservation = self._ledger.reserve(owner_id=self._owner_id, purpose=IMPORT_UNPACK,
                                                               nbytes=nbytes, subject_ref=None)
                        except InsufficientStorage as exc:
                            raise ArchiveNoSpace(exc.code) from None
                    folder = workspace_dir / f"unpack-{uuid.uuid4().hex}"
                    folder.mkdir()
                    files = self._copy(source, plan, folder, limits, nbytes, should_stop)
                except ValidationFailed as exc:
                    raise self._refuse(archive, identity, limits, _code(exc)) from None
                except (FileExistsError, NotADirectoryError, IsADirectoryError, PathEscapesRoot):
                    raise self._refuse(archive, identity, limits, "invalid") from None
                except OSError as exc:
                    if exc.errno in _UNWRITABLE_NAME:  # a name the disk cannot hold
                        raise self._refuse(archive, identity, limits, "invalid") from None
                    if exc.errno in (errno.ENOSPC, errno.EDQUOT):
                        raise ArchiveNoSpace("disk_full") from None
                    raise ArchiveWriteFailed() from None
            except BaseException:
                if folder is not None:
                    shutil.rmtree(folder, ignore_errors=True)
                raise
            finally:
                if reservation is not None:
                    try:
                        self._ledger.release(reservation)
                    except Exception as exc:  # never replaces the outcome; the next start reconciles it
                        operator_logger.warning("An import unpack reservation was not released: %s",
                                                type(exc).__name__)
        return folder, files, plan.other_audio

    def _refuse(self, archive, identity, limits, code) -> ArchiveRefused:
        self._refused[archive] = (identity, limits, code)
        return ArchiveRefused(code)

    def _copy(self, source, plan, folder, limits, reserved, should_stop) -> tuple[Path, ...]:
        """Each audio entry through the shared byte counters: never more than
        it declared (more is a corrupt archive, the reservation counted the
        declared size), the ratio, and never more in total than was reserved."""
        def between():
            if should_stop():
                raise ArchiveStopped()

        files, written = [], 0
        position = {m.index: i for i, m in enumerate(plan.members)}

        def write(member, read):
            nonlocal written
            own = folder / str(position[member.index])
            target = own / member.name.rsplit("/", 1)[-1]
            assert_within(target, folder)
            own.mkdir()
            with open(target, "xb") as out:
                try:
                    total, _ = copy_member(
                        read, out.write, compressed_bytes=member.compressed_bytes,
                        member_cap=member.declared_bytes, budget_left=reserved - written,
                        ratio=limits.max_compression_ratio, chunk_size=self._chunk_size, between=between)
                except ValidationFailed as exc:
                    if exc.error.code == errors.upload_archive_member_too_large().code:
                        raise ValidationFailed(errors.upload_archive_corrupt()) from None
                    raise
            written += total
            files.append(target)

        try:
            if _name(source).endswith(".zip"):
                source.seek(0)
                with zipfile.ZipFile(source) as zf:
                    infos = zf.infolist()
                    for member in plan.members:
                        with zf.open(infos[member.index]) as src:
                            write(member, src.read)
            elif plan.members:
                self._copy_listed(source, plan, write)
        except (zipfile.BadZipFile, zlib.error, EOFError, ArchiveError, IndexError):
            raise ValidationFailed(errors.upload_archive_corrupt()) from None
        if len(files) != len(plan.members):  # a planned entry the copy never reached
            raise ValidationFailed(errors.upload_archive_corrupt())
        return tuple(files)

    def _copy_listed(self, source, plan, write) -> None:
        """tar / tar.gz / RAR: one pass with the inspection's reader, the
        wanted entries found by their ordinal."""
        reader = _reader(source, _ext(_name(source)))
        wanted = {m.index: m for m in plan.members}
        last = max(wanted)
        os.lseek(source.fileno(), 0, os.SEEK_SET)
        with libarchive.fd_reader(source.fileno(), format_name=reader.format_name,
                                  filter_name=reader.filter_name) as listing:
            for index, entry in enumerate(listing):
                if index in wanted:
                    blocks = entry.get_blocks(self._chunk_size)
                    write(wanted[index], lambda _n: next(blocks, b""))
                if index >= last:
                    return


def sweep_workspace(root: Path) -> None:
    """Startup, before any import runs: remove the unpack folders a previous
    run left behind (``u<owner>/unpack-<hex>``, real directories only).
    Anything else is not ours: left in place and counted in one line without
    a path or name. Never raises."""
    try:
        root = Path(root).resolve(strict=True)
    except (OSError, RuntimeError):
        return
    foreign = 0
    try:
        with os.scandir(root) as owners:
            for owner in owners:
                if not (_OWNER_DIR.fullmatch(owner.name) and owner.is_dir(follow_symlinks=False)):
                    foreign += 1
                    continue
                with os.scandir(owner.path) as entries:
                    for entry in entries:
                        if not (_UNPACK_DIR.fullmatch(entry.name) and entry.is_dir(follow_symlinks=False)):
                            foreign += 1
                            continue
                        try:
                            shutil.rmtree(entry.path)
                        except Exception as exc:
                            operator_logger.warning("An import unpack folder was not removed: %s",
                                                    type(exc).__name__)
    except Exception as exc:
        operator_logger.warning("The import workspace was not swept: %s", type(exc).__name__)
    if foreign:
        operator_logger.warning(
            "The import workspace holds %d entries the server did not make; they were left in place.",
            foreign)

