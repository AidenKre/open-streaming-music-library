"""What happened to one file offered to the import pipeline (review r2 m-R2-01).

The one place that says which failures belong to the file itself and which
come from the environment. An archive leaves its import folder only when every
audio file was imported (it is deleted) or refused for a reason of its own (it
is set aside in ``.imported/``); an environmental
failure (or a file that changed, or a shutdown) leaves it for the next scan.
An archive the shared archive checks refuse is neither: it stays in place and
is not tried again while it and the limits are unchanged.
"""

import contextvars
import os
import stat
import threading
from collections import OrderedDict
from enum import Enum
from pathlib import Path


class ImportOutcome(Enum):
    IMPORTED = "imported"
    # The file's own reasons: retrying the same bytes cannot succeed.
    DUPLICATE = "duplicate"
    NOT_AUDIO = "not_audio"
    FAILS_CHECK = "fails_check"
    # Environmental: the same bytes may import on a later attempt.
    TOOL_UNAVAILABLE = "tool_unavailable"
    DATABASE_ERROR = "database_error"
    MOVE_FAILED = "move_failed"
    # An archive not unpacked now: no space for it, or writing an entry failed.
    NO_SPACE = "no_space"
    UNPACK_FAILED = "unpack_failed"
    # Neither: the attempt was abandoned and must be redone.
    CHANGED = "changed"
    # An archive whose end-of-archive marker is missing (still being copied).
    INCOMPLETE = "incomplete"
    STOPPED = "stopped"
    # Neither: an archive refused by the shared checks, or one kept earlier
    # because it could not be set aside. It stays where it is (not set aside,
    # not imported from) until the file or the limits change.
    REFUSED = "refused"

    @property
    def belongs_to_file(self) -> bool:
        return self in _FILES_OWN


_FILES_OWN = frozenset(
    {ImportOutcome.DUPLICATE, ImportOutcome.NOT_AUDIO, ImportOutcome.FAILS_CHECK}
)


def file_signature(path: Path) -> tuple[int, int] | None:
    """(size, mtime_ns) of ``path``, or None when it cannot be read. Compared
    before and after an attempt to tell whether the file changed under it."""
    try:
        st = os.stat(path)
    except OSError:
        return None
    return st.st_size, st.st_mtime_ns


def file_identity(path: Path, *, dir_fd: int | None = None) -> tuple[int, int, int, int] | None:
    """(device, inode, size, mtime_ns) of ``path`` itself (a symlink is not
    followed; relative to the opened folder ``dir_fd`` if given), or None when
    it cannot be read or is not a regular file. Two equal identities mean the
    same, unchanged file."""
    try:
        st = os.stat(path, dir_fd=dir_fd, follow_symlinks=False)
    except OSError:
        return None
    if not stat.S_ISREG(st.st_mode):
        return None
    return st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns


def entry_key(path: Path) -> tuple[int, int, int] | None:
    """(device, inode, type) of the entry at ``path`` itself (a link is not
    followed), or None when it cannot be looked at. Writes to the entry (a
    FIFO's times move with each) leave it unchanged; a new entry at the name
    changes it."""
    try:
        st = os.lstat(path)
    except OSError:
        return None
    return st.st_dev, st.st_ino, stat.S_IFMT(st.st_mode)


# The most entries that are no regular file one memory keeps (read when it is built).
SKIPPED_ENTRIES_REMEMBERED = 1024


class EntryMemory:
    """Entries that are no regular file, by path, with their ``entry_key``:
    the latest ``SKIPPED_ENTRIES_REMEMBERED`` only, the oldest dropped first
    (one may then be named or tried again). Safe across worker threads."""

    def __init__(self):
        self._bound = SKIPPED_ENTRIES_REMEMBERED
        self._keys: OrderedDict = OrderedDict()
        self._lock = threading.Lock()

    def __contains__(self, path) -> bool:
        with self._lock:
            return path in self._keys

    def __len__(self) -> int:
        with self._lock:
            return len(self._keys)

    def knows(self, path, key) -> bool:
        """Whether ``path`` is remembered with this very ``key``."""
        with self._lock:
            return key is not None and self._keys.get(path) == key

    def remember(self, path, key) -> None:
        with self._lock:
            self._keys[path] = key
            self._keys.move_to_end(path)
            while len(self._keys) > self._bound:
                self._keys.popitem(last=False)

    def forget(self, path) -> None:
        with self._lock:
            self._keys.pop(path, None)


# Set by the watcher, around handing over an entry that is no regular file, to
# the ``entry_key`` it saw: if another entry (a regular file) lies there by the
# time the ingest looks, that is a new file, not imported without its wait.
expected_special_entry: contextvars.ContextVar = contextvars.ContextVar(
    "expected_special_entry", default=None)


class NotARegularFile(OSError):
    """The path is not a regular file, or something else was at it once opened."""


def open_no_follow(path, flags):
    """An ``opener`` for ``open()``: never through a link at the name, and
    never waiting (a FIFO opened for reading waits until a writer appears)."""
    return os.open(path, flags | os.O_NOFOLLOW | os.O_NONBLOCK)


def open_regular_file(path: Path):
    """``path`` opened for binary reading, only if it is a regular file both
    when looked at and once opened (something may be swapped in between).
    Nothing else is ever opened: a FIFO would block the caller until a writer
    appears, and a device, a socket, a link or a folder is not a file to read.
    Raises ``OSError`` (``NotARegularFile`` for the wrong kind of file)."""
    if not stat.S_ISREG(os.lstat(path).st_mode):
        raise NotARegularFile("not a regular file")
    f = open(path, "rb", opener=open_no_follow)
    try:
        if not stat.S_ISREG(os.fstat(f.fileno()).st_mode):
            raise NotARegularFile("not a regular file")
    except BaseException:
        f.close()
        raise
    return f
