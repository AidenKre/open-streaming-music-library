"""Settle check (live gate m-L-08, decision DEV-M-15).

After a loose file is organized into the library the import records the size
and modification time it was read at. This deferred check re-reads them after
a settle window much longer than the quiet window; if they changed, the track
is refreshed and the check repeats until one full window passes with no
change. Entries live in memory only (a stop loses them), the clock is
injected, and no lock is held while a refresh runs or while waiting.
"""

import logging
import threading
import time
from pathlib import Path
from typing import Callable

from app.library import Library
from app.services.conversion import evict_converted_track_caches
from app.services.import_outcome import file_signature
from app.services.metadata import get_track_metadata

logger = logging.getLogger(__name__)

SETTLE_WINDOW_S = 30.0
# Longest real wait between looks at the stop flag and at new entries.
_POLL_S = 1.0


class SettleCheck:
    def __init__(
        self,
        *,
        refresh: Callable[[str, int, Path], bool],
        clock: Callable[[], float] = time.monotonic,
        stop_event: threading.Event | None = None,
        window: float = SETTLE_WINDOW_S,
    ):
        self._refresh = refresh
        # Public and read at each use, so a test can swap it before scheduling.
        self.clock = clock
        self._stop = stop_event if stop_event is not None else threading.Event()
        self._window = window
        self._lock = threading.Lock()
        # uuid -> (owner_id, path, signature, due); insertion ordered.
        self._entries: dict[str, tuple[int, Path, tuple[int, int] | None, float]] = {}
        self._thread: threading.Thread | None = None

    def schedule(self, uuid_id: str, owner_id: int, path: Path, signature) -> None:
        with self._lock:
            self._entries.pop(uuid_id, None)
            self._entries[uuid_id] = (owner_id, Path(path), signature, self.clock() + self._window)

    def pending(self) -> list[str]:
        with self._lock:
            return list(self._entries)

    def run_due(self) -> None:
        now = self.clock()
        with self._lock:
            due = [(u, e) for u, e in self._entries.items() if e[3] <= now]
        for uuid_id, (owner_id, path, signature, _) in due:
            if self._stop.is_set():
                return
            current = file_signature(path)
            if current is None or current == signature:
                self._drop(uuid_id, signature)
                continue
            try:
                keep = self._refresh(uuid_id, owner_id, path)
            except Exception:
                logger.exception("settle check: refresh of %s failed", uuid_id)
                keep = False
            with self._lock:
                entry = self._entries.get(uuid_id)
                # Rescheduled meanwhile: the newer entry stands.
                if entry is None or entry[2] != signature:
                    continue
                if keep:
                    self._entries[uuid_id] = (owner_id, path, current, self.clock() + self._window)
                else:
                    del self._entries[uuid_id]

    def _drop(self, uuid_id: str, signature) -> None:
        with self._lock:
            entry = self._entries.get(uuid_id)
            if entry is not None and entry[2] == signature:
                del self._entries[uuid_id]

    def _wait_s(self) -> float:
        with self._lock:
            if not self._entries:
                return _POLL_S
            soonest = min(e[3] for e in self._entries.values())
        return min(_POLL_S, max(0.0, soonest - self.clock()))

    def _loop(self) -> None:
        while not self._stop.is_set():
            if self._stop.wait(self._wait_s()):
                break
            self.run_due()
        with self._lock:
            self._entries.clear()

    def start(self) -> None:
        if self.is_running():
            return
        self._thread = threading.Thread(target=self._loop, name="settle-check", daemon=True)
        self._thread.start()

    def join(self, timeout: float | None = None) -> None:
        if self._thread is not None:
            self._thread.join(timeout)

    def is_running(self) -> bool:
        return self._thread is not None and self._thread.is_alive()


def make_settle_refresh(
    *, database, track_locks, cache, default_cache, encoder_coordinator,
    identity_signal=None,
) -> Callable[[str, int, Path], bool]:
    """The refresh the check calls when a file changed: re-read only the
    file-derived fields (never tags), then drop every cache entry built from
    the old content and, for the admin, warm again. False skips a track that
    was deleted or re-organized meanwhile. The refresh also marks the track's
    audio identity stale; ``identity_signal`` (anything with notify()) is woken
    once that has committed."""

    def refresh(uuid_id: str, owner_id: int, path: Path) -> bool:
        with track_locks.lock(uuid_id):
            track = Library(database, owner_id).get_track_by_uuid(uuid_id)
            if track is None:
                # Deleted meanwhile: nothing to refresh, but an entry cached
                # from the old content would be orphaned.
                evict_converted_track_caches(uuid_id, cache, default_cache)
                return False
            if Path(track.file_path).resolve() != Path(path).resolve():
                return False
            meta = get_track_metadata(path)
            if meta is None or meta.is_empty():
                # Unreadable for now, but the file changed: the identity from
                # the old bytes is stale.
                if (
                    database.mark_audio_identity_stale(
                        uuid_id, "settle", owner_id=owner_id
                    )
                    and identity_signal is not None
                ):
                    identity_signal.notify()
                return True  # keep checking
            revision = database.refresh_track_audio_properties(
                uuid_id,
                codec=meta.codec,
                bitrate_kbps=meta.bitrate_kbps,
                sample_rate_hz=meta.sample_rate_hz,
                channels=meta.channels,
                duration=meta.duration,
                owner_id=owner_id,
            )
            if revision is None:
                return False
            if identity_signal is not None:
                identity_signal.notify()
        evict_converted_track_caches(uuid_id, cache, default_cache)
        encoder_coordinator.warm_imported(uuid_id, owner_id)
        return True

    return refresh
