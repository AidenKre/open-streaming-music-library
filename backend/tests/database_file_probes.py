"""What is in a database's files, and which of them this process holds open.

For the tests of the server's held connection:
they ask where a committed row is (the main file alone, or the main file with
its write-ahead log), whether a connection was left open, and whether another
process still holds the database.

Every probe that reads a file here opens and closes a descriptor of its own in
the test process. Closing any descriptor of a file drops every POSIX lock the
process holds on that file (audit AU3-01). A stock SQLite build locks the
database file with POSIX locks, so there the process's connections lose their
lock; the build this Mac's Python links (3.51.0, with Apple's compile
options) keeps it (measured 2026-11-20). So these probes
are for a test process that needs no lock of its own at that moment: a test
whose point is that *this* process keeps holding the database for *another*
process must not call them while it holds.
"""

import fcntl
import os
import shutil
import sqlite3
from pathlib import Path


def log_file(database_path) -> Path:
    """The write-ahead log SQLite keeps beside the database file."""
    return Path(str(database_path) + "-wal")


def log_bytes(database_path) -> int:
    """How much the log holds: 0 when it is empty or gone. (After the last
    connection's close SQLite deletes the log or leaves it empty, depending on
    its build (the one this Mac's Python links leaves an empty file); both mean
    "checkpointed".)"""
    path = log_file(database_path)
    return path.stat().st_size if path.exists() else 0


# The byte range every SQLite connection locks shared for as long as it has a
# WAL-mode database open (SHARED_FIRST and SHARED_SIZE of SQLite's file
# locking protocol; the same in every build that locks with POSIX locks).
SQLITE_SHARED_FIRST = 0x40000002
SQLITE_SHARED_SIZE = 510


def another_process_holds_the_database(database_path) -> bool:
    """Whether a process other than this one holds SQLite's shared lock on the
    database file. Asks the kernel, not SQLite: an exclusive lock on the shared
    range, without waiting, is refused exactly while another process holds a
    lock there. A process that lost its lock is answered False although its
    connection is open (on a SQLite build that locks with POSIX locks: after
    it closed a descriptor of the file beside SQLite). Not for a process that
    itself has a connection to the file: the probe's lock would replace that
    process's own, and its close would drop it."""
    fd = os.open(database_path, os.O_RDWR)
    try:
        try:
            fcntl.lockf(fd, fcntl.LOCK_EX | fcntl.LOCK_NB, SQLITE_SHARED_SIZE, SQLITE_SHARED_FIRST)
        except OSError:
            return True
        return False
    finally:
        os.close(fd)  # also releases the probe's own lock


def file_identities(database_path) -> dict:
    """(device, inode) -> name for the database file and the two files SQLite
    keeps beside it, as far as they exist now."""
    found = {}
    for suffix in ("", "-wal", "-shm"):
        path = Path(str(database_path) + suffix)
        if path.exists():
            stat = path.stat()
            found[(stat.st_dev, stat.st_ino)] = path.name
    return found


def open_in_this_process(identities: dict) -> list[str]:
    """The names of those files this process holds an open descriptor on, one
    entry per descriptor."""
    held = []
    for name in os.listdir("/dev/fd"):
        try:
            stat = os.fstat(int(name))
        except (OSError, ValueError):
            continue  # the listing's own descriptor, closed by now
        if (stat.st_dev, stat.st_ino) in identities:
            held.append(identities[(stat.st_dev, stat.st_ino)])
    return sorted(held)


def setting_in(database_file, key: str = "probe") -> str | None:
    """The ``app_settings`` value in ``database_file``, read with a plain connection."""
    conn = sqlite3.connect(database_file)
    try:
        row = conn.execute("SELECT value FROM app_settings WHERE key = ?", (key,)).fetchone()
        return row[0] if row else None
    finally:
        conn.close()


def setting_in_the_main_file_alone(database_path, scratch: Path, key: str = "probe") -> str | None:
    """Read a copy of the database file without its log: what a checkpoint has
    put into the main file so far."""
    folder = scratch / "main-file-alone"
    shutil.rmtree(folder, ignore_errors=True)
    folder.mkdir(parents=True)
    shutil.copyfile(database_path, folder / "copy.sqlite")
    return setting_in(folder / "copy.sqlite", key)


def setting_in_a_copy_of_the_files(database_path, scratch: Path, key: str = "probe") -> str | None:
    """Read a copy of the main file and its log, as they are on disk now."""
    folder = scratch / "files-as-they-are"
    shutil.rmtree(folder, ignore_errors=True)
    folder.mkdir(parents=True)
    shutil.copyfile(database_path, folder / "copy.sqlite")
    shutil.copyfile(log_file(database_path), folder / "copy.sqlite-wal")
    return setting_in(folder / "copy.sqlite", key)
