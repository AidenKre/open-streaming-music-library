import os
import re
from pathlib import Path

from app.core.internal_dirs import INTERNAL_DIRS

# Characters that must never appear in a single path component: the path
# separators, ASCII control chars (NUL through US), and the Windows-reserved
# ``: * ? " < > |``. On-disk only — the DB and the file tags keep the raw value.
_ILLEGAL = re.compile(r'[/\\\x00-\x1f:*?"<>|]')

# Windows device names; a component whose stem (text before the first ``.``)
# matches one of these, in any case, is reserved there.
_DEVICE_STEMS = frozenset(
    {"con", "prn", "aux", "nul"}
    | {f"com{i}" for i in range(1, 10)}
    | {f"lpt{i}" for i in range(1, 10)}
)

# A budget of UTF-8 bytes (a filesystem name holds 255 bytes), not characters.
_MAX_COMPONENT_LEN = 200


def utf8_len(value: str) -> int:
    """``value``'s length in UTF-8 bytes. Undecodable bytes from
    ``os.fsdecode`` (surrogate escapes) count as the one byte each stands for;
    any other lone surrogate is counted as its 3-byte form, never raised."""
    try:
        return len(value.encode("utf-8", "surrogateescape"))
    except UnicodeEncodeError:
        return sum(len(ch.encode("utf-8", "surrogatepass")) for ch in value)


def cut_to_bytes(value: str, max_bytes: int) -> str:
    """The longest prefix of ``value`` within ``max_bytes`` UTF-8 bytes, cut
    between whole characters."""
    if utf8_len(value) <= max_bytes:
        return value
    used = 0
    for i, ch in enumerate(value):
        used += utf8_len(ch)
        if used > max_bytes:
            return value[:i]
    return value


class UnsafePathComponent(ValueError):
    """Raised when a string cannot be turned into a usable folder name (empty
    after stripping illegal characters)."""


class PathEscapesRoot(ValueError):
    """Raised when a destination path resolves outside its library root (for
    example through a symlinked folder)."""


def _sanitize(value: str, max_len: int) -> str:
    """Apply every sanitizing rule to ``value``, capping it at ``max_len``
    UTF-8 bytes."""
    cleaned = _ILLEGAL.sub("_", value)
    # Trailing dot/space make a directory awkward to address; drop them.
    cleaned = cleaned.rstrip(" .")

    # Device stems are at most 4 chars, so the added "_" is well inside the cap.
    stem, dot, rest = cleaned.partition(".")
    if stem.lower() in _DEVICE_STEMS:
        cleaned = f"{stem}_{dot}{rest}"

    cleaned = cut_to_bytes(cleaned, max_len).rstrip(" .")

    if cleaned in ("", ".", ".."):
        raise UnsafePathComponent(f"cannot sanitize path component: {value!r}")

    return cleaned


def _not_internal(name: str) -> str:
    """A whole name must never read as one of the library's internal directories."""
    return name + "_" if name in INTERNAL_DIRS else name


def sanitize_path_component(value: str) -> str:
    """Make ``value`` safe to use as one on-disk folder name.

    Asymmetry by design: the DB row and the file's tags store the **raw** user
    value; only the directory created under the music library uses this
    sanitized form. So ``AC/DC`` is stored verbatim but foldered as ``AC_DC``.

    Rules: replace path separators, control chars and the Windows-reserved
    ``: * ? " < > |`` with ``_``; reject the whole-component specials ``.`` and
    ``..``; strip trailing spaces/dots (Windows-hostile and confusing on any
    OS); append ``_`` to a Windows device-name stem (``aux.mp3`` becomes
    ``aux_.mp3``, ``CON`` becomes ``CON_``); append ``_`` to a name that is
    exactly an internal directory name (``.uploads``, ``.staging``; exact,
    case-sensitive); length-cap; and reject anything
    that is empty after stripping.
    """
    return _not_internal(_sanitize(value, _MAX_COMPONENT_LEN))


def sanitize_file_name(name: str) -> str:
    """Like :func:`sanitize_path_component` for a file name: the stem is
    sanitized and capped so the last extension survives within the length cap.
    """
    cleaned = _ILLEGAL.sub("_", name).rstrip(" .")
    ext = os.path.splitext(cleaned)[1]
    if not ext or utf8_len(ext) >= _MAX_COMPONENT_LEN:
        # No extension, or one too long to leave room for a stem.
        return _not_internal(_sanitize(name, _MAX_COMPONENT_LEN))
    stem = cleaned[: -len(ext)]
    return _sanitize(stem, _MAX_COMPONENT_LEN - utf8_len(ext)) + ext


def assert_within(path, root) -> None:
    """Raise PathEscapesRoot unless ``path`` is strictly inside ``root`` once
    both are resolved. Explicit raise (not assert) so it holds under -O."""
    resolved_path = Path(path).resolve()
    resolved_root = Path(root).resolve()
    if resolved_path == resolved_root or not resolved_path.is_relative_to(
        resolved_root
    ):
        raise PathEscapesRoot(f"{path} is not strictly inside {root}")
