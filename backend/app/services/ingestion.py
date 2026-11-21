from pathlib import Path
from app.core.media_types import AUDIO_EXTENSIONS, ARCHIVE_EXTENSIONS
from dataclasses import dataclass
from typing import Callable
import errno
import logging
import signal
import stat
import threading
import json
import os
import gzip
import struct
import tarfile

from app.core.operator_log import operator_logger
from app.services.import_archive import (
    ArchiveChanged, ArchiveNoSpace, ArchiveRefused, ArchiveStopped, ArchiveUnpacker, ArchiveWriteFailed,
    default_limits,
)
from app.services.import_outcome import (
    EntryMemory, ImportOutcome, entry_key, expected_special_entry, file_identity, file_signature,
    open_regular_file,
)
from app.services.ffmpeg_runner import (
    CaptureOverflow, CaptureTimeout, FfmpegError, FfmpegProcessRegistry, run_capture,
)
from app.services.metadata import ProbeUnavailable  # re-exported: ingestion.ProbeUnavailable
from app.services.metadata import (
    SHORT_PROBE_MAX_STDOUT_BYTES, probe_registration, probe_timeout, probes_killed_by,
)

logger = logging.getLogger(__name__)

IMPORTED_DIR_NAME = ".imported"


def _never_stop() -> bool:
    return False


@dataclass(frozen=True)
class IngestorContext:
    workspace_dir: Path
    organize_function: Callable[[Path], ImportOutcome | bool]
    should_stop: Callable[[], bool] = _never_stop
    # The owner's unpacker (the pipeline builds it); None: one without a
    # reservation, with the import-archive defaults.
    archives: ArchiveUnpacker | None = None
    # The quick check runs registered here, so closing it at shutdown ends it.
    probe_registry: FfmpegProcessRegistry | None = None


class _AlreadyRefused(Exception):
    """An unchanged archive refused before: REFUSED, and nothing is logged again."""


class _SkippedEntry(Exception):
    """An entry that is no regular file: NOT_AUDIO, and only its own skip line."""


class Ingestor:
    def __init__(self, ctx: IngestorContext):
        self.ctx = ctx
        self.organize_function = ctx.organize_function
        self._archives = ctx.archives or ArchiveUnpacker(
            owner_id=None, ledger=None, limits=default_limits)
        # Entries that are no regular file, named once (by their entry_key).
        self._skipped = EntryMemory()

    def ingest_file(self, file_path: Path, *, imported_dir: Path) -> bool:
        """True when imported, or the archive was deleted or set aside."""
        return self.ingest(file_path, imported_dir=imported_dir) is ImportOutcome.IMPORTED

    def ingest(self, file_path: Path, *, imported_dir: Path) -> ImportOutcome:
        """Why a path was or was not imported. Every attempt that is not
        imported is logged once, here (an entry that is no regular file only
        by its own skip line, once). An archive leaves its folder only when
        every audio file was imported (deleted) or refused for a reason of its
        own (set aside); otherwise it stays for the next scan."""
        try:
            outcome = self._ingest(file_path, imported_dir)
        except _AlreadyRefused:
            return ImportOutcome.REFUSED
        except _SkippedEntry:
            return ImportOutcome.NOT_AUDIO
        except ProbeUnavailable:
            outcome = ImportOutcome.TOOL_UNAVAILABLE
        if outcome is not ImportOutcome.IMPORTED:
            name = _in_folder(file_path, imported_dir.parent)  # never a full path
            owner = self._archives.owner_id
            if is_archive(file_path):
                logger.warning("archive kept: %s of user %s (%s)", name, owner, outcome.value)
            else:
                logger.warning("import failed: %s of user %s (%s)", name, owner, outcome.value)
        return outcome

    def _ingest(self, file_path: Path, imported_dir: Path) -> ImportOutcome:
        # A symbolic link (or anything else that is not a regular file) is never
        # imported and never read through: not probed, not unpacked. It stays
        # where it is, like any file that is no audio file. Nor a file reached
        # through a linked folder: it does not lie in this import folder, and
        # moving it would take it from wherever it really is.
        import_folder = imported_dir.parent
        # Handed over by the watcher as an entry that is no regular file: what
        # lies there now (a regular file) is new and gets the watcher's wait.
        expected = expected_special_entry.get()
        if expected is not None and entry_key(file_path) != expected:
            return ImportOutcome.CHANGED
        if _is_no_regular_file(file_path):
            self._name_skipped(file_path, import_folder)
            raise _SkippedEntry()
        if _under_a_linked_folder(file_path, import_folder):
            return ImportOutcome.NOT_AUDIO
        if is_archive(file_path):
            return self._ingest_archive(file_path, imported_dir)
        if not is_music_file(file_path):
            return ImportOutcome.NOT_AUDIO
        return self._ingest_member(file_path)

    def _name_skipped(self, path: Path, import_folder: Path) -> None:
        """Tells the operator once what lies at ``path`` (looked at with
        ``lstat`` only, never opened); again only for a new entry at the name."""
        key = entry_key(path)
        if key is None or self._skipped.knows(path, key):
            return
        self._skipped.remember(path, key)
        operator_logger.warning(
            "An entry in an import folder of user %s is skipped: %s is %s, not a file.",
            self._archives.owner_id, _in_folder(path, import_folder), _kind_of_entry(key[2]))

    def _ingest_archive(self, file_path: Path, imported_dir: Path) -> ImportOutcome:
        """The archive goes through the shared archive checks (bomb guards
        only, no size or count limit) and a reservation of its disk cost for
        the copy (sign-off DEV-7-14 point 1); only its planned audio entries
        are unpacked, and the folder is removed after their import.
        From an import folder (``imported_dir``), an archive whose every audio
        file was imported is deleted (DEV-M-10); one with a track refused for
        its own content, without audio, or with audio the server does not
        import, is set aside in ``imported_dir`` (the last with a warning:
        owner, "keep it, and warn the user")."""
        if self._archives.remembered(file_path):  # refused before, unchanged: not even read
            raise _AlreadyRefused()
        before = file_signature(file_path)
        identity = file_identity(file_path)  # None for a symlink: never deleted
        # Bounded by the ratio: past it, the inspection refuses the archive.
        max_bytes = self._archives.byte_budget(before[0] if before else 0)
        if not archive_is_complete(file_path, max_bytes=max_bytes, should_stop=self.ctx.should_stop,
                                   max_headers=self._archives.header_cap()):
            return ImportOutcome.INCOMPLETE
        kept: ImportOutcome | None = None
        imported = 0  # audio files imported from this archive
        owner = self._archives.owner_id
        try:
            with self._archives.unpack(file_path, self.ctx.workspace_dir,
                                       should_stop=self.ctx.should_stop, expected=identity) as unpacked:
                planned, other_audio = len(unpacked.files), unpacked.other_audio
                if file_signature(file_path) != before:
                    return ImportOutcome.CHANGED
                for member in unpacked.files:
                    if self.ctx.should_stop():
                        return ImportOutcome.STOPPED
                    if not member.is_file():
                        kept = kept or ImportOutcome.CHANGED
                        continue
                    outcome = self._ingest_member(member)
                    if outcome is ImportOutcome.IMPORTED:
                        imported += 1
                    elif not outcome.belongs_to_file:
                        kept = kept or outcome
        except ArchiveRefused as e:
            if e.remembered:
                raise _AlreadyRefused() from None
            operator_logger.warning(
                "An archive in an import folder of user %s was not unpacked (%s); it stays in the folder.",
                owner, e.code)
            return ImportOutcome.REFUSED
        except (ArchiveNoSpace, ArchiveWriteFailed) as e:
            operator_logger.warning(
                "An archive in an import folder of user %s was not unpacked now (%s); it is tried again later.",
                owner, e.code)
            return ImportOutcome.NO_SPACE if isinstance(e, ArchiveNoSpace) else ImportOutcome.UNPACK_FAILED
        except ArchiveStopped:
            return ImportOutcome.STOPPED
        except ArchiveChanged:
            return ImportOutcome.CHANGED

        if kept is not None:
            return kept
        if file_signature(file_path) != before:
            return ImportOutcome.CHANGED
        # Every audio file imported, from a regular file: delete. Otherwise (a
        # track refused for its own content, no audio, audio the server does
        # not import): set aside.
        if imported > 0 and imported == planned and other_audio == 0 and identity is not None:
            return self._delete_archive(file_path, identity, imported)
        # Only the very file that was looked at first is moved (as only that
        # file would be deleted): not a link, and not another file that came
        # to lie at the path meanwhile. Checked here (nothing is made in
        # .imported for a changed file) and again inside the opened folder.
        if identity is None or file_identity(file_path) != identity:
            return ImportOutcome.CHANGED
        try:
            target = move_to_imported(file_path, imported_dir, identity)
        except SetAsideChanged:
            return ImportOutcome.CHANGED
        except SetAsideRefused as e:
            operator_logger.warning(
                "An archive in an import folder of user %s could not be set aside in .imported (%s);"
                " it stays in the folder and is tried again when it changes or when the server restarts.",
                owner, e.reason)
            # Not unpacked again in this run while it is unchanged.
            self._archives.remember_kept(file_path, identity, "set_aside_failed")
            return ImportOutcome.MOVE_FAILED
        if other_audio > 0:
            folder = imported_dir.parent
            operator_logger.warning(
                "An archive in an import folder of user %s was kept as %s (it was %s): %s imported,"
                " %s in a format the server cannot import.",
                owner, _in_folder(target, folder), _in_folder(file_path, folder),
                _songs(imported), _songs(other_audio))
        return ImportOutcome.IMPORTED

    def _delete_archive(self, file_path: Path, identity, imported: int) -> ImportOutcome:
        """Removes exactly this one file, and only if it is still the file
        that was imported (sign-off DEV-M-10). A failed removal keeps it: its
        tracks are in, and the watcher remembers the unchanged file.
        The name is checked and removed inside one opened folder: a folder on
        the way swapped for a link in between cannot redirect the removal."""
        owner = self._archives.owner_id
        try:
            folder = os.open(file_path.parent, os.O_RDONLY | os.O_DIRECTORY)
        except OSError:
            return ImportOutcome.CHANGED
        try:
            if file_identity(file_path.name, dir_fd=folder) != identity:
                return ImportOutcome.CHANGED
            try:
                os.unlink(file_path.name, dir_fd=folder)
            except OSError as e:
                operator_logger.warning(
                    "An archive in an import folder of user %s was imported in full but could not be"
                    " deleted (%s); it stays in the folder.", owner, _errno_name(e))
                return ImportOutcome.IMPORTED
        finally:
            os.close(folder)
        operator_logger.warning(
            "An archive in an import folder of user %s was imported in full (%d audio files) and deleted.",
            owner, imported)
        return ImportOutcome.IMPORTED

    def _ingest_member(self, path: Path) -> ImportOutcome:
        try:
            with probes_killed_by(self.ctx.probe_registry):
                passed = does_music_pass_quick_check(path)
        except ProbeUnavailable:
            # This member's environmental outcome: an archive's later members are still tried.
            return ImportOutcome.TOOL_UNAVAILABLE
        if not passed:
            return ImportOutcome.FAILS_CHECK
        if self.ctx.should_stop():
            return ImportOutcome.STOPPED
        return as_outcome(self.organize_function(path))


def _is_no_regular_file(path: Path) -> bool:
    """Whether something is at ``path`` itself (a symbolic link is not
    followed) that is not a regular file. A missing path is False: the
    import's own checks answer for it."""
    try:
        return not stat.S_ISREG(os.lstat(path).st_mode)
    except OSError:
        return False


_ENTRY_KINDS = (
    (stat.S_ISFIFO, "a named pipe"),
    (stat.S_ISLNK, "a symbolic link"),
    (stat.S_ISSOCK, "a socket"),
    (stat.S_ISCHR, "a device"),
    (stat.S_ISBLK, "a device"),
    (stat.S_ISDIR, "a folder"),
)


def _kind_of_entry(mode: int) -> str:
    """What an entry that is no regular file is, in plain words."""
    return next((words for test, words in _ENTRY_KINDS if test(mode)), "a special file")


def _under_a_linked_folder(path: Path, import_folder: Path) -> bool:
    """Whether a folder between ``import_folder`` and ``path`` is a symbolic
    link. Neither the import folder itself (an operator may reach it through a
    link) nor the file is looked at. False for a path not below it, and when a
    folder cannot be examined: the import's own checks answer for a path that
    is not there."""
    try:
        parts = path.relative_to(import_folder).parts
    except ValueError:
        return False
    folder = import_folder
    for part in parts[:-1]:
        folder = folder / part
        try:
            if stat.S_ISLNK(os.lstat(folder).st_mode):
                return True
        except OSError:
            return False
    return False


def _in_folder(path: Path, folder: Path) -> str:
    """The path relative to the import folder (never absolute in a log line);
    outside it, the file name only."""
    try:
        return path.relative_to(folder).as_posix()
    except ValueError:
        return path.name


def _songs(n: int) -> str:
    return "1 song" if n == 1 else f"{n} songs"


def as_outcome(result: ImportOutcome | bool) -> ImportOutcome:
    """Older callables and test doubles return a bool."""
    if isinstance(result, ImportOutcome):
        return result
    return ImportOutcome.IMPORTED if result else ImportOutcome.FAILS_CHECK


# One probe-and-move at a time: the POSIX rename replaces an existing file, so
# two same-named archives set aside at once could destroy one.
_imported_lock = threading.Lock()


class SetAsideRefused(Exception):
    """The archive cannot be set aside in ``.imported``: the folder is a symbolic
    link, something else has its name, it is on another filesystem, or the
    system refused (no permission, read-only, no space). Nothing was moved.
    ``reason`` is short: an errno name."""

    def __init__(self, reason: str):
        super().__init__(reason)
        self.reason = reason


class SetAsideChanged(Exception):
    """The archive is no longer the file that was looked at first (its folder
    cannot be opened, another file is at its name, or it is gone): nothing was
    moved, and nothing is kept for a reason of its own."""


def _errno_name(e: OSError) -> str:
    return errno.errorcode.get(e.errno) or type(e).__name__


def move_to_imported(archive_path: Path, imported_dir: Path, expected) -> Path:
    """Move a handled archive into imported_dir without overwriting anything,
    only if it is still the file of identity ``expected``."""
    with _imported_lock:
        return _move_to_imported(archive_path, imported_dir, expected)


def _move_to_imported(archive_path: Path, imported_dir: Path, expected) -> Path:
    # The archive is taken from its folder opened once (a link there is
    # followed: the identity proves the entry), so a folder on the way swapped
    # for a link later cannot hand over another file of the same name.
    try:
        source = os.open(archive_path.parent, os.O_RDONLY | os.O_DIRECTORY)
    except OSError:
        raise SetAsideChanged() from None
    try:
        return _move_from_folder(source, archive_path.name, imported_dir, expected)
    finally:
        os.close(source)


def _move_from_folder(source: int, name: str, imported_dir: Path, expected) -> Path:
    if imported_dir.is_symlink():
        raise SetAsideRefused("ELOOP")
    try:
        imported_dir.mkdir(parents=True, exist_ok=True)
    except FileExistsError:  # a dangling link, or a file, put at the name after the look
        raise SetAsideRefused("EEXIST") from None
    except OSError as e:
        raise SetAsideRefused(_errno_name(e)) from None
    lower = name.lower()
    ext = next((e for e in ARCHIVE_EXTENSIONS if lower.endswith(e)), "")
    stem = name[: len(name) - len(ext)] if ext else name
    suffix = name[len(stem):]
    # The folder is opened once, never through a link, and the archive is moved
    # into that very folder, so a link put at its name after the look changes
    # nothing; no name found in the folder is replaced.
    try:
        # ELOOP or ENOTDIR: a link put there after the look.
        folder = os.open(imported_dir, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    except OSError as e:
        raise SetAsideRefused(_errno_name(e)) from None
    try:
        candidate = name
        n = 2
        while _name_taken(candidate, folder):
            candidate = f"{stem}-{n}{suffix}"
            n += 1
        if file_identity(name, dir_fd=source) != expected:
            raise SetAsideChanged()
        # EXDEV (the folder is on another filesystem) included: the archive is
        # not moved, and never copied by its name.
        os.rename(name, candidate, src_dir_fd=source, dst_dir_fd=folder)
    except OSError as e:
        if e.errno == errno.ENOENT:  # removed or moved away since the look
            raise SetAsideChanged() from None
        raise SetAsideRefused(_errno_name(e)) from None
    finally:
        os.close(folder)
    return imported_dir / candidate


def _name_taken(name: str, folder: int) -> bool:
    """Whether anything (a dangling link too) has ``name`` in the opened
    ``folder``; a link is never followed."""
    try:
        os.stat(name, dir_fd=folder, follow_symlinks=False)
    except FileNotFoundError:
        return False
    return True

def is_music_file(file_path: Path) -> bool:
    return file_path.suffix.lower() in AUDIO_EXTENSIONS

def is_archive(file_path: Path) -> bool:
    # Match against known archive extensions at the *end* of the filename.
    # This intentionally supports names with extra dots like "my.album.v1.zip" or "backup.2025.12.tar.gz".
    name = file_path.name.lower()
    return any(name.endswith(ext) for ext in ARCHIVE_EXTENSIONS)

def is_macos_companion(file_path: Path) -> bool:
    """An AppleDouble file (``._<name>``) macOS writes beside each file on
    filesystems without extended attributes; it is metadata, never audio."""
    return file_path.name.startswith("._")

def does_music_pass_quick_check(file_path: Path, timeout: float | None = None) -> bool:
    """Whether ffprobe sees an audio stream. Bounded by ``timeout`` (default
    the shared probe bound); a tool that cannot start, a time-out or a SIGKILL
    raises ProbeUnavailable (unreadable for now); any other non-zero exit
    (another signal included, as in identity_reasons.reason_for_exit) is the
    file's own answer (False)."""
    try:
        with probe_registration() as registration:
            completed_process = run_capture(
                [
                    "ffprobe",
                    "-v",
                    "error",
                    "-select_streams",
                    "a",
                    "-hide_banner",
                    "-show_entries",
                    "stream=codec_type",
                    "-read_intervals",
                    "0%+#20",
                    "-of",
                    "json",
                    str(file_path),
                ],
                timeout_s=probe_timeout(timeout),
                max_stdout_bytes=SHORT_PROBE_MAX_STDOUT_BYTES,
                options=registration,
            )
    except CaptureOverflow:
        return False
    except CaptureTimeout as e:
        raise ProbeUnavailable("ffprobe timed out") from e
    except FfmpegError as e:  # not found, or cannot start
        if isinstance(e.__cause__, FileNotFoundError):
            operator_logger.warning("ffprobe not found")
        raise ProbeUnavailable(str(e)) from e
    except OSError as e:  # setting up the pipes failed (e.g. EMFILE): cannot run now
        raise ProbeUnavailable(f"ffprobe cannot run: {e.strerror or type(e).__name__}") from e

    if completed_process.returncode == -signal.SIGKILL:
        # A stop through the registry, the OOM killer: says nothing about the file.
        raise ProbeUnavailable("ffprobe was killed")
    if completed_process.returncode != 0:
        return False

    try:
        output = json.loads(completed_process.stdout.decode("utf-8", errors="replace") or "")
    except json.JSONDecodeError:
        return False

    if not isinstance(output, dict):
        return False

    streams = output.get("streams", [])
    if not isinstance(streams, list):
        return False

    for stream in streams:
        if isinstance(stream, dict) and stream.get("codec_type") == "audio":
            return True
    return False


def archive_is_complete(path: Path, *, max_bytes: int | None = None, should_stop=None,
                        max_headers: int | None = None) -> bool:
    """Whether an archive that may still be being copied has all its bytes.

    Deterministic (no timing): libarchive reads a tar or RAR cut at a member
    boundary as a shorter whole archive, so we walk the headers ourselves and
    call it complete only on the end-of-archive marker (tar: two zero blocks;
    RAR: the end header). Reaching EOF first means incomplete. Anything we
    cannot parse, or that raises while being parsed, is reported complete so the
    inspection decides, as is a path that is not a regular file (it is never
    opened, so a FIFO cannot block the check). A zip needs no check (its
    central directory is written last), and a truncated gzip fails on its
    trailer. A tar walk stops after ``max_bytes`` or ``max_headers``
    (complete: the inspection refuses it by its ratio or header count) and
    when ``should_stop()`` (incomplete: tried again on the next start).
    """
    name = path.name.lower()
    bounds = {"max_bytes": max_bytes, "should_stop": should_stop, "max_headers": max_headers}
    try:
        if name.endswith(".tar"):
            with open_regular_file(path) as f:
                return _tar_is_complete(f, **bounds)
        if name.endswith(".tar.gz"):
            with open_regular_file(path) as raw, gzip.GzipFile(fileobj=raw, mode="rb") as f:
                return _tar_is_complete(f, **bounds)
        if name.endswith(".rar"):
            with open_regular_file(path) as f:
                return _rar_is_complete(f)
    except Exception:
        # Truncated/corrupt/crafted input: libarchive's own failure decides.
        return True
    return True


def _tar_is_complete(f, *, max_bytes: int | None = None, should_stop=None,
                     max_headers: int | None = None) -> bool:
    read = headers = 0
    while True:
        if max_bytes is not None and read > max_bytes:
            return True
        if should_stop is not None and should_stop():
            return False
        buf = f.read(512)
        read += len(buf)
        if len(buf) < 512:
            return False
        if buf == bytes(512):
            return f.read(512) == bytes(512)
        headers += 1
        if max_headers is not None and headers > max_headers:
            return True  # the inspection refuses it by its header count
        try:
            info = tarfile.TarInfo.frombuf(buf, "utf-8", "surrogateescape")
        except tarfile.TarError:
            return True
        skip = -(-info.size // 512) * 512
        while skip:
            if should_stop is not None and should_stop():
                return False
            if max_bytes is not None and read > max_bytes:
                return True
            got = len(f.read(min(skip, 1 << 20)))
            if not got:
                return False
            read += got
            skip -= got


def _rar_vint(buf: bytes, pos: int) -> tuple[int, int] | None:
    """(value, next position) of a RAR5 variable-length integer, or None."""
    value = 0
    for i in range(10):
        if pos + i >= len(buf):
            return None
        byte = buf[pos + i]
        value |= (byte & 0x7F) << (7 * i)
        if not byte & 0x80:
            return value, pos + i + 1
    return None


_RAR5_MAX_HEADER = 2 * 1024 * 1024  # the format caps a header at 2 MB


def _rar_is_complete(f) -> bool:
    size = os.fstat(f.fileno()).st_size
    sig = f.read(8)
    if sig == b"Rar!\x1a\x07\x01\x00":
        pos = 8
        while pos < size:
            f.seek(pos)
            head = f.read(4 + 10)
            if len(head) < 5:
                return False
            parsed = _rar_vint(head, 4)
            if parsed is None:
                return True
            hsize, body_at = parsed
            if hsize > _RAR5_MAX_HEADER:
                return True  # not a valid header: the extractor fails it
            f.seek(pos + body_at)
            body = f.read(hsize)
            if len(body) < hsize:
                return False
            fields = []
            p = 0
            for _ in range(2):
                parsed = _rar_vint(body, p)
                if parsed is None:
                    return True
                fields.append(parsed[0])
                p = parsed[1]
            kind, flags = fields
            if kind == 5:
                return True
            if flags & 0x0001:
                parsed = _rar_vint(body, p)
                if parsed is None:
                    return True
                p = parsed[1]
            data = 0
            if flags & 0x0002:
                parsed = _rar_vint(body, p)
                if parsed is None:
                    return True
                data = parsed[0]
            pos += body_at + hsize + data
        return False
    if sig[:7] == b"Rar!\x1a\x07\x00":
        pos = 7
        while pos < size:
            f.seek(pos)
            head = f.read(11)
            if len(head) < 7:
                return False
            _crc, kind, flags, hsize = struct.unpack("<HBHH", head[:7])
            if hsize < 7:
                return True
            if kind == 0x7B:
                return True
            add = 0
            if flags & 0x8000:
                if hsize < 11:
                    return True
                if len(head) < 11:
                    return False
                add = struct.unpack("<I", head[7:11])[0]
                if kind == 0x74 and flags & 0x0100:
                    if hsize < 36:
                        return True
                    f.seek(pos + 32)
                    high = f.read(4)
                    if len(high) < 4:
                        return False
                    add += struct.unpack("<I", high)[0] << 32
            pos += hsize + add
        return False
    return True
