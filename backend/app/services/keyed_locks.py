import threading
from contextlib import contextmanager
from typing import Dict, Generic, Hashable, TypeVar

K = TypeVar("K", bound=Hashable)


class KeyedLocks(Generic[K]):
    """Lazily-created, never-deleted per-key ``threading.Lock`` registry: two
    callers for the same key always get the identical lock object. Entries are
    never deleted so get-or-create stays race-free without a delete/recreate
    dance; key cardinality is bounded by the library size, so growth is fine.
    Shared by the per-uuid edit locks and the encoder coordinator's per
    ``(uuid, quality)`` encode locks."""

    def __init__(self):
        self._locks: Dict[K, threading.Lock] = {}
        self._guard = threading.Lock()

    def lock_for(self, key: K) -> threading.Lock:
        with self._guard:
            lock = self._locks.get(key)
            if lock is None:
                lock = threading.Lock()
                self._locks[key] = lock
            return lock

    @contextmanager
    def lock(self, key: K):
        """Hold the per-key lock for the duration of the ``with`` block."""
        with self.lock_for(key):
            yield

    def __contains__(self, key: K) -> bool:
        with self._guard:
            return key in self._locks

    def __len__(self) -> int:
        with self._guard:
            return len(self._locks)
