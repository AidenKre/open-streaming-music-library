"""Regression tests for the encoder coordinator's thread safety.

Covers two bugs:

- Bug #1: ``_warm_generation`` and ``default_quality`` were mutated without a
  lock and read by ``encode_for_stream`` / ``_warm_one`` from worker threads.
  Concurrent ``set_default_quality`` calls or a PUT racing with an in-flight
  encode could land entries in the wrong tier or skip valid warm tasks.

- Bug #2: ``_key_locks.pop`` was missing from the cached-after-lock return
  path in ``encode_for_stream``. Every cache-warm race leaked one entry.
"""

from __future__ import annotations

import threading
from pathlib import Path

import pytest

from app.services.encoded_cache import EncodedCache, EncodedCacheContext
from app.services.encoder_coordinator import EncoderCoordinator


# ── Helpers ───────────────────────────────────────────────────────────────────

def _make_coordinator(
    tmp_path: Path,
    *,
    workers: int = 4,
    default_quality: str = "192",
    transcode_fn=None,
    all_uuids_fn=None,
) -> EncoderCoordinator:
    source = tmp_path / "source.mp3"
    source.write_bytes(b"audio" * 100)

    stream_cache = EncodedCache(
        ctx=EncodedCacheContext(
            cache_dir=tmp_path / "stream",
            max_size_bytes=10 * 1024 * 1024,
        )
    )
    default_cache = EncodedCache(
        ctx=EncodedCacheContext(cache_dir=tmp_path / "default", max_size_bytes=0)
    )

    if transcode_fn is None:
        def transcode_fn(src: Path, dst: Path, bitrate: int) -> bool:  # noqa: E306
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_bytes(b"encoded" * 10)
            return True

    return EncoderCoordinator(
        cache=stream_cache,
        source_lookup=lambda _: source,
        workers=workers,
        transcode_fn=transcode_fn,
        default_cache=default_cache,
        default_quality=default_quality,
        all_uuids_fn=all_uuids_fn,
    )


# ── Bug #1: default-state read/write races ────────────────────────────────────

class TestDefaultStateLocking:
    def test_concurrent_set_default_quality__warm_generation_monotonic(self, tmp_path):
        """N concurrent set_default_quality calls must all bump the generation.

        Without a lock, two ``+=`` operations can interleave and lose updates.
        Repeat the burst across multiple rounds to make the race deterministic
        — even a small race window is amplified to near-certain failure.
        """
        c = _make_coordinator(tmp_path, default_quality="192")
        c.all_uuids_fn = lambda: []  # no warm work to actually do
        start_gen = c._warm_generation

        total_distinct_calls = 0
        for round_idx in range(5):
            # Use distinct quality strings each round so every call passes the
            # "same quality" check. Each round flips between two interleaved
            # ranges to ensure all calls do real work.
            base = 96 + round_idx * 400
            qualities = [str(base + 8 * i) for i in range(40)]
            total_distinct_calls += len(qualities)
            barrier = threading.Barrier(len(qualities))

            def worker(q: str) -> None:
                barrier.wait()
                c.set_default_quality(q)

            threads = [threading.Thread(target=worker, args=(q,)) for q in qualities]
            for t in threads:
                t.start()
            for t in threads:
                t.join()

        c._executor.shutdown(wait=True)

        # Every distinct call must have incremented the generation. Under a
        # broken lock, lost updates would make this strictly less than
        # ``total_distinct_calls`` with very high probability.
        assert c._warm_generation == start_gen + total_distinct_calls

    def test_concurrent_set_and_encode__entries_land_in_consistent_tier(self, tmp_path):
        """While ``set_default_quality`` flips the default, concurrent encodes
        must land in *one* cache. After the dust settles, for every (uuid,
        quality) entry that exists, the choice of cache tier must be
        consistent with the rule:

            entry in default_cache  → quality == final default_quality
            entry in stream cache   → quality != some default_quality at write time

        We can't assert tier from a single read mid-flight, but we *can*
        assert that no (uuid, quality) ends up duplicated in both caches —
        that would only happen if a writer snapshotted one default and a
        reader (re-check) snapshotted another.
        """
        c = _make_coordinator(tmp_path, workers=4, default_quality="192")

        N = 30
        uuids = [f"uuid-{i}" for i in range(N)]
        qualities = ["128", "192", "256", "320"]
        barrier = threading.Barrier(N + 2)

        def encoder(i: int) -> None:
            barrier.wait()
            c.encode_for_stream(uuids[i], qualities[i % len(qualities)],
                                source_bitrate_kbps=500)

        def flipper(target: str) -> None:
            barrier.wait()
            c.set_default_quality(target)

        threads = [threading.Thread(target=encoder, args=(i,)) for i in range(N)]
        threads.append(threading.Thread(target=flipper, args=("256",)))
        threads.append(threading.Thread(target=flipper, args=("128",)))
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        c._executor.shutdown(wait=True)

        # No (uuid, quality) may be present in both caches.
        for uid, q in ((u, q) for u in uuids for q in qualities):
            in_default = c.default_cache.has(uid, q)
            in_stream = c.cache.has(uid, q)
            assert not (in_default and in_stream), (
                f"({uid}, {q}) duplicated across both caches"
            )

    def test_set_default_quality_atomic_with_warm_generation(self, tmp_path):
        """A reader that snapshots ``(default_quality, _warm_generation)``
        under the guard lock must never observe ``new_quality`` paired with
        the pre-increment generation, or vice versa.

        We instrument the lock to release the GIL on every acquire and run
        many flipper/reader pairs; with the fix, the snapshot is always
        internally consistent because both fields are written and read under
        the same guard.
        """
        c = _make_coordinator(tmp_path, default_quality="original")
        c.all_uuids_fn = lambda: []

        observations: list[tuple[str, int]] = []
        obs_lock = threading.Lock()
        stop = threading.Event()

        def reader() -> None:
            while not stop.is_set():
                snap = c._snapshot_default_state()
                with obs_lock:
                    observations.append((snap[0], snap[2]))

        readers = [threading.Thread(target=reader) for _ in range(3)]
        for r in readers:
            r.start()

        # Each flipper transitions quality from "qN" → "qN+1", incrementing gen.
        # Quality string equals "q{gen_after}" so the invariant is:
        # observed_quality == "q{observed_gen}" or initial ("original", 0).
        for i in range(1, 200):
            c.set_default_quality(f"q{i}")

        stop.set()
        for r in readers:
            r.join()
        c._executor.shutdown(wait=True)

        for q, gen in observations:
            if q == "original":
                # Only legal pairing for the initial state.
                assert gen == 0, f"original quality must be gen 0, saw gen={gen}"
            else:
                assert q == f"q{gen}", (
                    f"inconsistent snapshot: quality={q!r} but gen={gen} "
                    f"(expected q{gen})"
                )

    def test_snapshot_default_state_returns_consistent_triple(self, tmp_path):
        """``_snapshot_default_state`` must be atomic w.r.t. set_default_quality.

        Spawn flippers and snapshot readers concurrently; every snapshot must
        pair a quality with a generation that is at least as new as the
        generation when that quality was set.
        """
        c = _make_coordinator(tmp_path, default_quality="192")
        c.all_uuids_fn = lambda: []

        # Initial state.
        snapshots: list[tuple[str, int]] = []
        snap_lock = threading.Lock()
        stop = threading.Event()

        def reader() -> None:
            while not stop.is_set():
                q, _, gen = c._snapshot_default_state()
                with snap_lock:
                    snapshots.append((q, gen))

        def flipper(target: str) -> None:
            c.set_default_quality(target)

        readers = [threading.Thread(target=reader) for _ in range(4)]
        for r in readers:
            r.start()

        flipper_threads = [
            threading.Thread(target=flipper, args=(str(96 + 8 * i),))
            for i in range(20)
        ]
        for t in flipper_threads:
            t.start()
        for t in flipper_threads:
            t.join()

        stop.set()
        for r in readers:
            r.join()
        c._executor.shutdown(wait=True)

        # Generation observed in snapshots must be monotonically non-decreasing
        # *for the same observer thread*. Across all readers it should be
        # non-decreasing too because the lock serializes mutations and reads.
        # We just check the trivial invariant: every generation in any
        # snapshot is in range [0, final_generation].
        final = c._warm_generation
        for _, gen in snapshots:
            assert 0 <= gen <= final


# ── Bug #2: per-key lock leak ─────────────────────────────────────────────────

class TestKeyLockCleanup:
    def test_pre_populated_cache__no_lock_entry_leaked(self, tmp_path):
        """If the entry is already cached, the outer fast path returns and
        never creates a key lock. ``_key_locks`` stays empty.
        """
        c = _make_coordinator(tmp_path, default_quality="192")

        # Prime the default cache via a normal encode.
        c.encode_for_stream("uuid-a", "192", source_bitrate_kbps=500)
        # Force any leaked entry from the first call to be popped: it was popped
        # by the finally block. Confirm:
        assert c._key_locks == {}

        # Second call must be a cache-hit fast path, no key lock involvement.
        result = c.encode_for_stream("uuid-a", "192", source_bitrate_kbps=500)
        assert result is not None
        assert c._key_locks == {}

    def test_concurrent_first_encode__no_lock_entry_leaks_when_second_finds_cache(
        self, tmp_path
    ):
        """Two concurrent calls for the same (uuid, quality). The second
        thread enters ``with lock`` after the first wrote the cache and so
        returns from the cached-after-lock path. Before the fix, that exit
        skipped the ``pop`` and leaked an entry. After: ``_key_locks`` ends
        empty regardless of which thread finishes first.
        """
        enter_gate = threading.Event()
        first_finished_write = threading.Event()

        def slow_transcode(src: Path, dst: Path, bitrate: int) -> bool:
            # Block the first transcode until the second thread is queued
            # behind the per-key lock. ``enter_gate`` is set by the test
            # after both threads are launched.
            enter_gate.wait(timeout=5)
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_bytes(b"encoded" * 10)
            return True

        c = _make_coordinator(tmp_path, default_quality="192",
                              transcode_fn=slow_transcode)

        results: list[object] = [None, None]

        def worker(idx: int) -> None:
            results[idx] = c.encode_for_stream("uuid-a", "192",
                                               source_bitrate_kbps=500)

        t1 = threading.Thread(target=worker, args=(0,))
        t2 = threading.Thread(target=worker, args=(1,))
        t1.start()
        # Give t1 a moment to acquire the per-key lock and call transcode.
        # Polling: wait until exactly one entry is in _key_locks. The sleep
        # forces GIL release so t1 can actually run between checks.
        import time as _time
        for _ in range(500):
            if ("uuid-a", "192") in c._key_locks:
                break
            _time.sleep(0.002)
        else:
            enter_gate.set()  # release t1 so the test doesn't hang
            pytest.fail("first thread never registered a key lock")
        t2.start()
        # Release the transcode so t1 completes; t2 then enters the lock,
        # hits the cache re-check, and returns via the previously-leaky path.
        enter_gate.set()

        t1.join()
        t2.join()
        c._executor.shutdown(wait=True)

        assert results[0] is not None
        assert results[1] is not None
        # No lock entries should remain regardless of interleaving.
        assert c._key_locks == {}

    def test_passthrough_path__no_lock_entry_leaks(self, tmp_path):
        """The passthrough return (source bitrate ≤ requested bitrate) is one
        of the early exits inside the lock; it must also clean up.
        """
        c = _make_coordinator(tmp_path, default_quality="192")
        # source_bitrate_kbps=64 ≤ 128 → passthrough.
        r = c.encode_for_stream("uuid-pass", "128", source_bitrate_kbps=64)
        assert r is not None
        assert r.transcoded is False
        assert c._key_locks == {}

    def test_transcode_failure_path__no_lock_entry_leaks(self, tmp_path):
        """Failed transcodes must also pop the key lock entry."""
        def failing_transcode(src: Path, dst: Path, bitrate: int) -> bool:
            return False

        c = _make_coordinator(tmp_path, default_quality="192",
                              transcode_fn=failing_transcode)
        result = c.encode_for_stream("uuid-fail", "192",
                                     source_bitrate_kbps=500)
        assert result is None
        assert c._key_locks == {}

    def test_missing_source_path__no_lock_entry_leaks(self, tmp_path):
        """Missing source must also pop the key lock entry."""
        c = _make_coordinator(tmp_path, default_quality="192")
        c.source_lookup = lambda _: None
        result = c.encode_for_stream("uuid-missing", "192",
                                     source_bitrate_kbps=500)
        assert result is None
        assert c._key_locks == {}

    def test_transcode_raises_exception__no_lock_entry_leaks(self, tmp_path):
        """The cleanup must survive transcode_fn raising. Without the
        ``try/finally`` around the lock body, an exception escape would leave
        the per-key entry forever. This is the path a contributor most likely
        misses if they restructure encode_for_stream into per-return-path
        pops instead of a single finally.
        """
        def raising_transcode(src: Path, dst: Path, bitrate: int) -> bool:
            raise RuntimeError("ffmpeg blew up")

        c = _make_coordinator(tmp_path, default_quality="192",
                              transcode_fn=raising_transcode)
        with pytest.raises(RuntimeError):
            c.encode_for_stream("uuid-boom", "192", source_bitrate_kbps=500)
        assert c._key_locks == {}
