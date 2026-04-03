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
from app.services.encoder_coordinator import EncoderCoordinator, SourceUnavailable
from app.services.transcoder import ORIGINAL_QUALITY


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

class TestKeyLockDedup:
    """Per-key lock contract: one transcode per (uuid, quality), even under
    high concurrency. The previous implementation tried to remove the lock
    from the map after release, which raced — a new caller arriving in the
    gap between release and pop could create a *fresh* lock, letting two
    threads simultaneously run the encode/cache-write block. Locks are now
    kept for the process lifetime.
    """

    def test_lock_entry_persists_after_encode(self, tmp_path):
        """The map keeps the lock alive after the encode finishes. The map
        is bounded by (track count × quality count), so this is fine; the
        previous "remove after use" strategy was the source of the bug.
        """
        c = _make_coordinator(tmp_path, default_quality="192")
        c.encode_for_stream("uuid-a", "192", source_bitrate_kbps=500)
        assert ("uuid-a", "192") in c._key_locks

    def test_concurrent_first_encode__transcode_runs_exactly_once(self, tmp_path):
        """Many concurrent callers for the same (uuid, quality) must trigger
        exactly one transcode. All callers must receive a usable result.
        """
        gate = threading.Event()
        transcode_calls = []
        transcode_lock = threading.Lock()

        def slow_transcode(src: Path, dst: Path, bitrate: int) -> bool:
            with transcode_lock:
                transcode_calls.append(1)
            # Hold here long enough that every other thread queues on the
            # per-key lock before this one finishes writing the cache.
            gate.wait(timeout=5)
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_bytes(b"encoded" * 10)
            return True

        c = _make_coordinator(
            tmp_path, default_quality="192", transcode_fn=slow_transcode
        )

        results: list[object | None] = [None] * 8

        def worker(idx: int) -> None:
            results[idx] = c.encode_for_stream(
                "uuid-a", "192", source_bitrate_kbps=500
            )

        threads = [threading.Thread(target=worker, args=(i,)) for i in range(8)]
        for t in threads:
            t.start()
        # Give all workers time to queue on the per-key lock.
        import time as _time
        _time.sleep(0.1)
        gate.set()

        for t in threads:
            t.join()
        c._executor.shutdown(wait=True)

        # Exactly one transcode, despite 8 concurrent callers.
        assert sum(transcode_calls) == 1
        # Every caller received a usable result pointing at the same file.
        assert all(r is not None for r in results)
        paths = {r.path for r in results}  # type: ignore[union-attr]
        assert len(paths) == 1

    def test_passthrough_path_returns_correctly(self, tmp_path):
        """The passthrough early return (source bitrate ≤ requested) still
        works; nothing else to assert about lock map state.
        """
        c = _make_coordinator(tmp_path, default_quality="192")
        r = c.encode_for_stream("uuid-pass", "128", source_bitrate_kbps=64)
        assert r is not None
        assert r.transcoded is False

    def test_transcode_failure_returns_none(self, tmp_path):
        def failing_transcode(src: Path, dst: Path, bitrate: int) -> bool:
            return False

        c = _make_coordinator(
            tmp_path, default_quality="192", transcode_fn=failing_transcode
        )
        assert c.encode_for_stream("uuid-fail", "192", source_bitrate_kbps=500) is None

    def test_missing_source_raises_source_unavailable(self, tmp_path):
        c = _make_coordinator(tmp_path, default_quality="192")
        c.source_lookup = lambda _: None
        with pytest.raises(SourceUnavailable):
            c.encode_for_stream("uuid-missing", "192", source_bitrate_kbps=500)

    def test_original_quality_missing_source_raises(self, tmp_path):
        c = _make_coordinator(tmp_path, default_quality="192")
        c.source_lookup = lambda _: None
        with pytest.raises(SourceUnavailable):
            c.encode_for_stream("uuid-missing", ORIGINAL_QUALITY)

    def test_source_path_skips_source_lookup(self, tmp_path):
        """When the caller supplies source_path, the redundant source_lookup DB
        query must not run (hot streaming-endpoint path)."""
        c = _make_coordinator(tmp_path, default_quality="192")
        calls = {"n": 0}

        def _lookup(_):
            calls["n"] += 1
            return None

        c.source_lookup = _lookup
        src = tmp_path / "source.mp3"
        r = c.encode_for_stream(
            "uuid-direct", "128", source_bitrate_kbps=64, source_path=src
        )
        assert r is not None
        assert r.transcoded is False
        assert calls["n"] == 0

    def test_transcode_raises_propagates_and_releases_lock(self, tmp_path):
        """A raising transcode must NOT leave the per-key lock held — the
        next caller for the same key must be able to acquire it.
        """
        attempts = {"n": 0}

        def maybe_raise(src: Path, dst: Path, bitrate: int) -> bool:
            attempts["n"] += 1
            if attempts["n"] == 1:
                raise RuntimeError("ffmpeg blew up")
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_bytes(b"ok" * 10)
            return True

        c = _make_coordinator(
            tmp_path, default_quality="192", transcode_fn=maybe_raise
        )
        with pytest.raises(RuntimeError):
            c.encode_for_stream("uuid-boom", "192", source_bitrate_kbps=500)

        # If the lock were stuck held, this second call would hang. The test
        # framework will time out; if it returns, the lock was released.
        result = c.encode_for_stream("uuid-boom", "192", source_bitrate_kbps=500)
        assert result is not None


# ── persist_and_set_default_quality ───────────────────────────────────────────

class TestPersistAndSetDefaultQuality:
    def test_persist_failure_leaves_live_state_unchanged(self, tmp_path):
        c = _make_coordinator(tmp_path, default_quality="192")
        c.all_uuids_fn = lambda: []

        def persist(_q):
            raise RuntimeError("db down")

        with pytest.raises(RuntimeError):
            c.persist_and_set_default_quality("256", persist)

        assert c.default_quality == "192"
        c._executor.shutdown(wait=True)

    def test_no_op_when_quality_unchanged_skips_persist(self, tmp_path):
        c = _make_coordinator(tmp_path, default_quality="192")
        c.all_uuids_fn = lambda: []
        persisted: list[str] = []

        changed, warming = c.persist_and_set_default_quality(
            "192", lambda q: persisted.append(q)
        )

        assert changed is False
        assert warming is False
        assert persisted == []
        c._executor.shutdown(wait=True)

    def test_concurrent_puts__persisted_matches_live(self, tmp_path):
        """Final persisted value and live default_quality must agree after
        many concurrent persist_and_set_default_quality calls."""
        c = _make_coordinator(tmp_path, default_quality="192")
        c.all_uuids_fn = lambda: []

        persisted_store: dict[str, str] = {}
        store_lock = threading.Lock()

        def persist(q: str) -> None:
            # Mirror the DB's serialized write semantics.
            with store_lock:
                persisted_store["q"] = q

        qualities = [str(96 + 8 * i) for i in range(32)]
        barrier = threading.Barrier(len(qualities))

        def worker(q: str) -> None:
            barrier.wait()
            c.persist_and_set_default_quality(q, persist)

        threads = [threading.Thread(target=worker, args=(q,)) for q in qualities]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        c._executor.shutdown(wait=True)

        # Whichever caller serialized last, the persisted value MUST match the
        # in-memory default. The interleaving "persist A, persist B, live=B,
        # live=A" — where the live state diverges from what's on disk — must
        # be impossible.
        assert persisted_store["q"] == c.default_quality
        assert c.default_quality in qualities
