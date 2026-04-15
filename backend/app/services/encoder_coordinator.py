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
from app.services.metadata import get_audio_bitrate_kbps
from app.services.transcoder import (
    ORIGINAL_QUALITY,
    QUALITY_BITRATES_KBPS,
    transcode_to_aac_m4a,
)


SourceLookup = Callable[[str], Optional[Path]]
TranscodeFn = Callable[[Path, Path, int], bool]


@dataclass(frozen=True)
class EncodeResult:
    """Outcome of encode_for_stream.

    ``transcoded=True``  — an AAC m4a was produced; ``path`` points to it.
    ``transcoded=False`` — the source file is returned as-is (ORIGINAL_QUALITY
    was requested, or the source bitrate was already ≤ the requested bitrate
    making transcoding pointless). Callers must use the source codec's MIME
    type, not ``audio/mp4``, when ``transcoded`` is False.
    """
    path: Path
    bitrate_kbps: int
    transcoded: bool


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

    def encode_for_stream(
        self,
        uuid_id: str,
        quality: str,
        source_bitrate_kbps: Optional[int] = None,
    ) -> Optional[EncodeResult]:
        """Return an EncodeResult for streaming, transcoding if needed.

        Returns None when the source can't be found or transcoding fails.

        ``source_bitrate_kbps`` is an optional hint used to skip transcoding
        when the source is already at or below the requested bitrate. Callers
        with the value in hand (e.g. from the DB) should pass it; background
        workers can pass None and the coordinator will ffprobe the source file.

        ORIGINAL_QUALITY always returns the source file directly.
        """
        if quality == ORIGINAL_QUALITY:
            source = self.source_lookup(uuid_id)
            if source is None or not source.exists():
                return None
            return EncodeResult(
                path=source,
                bitrate_kbps=source_bitrate_kbps or 0,
                transcoded=False,
            )

        bitrate = QUALITY_BITRATES_KBPS.get(quality)
        if bitrate is None:
            return None

        cached = self.cache.get(uuid_id, quality)
        if cached is not None:
            return EncodeResult(path=cached, bitrate_kbps=bitrate, transcoded=True)

        lock = self._key_lock(uuid_id, quality)
        with lock:
            cached = self.cache.get(uuid_id, quality)
            if cached is not None:
                return EncodeResult(path=cached, bitrate_kbps=bitrate, transcoded=True)

            source = self.source_lookup(uuid_id)
            if source is None or not source.exists():
                with self._key_locks_guard:
                    self._key_locks.pop((uuid_id, quality), None)
                return None

            # Resolve source bitrate: use caller-supplied hint if available,
            # otherwise ffprobe. Runs inside the lock so we probe at most once
            # per (uuid, quality) even under concurrent requests.
            effective_source_bitrate = source_bitrate_kbps
            if effective_source_bitrate is None:
                effective_source_bitrate = get_audio_bitrate_kbps(source)

            # Passthrough: source is already at or below the requested bitrate.
            # Transcoding would not improve quality and would waste CPU + space.
            if effective_source_bitrate and effective_source_bitrate <= bitrate:
                with self._key_locks_guard:
                    self._key_locks.pop((uuid_id, quality), None)
                return EncodeResult(
                    path=source,
                    bitrate_kbps=effective_source_bitrate,
                    transcoded=False,
                )

            scratch = self._scratch_dir / f"{uuid_lib.uuid4().hex}.m4a"
            ok = self.transcode_fn(source, scratch, bitrate)
            if not ok:
                if scratch.exists():
                    scratch.unlink(missing_ok=True)
                with self._key_locks_guard:
                    self._key_locks.pop((uuid_id, quality), None)
                return None

            cached_path = self.cache.insert(uuid_id, quality, scratch)
            with self._key_locks_guard:
                self._key_locks.pop((uuid_id, quality), None)
            return EncodeResult(path=cached_path, bitrate_kbps=bitrate, transcoded=True)

    def enqueue_prefetch(
        self,
        uuid_id: str,
        quality: str,
        source_bitrate_kbps: Optional[int] = None,
    ) -> bool:
        """Schedule a background encode. Returns False for invalid params.

        No-ops for ORIGINAL_QUALITY (no transcoding needed) or when the entry
        already exists in cache. ``source_bitrate_kbps`` is threaded through to
        the worker so it can skip transcoding for low-bitrate sources.
        """
        if quality == ORIGINAL_QUALITY:
            return True
        if quality not in QUALITY_BITRATES_KBPS:
            return False
        if self.cache.has(uuid_id, quality):
            return True
        self._executor.submit(self._prefetch_one, uuid_id, quality, source_bitrate_kbps)
        return True

    def enqueue_prefetch_batch(
        self,
        items: list[tuple[str, str]],
        source_bitrates: Optional[dict[str, int]] = None,
    ) -> int:
        """Schedule a batch of background encodes.

        Each item is ``(uuid_id, quality)``. Items that are already cached,
        use ORIGINAL_QUALITY, or have invalid quality are silently skipped.
        ``source_bitrates`` is an optional ``{uuid_id: bitrate_kbps}`` map
        passed through to workers for passthrough checks.
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
            self._executor.submit(self._prefetch_batch, to_encode, source_bitrates or {})
        return len(to_encode)

    def _prefetch_one(
        self,
        uuid_id: str,
        quality: str,
        source_bitrate_kbps: Optional[int],
    ) -> None:
        try:
            self.encode_for_stream(uuid_id, quality, source_bitrate_kbps)
        except Exception:
            # Background prefetches must never propagate.
            return

    def _prefetch_batch(
        self,
        items: list[tuple[str, str]],
        source_bitrates: dict[str, int],
    ) -> None:
        """Encode multiple tracks in one worker call."""
        for uuid_id, quality in items:
            try:
                self.encode_for_stream(uuid_id, quality, source_bitrates.get(uuid_id))
            except Exception:
                continue
