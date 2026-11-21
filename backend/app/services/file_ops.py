"""File placement helpers shared by the import organizer, the tag editor,
conversion, uploads and deletion: move a file without replacing anything, put
one at a library name (hard link first, then a move or a copy through a
temporary name), prove a name is our own hard link, flush a move to disk, and
remove folders a track left empty. They take a per-folder lock so a move into
a folder and the removal of that folder never interleave.

These helpers used to live in ``organizer.py``; that module still exports
every public name of this one, so ``organizer.move_file`` and friends keep
working for existing callers.
"""

import errno
import hashlib
import logging
import os
import re
import shutil
import stat
from pathlib import Path
from typing import Optional

from app.core.durable_fs import fsync_dir, fsync_file
from app.core.internal_dirs import is_internal_path
from app.core.operator_log import operator_logger
from app.database.database import _fold_path
from app.services.keyed_locks import KeyedLocks

# The lines these helpers log keep the logger name they had in organizer.py.
logger = logging.getLogger("app.services.organizer")

# Per-directory mutual exclusion for move_file/prune_empty_dirs: without it,
# one track's prune of a now-empty shared album directory can race another
# track's move into that same directory (removing it out from under a
# concurrent mkdir+replace), and two concurrent moves to the same destination
# can race the exists()-then-replace() check-then-act into a silent clobber.
# Mirrors TrackLocks' "never delete the entry" KeyedLocks pattern.
_directory_locks = KeyedLocks[Path]()


def directory_lock_key(path) -> Path:
    """The ``_directory_locks`` key of a folder: its resolved path in folded
    form, so spellings a case-insensitive disk treats as one folder
    ("ABBA/Gold", "Abba/Gold") share one lock."""
    return Path(_fold_path(str(Path(path).resolve())))


def move_back(destination_path: Path, file_path: Path) -> bool:
    """Undo a ``move_file``: put the file at ``destination_path`` back at
    ``file_path``. False when it could not be moved back."""
    try:
        destination_path.replace(file_path)
        return True
    except OSError as e:
        logger.warning("could not move a file back: %s", e.strerror or type(e).__name__)
        return False


def flush_move(placed: Path, came_from: Path, root: Optional[Path] = None) -> None:
    """Force a rename to disk, best effort (see fsync_dir): the folder that now
    names the file and, when ``root`` is given, every folder above it up to and
    including ``root`` (move_file may have created them), then the folder the
    file came from."""
    folder = placed.parent
    fsync_dir(folder)
    if root is not None:
        while folder != root and root in folder.parents:
            folder = folder.parent
            fsync_dir(folder)
    fsync_dir(came_from.parent)


def _is_regular_file(path: Path) -> bool:
    """Whether ``path`` itself, never followed, is a regular file; any error is no."""
    try:
        return stat.S_ISREG(os.lstat(path).st_mode)
    except OSError:
        return False


def move_file(file_path: Path, destination_path: Path) -> bool:
    if not _is_regular_file(file_path):
        return False
    parent = destination_path.parent

    # Held for the whole exists-check + mkdir + replace sequence so a
    # concurrent move_file to the same destination, or a concurrent
    # prune_empty_dirs on this same directory, can't interleave with it.
    with _directory_locks.lock(directory_lock_key(parent)):
        if parent.exists() and not parent.is_dir():
            logger.warning("could not move a file: the destination's parent is not a directory")
            return False
        # Currently only supporting atomic move, so if file exists (even a
        # dangling symbolic link), return false
        if os.path.lexists(destination_path):
            logger.warning("could not move a file: the destination already exists")
            return False
        try:
            parent.mkdir(parents=True, exist_ok=True)
            # Fails if moving to a different filesystem, since it is an atomic move
            file_path.replace(destination_path)
        except (PermissionError, FileExistsError, OSError) as e:
            logger.warning("could not move a file: %s", e.strerror or type(e).__name__)
            return False
        # A link swapped in between the look above and the rename: put it back.
        if not _is_regular_file(destination_path):
            logger.warning("could not move a file: it is not a regular file")
            move_back(destination_path, file_path)
            return False
        return True


class LinkUnknown(OSError):
    """The name could not be examined: neither proven ours nor proven not ours."""


def is_own_hard_link(a, b, *, strict: bool = False) -> bool:
    """True only when ``a`` and ``b`` are both regular files (never followed
    symbolic links) that are the same file: the proof a name is our own link.
    A name proven absent (missing, a parent that is not a directory, or too long for
    the filesystem to hold) is False in both modes.
    Any other OSError (a name that cannot be examined) is also False by default;
    with ``strict`` it is raised as ``LinkUnknown`` (chained from the original error),
    so the caller can tell "unknown" from "not ours"."""
    try:
        sa, sb = os.lstat(a), os.lstat(b)
    except (FileNotFoundError, NotADirectoryError):
        return False
    except OSError as e:
        if e.errno == errno.ENAMETOOLONG:  # a name the filesystem cannot hold cannot exist
            return False
        if strict:
            raise LinkUnknown(e.errno, e.strerror) from e
        return False
    return (
        stat.S_ISREG(sa.st_mode) and stat.S_ISREG(sb.st_mode)
        and sa.st_dev == sb.st_dev and sa.st_ino == sb.st_ino
    )


class HardLinkError(OSError):
    """``os.link`` itself failed (not making the folders): the cause of "hard links
    are not supported here" is told apart from a folder that cannot be made."""


# ``os.link`` refusals that mean "this filesystem will not hard-link here".
FALLBACK_ERRNOS = (errno.EXDEV, errno.EPERM, errno.ENOTSUP, errno.EOPNOTSUPP, errno.EMLINK)
COPY_BLOCK_BYTES = 1024 * 1024


def temp_name_for(destination: Path) -> Path:
    """The hidden name next to ``destination`` a copy is written under: derived
    from the final name, a fixed 43 bytes, so it fits wherever the final does."""
    digest = hashlib.sha256(destination.name.encode("utf-8", "surrogateescape")).hexdigest()
    return destination.parent / f".{digest[:32]}.osml-part"


_TEMP_NAME = re.compile(r"\.[0-9a-f]{32}\.osml-part")


def is_temp_name(name: str) -> bool:
    """True for a name ``temp_name_for`` makes."""
    return _TEMP_NAME.fullmatch(name) is not None


def place_no_replace(source: Path, destination: Path, *, in_use, before_fallback=None,
                     allow_copy: bool = True, copy_floor_bytes=None, seam=None, before_temp=None):
    """Put ``source`` at ``destination`` under the destination directory lock
    without ever replacing anything: ``"linked"`` (hard link, or our own earlier
    link), ``"moved"``, ``"copied"``, or None when the name is taken, is a
    track's master (``in_use(destination)``), or its parent is unusable. On a
    failure the folders this call made are removed again (one at a time under
    their own locks, deepest first, never one that is not empty) and the error
    propagates; a refused link with an errno outside ``FALLBACK_ERRNOS`` is
    raised as ``HardLinkError``. A link refused with one of
    ``FALLBACK_ERRNOS`` falls back: ``"rename"`` calls ``before_fallback("rename")``
    then moves the source (same filesystem); ``"copy"`` (EXDEV; a plain EXDEV
    OSError when not ``allow_copy``) answers None for a taken name, refuses with
    ENOSPC when the copy would leave less than ``copy_floor_bytes`` free, calls
    ``before_temp()`` (the slow work that must not happen while a temp exists
    unrecorded), creates ``temp_name_for(destination)`` with O_EXCL (a file
    already there raises ``FileExistsError`` before the hook), calls
    ``before_fallback("copy")``, then copies through the temp and leaves the
    source alone. A fallback failure removes this call's temp and folders and
    propagates unchanged. ``seam(name)`` is a test hook."""
    parent = destination.parent
    created = []  # the directories this call makes, deepest first
    with _directory_locks.lock(directory_lock_key(parent)):
        if parent.exists() and not parent.is_dir():
            return None
        if in_use(destination):
            return None
        ancestor = parent
        while not ancestor.exists():
            created.append(ancestor)
            ancestor = ancestor.parent
        try:
            parent.mkdir(parents=True, exist_ok=True)
            try:
                os.link(source, destination)
            except FileExistsError:
                # Our own earlier link (a crash before the journal moved) is not a collision.
                return "linked" if is_own_hard_link(source, destination) else None
            except OSError as e:
                if e.errno not in FALLBACK_ERRNOS:
                    failure = HardLinkError(e.errno, e.strerror)
                    failure.__cause__ = e
                elif e.errno == errno.EXDEV and not allow_copy:
                    failure = OSError(errno.EXDEV, os.strerror(errno.EXDEV))
                else:
                    try:
                        return _fall_back(source, destination, e.errno, before_fallback,
                                          copy_floor_bytes, seam, before_temp)
                    except Exception as fallback_error:  # never BaseException: a kill keeps the temp
                        failure = fallback_error
            else:
                return "linked"
        except OSError as e:
            failure = e
    for directory in created:  # after the parent's lock: an ancestor may be in use
        with _directory_locks.lock(directory_lock_key(directory)):
            try:
                directory.rmdir()
            except OSError:
                break  # not empty or gone: stop, never rmtree
    raise failure


def _fall_back(source, destination, link_errno, before_fallback, copy_floor_bytes, seam,
               before_temp=None):
    if link_errno == errno.EXDEV:
        result = _copy_through_temp(source, destination, before_fallback, copy_floor_bytes, seam,
                                    before_temp)
    else:
        if before_fallback is not None:
            before_fallback("rename")
        result = None
        if _is_absent(destination):
            os.rename(source, destination)
            result = "moved"
    if result is not None:
        fsync_dir(destination.parent)
    return result


def _is_absent(path) -> bool:
    """True only when ``path`` is proven not to exist; other errors propagate."""
    try:
        os.lstat(path)
    except FileNotFoundError:
        return True
    return False


def _copy_through_temp(source, destination, before_fallback, copy_floor_bytes, seam,
                       before_temp=None):
    if not _is_absent(destination):
        return None  # a taken name is a collision, even on a nearly full disk
    if copy_floor_bytes is not None:
        free = shutil.disk_usage(destination.parent).free
        if free - os.stat(source).st_size < copy_floor_bytes:
            raise OSError(errno.ENOSPC, "copy would go below the free-space floor")
    if before_temp is not None:  # no temp exists yet: a failure here leaves only the folders
        before_temp()
    temp = temp_name_for(destination)
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o666)  # never someone else's file
    try:
        if before_fallback is not None:  # only now is the temp provably this call's
            before_fallback("copy")
        with open(fd, "wb") as out, open(source, "rb") as src:
            first = True
            while block := src.read(COPY_BLOCK_BYTES):
                out.write(block)
                if first and seam is not None:
                    seam("mid_copy")
                first = False
            out.flush()
        fsync_file(temp)
        if seam is not None:
            seam("after_copy")
        try:
            os.link(temp, destination)
            linked = True
        except FileExistsError:
            _remove_temp(temp)
            return None
        except OSError as e:
            if e.errno not in FALLBACK_ERRNOS:
                raise
            if not _is_absent(destination):
                _remove_temp(temp)
                return None
            os.rename(temp, destination)  # from here the temp name is not ours any more
            linked = False
    except Exception:
        _remove_temp(temp)
        raise
    if seam is not None:
        seam("after_temp_placed")
    if linked:
        _remove_temp(temp)  # best effort: the destination is already in place
    return "copied"


def _remove_temp(temp) -> None:
    try:
        os.unlink(temp)
    except FileNotFoundError:
        pass
    except OSError as e:
        logger.warning("could not remove a copy's temporary file: %s", type(e).__name__)


def prune_empty_dirs(directory: Path, root: Path) -> None:
    """Best-effort cleanup after a track leaves ``directory``: remove it and
    walk upward removing now-empty ancestors, never touching ``root`` itself
    or anything outside it. A directory holding even a hidden/junk file stops
    the walk — mirrors this codebase's policy of never destroying data the
    app didn't put there itself."""
    if is_internal_path(directory, root):
        return  # internal dirs (and their stages) are never pruned
    root = root.resolve()
    current = directory.resolve()
    while current != root and current.is_relative_to(root):
        # One directory's lock at a time (acquired, used, released before
        # moving to the parent) so this can never race move_file's own
        # per-directory lock into a deadlock.
        with _directory_locks.lock(directory_lock_key(current)):
            try:
                current.rmdir()
            except OSError:
                return  # not empty, already gone, or a permissions error — stop
        current = current.parent


def rollback_move(destination_path: Path, original_path: Path) -> bool:
    if not destination_path.exists():
        return False
    if original_path.exists():
        operator_logger.warning(
            "Cannot roll back move because the original name is taken: %s",
            original_path.name,
        )
        return False
    try:
        original_path.parent.mkdir(parents=True, exist_ok=True)
        destination_path.replace(original_path)
        return True
    except (PermissionError, FileExistsError, OSError) as e:
        operator_logger.warning(
            "Could not roll back the move of %s: %s",
            destination_path.name, getattr(e, "strerror", None) or type(e).__name__,
        )
        return False
