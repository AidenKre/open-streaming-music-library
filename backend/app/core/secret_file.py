"""Reading a secret from a ``*_FILE`` setting."""

import logging
import stat
from pathlib import Path

logger = logging.getLogger(__name__)


class SecretFileUnreadable(Exception):
    """The file could not be read; the text is a predicate phrase and never carries file content."""


def read_secret_file(path: Path) -> str:
    # Raise outside the except blocks: inside, __context__ would keep the
    # exception, and a UnicodeDecodeError holds the file's bytes.
    reason = None
    try:
        text = path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        reason = "is not valid UTF-8"
    except ValueError:  # pathlib: an embedded NUL byte in the path
        reason = "cannot be read: invalid path"
    except OSError as e:
        reason = f"cannot be read: {e.strerror or type(e).__name__}"
    if reason is not None:
        raise SecretFileUnreadable(reason)
    return text.removesuffix("\n").removesuffix("\r") if text.endswith("\n") else text


def warn_if_group_or_world_readable(path: Path, holds: str) -> None:
    try:
        mode = stat.S_IMODE(path.stat().st_mode)
    except (OSError, ValueError):
        return
    if mode & 0o077:
        logger.warning(
            "%s is readable by group or others and holds %s; run: chmod 600 %s",
            path,
            holds,
            path,
        )
