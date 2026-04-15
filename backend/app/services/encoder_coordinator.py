"""Coordinates synchronous + asynchronous transcoding requests.

`encode_for_stream` produces an encoded file for the streaming endpoint, using
the cache when possible. `enqueue_prefetch` queues background encodes used by
the queue-prefetch API. We dedupe in-flight work via per-key locks so two
concurrent requests for the same (uuid, quality) only encode once.
"""

import threading
import uuid as uuid_lib
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Optional

from app.services.encoded_cache import EncodedCache
from app.services.transcoder import (
    ORIGINAL_QUALITY,
    QUALITY_BITRATES_KBPS,
    transcode_to_aac_m4a,
)


SourceLookup = Callable[[str], Optional[Path]]
TranscodeFn = Callable[[Path, Path, int], bool]


@dataclass
class EncoderCoordinator:
    cache: EncodedCache
    source_lookup: SourceLookup
    workers: int = 2
    transcode_fn: TranscodeFn = transcode_to_aac_m4a
    _executor: ThreadPoolExecutor = field(init=False)
    _key_locks: dict[tuple[str, str], threading.Lock] = field(default_factory=dict)
    _key_locks_guard: threading.Lock = field(default_factory=threading.Lock)
    _scratch_dir: Path = field(init=False)

    def __post_init__(self) -> None:
        self._executor = ThreadPoolExecutor(max_workers=max(1, self.workers))
        self._scratch_dir = self.cache.ctx.cache_dir / "_scratch"
        self._scratch_dir.mkdir(parents=True, exist_ok=True)

    def shutdown(self) -> None:
        self._executor.shutdown(wait=False, cancel_futures=True)

    def _key_lock(self, uuid_id: str, quality: str) -> threading.Lock:
        key = (uuid_id, quality)
        with self._key_locks_guard:
            lock = self._key_locks.get(key)
            if lock is None:
                lock = threading.Lock()
                self._key_locks[key] = lock
            return lock

    def encode_for_stream(self, uuid_id: str, quality: str) -> Optional[Path]:
        """Return path to an encoded file for streaming, encoding if needed.

        Returns None when the source can't be found or transcoding fails. The
        ORIGINAL_QUALITY preset returns the source path directly without
        touching the cache.
        """
        if quality == ORIGINAL_QUALITY:
            return self.source_lookup(uuid_id)

        bitrate = QUALITY_BITRATES_KBPS.get(quality)
        if bitrate is None:
            return None

        cached = self.cache.get(uuid_id, quality)
        if cached is not None:
            return cached

        lock = self._key_lock(uuid_id, quality)
        with lock:
            cached = self.cache.get(uuid_id, quality)
            if cached is not None:
                return cached

            source = self.source_lookup(uuid_id)
            if source is None or not source.exists():
                return None

            scratch = self._scratch_dir / f"{uuid_lib.uuid4().hex}.m4a"
            ok = self.transcode_fn(source, scratch, bitrate)
            if not ok:
                if scratch.exists():
                    scratch.unlink(missing_ok=True)
                return None

            result = self.cache.insert(uuid_id, quality, scratch)
            with self._key_locks_guard:
                self._key_locks.pop((uuid_id, quality), None)
            return result

    def enqueue_prefetch(self, uuid_id: str, quality: str) -> bool:
        """Schedule a background encode. Returns False for invalid params.

        No-ops for ORIGINAL_QUALITY (no transcoding needed) or when the entry
        already exists in cache.
        """
        if quality == ORIGINAL_QUALITY:
            return True
        if quality not in QUALITY_BITRATES_KBPS:
            return False
        if self.cache.has(uuid_id, quality):
            return True
        self._executor.submit(self._prefetch_one, uuid_id, quality)
        return True

    def enqueue_prefetch_batch(self, items: list[tuple[str, str]]) -> int:
        """Schedule a batch of background encodes.

        Each item is ``(uuid_id, quality)``.  Items that are already cached,
        use ORIGINAL_QUALITY, or have invalid quality are silently skipped.
        Returns the number of items actually queued.
        """
        to_encode = [
            (uid, q)
            for uid, q in items
            if q != ORIGINAL_QUALITY
            and q in QUALITY_BITRATES_KBPS
            and not self.cache.has(uid, q)
        ]
        if to_encode:
            self._executor.submit(self._prefetch_batch, to_encode)
        return len(to_encode)

    def _prefetch_one(self, uuid_id: str, quality: str) -> None:
        try:
            self.encode_for_stream(uuid_id, quality)
        except Exception:
            # Background prefetches must never propagate.
            return

    def _prefetch_batch(self, items: list[tuple[str, str]]) -> None:
        """Encode multiple tracks in one worker call."""
        for uuid_id, quality in items:
            try:
                self.encode_for_stream(uuid_id, quality)
            except Exception:
                continue
