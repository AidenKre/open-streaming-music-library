import re

# Characters that must never appear in a single path component: the path
# separators and ASCII control chars (NUL through US). On-disk only — the DB
# and the file tags keep the raw value.
_ILLEGAL = re.compile(r'[/\\\x00-\x1f]')

_MAX_COMPONENT_LEN = 200


class UnsafePathComponent(ValueError):
    """Raised when a string cannot be turned into a usable folder name (empty
    after stripping illegal characters)."""


def sanitize_path_component(value: str) -> str:
    """Make ``value`` safe to use as one on-disk folder name.

    Asymmetry by design: the DB row and the file's tags store the **raw** user
    value; only the directory created under the music library uses this
    sanitized form. So ``AC/DC`` is stored verbatim but foldered as ``AC_DC``.

    Rules: replace path separators and control chars with ``_``; reject the
    whole-component specials ``.`` and ``..``; strip trailing spaces/dots
    (Windows-hostile and confusing on any OS); length-cap; and reject anything
    that is empty after stripping.
    """
    cleaned = _ILLEGAL.sub("_", value)
    # Trailing dot/space make a directory awkward to address; drop them.
    cleaned = cleaned.rstrip(" .")
    cleaned = cleaned[:_MAX_COMPONENT_LEN].rstrip(" .")

    if cleaned in ("", ".", ".."):
        raise UnsafePathComponent(f"cannot sanitize path component: {value!r}")

    return cleaned
