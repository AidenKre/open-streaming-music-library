"""The admin tool's ``library check``: one user's library folder against their
tracks. A report: it writes no library file and no database row, walks into no
symbolic link and opens no library file; it runs beside the server. A track
path that runs through a link is resolved (``realpath``), so a file any
user's track reaches, directly or through links, is never unused (a folder
mounted a second time is not recognised). Findings are written as they are found,
never collected."""

import os
import stat
from pathlib import Path

from app.database.core import _fold_path
from app.services.file_ops import is_temp_name


class ReportNotWritten(Exception):
    """The report could not be written; ``error`` is the ``OSError``. Not an
    ``OSError`` itself, so the walk never takes it for an unreadable folder."""

    def __init__(self, error: OSError):
        super().__init__(error)
        self.error = error


class ReportOutput:
    """``out`` whose failed write or flush raises ``ReportNotWritten``."""

    def __init__(self, out):
        self._out = out

    def write(self, text):
        try:
            return self._out.write(text)
        except OSError as exc:
            raise ReportNotWritten(exc) from exc

    def flush(self):
        try:
            self._out.flush()
        except OSError as exc:
            raise ReportNotWritten(exc) from exc


def files_tracks_reach(db, settings, everyone, checked) -> dict | None:
    """Once per run, before any walk: every user's live track that may reach
    a file through a link (stored behind one, outside its owner's folder, or
    under an owner's folder that is itself a link), resolved. Returns, per
    checked user's id, the folds of the resolved files inside that user's
    real folder: nothing else is kept. None when a track's path cannot be
    followed (a loop, a folder that cannot be searched): what it reaches is
    unknown, so no user's unused list may be made. When no checked user can
    have an unused list (each one being deleted, or with a folder that is a
    link, cannot be computed or cannot be listed), nothing is read: ``{}``."""
    from app.library import library_root  # deferred: app.library imports the services
    from app.services.path_sanitize import PathEscapesRoot

    real_roots = {}  # checked user's id -> the fold of their real folder + "/"
    for user in checked:
        if user["deleting_at"] is not None:
            continue  # not checked
        try:
            root = library_root(settings.music_library_dir, user)
        except (PathEscapesRoot, RuntimeError, OSError):
            continue  # not checked
        if os.path.islink(root):
            continue  # not checked
        try:
            with os.scandir(root):
                pass
        except FileNotFoundError:
            pass  # no folder yet: it is checked (and has nothing to list)
        except OSError:
            continue  # not checked: its folder cannot be listed
        real_roots[user["id"]] = _fold_path(os.path.realpath(root)) + "/"
    reached = {user_id: set() for user_id in real_roots}
    if not reached:
        return reached  # no unused list can be made: nothing to protect or say
    folders = {}  # folder -> _folder_state, one lstat each for the whole run
    for owner in everyone:
        try:
            root = library_root(settings.music_library_dir, owner)
        except (PathEscapesRoot, RuntimeError, OSError):
            root = None
        every_track = root is None or os.path.islink(root)
        in_root = None if every_track else _fold_path(str(root)) + "/"
        for stored in db.live_track_paths(owner_id=owner["id"]):
            if not every_track and _fold_path(stored).startswith(in_root):
                state = _path_state(stored, len(root.parts), folders)
                if state == "unreadable":
                    return None
                if state != "link":
                    continue  # no link on the way: it reaches its own spelling
            try:
                real = os.path.realpath(stored, strict=True)  # opens no file
            except (FileNotFoundError, NotADirectoryError):
                continue  # it reaches no file: nothing to keep
            except (OSError, RuntimeError):  # a loop, or a folder not searchable
                return None
            fold = _fold_path(real)
            for user_id, prefix in real_roots.items():
                if fold.startswith(prefix):
                    reached[user_id].add(fold)
    return reached


def _path_state(stored: str, depth: int, folders: dict) -> str:
    """A track's path below its owner's folder (``depth`` parts), top down:
    ``link`` when a folder on it or the file is a link, ``unreadable`` when a
    folder on it cannot be searched, ``missing``, else ``dir``."""
    parts = Path(stored).parts
    for end in range(depth + 1, len(parts)):  # the owner's folder excluded
        folder = Path(*parts[:end])
        state = folders.get(folder) or folders.setdefault(folder, _folder_state(folder))
        if state != "dir":
            return state
    try:
        status = os.lstat(stored)
    except (FileNotFoundError, NotADirectoryError):
        return "missing"
    except OSError:
        return "unreadable"
    return "link" if stat.S_ISLNK(status.st_mode) else "dir"


def check_library(db, settings, user, out, reached) -> bool:
    """Writes ``{name}\\t{unused|missing|link|unreadable}\\t{path}`` per finding, then
    the user's summary line. Paths are relative to the user's library folder.
    ``reached`` is ``files_tracks_reach``'s result: a file any user's track
    resolves to is never unused, and with None no unused list is made.
    Returns whether the user was checked in full: False when they were not
    checked at all, when anything could not be read or when the unused list
    could not be made."""
    from app.library import library_root  # deferred: app.library imports the services
    from app.services.path_sanitize import PathEscapesRoot

    out = ReportOutput(out)  # a failed write is never an unreadable folder
    name, owner_id = user["username"], user["id"]
    if user["deleting_at"] is not None:
        out.write(f"{name}: not checked: the user is being deleted\n")
        return False
    try:
        root = library_root(settings.music_library_dir, user)
    except (PathEscapesRoot, RuntimeError):  # RuntimeError: a link loop
        root = None
    except OSError as exc:
        out.write(
            f"{name}: not checked: the library folder could not be read "
            f"({exc.strerror or type(exc).__name__})\n"
        )
        return False
    if root is None or os.path.islink(root):  # never pass through a link
        out.write(
            f"{name}: not checked: the library folder is a symbolic link "
            "or not a folder inside the music folder\n"
        )
        return False
    # 1. The folder itself first: nothing is reported for a folder never listed.
    try:
        with os.scandir(root):
            pass
    except FileNotFoundError:
        pass  # a user who has no music yet has no folder yet
    except OSError as exc:  # nothing was looked at: no count may read as none
        out.write(
            f"{name}: not checked: the library folder could not be read "
            f"({exc.strerror or type(exc).__name__})\n"
        )
        return False
    counts = {"unused": 0, "missing": 0, "link": 0, "unreadable": 0}
    unreadable = set()  # folders reported unreadable: each one reported once

    def report(kind, path):
        counts[kind] += 1
        out.write(f"{name}\t{kind}\t{_escaped(_relative(path, root))}\n")

    def report_unreadable(folder):
        if folder not in unreadable:
            unreadable.add(folder)
            report("unreadable", folder)

    # 2. The tracks, before any file is called unused: a track reached another
    # way (through a link, or outside the folder's spelling) may name any file.
    behind = outside = unresolved = 0  # counts only: what these reach is not checked
    folders = {}  # folder -> "dir" | "link" | "missing" | "unreadable" (one lstat each)
    in_root = _fold_path(str(root)) + "/"
    for stored in db.live_track_paths(owner_id=owner_id):
        if not _fold_path(stored).startswith(in_root):
            outside += 1
            continue
        parts = Path(stored).parts
        state = "dir"
        for depth in range(len(root.parts) + 1, len(parts)):  # top down, root excluded
            folder = Path(*parts[:depth])
            state = folders.get(folder) or folders.setdefault(folder, _folder_state(folder))
            if state == "unreadable":  # the folder above it cannot be searched
                report_unreadable(folder.parent)
            if state != "dir":
                break
        if state == "dir":
            try:
                status = os.lstat(stored)
            except (FileNotFoundError, NotADirectoryError):
                state = "missing"
            except OSError:
                report_unreadable(Path(stored).parent)
                state = "unreadable"
            else:
                state = "link" if stat.S_ISLNK(status.st_mode) else "dir"
        if state == "link":
            behind += 1
        elif state == "missing":
            report("missing", stored)
        elif state == "unreadable":  # may run through a link the check cannot see
            unresolved += 1  # no line: its folder is reported unreadable
    make_unused = outside == behind == unresolved == 0 and reached is not None
    # Files any user's track reaches through a link, by their real path (whose
    # track it is stays unsaid).
    real_root = Path(os.path.realpath(root))
    theirs = reached.get(owner_id, set()) if make_unused else set()

    # 3. The walk: links listed, never walked; unused files only when no track
    # can reach a file another way.
    stack = [root]
    while stack:
        directory = stack.pop()
        try:
            listing = os.scandir(directory)
        except FileNotFoundError:
            if directory != root:
                report_unreadable(directory)
            continue
        except OSError:
            report_unreadable(directory)
            continue
        try:
            with listing as entries:
                named = _named(db, directory, owner_id) if make_unused else set()
                # The walk reaches this folder through no link: real_root
                # spells it like root.
                real = real_root / directory.relative_to(root)
                for entry in entries:
                    if is_temp_name(entry.name):
                        continue
                    path = directory / entry.name
                    try:
                        if entry.is_symlink():  # to a file, a folder, nothing or back in
                            report("link", path)
                            continue
                        is_dir = entry.is_dir(follow_symlinks=False)
                    except OSError:
                        report_unreadable(path)
                        continue
                    if is_dir:
                        stack.append(path)
                    elif (
                        make_unused
                        and _fold_path(str(path)) not in named
                        and _fold_path(str(real / entry.name)) not in theirs
                    ):
                        report("unused", path)
        except OSError:  # the listing broke off part way
            report_unreadable(directory)

    out.write(
        f"{name}: files no track uses: "
        f"{counts['unused'] if make_unused else 'not checked'}; "
        f"tracks whose file is missing: {counts['missing']}; "
        f"symbolic links, not followed: {counts['link']}; "
        f"tracks stored behind a symbolic link, not checked: {behind}; "
        f"tracks stored outside the library folder, not checked: {outside}; "
        f"folders or files that could not be read: {counts['unreadable']}"
        + (
            "; not everything could be read, so these counts are lower bounds"
            if counts["unreadable"]
            else ""
        )
        + "\n"
    )
    return counts["unreadable"] == counts["link"] == behind == outside == 0 and (
        reached is not None
    )


def _folder_state(folder: Path) -> str:
    """One folder on a track's path, by ``lstat``: ``dir``, ``link``,
    ``missing`` (not there, or not a folder) or ``unreadable`` (the folder
    above it cannot be searched)."""
    try:
        status = os.lstat(folder)
    except (FileNotFoundError, NotADirectoryError):
        return "missing"
    except OSError:
        return "unreadable"
    if stat.S_ISLNK(status.st_mode):
        return "link"
    return "dir" if stat.S_ISDIR(status.st_mode) else "missing"


def _named(db, directory: Path, owner_id) -> set:
    """The folded paths of the tracks in ``directory``."""
    try:
        rows = db.track_identities_in_folder(str(directory), owner_id=owner_id)
    except UnicodeEncodeError:  # a name not valid UTF-8 is no track's folder
        return set()
    return {_fold_path(row["file_path"]) for row in rows}


_ESCAPES = {"\\": "\\\\", "\n": "\\n", "\t": "\\t", "\r": "\\r"}


def _escaped(text: str) -> str:
    """``text`` with backslash escapes for a backslash and for every character
    that is not printable, so a name can never forge a line or a field."""
    return "".join(
        _ESCAPES.get(c) or (c if c.isprintable() else repr(c)[1:-1]) for c in text
    )


def _relative(path, root: Path) -> str:
    """POSIX form relative to ``root`` (``.`` for the root); a path not under
    it as given."""
    try:
        return Path(path).relative_to(root).as_posix()
    except ValueError:
        return str(path)
