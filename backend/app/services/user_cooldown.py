"""A per-user limit on how often an action may be taken."""

import math
import threading
import time


class UserCooldown:
    """When each user last took each action, kept in memory per user and per
    action; a restart empties it."""

    def __init__(self, *, clock=time.monotonic):
        self._clock = clock
        self._lock = threading.Lock()
        self._last: dict = {}

    def claim(self, owner, action: str, period_s: float) -> tuple[int | None, object]:
        """Returns (retry_after_s, undo). When the claim was taken (the time is now
        recorded), retry_after_s is None and undo is an opaque value for release().
        Otherwise retry_after_s is the whole seconds to wait and undo is None."""
        key = (owner, action)
        with self._lock:
            now = self._clock()
            previous = self._last.get(key)
            if previous is not None and now - previous < period_s:
                return max(1, math.ceil(period_s - (now - previous))), None
            self._last[key] = now
            return None, (previous, now)

    def release(self, owner, action: str, undo) -> None:
        """Undo a claim when the action did not happen: restores what was there
        before it, but only while that claim is still the latest one, so a newer
        claim taken meanwhile is never erased."""
        previous, claimed_at = undo
        key = (owner, action)
        with self._lock:
            if self._last.get(key) != claimed_at:
                return
            if previous is None:
                self._last.pop(key, None)
            else:
                self._last[key] = previous
