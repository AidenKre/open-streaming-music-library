"""Upload link fallback (sign-off DEV-7-25): the placement record and its proof.

Before a library that refuses hard links gets the work file moved (or, once
its temp exists, copied) into place, a record next to the work file
(``<work>.place``, flushed) holds the prepared file's size and sha256, the
final name it was written for, and whether this operation made the temp next
to that name (``"temp"``: only a copy, and only after its O_EXCL create). After
a crash it is the only proof (besides the work file's own hard link) that the
file at the final name is this import's, and the only licence to remove that
temp. A record is trusted only inside the owner's own uploads folder; a final
or temp only in a folder inside the owner's library root. ``final_is_placed``
holds the proof order; its third proof (name and audio, sign-off
s7-live-findings item 3) is used at startup only, with the work file proven
absent."""

import errno
import hashlib
import json
import logging
import os
import re
import stat
from pathlib import Path

from app.core.durable_fs import fsync_dir, fsync_file
from app.services import organizer
from app.services.path_sanitize import assert_within
from app.services.upload_receipt import owner_dir

log = logging.getLogger(__name__)

HASH_BLOCK_BYTES = 1024 * 1024
_RECORD_MAX_BYTES = 4096
_SHA256 = re.compile(r"[0-9a-f]{64}")
_ABSENT = object()  # no record at all (unlike None: a record that proves nothing)
# Never follow a symbolic link, never block on a FIFO swapped in.
_READ_FLAGS = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)


def _record_path(row, uploads_root) -> Path:
    """``<work>.place``; raises ValueError unless it is inside the owner's folder."""
    record = Path(row["work_path"] + ".place")
    assert_within(record, owner_dir(Path(uploads_root), row["owner_id"]))
    return record


def _hash(path):
    """(size, sha256 hex) of the regular file at ``path``, read in bounded blocks
    without following a symbolic link; None when it is not such a file."""
    before = os.lstat(path)
    if not stat.S_ISREG(before.st_mode):
        return None
    fd = os.open(path, _READ_FLAGS)
    try:
        opened = os.fstat(fd)
        if not stat.S_ISREG(opened.st_mode) or (opened.st_dev, opened.st_ino) != (
                before.st_dev, before.st_ino):
            return None
        digest, size = hashlib.sha256(), 0
        while block := os.read(fd, HASH_BLOCK_BYTES):
            digest.update(block)
            size += len(block)
        return size, digest.hexdigest()
    finally:
        os.close(fd)


def _valid(data) -> bool:
    return (isinstance(data, dict) and set(data) == {"v", "sha256", "size", "final", "temp"}
            and type(data["v"]) is int and data["v"] == 1  # never True or 1.0
            and isinstance(data["sha256"], str) and _SHA256.fullmatch(data["sha256"]) is not None
            and type(data["size"]) is int and data["size"] >= 0
            and isinstance(data["final"], str) and type(data["temp"]) is bool)


def _read_record(record: Path):
    """The record's content, ``_ABSENT``, or None when it proves nothing. A
    record that cannot be read raises ``LinkUnknown``."""
    try:
        info = os.lstat(record)
        if not stat.S_ISREG(info.st_mode) or info.st_size > _RECORD_MAX_BYTES:
            return None
        fd = os.open(record, _READ_FLAGS)
        try:
            if not stat.S_ISREG(os.fstat(fd).st_mode):
                return None
            raw = os.read(fd, _RECORD_MAX_BYTES + 1)
        finally:
            os.close(fd)
    except (FileNotFoundError, NotADirectoryError):
        return _ABSENT
    except OSError as e:
        if e.errno == errno.ELOOP:  # a symbolic link swapped in: not a record
            return None
        raise organizer.LinkUnknown(e.errno, e.strerror) from e
    try:
        data = json.loads(raw.decode("utf-8"))
    except ValueError:  # includes UnicodeDecodeError
        return None
    return data if len(raw) <= _RECORD_MAX_BYTES and _valid(data) else None


def _proven_absent(e: OSError) -> bool:
    """A missing name, a parent that is not a folder, or a name too long to exist."""
    return isinstance(e, (FileNotFoundError, NotADirectoryError)) or e.errno == errno.ENAMETOOLONG


def _remove(path: Path) -> tuple[bool, bool]:
    """(whether this call removed it, whether it is now verifiably gone)."""
    removed = False
    try:
        os.unlink(path)
        removed = True
    except OSError as e:
        if not _proven_absent(e):
            log.warning("upload placement file not removed: %s", type(e).__name__)
    try:
        os.lstat(path)
    except OSError as e:
        return removed, _proven_absent(e)
    return removed, False


def _within(path, root) -> bool:
    try:
        assert_within(path, root)
        return True
    except (ValueError, OSError, RuntimeError):  # resolving a symlink loop raises
        return False


def _temp_of(final, library_root):
    """The temp next to a record's ``final``, or None when that folder is not
    really the owner's root or inside it (resolved: a symlink from outside is
    not inside)."""
    try:
        parent = Path(final).parent.resolve()
        root = Path(library_root).resolve()
    except (OSError, RuntimeError):
        return None
    if parent != root and not parent.is_relative_to(root):
        return None
    return parent / organizer.temp_name_for(Path(final)).name


def _remove_own_temp(temp: Path) -> tuple[bool, bool]:
    """(whether this call removed it, whether nothing of ours is left there).
    Only a regular file is ours; anything else at the name is left alone."""
    try:
        info = os.lstat(temp)
    except OSError as e:
        return False, _proven_absent(e)
    if not stat.S_ISREG(info.st_mode):
        return False, True
    return _remove(temp)


def measure(row) -> tuple[int, str]:
    """(size, sha256) of the row's work file; raises when it is not a regular file."""
    hashed = _hash(Path(row["work_path"]))
    if hashed is None:
        raise OSError(errno.EINVAL, "the work file is not a regular file")
    return hashed


def write_record(row, *, uploads_root, library_root, temp: bool, measured=None) -> None:
    """Write and flush the placement record for ``row`` (the publisher's
    ``before_fallback`` hook); ``temp`` says this call created the temp (a
    copy, after its O_EXCL create). ``measured`` is the work file's
    ``measure(row)`` taken earlier (a copy measures before its temp exists);
    without it the work file is hashed here. Raises when a path is outside its
    root or anything fails."""
    record = _record_path(row, uploads_root)
    assert_within(Path(row["final_path"]), library_root)
    size, sha256 = measured if measured is not None else measure(row)
    data = json.dumps({"v": 1, "sha256": sha256, "size": size, "final": row["final_path"],
                       "temp": bool(temp)})
    fd = os.open(record, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | getattr(os, "O_NOFOLLOW", 0), 0o600)
    with open(fd, "wb") as out:
        out.write(data.encode("utf-8"))
    fsync_file(record)
    fsync_dir(record.parent)


def remove_earlier_temp(row, *, uploads_root, library_root) -> None:
    """Before a new attempt: remove the temp an earlier attempt's record proves
    it made, and flush its folder, before any new record can replace that proof.
    Raises OSError when it is still there (``LinkUnknown`` when the record cannot
    be read)."""
    record = _read_record(_record_path(row, uploads_root))
    if not isinstance(record, dict) or record["temp"] is not True:
        return
    temp = _temp_of(record["final"], library_root)
    if temp is None:
        return  # no temp of ours can be there
    removed, gone = _remove_own_temp(temp)
    if not gone:
        raise OSError(errno.EBUSY, "an earlier attempt's temporary file is still there")
    if removed:
        fsync_dir(temp.parent)


class AudioUnknown(organizer.LinkUnknown):
    """The final's audio could not be compared now; ``reason`` is a fixed word
    (never a path)."""

    def __init__(self, reason: str):
        super().__init__(reason)
        self.reason = reason


def final_is_placed(row, *, uploads_root, library_root, audio=None) -> bool:
    """Is the file at the row's final name this operation's? The one proof
    order: its own hard link, then a file its placement record proves, then,
    only when ``audio`` is given (startup recovery alone), its name and audio
    (``audio_proves_final``: the work file proven absent). Raises
    ``LinkUnknown`` when a name or the audio cannot be examined."""
    if organizer.final_is_own_link(row) or record_proves_final(
            row, uploads_root=uploads_root, library_root=library_root):
        return True
    return audio is not None and audio_proves_final(row, library_root=library_root, audio=audio)


def audio_proves_final(row, *, library_root, audio) -> bool:
    """Row HP (a power cut lost the ``moved`` commit but kept the work file's
    removal): the work file is proven absent, and the row's final name is a
    regular file inside ``library_root`` (a symbolic link is never followed)
    for which ``audio(final)`` says the decoded audio equals the journaled
    digest. ``audio`` returns a bool or raises ``LinkUnknown``. Raises
    ``LinkUnknown`` when a name cannot be examined and ``AudioUnknown`` when the
    final changed while it was checked."""
    try:
        os.lstat(row["work_path"])
        return False  # the work file is still there: not this case
    except OSError as e:
        if not _proven_absent(e):
            raise organizer.LinkUnknown(e.errno, e.strerror) from e
    final = Path(row["final_path"])
    if not _within(final, library_root):
        return False  # never opened
    try:
        before = os.lstat(final)
    except (FileNotFoundError, NotADirectoryError):
        return False
    except OSError as e:
        raise organizer.LinkUnknown(e.errno, e.strerror) from e
    if not stat.S_ISREG(before.st_mode):
        return False
    if not _opens(final, before):
        return False
    verdict = audio(final)
    try:
        after = os.lstat(final)
    except OSError as e:
        raise AudioUnknown("file_changed") from e
    if not stat.S_ISREG(after.st_mode) or _identity(after) != _identity(before):
        raise AudioUnknown("file_changed")
    return bool(verdict)


def _opens(final: Path, before) -> bool:
    """The server can read the regular file ``before`` describes (a decoder
    that cannot open a file reports a decode error, which would read as other
    audio). False for a symbolic link swapped in; raises ``AudioUnknown`` for
    another file at the name or a file that cannot be read."""
    try:
        fd = os.open(final, _READ_FLAGS)
    except OSError as e:
        if e.errno == errno.ELOOP:
            return False
        raise AudioUnknown(errno.errorcode.get(e.errno) or type(e).__name__) from e
    try:
        opened = os.fstat(fd)
        if not stat.S_ISREG(opened.st_mode) or (opened.st_dev, opened.st_ino) != (
                before.st_dev, before.st_ino):
            raise AudioUnknown("file_changed")
        os.read(fd, 1)
    except AudioUnknown:
        raise
    except OSError as e:
        raise AudioUnknown(errno.errorcode.get(e.errno) or type(e).__name__) from e
    finally:
        os.close(fd)
    return True


def _identity(info) -> tuple:
    return info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns


def record_proves_final(row, *, uploads_root, library_root) -> bool:
    """The row's record names its final name, and that is a regular file inside
    ``library_root`` with the recorded size and sha256. Raises ``LinkUnknown``
    when the record or the final cannot be examined."""
    try:
        record = _read_record(_record_path(row, uploads_root))
    except ValueError:
        return False
    if not isinstance(record, dict) or record["final"] != row["final_path"]:
        return False
    final = Path(row["final_path"])
    if not _within(final, library_root):
        return False  # never opened or hashed
    try:
        info = os.lstat(final)
        if not stat.S_ISREG(info.st_mode) or info.st_size != record["size"]:
            return False
        hashed = _hash(final)
    except (FileNotFoundError, NotADirectoryError):
        return False
    except OSError as e:
        if e.errno == errno.ELOOP:  # a symbolic link swapped in after the lstat
            return False
        raise organizer.LinkUnknown(e.errno, e.strerror) from e
    return hashed is not None and hashed == (record["size"], record["sha256"])


def clear_leftovers(row, *, uploads_root, library_root) -> bool:
    """Remove what this operation's fallback left: the temp its record proves it
    made, then the record (both removals flushed). True when nothing is left;
    False keeps the journal row for a later pass. The temp is found from the
    record, never from the row."""
    if not row.get("work_path"):
        return True  # no work file, so no record
    try:
        record_path = _record_path(row, uploads_root)
    except ValueError:
        return False
    try:
        record = _read_record(record_path)
    except OSError:
        return False
    if record is _ABSENT:
        return True
    if isinstance(record, dict) and record["temp"] is True:
        temp = _temp_of(record["final"], library_root)
        if temp is None:
            return False  # touch nothing
        removed, gone = _remove_own_temp(temp)
        if not gone:
            return False
        if removed:
            fsync_dir(temp.parent)
            organizer.prune_empty_dirs(temp.parent, Path(library_root))  # the folders made for it
    removed, gone = _remove(record_path)
    if removed:
        fsync_dir(record_path.parent)
    return gone
