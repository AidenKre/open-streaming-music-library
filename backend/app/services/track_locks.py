from app.services.keyed_locks import KeyedLocks


class TrackLocks(KeyedLocks[str]):
    """Per-uuid mutual exclusion for track mutations.

    SQLite's single writer + the in-transaction 409 check already serialize the
    *database* writes. This lock exists to serialize the **non-transactional**
    work around an edit — the master-file staging/move — and Phase 2's
    conversion worker must share this *same instance* so a long FS operation
    excludes a racing PATCH. Entries are created lazily and never deleted (see
    ``KeyedLocks``), so two callers for the same uuid always get the identical
    lock object.
    """
