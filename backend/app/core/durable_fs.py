"""Best-effort durability helpers."""

import os
import sys
from pathlib import Path

try:
    import fcntl
except ImportError:  # Windows
    fcntl = None


def fsync_dir(path: Path) -> None:
    """Best effort: not every platform can open a directory."""
    try:
        fd = os.open(path, os.O_RDONLY)
    except OSError:
        return
    try:
        os.fsync(fd)
    except OSError:
        pass
    finally:
        os.close(fd)


def fsync_file(path: Path) -> None:
    """Force a file's data to stable storage; raises OSError when it cannot.
    On macOS a plain fsync leaves the data in the drive cache, so F_FULLFSYNC,
    falling back to fsync on a file system that refuses it."""
    fd = os.open(path, os.O_RDONLY)
    try:
        if sys.platform == "darwin" and fcntl is not None:
            try:
                fcntl.fcntl(fd, fcntl.F_FULLFSYNC)
            except OSError:
                os.fsync(fd)
        else:
            os.fsync(fd)
    finally:
        os.close(fd)
