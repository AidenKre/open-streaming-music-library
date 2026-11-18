"""Internal directories under MUSIC_LIBRARY_DIR (SC-16f)."""

import os
from pathlib import Path

from app.core.operator_log import operator_logger

STAGING = ".staging"
UPLOADS = ".uploads"
INTERNAL_DIRS: tuple[str, ...] = (STAGING, UPLOADS)


class InternalDirRefused(RuntimeError):
    pass


def is_or_inside(a: Path, b: Path) -> bool:
    """True when ``a`` is ``b`` or inside it. Compares by filesystem identity
    (so case aliases on case-insensitive volumes match) where the paths exist,
    and by resolved path otherwise."""
    a, b = a.resolve(), b.resolve()
    if a == b or b in a.parents:
        return True
    if not b.exists():
        return False
    for ancestor in (a, *a.parents):
        try:
            if os.path.samefile(ancestor, b):
                return True
        except OSError:
            continue
    return False


def is_internal_path(path, root) -> bool:
    """True when ``path`` is inside ``root`` and any component of its path
    relative to ``root`` names an internal dir. Components above ``root``
    never count."""
    path, root = Path(path).resolve(), Path(root).resolve()
    if not path.is_relative_to(root):
        return False
    return any(part in INTERNAL_DIRS for part in path.relative_to(root).parts)


def internal_dirs(music_library_dir) -> tuple[Path, ...]:
    return tuple(Path(music_library_dir) / name for name in INTERNAL_DIRS)


def filesystem_id(path) -> int:
    return os.stat(path).st_dev


def _refuse(message: str):
    # Names and setting names only, never a path.
    operator_logger.error("Startup refused: %s", message)
    raise InternalDirRefused(message)


def ensure_internal_dirs(music_library_dir, *, import_trees) -> tuple[Path, ...]:
    """Validate every existing internal dir, then create the missing ones, so a
    refusal happens before any write. Each import tree is a path or a
    (setting_name, path) pair; the setting name is what a refusal reports."""
    dirs = internal_dirs(music_library_dir)
    for name, path in zip(INTERNAL_DIRS, dirs):
        if not os.path.lexists(path):
            continue
        if not path.is_dir():
            _refuse(f"{name} must be a directory")
        for entry in import_trees:
            setting, tree = entry if isinstance(entry, tuple) else (None, entry)
            tree = Path(tree)
            if is_or_inside(path, tree) or is_or_inside(tree, path):
                _refuse(
                    f"{name} must not overlap an import tree"
                    + (f" ({setting})" if setting else "")
                )
        for other_name, other in zip(INTERNAL_DIRS, dirs):
            if other_name != name and (
                is_or_inside(path, other) or is_or_inside(other, path)
            ):
                _refuse(f"{name} must not overlap {other_name}")
        if filesystem_id(path) != filesystem_id(music_library_dir):
            _refuse(f"{name} must be on the same filesystem as music_library_dir")
    for path in dirs:
        path.mkdir(exist_ok=True)
    return dirs
