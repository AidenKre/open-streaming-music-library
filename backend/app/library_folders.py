"""Choosing a user's library folder (spec §4.5)."""

import logging
from dataclasses import dataclass
from pathlib import Path

from app.auth.usernames import is_reserved_username
from app.services.path_sanitize import sanitize_path_component

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class FolderChoice:
    folder: str
    adopted_import_dir: Path | None


def choose_library_folder(
    username_key, *, existing_folders, music_library_dir, user_import_dir
) -> FolderChoice:
    base = sanitize_path_component(username_key)
    taken = {f.casefold() for f in existing_folders}
    taken |= {e.name.casefold() for e in _entries(music_library_dir)}

    chosen, n = base, 1
    while is_reserved_username(chosen) or chosen.casefold() in taken:
        n += 1
        chosen = f"{base}-{n}"

    import_entries = _entries(user_import_dir)
    adopted = next(
        (e for e in matching_import_dirs(user_import_dir, chosen) if e.is_dir()),
        None,
    )
    if chosen != base:
        for e in import_entries:
            if e.name.casefold() == base.casefold():
                logger.warning(
                    "library folder %r chosen instead of %r; %s exists in the "
                    "user import dir and may need to be moved",
                    chosen,
                    base,
                    str(e),
                )
    return FolderChoice(folder=chosen, adopted_import_dir=adopted)


def matching_import_dirs(user_import_dir, folder: str) -> list[Path]:
    """Every directory (or symlink to one) in ``user_import_dir`` whose name
    equals ``folder`` by ``casefold()``, sorted. The one casefold matcher for
    adoption, import-folder lookup and delete."""
    return [
        e
        for e in sorted(_entries(user_import_dir))
        if e.name.casefold() == folder.casefold() and (e.is_dir() or e.is_symlink())
    ]


def _entries(directory) -> list[Path]:
    directory = Path(directory)
    return list(directory.iterdir()) if directory.is_dir() else []
