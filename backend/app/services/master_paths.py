"""Judgements about a track's master file and its place in the deletion
quarantine, shared by the deletion worker, deletion recovery, the deletion
preview and the duplicates page: is a stored master path a real file inside
its owner's library, is a file the one a journal row names, what is at a
quarantine path. Only ``put_back_file`` changes anything: it returns a
quarantined file to its original path without replacing anything.

The judgements and ``put_back_file`` used to live in ``deletion_worker.py``;
that module still exports them, so existing imports keep working.
``quarantine_base`` and ``quarantine_dir`` are new here.
"""

import os
import stat
from pathlib import Path

from app.core.durable_fs import fsync_dir
from app.core.internal_dirs import DELETING
from app.library import library_root
from app.services import file_ops
from app.services.path_sanitize import PathEscapesRoot, assert_within


def quarantine_base(music_library_dir) -> Path:
    """The folder that holds every user's deletion quarantine: ``.deleting``
    under the music folder."""
    return Path(music_library_dir) / DELETING


def quarantine_dir(music_library_dir, owner) -> Path:
    """One user's deletion quarantine, ``.deleting/<owner id>``: a deletion
    moves a master to ``<operation uuid>/<track uuid><ext>`` below it."""
    return quarantine_base(music_library_dir) / str(owner)


def check_master_path(music_library_dir, user, file_path):
    """Judge a stored master path without touching anything: ("ok", lstat),
    ("missing", None) or ("rejected", None). A symlink or non-regular file on the
    way is rejected; an unknown error is never "missing"."""
    if user is None:
        return "rejected", None
    try:
        root = library_root(music_library_dir, user)
    except (PathEscapesRoot, OSError):
        return "rejected", None
    return check_master_in_root(root, file_path)


def check_master_in_root(root, file_path):
    """The one master-present judgement (worker, recovery, preview, duplicates)
    against the owner's library root; same answers as ``check_master_path``."""
    if root is None:
        return "rejected", None
    root = Path(root)
    try:
        root_stat = os.lstat(root)
    except OSError:
        return "rejected", None
    if not stat.S_ISDIR(root_stat.st_mode):
        return "rejected", None
    path = Path(file_path)
    parts = None
    for base in (root, Path(os.path.realpath(root))):
        if path.is_relative_to(base):
            parts = path.relative_to(base).parts
            break
    if not parts or any(part in ("", ".", "..") for part in parts):
        return "rejected", None
    current = root
    for index, part in enumerate(parts):
        current = current / part
        try:
            st = os.lstat(current)
        except FileNotFoundError:
            return "missing", None
        except OSError:
            return "rejected", None
        if stat.S_ISLNK(st.st_mode):
            return "rejected", None
        last = index == len(parts) - 1
        if not (stat.S_ISREG(st.st_mode) if last else stat.S_ISDIR(st.st_mode)):
            return "rejected", None
    try:
        assert_within(file_path, root)
    except PathEscapesRoot:
        return "rejected", None
    return "ok", st


def master_exists_in_root(root, file_path):
    """``check_master_in_root`` as a three-valued existence plus its lstat:
    (True, lstat) when present, (False, None) when missing, and (None, None)
    when the server refused to judge it. Unknown is never "missing"."""
    verdict, st = check_master_in_root(root, file_path)
    if verdict == "ok":
        return True, st
    if verdict == "missing":
        return False, None
    return None, None


def is_journaled_file(path, identity) -> bool:
    """True only when ``path`` is, by lstat, the regular file the journal
    names. Any error is "not the same": unknown is never proof."""
    try:
        st = os.lstat(path)
    except OSError:
        return False
    return stat.S_ISREG(st.st_mode) and (
        st.st_dev, st.st_ino, st.st_size
    ) == tuple(identity[:3])


def quarantine_state(quarantine, identity) -> str:
    """"free", "ours", "other" (proven a different file) or "unknown"."""
    try:
        st = os.lstat(quarantine)
    except FileNotFoundError:
        return "free"
    except OSError:
        return "unknown"
    if stat.S_ISREG(st.st_mode) and (st.st_dev, st.st_ino) == tuple(identity[:2]):
        return "ours"
    return "other"


def put_back_file(original, quarantine, *, prove_identity, in_use=None) -> bool:
    """Put the quarantined file back at ``original`` without replacing anything:
    a hard link (then the quarantine name is removed), or, on a filesystem that
    refuses hard links, a rename (never a copy: a quarantine on another
    filesystem raises EXDEV).

    True: the file is back at ``original`` and the quarantine name is gone.
    False: not put back or not proven, so the caller must keep the journal.
    Note that a False after a successful link leaves both names on one inode,
    and after a rename the file is at ``original`` only. Exceptions propagate.
    When ``prove_identity`` is given, both the quarantined file and the restored
    one must be that journaled file; a rename is also proven by the
    quarantine's own identity taken just before it."""
    if prove_identity is not None and not is_journaled_file(quarantine, prove_identity):
        return False
    if os.path.lexists(original):
        return False
    before_rename = []

    def remember_quarantine(_mode):  # rename only: allow_copy=False raises before a copy
        before_rename.append(os.lstat(quarantine))

    # The original is our own track's master, so no other track check applies;
    # existence is refused by the primitive itself, under the directory lock.
    placed = file_ops.place_no_replace(
        quarantine, original, in_use=in_use or (lambda _path: False), allow_copy=False,
        before_fallback=remember_quarantine)
    if placed == "moved":
        try:
            st = os.lstat(original)
        except OSError:
            return False  # unknown is never proof
        q = before_rename[0]
        if not stat.S_ISREG(st.st_mode) or (st.st_dev, st.st_ino) != (q.st_dev, q.st_ino) or (
            prove_identity is not None and not is_journaled_file(original, prove_identity)
        ):
            return False  # unproven: nothing removed, the journal stays
        fsync_dir(quarantine.parent)  # the primitive flushed the original's folder
    elif placed == "linked":
        if not file_ops.is_own_hard_link(quarantine, original) or (
            prove_identity is not None and not is_journaled_file(original, prove_identity)
        ):
            return False
        fsync_dir(original.parent)  # the new name is on disk before the old one goes
        os.unlink(quarantine)  # proof: O is now the same inode as Q
        fsync_dir(quarantine.parent)
    else:
        return False
    try:
        os.rmdir(quarantine.parent)
    except OSError:
        pass
    return True
