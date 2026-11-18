"""What happened to one file offered to the import pipeline (review r2 m-R2-01).

The one place that says which failures belong to the file itself and which
come from the environment. An archive leaves its import folder only when every
audio file was imported (it is deleted) or refused for a reason of its own (it
is set aside in ``.imported/``); an environmental
failure (or a file that changed, or a shutdown) leaves it for the next scan.
An archive the shared archive checks refuse is neither: it stays in place and
is not tried again while it and the limits are unchanged.
"""

import os
import stat
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
    # Neither: an archive refused by the shared checks. It stays where it is
    # (not set aside, not imported from) until the file or the limits change.
    REFUSED = "refused"

    @property
    def belongs_to_file(self) -> bool:
        return self in _FILES_OWN

    @property
    def environmental(self) -> bool:
        return self in _ENVIRONMENTAL


_FILES_OWN = frozenset(
    {ImportOutcome.DUPLICATE, ImportOutcome.NOT_AUDIO, ImportOutcome.FAILS_CHECK}
)
_ENVIRONMENTAL = frozenset(
    {
        ImportOutcome.TOOL_UNAVAILABLE,
        ImportOutcome.DATABASE_ERROR,
        ImportOutcome.MOVE_FAILED,
        ImportOutcome.NO_SPACE,
        ImportOutcome.UNPACK_FAILED,
    }
)


def file_signature(path: Path) -> tuple[int, int] | None:
    """(size, mtime_ns) of ``path``, or None when it cannot be read. Compared
    before and after an attempt to tell whether the file changed under it."""
    try:
        st = os.stat(path)
    except OSError:
        return None
    return st.st_size, st.st_mtime_ns


def file_identity(path: Path) -> tuple[int, int, int, int] | None:
    """(device, inode, size, mtime_ns) of ``path`` itself (a symlink is not
    followed), or None when it cannot be read or is not a regular file. Two
    equal identities mean the same, unchanged file."""
    try:
        st = os.lstat(path)
    except OSError:
        return None
    if not stat.S_ISREG(st.st_mode):
        return None
    return st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns
