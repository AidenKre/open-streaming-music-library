"""Phase 6.5 (SC-25): the identity writers' post-commit wake-up signal."""

import threading


class IdentityWakeup:
    """Writers call notify() after their transaction commits; the worker wait()s on it.

    Notifies before a wait collapse into one wake-up. Thread-safe.
    """

    def __init__(self) -> None:
        self._event = threading.Event()

    def notify(self) -> None:
        self._event.set()

    def wait(self, timeout: float | None = None) -> bool:
        """True (and the signal is cleared) if notified within `timeout`; False on timeout."""
        if not self._event.wait(timeout):
            return False
        self._event.clear()
        return True
