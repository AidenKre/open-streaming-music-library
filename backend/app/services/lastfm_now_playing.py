"""Now Playing (spec §7.10): at most one waiting notice per user, in memory only.

The route puts a notice (the newest replaces the one waiting) and wakes the
sender; the sender sends it through the gate as ``track.updateNowPlaying`` or
discards it. Nothing about a notice is ever stored or retried."""

import math
import threading
import time
from dataclasses import dataclass

from app.services.lastfm_rules import lastfm_track_fields

NOTICE_MAX_WAIT_S = 10


@dataclass(frozen=True, eq=False)
class Notice:
    owner_id: int
    track_uuid: str
    queued_at: float


class NowPlayingNotices:
    def __init__(self, *, clock=time.monotonic, wake=None):
        self._clock = clock
        self._wake = wake
        self._lock = threading.Lock()
        self._by_owner: dict[int, Notice] = {}

    def attach(self, wake) -> None:
        self._wake = wake

    @property
    def attached(self) -> bool:
        return self._wake is not None

    def put(self, owner_id, track_uuid) -> None:
        with self._lock:
            self._by_owner[owner_id] = Notice(owner_id, track_uuid, self._clock())
        if self._wake is not None:
            self._wake()

    def drop(self, owner_id) -> None:
        with self._lock:
            self._by_owner.pop(owner_id, None)

    def waiting(self) -> list[Notice]:
        with self._lock:
            now = self._clock()
            for owner_id, notice in list(self._by_owner.items()):
                if now - notice.queued_at >= NOTICE_MAX_WAIT_S:
                    del self._by_owner[owner_id]
            return sorted(self._by_owner.values(), key=lambda n: n.queued_at)

    def claim(self, notice: Notice) -> bool:
        """True only if `notice` is still the owner's current notice; it is removed. Its age
        is not checked here: `waiting()` drops old notices and the gate bounds the wait."""
        with self._lock:
            if self._by_owner.get(notice.owner_id) is not notice:
                return False
            del self._by_owner[notice.owner_id]
            return True

    def remaining_s(self, notice: Notice) -> float:
        """How much longer ``notice`` may wait, on the clock it was queued on."""
        return NOTICE_MAX_WAIT_S - (self._clock() - notice.queued_at)

    def discard(self, notice: Notice) -> None:
        with self._lock:
            if self._by_owner.get(notice.owner_id) is notice:
                del self._by_owner[notice.owner_id]

    def clear(self) -> None:
        with self._lock:
            self._by_owner.clear()

    def __len__(self) -> int:
        with self._lock:
            return len(self._by_owner)


def now_playing_track(fields) -> dict | None:
    track = lastfm_track_fields(fields)
    if track is None:
        return None
    duration = fields["duration"]
    if duration is not None and duration > 0:
        track["duration"] = math.ceil(duration)
    return track
