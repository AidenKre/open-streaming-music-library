"""Offline hard delete of one user (spec §6.4 ``users delete``).

Five idempotent steps; the ``users`` row goes last so a rerun always finds
the user. Only ever run with the server stopped.
"""

import logging
import os
import re
import shutil
import time
from dataclasses import dataclass
from pathlib import Path

from app.core.internal_dirs import STAGING, UPLOADS
from app.database.table_registry import delete_order
from app.library import library_root
from app.library_folders import matching_import_dirs
from app.services.cover_art_manager import _FORMAT_TO_EXT
from app.services.path_sanitize import PathEscapesRoot


# Roots the server records at startup so `users delete` can refuse to run
# against a different tree.
RECORDED_ROOT_KEYS = ("music_library_dir", "import_dir", "user_import_dir")


class DeleteRefused(Exception):
    pass


@dataclass(frozen=True)
class DeletePaths:
    app_data_dir: Path
    import_dir: Path
    music_library_dir: Path
    user_import_dir: Path
    workspace_root: Path
    staging_dir: Path
    uploads_dir: Path
    cache_dirs: tuple
    cover_art_dir: Path

    @classmethod
    def from_settings(cls, settings):
        data = Path(settings.app_data_dir)
        music = Path(settings.music_library_dir)
        return cls(
            app_data_dir=data,
            import_dir=Path(settings.import_dir),
            music_library_dir=music,
            user_import_dir=Path(settings.user_import_dir),
            workspace_root=data / "workspace",
            staging_dir=music / STAGING,
            uploads_dir=music / UPLOADS,
            cache_dirs=(data / "encoded_cache", data / "default_cache"),
            cover_art_dir=data / "cover_art",
        )


def _import_root_names(folder, paths, match_case):
    # Every on-disk spelling the matcher finds; the exact spelling when none
    # exists, so a misconfigured root is still refused.
    names = []
    if match_case:
        names = [e.name for e in matching_import_dirs(paths.user_import_dir, folder)]
    return [(paths.user_import_dir, name) for name in names or [folder]]


def _user_roots(user, paths, match_case=True):
    folder = user["library_folder"]
    return [
        (paths.music_library_dir, folder),
        *_import_root_names(folder, paths, match_case),
        (paths.workspace_root, f"u{user['id']}"),
        (paths.uploads_dir, str(user["id"])),  # the user's staged uploads
    ]


def _configured_dirs(paths):
    return [
        paths.app_data_dir, paths.import_dir, paths.music_library_dir,
        paths.user_import_dir, paths.workspace_root, paths.staging_dir,
        paths.uploads_dir, paths.cover_art_dir, *paths.cache_dirs,
    ]


def check_delete_guards(user, paths, others=()):
    try:
        library_root(paths.music_library_dir, user)
    except PathEscapesRoot as exc:
        raise DeleteRefused(str(exc)) from exc
    folder = user["library_folder"]
    if folder.startswith("."):
        raise DeleteRefused(f"library_folder {folder!r} is an internal directory name")
    for base, name in _user_roots(user, paths):
        root = base / name
        if os.path.islink(root):
            raise DeleteRefused(f"{root} is a symlink")
        if root.exists() and root.resolve() != base.resolve() / name:
            raise DeleteRefused(f"{root} does not resolve to {base.resolve() / name}")
    cover = paths.cover_art_dir
    if os.path.islink(cover) or (
        cover.exists() and cover.resolve() != paths.app_data_dir.resolve() / "cover_art"
    ):
        raise DeleteRefused(f"{cover} is not the cover_art directory under the data dir")
    roots = [(base / name).resolve() for base, name in _user_roots(user, paths)]
    protected = [d.resolve() for d in _configured_dirs(paths)]
    for other in others:
        protected += [(base / name).resolve() for base, name in _user_roots(other, paths, match_case=False)]
    for root in roots:
        for other in protected:
            if other == root or other.is_relative_to(root):
                raise DeleteRefused(f"{root} is, or contains, {other}; refusing to delete it")


def mark(db, user, paths):
    db.mark_user_deleting(user["id"], int(time.time()))


def _remove_matching(directory, prefixes, exact=()):
    if not directory.is_dir():
        return
    for entry in directory.iterdir():
        if (entry.name in exact or entry.name.startswith(prefixes)) and (
            entry.is_symlink() or entry.is_file()
        ):
            entry.unlink(missing_ok=True)


def remove_files(db, user, paths):
    for base, name in _user_roots(user, paths):
        root = base / name
        if os.path.islink(root):
            raise DeleteRefused(f"{root} is a symlink")
        if root.is_dir():
            shutil.rmtree(root)
    uuids = db.list_user_track_uuids_for_delete(user["id"])
    if not uuids:
        return
    _remove_matching(paths.staging_dir, tuple(u + "." for u in uuids), exact=uuids)
    for cache_dir in paths.cache_dirs:
        _remove_matching(cache_dir, tuple(u.replace("/", "_") + "__q" for u in uuids))


def delete_rows(db, user, paths):
    db.purge_user_rows(user["id"], delete_order())


_ART_NAME = re.compile(
    r"^[0-9a-f]{64}(" + "|".join(re.escape(e) for e in _FORMAT_TO_EXT.values()) + ")$"
)


def sweep_art_files(db, user, paths):
    if not paths.cover_art_dir.is_dir():
        return
    referenced = {Path(p).name for p in db.get_cover_art_file_paths()}
    for entry in paths.cover_art_dir.iterdir():
        if entry.is_symlink() or not entry.is_file():
            continue
        if _ART_NAME.match(entry.name) and entry.name not in referenced:
            entry.unlink(missing_ok=True)


def delete_user_row(db, user, paths):
    db.delete_user_row(user["id"])


STEPS = [mark, remove_files, delete_rows, sweep_art_files, delete_user_row]


def run_user_delete(db, user_id, paths):
    user = db.get_user(user_id)
    if user is None:
        return
    others = [u for u in db.list_user_folders() if u["id"] != user_id]
    check_delete_guards(user, paths, others=others)
    for step in STEPS:
        step(db, user, paths)


def resume_user_deletes(db, paths):
    """Finish every delete a crash interrupted. Never blocks the boot."""
    for user in db.list_user_folders():
        if user["deleting_at"] is None:
            continue
        try:
            run_user_delete(db, user["id"], paths)
        except Exception as exc:
            logging.getLogger(__name__).error(
                "Could not finish deleting user %s: %s", user["username"], exc
            )
