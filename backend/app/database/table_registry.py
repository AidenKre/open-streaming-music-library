"""Table registry (SC-28 rule 2, spec §4.6).

Every table in sqlite_master is classified here; an unclassified table fails
``verify``. ``REGISTRY`` is the single source for the children-first delete
order that hard delete follows.
"""

from dataclasses import dataclass

OWNER_TABLE = "owner_table"
OWNED_BY_USER_ID = "owned_by_user_id"
OWNED = "owned"
OWNED_THROUGH = "owned_through"
INTERNAL = "internal"
SERVER_WIDE = "server_wide"

_PER_USER = (OWNER_TABLE, OWNED_BY_USER_ID, OWNED, OWNED_THROUGH)
_FTS_SHADOW_SUFFIXES = ("_config", "_data", "_docsize", "_idx")


@dataclass(frozen=True)
class Entry:
    kind: str
    parent: str | None = None  # owned-through only
    fk: str | None = None  # child column of the foreign key to parent
    named: tuple[str, str] | None = None  # (child_col, parent_col), no FK
    fts_rowid: bool = False  # rowid is the parent's rowid
    # Every other per-user table this one has a foreign key to.
    references: frozenset = frozenset()


def _owned(*extra):
    return Entry(OWNED, references=frozenset({"users", *extra}))


def _user_id():
    return Entry(OWNED_BY_USER_ID, references=frozenset({"users"}))


REGISTRY = {
    "users": Entry(OWNER_TABLE),
    "user_settings": _user_id(),
    "auth_sessions": _user_id(),
    "user_delete_art_capture": _user_id(),
    "artists": _owned(),
    "tracks": _owned(),
    "track_tombstones": _owned(),
    "history_events": _owned(),
    "conversion_jobs": _owned(),
    "edit_journal": _owned(),
    "trackmetadata": Entry(
        OWNED_THROUGH,
        parent="tracks",
        fk="track_id",
        references=frozenset({"artists", "albums"}),
    ),
    "albums": Entry(OWNED_THROUGH, parent="artists", fk="artist_id"),
    "history_hook_failures": Entry(
        OWNED_THROUGH, parent="history_events", named=("event_uuid", "event_uuid")
    ),
    "track_audio_identity": Entry(
        OWNED_THROUGH, parent="tracks", fk="uuid_id", named=("uuid_id", "uuid_id")
    ),
    "track_audio_fingerprint": Entry(
        OWNED_THROUGH,
        parent="track_audio_identity",
        fk="uuid_id",
        named=("uuid_id", "uuid_id"),
    ),
    "track_duplicate_candidates": _owned("tracks"),
    # Phase 7 (O2): keys are (owner_id, client uuid), unique per owner only.
    "upload_batches": _owned(),
    # References itself for the ZIP parent; delete_order ignores self-references.
    "upload_items": _owned("upload_batches", "upload_items"),
    # Own owner_id: item_uuid is unique per owner only (O2), so a named= uuid link would purge other users' rows.
    "upload_item_audio_identity": _owned("upload_items"),
    # SC-16c receipts: keyed (owner_id, operation_uuid), unique per owner only (O2).
    "operation_receipts": _owned(),
    # SC-16g storage reservation ledger; owner_id is the owner_ref.
    "storage_reservations": _owned(),
    # Frozen acknowledgements of an accepted commit; kept as long as the item.
    "upload_item_acknowledgements": _owned("upload_items"),
    # Spec 6 publication journal; needs its receipt and its item.
    "upload_commit_journal": _owned("upload_items", "operation_receipts"),
    "fts_tracks": Entry(OWNED_THROUGH, parent="tracks", fts_rowid=True),
    "fts_artists": Entry(OWNED_THROUGH, parent="artists", fts_rowid=True),
    "fts_albums": Entry(OWNED_THROUGH, parent="albums", fts_rowid=True),
    "app_settings": Entry(SERVER_WIDE),
    "revision_counter": Entry(SERVER_WIDE),
    "cover_arts": Entry(SERVER_WIDE),
}

_INTERNAL = Entry(INTERNAL)


def classify(table):
    entry = REGISTRY.get(table)
    if entry is not None:
        return entry
    if table.startswith("sqlite_"):
        return _INTERNAL
    for name, registered in REGISTRY.items():
        if registered.fts_rowid and any(
            table == name + suffix for suffix in _FTS_SHADOW_SUFFIXES
        ):
            return _INTERNAL
    return None


def _per_user():
    return {t for t, e in REGISTRY.items() if e.kind in _PER_USER}


def _fks(conn, table):
    """(child column, target table) for each foreign key of ``table``."""
    return [
        (row[3], row[2])
        for row in conn.execute(f"PRAGMA foreign_key_list('{table}')")
    ]


def _columns(conn, table):
    return {row[1] for row in conn.execute(f"PRAGMA table_info('{table}')")}


def verify(conn):
    problems = []
    existing = {
        row[0] for row in conn.execute("SELECT name FROM sqlite_master WHERE type = 'table'")
    }
    for table in sorted(existing):
        if classify(table) is None:
            problems.append(f"table {table} is not classified in the registry")
    for table in sorted(REGISTRY):
        if table not in existing:
            problems.append(f"registered table {table} is missing from the schema")

    per_user = _per_user()
    for table in sorted(per_user & existing):
        entry = REGISTRY[table]
        fks = _fks(conn, table)
        if entry.kind == OWNED and ("owner_id", "users") not in fks:
            problems.append(f"owned table {table} has no owner_id foreign key to users")
        if entry.kind == OWNED_BY_USER_ID and ("user_id", "users") not in fks:
            problems.append(f"table {table} has no user_id foreign key to users")
        if entry.fk is not None and (entry.fk, entry.parent) not in fks:
            problems.append(
                f"{table} has no foreign key {entry.fk} to its parent {entry.parent}"
            )
        if entry.named is not None:
            child_col, parent_col = entry.named
            if child_col not in _columns(conn, table):
                problems.append(f"{table} is missing link column {child_col}")
            if parent_col not in _columns(conn, entry.parent):
                problems.append(
                    f"{entry.parent} is missing link column {parent_col} (parent of {table})"
                )
        if entry.fts_rowid:
            continue  # virtual tables carry no foreign keys
        declared = set(entry.references)
        if entry.fk is not None:
            declared.add(entry.parent)
        actual = {target for _, target in fks if target in per_user}
        if actual != declared:
            problems.append(
                f"{table} foreign keys to per-user tables are {sorted(actual)}, "
                f"registry declares {sorted(declared)}"
            )
    for table in sorted(existing):
        if table in REGISTRY and REGISTRY[table].kind == SERVER_WIDE:
            if _columns(conn, table) & {"owner_id", "user_id"}:
                problems.append(f"server-wide table {table} has an owner_id or user_id column")
            if any(target in per_user for _, target in _fks(conn, table)):
                problems.append(f"server-wide table {table} has a foreign key to a per-user table")
    return problems


def delete_order():
    """Per-user tables, children first (Kahn's algorithm; ties by name)."""
    tables = _per_user()
    parents = {
        # A table's own name is ignored (self-referencing FK), else Kahn never readies it.
        t: (({REGISTRY[t].parent} if REGISTRY[t].parent else set()) | set(REGISTRY[t].references)) - {t}
        for t in tables
    }
    children = {t: {c for c in tables if t in parents[c]} for t in tables}
    order, emitted = [], set()
    while len(order) < len(tables):
        ready = sorted(t for t in tables - emitted if children[t] <= emitted)
        order.append(ready[0])
        emitted.add(ready[0])
    return order


def owner_predicate(table):
    """WHERE clause (one ``?`` placeholder: the user id) selecting ``table``'s
    rows owned by that user. Identifiers come only from the registry; an
    unregistered table or a kind with no ownership rule raises."""
    entry = REGISTRY[table]
    if entry.kind == OWNED:
        return "owner_id = ?"
    if entry.kind == OWNED_BY_USER_ID:
        return "user_id = ?"
    if entry.kind == OWNED_THROUGH and not entry.fts_rowid:
        child_col, parent_col = entry.named or (entry.fk, "id")
        return (
            f"{child_col} IN (SELECT {parent_col} FROM {entry.parent} "
            f"WHERE {owner_predicate(entry.parent)})"
        )
    raise ValueError(f"table {table} has no owner predicate")
