from app.services.keyed_locks import KeyedLocks


class TrackLocks(KeyedLocks[str]):
    """Per-uuid mutual exclusion for track mutations.

    ``Database.apply_track_metadata_edit`` opens its revision-check-then-write
    transaction with ``BEGIN IMMEDIATE``, so the in-transaction 409 check is
    itself authoritative against another concurrent *database* write for the
    same uuid, independent of this lock. This lock exists to serialize the
    **non-transactional** work around an edit — the master-file staging/move —
    and Phase 2's conversion worker must share this *same instance* so a long
    FS operation excludes a racing PATCH. Entries are created lazily and never
    deleted (see ``KeyedLocks``), so two callers for the same uuid always get
    the identical lock object.
    """
