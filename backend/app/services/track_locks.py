import threading
from contextlib import contextmanager


class TrackLocks:
    """Per-uuid mutual exclusion for track mutations.

    SQLite's single writer + the in-transaction 409 check already serialize the
    *database* writes. This lock exists to serialize the **non-transactional**
    work around an edit — in Phase 1 that is just PATCH-vs-PATCH on the same
    uuid, but slice 4's master-file staging/move and Phase 2's conversion worker
    must share this *same instance* so a long FS operation excludes a racing
    PATCH. Modeled on ``EncoderCoordinator._key_lock``: entries are created
    lazily and **never deleted**, so two callers for the same uuid always get
    the identical lock object.
    """

    def __init__(self):
        self._locks: dict[str, threading.Lock] = {}
        self._guard = threading.Lock()

    def _lock_for(self, uuid_id: str) -> threading.Lock:
        with self._guard:
            lock = self._locks.get(uuid_id)
            if lock is None:
                lock = threading.Lock()
                self._locks[uuid_id] = lock
            return lock

    @contextmanager
    def lock(self, uuid_id: str):
        """Hold the per-uuid lock for the duration of the ``with`` block."""
        lock = self._lock_for(uuid_id)
        lock.acquire()
        try:
            yield
        finally:
            lock.release()
