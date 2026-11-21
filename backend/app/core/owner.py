"""Owner checks (SC-28): whose rows a database read or write is for.

A leaf: it imports nothing from the app, so the database and the services can
both import it. ``app.database`` re-exports ``ANY_OWNER``, so
``from app.database import ANY_OWNER`` still works.
"""


class _AnyOwner:
    """Sentinel for the few reads that deliberately span all owners."""

    def __repr__(self) -> str:
        return "ANY_OWNER"


ANY_OWNER = _AnyOwner()

# An owner argument: a real user id, or ANY_OWNER where a method allows it.
Owner = int | _AnyOwner


def _is_real_owner(owner_id: object) -> bool:
    return isinstance(owner_id, int) and not isinstance(owner_id, bool)


def _require_owner(owner_id: object) -> int:
    """Validate the owner of an insert/write: only a real int is accepted."""
    if not _is_real_owner(owner_id):
        raise TypeError(f"owner_id must be an int, got {owner_id!r}")
    return owner_id  # type: ignore[return-value]


def _and_owner(column: str, owner_id: object) -> tuple[str, tuple]:
    """``_owner_predicate`` as a suffix to append to an existing WHERE."""
    clause, params = _owner_predicate(column, owner_id)
    return (f" AND {clause}" if clause else ""), params


def _owner_predicate(column: str, owner_id: object) -> tuple[str, tuple]:
    """SQL predicate and params scoping a read to an owner (none for ANY_OWNER)."""
    if owner_id is ANY_OWNER:
        return "", ()
    return f"{column} = ?", (_require_owner(owner_id),)
