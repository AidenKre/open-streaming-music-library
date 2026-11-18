"""Coordinates synchronous + asynchronous transcoding requests.

`encode_for_stream` produces an encoded file for the streaming endpoint, using
the cache when possible. `enqueue_prefetch` queues background encodes used by
the queue-prefetch API. We dedupe in-flight work via per-key locks so two
concurrent requests for the same (uuid, quality) only encode once.

Two-tier cache
--------------
There are two cache instances:

``cache``         — stream cache. LRU, capped at ``encoded_cache_size_gb``.
                   Holds on-demand and non-default encodes.
``default_cache`` — default-quality cache. Unlimited. Holds pre-warmed encodes
                   at the server's configured default quality so they are never
                   evicted by on-demand traffic.

Lookup order for ``encode_for_stream``:
  - If quality == default_quality: check default_cache first, then cache.
  - Otherwise: check cache only.

New encodes always land in the cache that matches the quality:
  - owner is the master admin AND quality == default_quality → default_cache
  - everything else                                          → cache (stream cache, subject to LRU)
(``default_cache`` only ever holds admin entries, so lookups stay owner-free.)
"""

import enum
import logging
import os
import queue as _queue
import threading
import uuid as uuid_lib
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Optional


class PrefetchOutcome(enum.Enum):
    """Result of a single [EncoderCoordinator.enqueue_prefetch] call.

    Distinguishes "really queued a background encode" from the no-op cases
    (already cached, original-quality pass-through) so callers can report
    accurate stats instead of overcounting work.
    """

    QUEUED = "queued"
    ALREADY_CACHED = "already_cached"
    SKIPPED_ORIGINAL = "skipped_original"
    INVALID = "invalid"

from app.services.encoded_cache import CACHE_FILE_SUFFIX, EncodedCache
from app.services.import_outcome import file_signature
from app.services.keyed_locks import KeyedLocks
from app.services.metadata import get_audio_bitrate_kbps
from app.services.transcoder import (
    ORIGINAL_QUALITY,
    QUALITY_BITRATES_KBPS,
    transcode_to_aac_m4a,
)

logger = logging.getLogger(__name__)


SourceLookup = Callable[[str], Optional[Path]]
TranscodeFn = Callable[[Path, Path, int], bool]
AllUuidsFn = Callable[[], list[str]]


class SourceUnavailable(Exception):
    """The track's source file could not be resolved or no longer exists.

    Distinct from a transcode failure (which returns ``None``): callers can map
    this to a 404 ("the source is gone, stop retrying") instead of a 500.
    """


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
    # None when the source's bitrate is unknown (passthrough of a file
    # ffprobe reported no bitrate for).
    bitrate_kbps: Optional[int]
    transcoded: bool


@dataclass(frozen=True)
class GenerationToken:
    """An encode cache's per-uuid generation, captured before the row is read."""
    cache: EncodedCache
    uuid_id: str
    generation: int

    def moved(self) -> bool:
        return self.cache.generation(self.uuid_id) != self.generation


# ── Priority pool ─────────────────────────────────────────────────────────────

@dataclass(order=True)
class _Task:
    priority: int
    neg_seq: int          # negated seq so higher seq → wins within same priority (LIFO)
    fn: Any = field(compare=False, default=None)   # None = shutdown sentinel
    args: tuple = field(compare=False, default_factory=tuple)
    kwargs: dict = field(compare=False, default_factory=dict)


class _PriorityPool:
    """Thread pool with three priority levels.

    Priority 0 (PRIORITY_HIGH)       — prefetch / queue-warm: encode tasks for
                                        tracks the user is about to play
                                        (enqueue_prefetch).
    Priority 1 (PRIORITY_LOW)        — background quality work: removing the
                                        default cache's files of other
                                        qualities and library-wide warming
                                        from set_default_quality.
    Priority 2 (PRIORITY_CONVERSION) — master-type conversion jobs (Phase 2).
                                        Lowest priority: a long-running convert
                                        must never starve streaming encodes.
    Within each level the newest submitted task runs first (LIFO).
    """
    PRIORITY_HIGH = 0
    PRIORITY_LOW = 1
    PRIORITY_CONVERSION = 2

    def __init__(self, max_workers: int) -> None:
        self._q: _queue.PriorityQueue[_Task] = _queue.PriorityQueue()
        self._seq = 0
        self._seq_lock = threading.Lock()
        self._threads = [
            threading.Thread(target=self._loop, daemon=True, name=f"encoder-{i}")
            for i in range(max(1, max_workers))
        ]
        for t in self._threads:
            t.start()

    def submit(self, fn: Callable, *args: Any, priority: int = PRIORITY_LOW, **kwargs: Any) -> None:
        with self._seq_lock:
            seq = self._seq
            self._seq += 1
        self._q.put(_Task(priority=priority, neg_seq=-seq, fn=fn, args=args, kwargs=kwargs))

    def _loop(self) -> None:
        while True:
            task = self._q.get()
            if task.fn is None:   # shutdown sentinel
                return
            try:
                task.fn(*task.args, **task.kwargs)
            except Exception as e:  # the type only: its text may name a file
                logger.warning("encoder pool task failed: %s", type(e).__name__)

    def shutdown(self, wait: bool = True, *, cancel_pending: bool = False) -> None:
        """Stop the worker threads.

        By default the sentinels sort after every queued task, so the pool
        drains its queue before stopping. With ``cancel_pending`` they sort
        ahead of every task: each thread exits after the task it is running
        now, and nothing only queued (or submitted later) starts."""
        priority = self.PRIORITY_HIGH - 1 if cancel_pending else 10**9
        for _ in self._threads:
            self._q.put(_Task(priority=priority, neg_seq=0))  # fn=None → sentinel
        if wait:
            for t in self._threads:
                t.join()


# ── Coordinator ───────────────────────────────────────────────────────────────

@dataclass
class EncoderCoordinator:
    cache: EncodedCache
    source_lookup: SourceLookup
    workers: int = 2
    transcode_fn: TranscodeFn = transcode_to_aac_m4a
    # Two-tier cache: default_cache is unlimited and holds the server default
    # quality; cache is the LRU stream cache for on-demand requests.
    default_cache: Optional[EncodedCache] = None
    default_quality: str = ORIGINAL_QUALITY
    # Optional callable that returns all track UUID strings; used by
    # _submit_warm_tasks to pre-encode every track at the new default quality.
    all_uuids_fn: Optional[AllUuidsFn] = None
    # The master admin's user id; only their encodes at the default quality
    # land in default_cache. Fixed at construction.
    admin_owner_id: Optional[int] = None
    # uuid -> owning user id (or None); used by background prefetch workers.
    owner_lookup: Optional[Callable[[str], Optional[int]]] = None
    _executor: _PriorityPool = field(init=False)
    # Per-(uuid, quality) encode locks (shared keyed-lock utility). The guard
    # below is NOT the lock registry's internal guard — it protects the
    # default-quality/warm-generation state snapshots.
    _key_locks: KeyedLocks[tuple[str, str]] = field(default_factory=KeyedLocks)
    _key_locks_guard: threading.Lock = field(default_factory=threading.Lock)
    _default_quality_update_lock: threading.Lock = field(default_factory=threading.Lock)
    _scratch_dir: Path = field(init=False)
    _warm_generation: int = field(init=False, default=0)

    def __post_init__(self) -> None:
        self._executor = _PriorityPool(max_workers=max(1, self.workers))
        self._scratch_dir = self.cache.ctx.cache_dir / "_scratch"
        self._scratch_dir.mkdir(parents=True, exist_ok=True)

    def shutdown(self) -> None:
        self._executor.shutdown(wait=False, cancel_pending=True)

    def drain(self) -> None:
        """Run every queued task, then stop the worker threads and wait for
        them. For tests and tools; the server stops with ``shutdown``, which
        drops the queued work."""
        self._executor.shutdown(wait=True)

    @property
    def warm_generation(self) -> int:
        """The warm generation: each default-quality change bumps it, and a
        queued warm task of an older generation does nothing."""
        with self._key_locks_guard:
            return self._warm_generation

    def submit_conversion(self, fn: Callable, *args: Any, **kwargs: Any) -> None:
        """Schedule work at PRIORITY_CONVERSION on the shared pool. The one
        entry point the Phase 2 conversion orchestrator uses instead of
        reaching into the private ``_executor`` -- reuses this same pool
        rather than adding a second one.

        A running conversion holds its worker thread for its whole duration
        (priority only orders the queue). With one active job per track and
        single-track enqueue, concurrent conversions are bounded by how many
        tracks the user converts at once; each occupies 1 of the
        ``encoded_cache_prefetch_workers`` threads (default 4). Queued
        conversions also wait behind any pending warm/prefetch work.
        TODO(bulk-throughput): cap concurrent conversions (or give them a
        dedicated slot) before bulk enqueue can flood the pool."""
        self._executor.submit(
            fn, *args, priority=_PriorityPool.PRIORITY_CONVERSION, **kwargs
        )

    def startup(self) -> None:
        """Called once at app startup before any requests are served.

        1. Cleans up orphaned scratch files from interrupted transcodes.
        2. Queues a prune of the default cache's files of every other quality
           (a cleanup queued by a default change is lost on stop or crash).
        3. Resumes warming: submits tasks only for tracks missing from the
           default cache (diff-based, avoids spamming the pool with no-ops).
        """
        # 1. Clean orphaned scratch files from interrupted transcodes.
        if self._scratch_dir.exists():
            for f in self._scratch_dir.iterdir():
                try:
                    f.unlink(missing_ok=True)
                except OSError:
                    pass

        default_quality, default_cache, gen = self._snapshot_default_state()

        # 2. Prune other qualities from the default cache.
        if default_cache is not None:
            self._executor.submit(
                self._delete_default_cache_files, default_cache,
                priority=_PriorityPool.PRIORITY_LOW,
            )

        # 3. Resume warming only for tracks not already in the default cache.
        if default_quality == ORIGINAL_QUALITY or self.all_uuids_fn is None:
            return

        all_uuids = set(self.all_uuids_fn())
        if default_cache is not None:
            cached = {uid for uid in all_uuids if default_cache.has(uid, default_quality)}
        else:
            cached = set()

        for uuid_id in all_uuids - cached:
            self._submit_warm(uuid_id, default_quality, gen)

    def warm_imported(self, uuid_id: str, owner_id: int) -> None:
        """Warm a freshly imported track at the default quality (admin only,
        spec §6.1). A no-op for other owners, at original quality, or when the
        track is already cached."""
        if owner_id != self.admin_owner_id:
            return
        default_quality, default_cache, gen = self._snapshot_default_state()
        if default_quality == ORIGINAL_QUALITY:
            return
        if default_cache is not None and default_cache.has(uuid_id, default_quality):
            return
        self._submit_warm(uuid_id, default_quality, gen)

    def _submit_warm(self, uuid_id: str, quality: str, generation: int) -> None:
        self._executor.submit(
            self._warm_one, uuid_id, quality, generation,
            priority=_PriorityPool.PRIORITY_LOW,
        )

    # ── Cache tier helpers ────────────────────────────────────────────────

    def _snapshot_default_state(self) -> tuple[str, Optional[EncodedCache], int]:
        """Snapshot ``(default_quality, default_cache, _warm_generation)`` under the
        guard lock so cache-tier decisions and warm-generation reads are
        consistent across concurrent ``set_default_quality`` mutations.
        """
        with self._key_locks_guard:
            return self.default_quality, self.default_cache, self._warm_generation

    def _write_cache(self, quality: str, owner_id: int) -> EncodedCache:
        """Return the cache to write new encodes into for this quality/owner."""
        default_quality, default_cache, _ = self._snapshot_default_state()
        if (
            default_cache is not None
            and quality == default_quality
            and self.admin_owner_id is not None
            and owner_id == self.admin_owner_id
        ):
            return default_cache
        return self.cache

    def _lookup_cached(self, uuid_id: str, quality: str) -> Optional[Path]:
        """Check caches in priority order and return a hit, or None."""
        default_quality, default_cache, _ = self._snapshot_default_state()
        if default_cache is not None and quality == default_quality:
            hit = default_cache.get(uuid_id, quality)
            if hit is not None:
                return hit
        return self.cache.get(uuid_id, quality)

    def _has_cached(self, uuid_id: str, quality: str) -> bool:
        default_quality, default_cache, _ = self._snapshot_default_state()
        if default_cache is not None and quality == default_quality:
            if default_cache.has(uuid_id, quality):
                return True
        return self.cache.has(uuid_id, quality)

    def capture_generation(
        self, uuid_id: str, quality: str, *, owner_id: int
    ) -> GenerationToken:
        """Capture the target cache's generation; call before resolving the row."""
        cache = self._write_cache(quality, owner_id)
        return GenerationToken(cache, uuid_id, cache.generation(uuid_id))

    # ── Per-key lock helpers ──────────────────────────────────────────────

    def _key_lock(self, uuid_id: str, quality: str) -> threading.Lock:
        return self._key_locks.lock_for((uuid_id, quality))

    # ── Public API ────────────────────────────────────────────────────────

    def encode_for_stream(
        self,
        uuid_id: str,
        quality: str,
        source_bitrate_kbps: Optional[int] = None,
        source_path: Optional[Path] = None,
        *,
        owner_id: int,
        generation: Optional[GenerationToken] = None,
    ) -> Optional[EncodeResult]:
        """Return an EncodeResult for streaming, transcoding if needed.

        Raises :class:`SourceUnavailable` when the source file can't be found or
        no longer exists; returns ``None`` only when transcoding fails.

        ``source_bitrate_kbps`` is an optional hint used to skip transcoding
        when the source is already at or below the requested bitrate. Callers
        with the value in hand (e.g. from the DB) should pass it; background
        workers can pass None and the coordinator will ffprobe the source file.

        ``source_path`` lets callers that already hold the source path (e.g. the
        streaming endpoint, which just queried the track row) skip the redundant
        ``source_lookup`` DB query. Background workers pass None and fall back to
        ``source_lookup``.

        ``owner_id`` (required) is the track row's owner; it only decides the
        write tier: default_cache iff the owner is the master admin and the
        quality is the admin's default, else the LRU stream cache.

        ORIGINAL_QUALITY always returns the source file directly.
        """
        if quality == ORIGINAL_QUALITY:
            source = source_path or self.source_lookup(uuid_id)
            if source is None or not source.exists():
                raise SourceUnavailable(uuid_id)
            return EncodeResult(
                path=source,
                bitrate_kbps=source_bitrate_kbps,
                transcoded=False,
            )

        bitrate = QUALITY_BITRATES_KBPS.get(quality)
        if bitrate is None:
            return None

        cached = self._lookup_cached(uuid_id, quality)
        if cached is not None:
            return EncodeResult(path=cached, bitrate_kbps=bitrate, transcoded=True)

        lock = self._key_lock(uuid_id, quality)
        # Per-key locks live for the process lifetime. Removing a lock from
        # the map after release races: a waiter wakes holding the old lock,
        # but a new caller arriving in that gap creates a *fresh* lock, and
        # both can run the encode/cache-write block in parallel. Keeping the
        # entry forever is the simpler correct fix. The key space is bounded
        # by (track count × quality count), so the map can't grow without
        # bound; each entry is a small `threading.Lock`.
        with lock:
            cached = self._lookup_cached(uuid_id, quality)
            if cached is not None:
                return EncodeResult(path=cached, bitrate_kbps=bitrate, transcoded=True)

            if generation is not None:
                # Captured by the caller before it read the row.
                target_cache = generation.cache
                expected = generation.generation
            else:
                target_cache = self._write_cache(quality, owner_id)
                # Captured before the source is read: a conversion that replaces
                # the master and evicts this uuid mid-encode invalidates it.
                expected = target_cache.generation(uuid_id)
            source = source_path or self.source_lookup(uuid_id)
            if source is None or not source.exists():
                raise SourceUnavailable(uuid_id)

            # Resolve source bitrate: use caller-supplied hint if available,
            # otherwise ffprobe. Runs inside the lock so we probe at most once
            # per (uuid, quality) even under concurrent requests.
            effective_source_bitrate = source_bitrate_kbps
            if effective_source_bitrate is None:
                effective_source_bitrate = get_audio_bitrate_kbps(source)

            # Passthrough: source is already at or below the requested bitrate.
            # Transcoding would not improve quality and would waste CPU + space.
            if effective_source_bitrate and effective_source_bitrate <= bitrate:
                return EncodeResult(
                    path=source,
                    bitrate_kbps=effective_source_bitrate,
                    transcoded=False,
                )

            scratch = self._scratch_dir / f"{uuid_lib.uuid4().hex}.m4a"
            signature_before = file_signature(source)
            ok = self.transcode_fn(source, scratch, bitrate)
            if not ok:
                if scratch.exists():
                    scratch.unlink(missing_ok=True)
                return None
            # A source still being copied would be cached as a partial encode.
            signature_after = file_signature(source)
            if signature_before is None or signature_before != signature_after:
                scratch.unlink(missing_ok=True)
                return None

            cached_path = target_cache.insert(
                uuid_id, quality, scratch, expected_generation=expected
            )
            if cached_path is None:
                return None  # encoded from a since-replaced master; the client retries
            return EncodeResult(path=cached_path, bitrate_kbps=bitrate, transcoded=True)

    def enqueue_prefetch(
        self,
        uuid_id: str,
        quality: str,
        source_bitrate_kbps: Optional[int] = None,
    ) -> "PrefetchOutcome":
        """Schedule a background encode. Returns a [PrefetchOutcome] so
        callers can distinguish "I actually queued work" from
        "no-op because nothing was needed."

        ``source_bitrate_kbps`` is threaded through to the worker so it can
        skip transcoding for low-bitrate sources.
        """
        if quality == ORIGINAL_QUALITY:
            return PrefetchOutcome.SKIPPED_ORIGINAL
        if quality not in QUALITY_BITRATES_KBPS:
            return PrefetchOutcome.INVALID
        if self._has_cached(uuid_id, quality):
            return PrefetchOutcome.ALREADY_CACHED
        self._executor.submit(
            self._prefetch_one, uuid_id, quality, source_bitrate_kbps,
            priority=_PriorityPool.PRIORITY_HIGH,
        )
        return PrefetchOutcome.QUEUED

    def set_default_quality(self, new_quality: str) -> bool:
        """Change the default streaming quality. Returns True if warming was submitted.

        No-ops when ``new_quality`` equals the current default. Otherwise:
        1. Bumps the warm generation counter to invalidate pending warm tasks.
        2. Removes the default cache's files of every other quality (background).
        3. Submits one warm task per UUID (parallel, PRIORITY_LOW).
        """
        # Mutate default_quality and _warm_generation atomically under the
        # guard lock so concurrent encoders/readers cannot observe a partially
        # updated state (e.g. new quality with stale generation).
        with self._key_locks_guard:
            if new_quality == self.default_quality:
                return False
            old_default_cache = self.default_cache
            self.default_quality = new_quality
            self._warm_generation += 1
            gen = self._warm_generation

        if old_default_cache is not None:
            self._executor.submit(
                self._delete_default_cache_files, old_default_cache,
                priority=_PriorityPool.PRIORITY_LOW,
            )

        if new_quality != ORIGINAL_QUALITY and self.all_uuids_fn is not None:
            self._submit_warm_tasks(new_quality, gen)
            return True

        return False

    def persist_and_set_default_quality(
        self,
        new_quality: str,
        persist: Callable[[str], None],
        read_stored: Optional[Callable[[], Optional[str]]] = None,
    ) -> tuple[bool, bool]:
        """Persist ``new_quality`` then update in-memory default, serialized.

        Returns ``(changed, warming)``. ``changed`` is False when the new
        quality already matches the current default (no live change, no
        warm). In that case ``read_stored``, when given, returns the stored
        value; if it differs (for example an invalid row the live default
        fell back from), ``new_quality`` is persisted to repair it. Without
        ``read_stored`` nothing is persisted. ``warming`` mirrors
        :meth:`set_default_quality`.

        ``persist`` is invoked under :attr:`_default_quality_update_lock`
        before any in-memory mutation. If it raises, neither the persisted
        store nor the coordinator's live state are updated for this call.
        The update lock serializes compare/persist/live-update across
        concurrent callers so the final live state always matches the last
        successful persist.
        """
        with self._default_quality_update_lock:
            if new_quality == self.default_quality:
                if read_stored is not None and read_stored() != new_quality:
                    persist(new_quality)
                return False, False
            persist(new_quality)
            warming = self.set_default_quality(new_quality)
            return True, warming

    # ── Background workers ────────────────────────────────────────────────

    def _prefetch_one(
        self,
        uuid_id: str,
        quality: str,
        source_bitrate_kbps: Optional[int],
    ) -> None:
        try:
            if self.owner_lookup is None:
                return
            owner = self.owner_lookup(uuid_id)
            if owner is None:
                return
            self.encode_for_stream(
                uuid_id, quality, source_bitrate_kbps, owner_id=owner
            )
        except Exception as e:
            # Background prefetches must never propagate.
            logger.warning("prefetch failed: %s", type(e).__name__)
            return

    def _delete_default_cache_files(self, cache: EncodedCache) -> None:
        """Delete every default-cache file whose quality is not the current
        default (all of them when the default is ``original``).

        The current default is re-read for each file, so a change arriving
        mid-scan never deletes the newer default's files. Best effort: a file
        that cannot be unlinked is skipped.

        Safe to call while a file is open: on Unix the inode stays alive until
        all file descriptors are closed, so in-flight streams finish normally.
        """
        try:
            for entry in cache.ctx.cache_dir.iterdir():
                if not entry.is_file() or not entry.name.endswith(CACHE_FILE_SUFFIX):
                    continue
                current_quality, _, _ = self._snapshot_default_state()
                keep_suffix = f"__q{current_quality}{CACHE_FILE_SUFFIX}"
                if current_quality != ORIGINAL_QUALITY and entry.name.endswith(keep_suffix):
                    continue
                try:
                    entry.unlink()
                except OSError:
                    continue
        except Exception as e:
            logger.warning("default cache clean-up failed: %s", type(e).__name__)

    def _submit_warm_tasks(self, quality: str, generation: int) -> None:
        """Submit one warm task per UUID to the pool (all workers run in parallel)."""
        if self.all_uuids_fn is None:
            return
        try:
            for uuid_id in self.all_uuids_fn():
                self._executor.submit(
                    self._warm_one, uuid_id, quality, generation,
                    priority=_PriorityPool.PRIORITY_LOW,
                )
        except Exception:
            pass

    def _warm_one(self, uuid_id: str, quality: str, generation: int) -> None:
        """Encode one track at ``quality`` into the default cache.

        Bails out immediately if the generation counter has moved on (i.e. the
        default quality changed again while this task was pending).
        """
        _, _, current_generation = self._snapshot_default_state()
        if generation != current_generation:
            return
        try:
            self.encode_for_stream(
                uuid_id, quality, owner_id=self.admin_owner_id
            )
        except Exception:
            pass
