"""Startup check: folders on another filesystem than the music library
directory (sign-off s7-live-findings item 2, XF-L-02/XF-L-03)."""

import errno
import os

from app.core.operator_log import operator_logger


def device_of(path) -> int:
    """The filesystem (``st_dev``) of ``path``, following a symbolic link."""
    return os.stat(path).st_dev


def _reason(e: BaseException) -> str:
    """The errno name of an ``OSError``, else the exception's type name."""
    if isinstance(e, OSError) and e.errno is not None:
        return str(errno.errorcode.get(e.errno, e.errno))
    return type(e).__name__


def warn_other_filesystems(database, *, music_library_dir, import_dir, user_import_dir) -> None:
    """Log one operator warning for each existing user library folder, user
    import folder and the shared import folder that is on another filesystem
    than ``music_library_dir`` (renames cannot cross filesystems, so this setup
    is not supported). A folder that does not exist is skipped; one that cannot
    be examined gets a "could not be checked" line instead, never a warning.
    No path or name is logged. Never raises."""
    try:
        _warn(database, music_library_dir, import_dir, user_import_dir)
    except Exception as e:  # a startup check never stops the server
        operator_logger.warning("The filesystem check could not be completed (%s).", _reason(e))


def _warn(database, music_library_dir, import_dir, user_import_dir) -> None:
    from app.library import library_root  # deferred: app.library imports the services
    from app.library_folders import matching_import_dirs

    try:
        library_device = device_of(music_library_dir)
    except Exception as e:
        operator_logger.warning(
            "The music library directory could not be checked for its filesystem (%s).", _reason(e))
        return

    def elsewhere(folder_of, unknown: str, *args) -> bool:
        """True when the folder ``folder_of()`` names is on another filesystem.
        False for a missing folder, and for one that cannot be examined, which
        logs ``unknown`` (``args`` then the reason)."""
        try:
            folder = folder_of()
            os.lstat(folder)  # a missing folder is skipped, not examined
            return device_of(folder) != library_device
        except (FileNotFoundError, NotADirectoryError):
            return False
        except Exception as e:
            operator_logger.warning(unknown, *args, _reason(e))
            return False

    try:
        users = database.list_users()
    except Exception as e:
        operator_logger.warning(
            "The folders could not be checked for their filesystem (%s).", _reason(e))
        return

    unknown_root = "The music library of user %s could not be checked for its filesystem (%s)."
    unknown_import = "The import folder of user %s could not be checked for its filesystem (%s)."
    for user in users:
        if elsewhere(lambda: library_root(music_library_dir, user), unknown_root, user["id"]):
            operator_logger.warning(
                "The music library of user %s is on another filesystem than the music library"
                " directory: only uploads work there; edits, conversions, deletions and"
                " import-folder imports fail. This setup is not supported.", user["id"])
        try:
            folders = matching_import_dirs(user_import_dir, user["library_folder"])
        except Exception as e:
            operator_logger.warning(unknown_import, user["id"], _reason(e))
            folders = []
        for folder in folders:
            if elsewhere(lambda: folder, unknown_import, user["id"]):
                operator_logger.warning(
                    "The import folder of user %s is on another filesystem than the music library"
                    " directory: files dropped there are not imported. This setup is not"
                    " supported.", user["id"])

    if elsewhere(lambda: import_dir,
                 "The shared import folder could not be checked for its filesystem (%s)."):
        operator_logger.warning(
            "The shared import folder is on another filesystem than the music library directory:"
            " files dropped there are not imported. This setup is not supported.")
