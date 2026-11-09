"""SC-16d POSIX single-instance guard."""

import errno
import fcntl
import logging
import os
from pathlib import Path


class InstanceLockHeld(RuntimeError):
    """Another process already holds ``APP_DATA_DIR/osml.lock``."""


class InstanceLock:
    def __init__(self, fd: int) -> None:
        self._fd: int | None = fd

    def release(self) -> None:
        if self._fd is None:
            return
        fd, self._fd = self._fd, None
        try:
            fcntl.flock(fd, fcntl.LOCK_UN)
        finally:
            os.close(fd)


def acquire_instance_lock(app_data_dir: Path) -> InstanceLock:
    app_data_dir.mkdir(parents=True, exist_ok=True)
    lock_path = app_data_dir.resolve() / "osml.lock"
    fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as exc:
        os.close(fd)
        if exc.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
            message = f"Another instance holds {lock_path}; run with --workers 1"
            logging.getLogger(__name__).error(message)
            raise InstanceLockHeld(message) from exc
        raise
    return InstanceLock(fd)
