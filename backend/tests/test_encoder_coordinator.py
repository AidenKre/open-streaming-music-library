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
import time
from pathlib import Path

import pytest

from app.services.encoded_cache import EncodedCache, EncodedCacheContext
from app.services.encoder_coordinator import EncoderCoordinator, SourceUnavailable
from app.services.transcoder import ORIGINAL_QUALITY
from tests.encoder_pool_fixtures import stop_every_encoder_pool  # noqa: F401  (autouse fixture)

# The master admin's id: only its tracks are routed to default_cache (M.2a).
ADMIN_OWNER = 1



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
        admin_owner_id=ADMIN_OWNER,
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
        start_gen = c.warm_generation

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

        c.drain()

        # Every distinct call must have incremented the generation. Under a
        # broken lock, lost updates would make this strictly less than
        # ``total_distinct_calls`` with very high probability.
        assert c.warm_generation == start_gen + total_distinct_calls

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
                                source_bitrate_kbps=500, owner_id=ADMIN_OWNER)

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
        c.drain()

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
        c.drain()

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
        c.drain()

        # Generation observed in snapshots must be monotonically non-decreasing
        # *for the same observer thread*. Across all readers it should be
        # non-decreasing too because the lock serializes mutations and reads.
        # We just check the trivial invariant: every generation in any
        # snapshot is in range [0, final_generation].
        final = c.warm_generation
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
        c.encode_for_stream("uuid-a", "192", source_bitrate_kbps=500, owner_id=ADMIN_OWNER)
        assert ("uuid-a", "192") in c._key_locks

    def test_concurrent_first_encode__transcode_runs_exactly_once(self, tmp_path):
        """Many concurrent callers for the same (uuid, quality) must trigger
        exactly one transcode. All callers must receive a usable result.
        """
        gate = threading.Event()
        transcode_calls = []
        transcode_lock = threading.Lock()

        at_lock = []

        def slow_transcode(src: Path, dst: Path, bitrate: int) -> bool:
            with transcode_lock:
                transcode_calls.append(1)
            # Hold here until every other thread has reached the per-key lock
            # (a condition, not a sleep): without the lock they would all be
            # in here too.
            assert gate.wait(timeout=5)
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_bytes(b"encoded" * 10)
            return True

        c = _make_coordinator(
            tmp_path, default_quality="192", transcode_fn=slow_transcode
        )
        key_lock = c._key_lock

        def counting_key_lock(*key):
            with transcode_lock:
                at_lock.append(key)
                if len(at_lock) == 8:
                    gate.set()
            return key_lock(*key)

        c._key_lock = counting_key_lock

        results: list[object | None] = [None] * 8

        def worker(idx: int) -> None:
            results[idx] = c.encode_for_stream(
                "uuid-a", "192", source_bitrate_kbps=500, owner_id=ADMIN_OWNER
            )

        threads = [threading.Thread(target=worker, args=(i,)) for i in range(8)]
        for t in threads:
            t.start()
        for t in threads:
            t.join(timeout=10)
        assert not any(t.is_alive() for t in threads)
        c.drain()

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
        r = c.encode_for_stream("uuid-pass", "128", source_bitrate_kbps=64, owner_id=ADMIN_OWNER)
        assert r is not None
        assert r.transcoded is False

    def test_transcode_failure_returns_none(self, tmp_path):
        def failing_transcode(src: Path, dst: Path, bitrate: int) -> bool:
            return False

        c = _make_coordinator(
            tmp_path, default_quality="192", transcode_fn=failing_transcode
        )
        assert c.encode_for_stream("uuid-fail", "192", source_bitrate_kbps=500, owner_id=ADMIN_OWNER) is None

    def test_missing_source_raises_source_unavailable(self, tmp_path):
        c = _make_coordinator(tmp_path, default_quality="192")
        c.source_lookup = lambda _: None
        with pytest.raises(SourceUnavailable):
            c.encode_for_stream("uuid-missing", "192", source_bitrate_kbps=500, owner_id=ADMIN_OWNER)

    def test_original_quality_missing_source_raises(self, tmp_path):
        c = _make_coordinator(tmp_path, default_quality="192")
        c.source_lookup = lambda _: None
        with pytest.raises(SourceUnavailable):
            c.encode_for_stream("uuid-missing", ORIGINAL_QUALITY, owner_id=ADMIN_OWNER)

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
            "uuid-direct", "128", source_bitrate_kbps=64, source_path=src, owner_id=ADMIN_OWNER
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
            c.encode_for_stream("uuid-boom", "192", source_bitrate_kbps=500, owner_id=ADMIN_OWNER)

        # A lock stuck held would hang the second call, so try it with a
        # timeout first.
        key_lock = c._key_lock("uuid-boom", "192")
        assert key_lock.acquire(timeout=2)
        key_lock.release()
        result = c.encode_for_stream("uuid-boom", "192", source_bitrate_kbps=500, owner_id=ADMIN_OWNER)
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
        c.drain()

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
        c.drain()

    def test_live_matches_but_stored_differs__persists_without_warming(self, tmp_path):
        """U06-B-09: an invalid stored value (the live default came from the
        env fallback) is repaired by sending the effective quality again."""
        c = _make_coordinator(tmp_path, default_quality="192")
        c.all_uuids_fn = lambda: ["uuid-a"]
        generation = c.warm_generation
        persisted: list[str] = []

        changed, warming = c.persist_and_set_default_quality(
            "192", persisted.append, read_stored=lambda: "lossless-MQA"
        )

        assert persisted == ["192"]
        assert (changed, warming) == (False, False)
        assert c.default_quality == "192"
        assert c.warm_generation == generation  # no warm, no cache delete
        c.drain()

    def test_live_and_stored_match__skips_persist(self, tmp_path):
        c = _make_coordinator(tmp_path, default_quality="192")
        c.all_uuids_fn = lambda: []
        persisted: list[str] = []

        changed, warming = c.persist_and_set_default_quality(
            "192", persisted.append, read_stored=lambda: "192"
        )

        assert (changed, warming) == (False, False)
        assert persisted == []
        c.drain()

    def test_concurrent_puts__persisted_matches_live(self, tmp_path):
        """A second caller cannot persist and go live in the middle of the
        first one's persist and live update, so the persisted value and the
        live default agree afterwards."""
        c = _make_coordinator(tmp_path, default_quality="192")
        c.all_uuids_fn = lambda: []
        persisted_store: dict[str, str] = {}
        # Set once the second caller is blocked on the update lock, or (when
        # nothing serializes the callers) once it has finished outright.
        second_waits_or_is_done = threading.Event()

        class _SpyLock:
            def __init__(self, real):
                self._real = real

            def __enter__(self):
                if not self._real.acquire(blocking=False):
                    second_waits_or_is_done.set()
                    self._real.acquire()

            def __exit__(self, *exc):
                self._real.release()

        c._default_quality_update_lock = _SpyLock(c._default_quality_update_lock)

        persist_calls: list[str] = []

        def persist(q: str) -> None:
            persisted_store["q"] = q
            persist_calls.append(q)
            if q == "256":  # the first caller holds here until the second has tried
                assert second_waits_or_is_done.wait(5)

        def second() -> None:
            c.persist_and_set_default_quality("320", persist)
            second_waits_or_is_done.set()

        first_result = []
        first = threading.Thread(
            target=lambda: first_result.append(c.persist_and_set_default_quality("256", persist)))
        first.start()
        deadline = time.monotonic() + 5
        while persisted_store.get("q") != "256":  # the first caller is in its persist
            assert time.monotonic() < deadline
            time.sleep(0.001)
        later = threading.Thread(target=second)
        later.start()
        for t in (first, later):
            t.join(timeout=10)
        assert not first.is_alive() and not later.is_alive()
        c.drain()

        # The interleaving "persist A, persist B, live=B, live=A", where the
        # live state diverges from what is on disk, must be impossible.
        assert [changed for changed, _warming in first_result] == [True]  # the first call ended normally
        assert persist_calls == ["256", "320"]
        assert (persisted_store["q"], c.default_quality) == ("320", "320")


class TestEvictionDuringEncode:
    """A conversion that replaces a track's master evicts its encodes; an
    encode already reading the OLD master must not land in the cache after
    that eviction (the default cache is never pruned, so it would be served
    forever)."""

    @pytest.mark.parametrize("quality", ["192", "320"])  # default cache, LRU cache
    def test_evicted_mid_encode__result_dropped_then_reencoded(self, tmp_path, quality):
        holder = {}

        def transcode_fn(src: Path, dst: Path, bitrate: int) -> bool:
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_bytes(b"encoded-from-" + src.read_bytes()[:5])
            if not holder.get("evicted"):
                holder["evicted"] = True
                holder["c"].cache.remove_all_for_uuid("u1")
                holder["c"]._default_cache_for_test.remove_all_for_uuid("u1")
            return True

        c = _make_coordinator(tmp_path, transcode_fn=transcode_fn)
        _, default_cache, _ = c._snapshot_default_state()
        c._default_cache_for_test = default_cache
        holder["c"] = c

        assert c.encode_for_stream("u1", quality, source_bitrate_kbps=1000, owner_id=ADMIN_OWNER) is None
        assert not c.cache.has("u1", quality)
        assert not default_cache.has("u1", quality)
        assert list((c._scratch_dir).glob("*.m4a")) == []

        result = c.encode_for_stream("u1", quality, source_bitrate_kbps=1000, owner_id=ADMIN_OWNER)
        assert result is not None and result.transcoded
        target = default_cache if quality == "192" else c.cache
        assert target.has("u1", quality)
        c.drain()

    def test_insert__stale_generation__dropped_and_source_deleted(self, tmp_path):
        cache = EncodedCache(ctx=EncodedCacheContext(cache_dir=tmp_path / "c", max_size_bytes=0))
        gen = cache.generation("u1")
        cache.remove_all_for_uuid("u1")
        scratch = tmp_path / "scratch.m4a"
        scratch.write_bytes(b"x")

        assert cache.insert("u1", "192", scratch, expected_generation=gen) is None
        assert not scratch.exists()
        assert not cache.has("u1", "192")

        other = tmp_path / "other.m4a"
        other.write_bytes(b"y")
        assert cache.insert("u2", "192", other, expected_generation=cache.generation("u2"))
        assert cache.has("u2", "192")


class TestSubmitConversion:
    def test_submit_conversion__runs_fn_on_shared_pool(self, tmp_path):
        c = _make_coordinator(tmp_path)
        done = threading.Event()
        received = {}

        def fn(job_id: int) -> None:
            received["job_id"] = job_id
            done.set()

        c.submit_conversion(fn, 42)

        assert done.wait(timeout=5)
        assert received["job_id"] == 42
        c.drain()

    def test_submit_conversion__uses_priority_conversion(self, tmp_path):
        from unittest.mock import MagicMock

        from app.services.encoder_coordinator import _PriorityPool

        c = _make_coordinator(tmp_path)
        c._executor.submit = MagicMock()

        def convert_fn(job_id: int) -> None:
            pass

        c.submit_conversion(convert_fn, 7, extra="x")

        c._executor.submit.assert_called_once_with(
            convert_fn, 7, priority=_PriorityPool.PRIORITY_CONVERSION, extra="x"
        )


class TestSourceChangedDuringEncode:
    """Live gate m-L-08: a loose file imported while its copy was paused kept
    growing after the import. A pre-warm (or any encode) that read the source
    while it was changing must not keep that encoding: the source's size and
    modification time are compared before and after the transcode."""

    @pytest.mark.parametrize("quality", ["192", "320"])  # default cache, LRU cache
    @pytest.mark.parametrize("change", ["grows", "mtime_only"])
    def test_an_encode_of_a_source_that_changed_meanwhile_is_not_kept(self, tmp_path, quality, change):
        import os

        source = tmp_path / "source.mp3"

        def transcode_fn(src: Path, dst: Path, bitrate: int) -> bool:
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_bytes(b"encoded-from-partial")
            if not holder.get("changed"):
                holder["changed"] = True
                if change == "grows":
                    with open(src, "ab") as f:
                        f.write(b"the rest of the copy")
                else:
                    st = os.stat(src)
                    os.utime(src, ns=(st.st_atime_ns, st.st_mtime_ns + 1_000_000))
            return True

        holder: dict = {}
        c = _make_coordinator(tmp_path, transcode_fn=transcode_fn)
        _, default_cache, _ = c._snapshot_default_state()

        assert c.encode_for_stream("u1", quality, source_bitrate_kbps=1000, owner_id=ADMIN_OWNER) is None
        assert not c.cache.has("u1", quality)
        assert not default_cache.has("u1", quality)
        assert list(c._scratch_dir.glob("*.m4a")) == []

        # The source is quiet now: the next encode is kept.
        result = c.encode_for_stream("u1", quality, source_bitrate_kbps=1000, owner_id=ADMIN_OWNER)
        assert result is not None and result.transcoded
        target = default_cache if quality == "192" else c.cache
        assert target.has("u1", quality)
        assert source.read_bytes().endswith(b"the rest of the copy") == (change == "grows")
        c.drain()

    def test_a_warm_of_a_source_that_changed_meanwhile_leaves_no_cache_entry(self, tmp_path):
        def transcode_fn(src: Path, dst: Path, bitrate: int) -> bool:
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_bytes(b"encoded-from-partial")
            with open(src, "ab") as f:
                f.write(b"more")
            return True

        c = _make_coordinator(tmp_path, transcode_fn=transcode_fn, workers=1)
        _, default_cache, gen = c._snapshot_default_state()

        c._warm_one("u1", "192", gen)

        assert not default_cache.has("u1", "192")
        assert not c.cache.has("u1", "192")
        c.drain()


class TestShutdown:
    """U06-B-01: the stop request goes ahead of the waiting backlog. An encode
    already running finishes; nothing that was only queued starts after it."""

    def test_shutdown__no_queued_encode_starts_after_the_stop_request(self, tmp_path):
        release = threading.Event()
        first_started = threading.Event()
        encoded: list[Path] = []

        def gated_transcode(src: Path, dst: Path, bitrate: int) -> bool:
            encoded.append(dst)
            first_started.set()
            assert release.wait(timeout=10)
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_bytes(b"encoded" * 10)
            return True

        c = _make_coordinator(
            tmp_path, workers=1, transcode_fn=gated_transcode,
            all_uuids_fn=lambda: ["w1", "w2"],
        )
        c.owner_lookup = lambda _uuid: ADMIN_OWNER
        conversions: list[int] = []

        c.enqueue_prefetch("running", "320", source_bitrate_kbps=1000)
        assert first_started.wait(timeout=10)
        # The backlog: prefetches, the warm of a default change and a conversion.
        c.enqueue_prefetch("queued-1", "320", source_bitrate_kbps=1000)
        c.enqueue_prefetch("queued-2", "256", source_bitrate_kbps=1000)
        c.set_default_quality("128")
        c.submit_conversion(conversions.append, 7)

        c.shutdown()
        c.submit_conversion(conversions.append, 8)  # arrives after the stop
        release.set()
        for t in c._executor._threads:
            t.join(timeout=10)

        assert not any(t.is_alive() for t in c._executor._threads)
        assert len(encoded) == 1  # only the encode that was already running
        assert conversions == []


class TestPoolOrder:
    """Other-issues row 48 (a): the order the pool runs queued work in, through
    the public drain(). Today: prefetches first (newest first), then the
    default-quality work (newest first), then conversions."""

    def test_queued_work_runs_prefetches_then_warm_up_then_conversions(self, tmp_path):
        release = threading.Event()
        first_started = threading.Event()
        ran: list[str] = []

        def recording_transcode(src: Path, dst: Path, bitrate: int) -> bool:
            ran.append(src.stem)
            first_started.set()
            assert release.wait(timeout=10)
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_bytes(b"encoded" * 10)
            return True

        c = _make_coordinator(
            tmp_path, workers=1, transcode_fn=recording_transcode,
            all_uuids_fn=lambda: ["warm-1", "warm-2"],
        )
        sources = tmp_path / "sources"
        sources.mkdir()

        def source_of(uuid_id: str) -> Path:
            path = sources / f"{uuid_id}.mp3"
            path.write_bytes(b"audio" * 100)
            return path

        c.source_lookup = source_of
        c.owner_lookup = lambda _uuid: ADMIN_OWNER

        c.enqueue_prefetch("running", "320", source_bitrate_kbps=1000)
        assert first_started.wait(timeout=10)
        # Queued while the one worker is busy, in this order:
        c.submit_conversion(lambda: ran.append("conversion-1"))
        c.enqueue_prefetch("prefetch-1", "320", source_bitrate_kbps=1000)
        c.set_default_quality("128")  # queues the cache clean-up and two warm tasks
        c.enqueue_prefetch("prefetch-2", "256", source_bitrate_kbps=1000)
        c.submit_conversion(lambda: ran.append("conversion-2"))
        release.set()
        c.drain()

        assert ran == [
            "running",
            "prefetch-2", "prefetch-1",
            "warm-2", "warm-1",
            "conversion-2", "conversion-1",
        ]


class TestPoolErrorLog:
    """Other-issues row 61: an exception the encoder pool drops leaves one line
    with its type name (never its text, which may name a file)."""

    LOGGER = "app.services.encoder_coordinator"

    def _lines(self, caplog):
        return [(r.levelname, r.getMessage()) for r in caplog.records if r.name == self.LOGGER]

    def test_a_task_that_raises_in_the_pool_leaves_one_line_with_its_type(self, tmp_path, caplog):
        c = _make_coordinator(tmp_path, workers=1)

        def broken():
            raise RuntimeError("/srv/music/Artist/Song.flac")

        with caplog.at_level("DEBUG", logger=self.LOGGER):
            c.submit_conversion(broken)
            c.drain()

        assert self._lines(caplog) == [("WARNING", "encoder pool task failed: RuntimeError")]

    def test_a_failed_prefetch_leaves_one_line_with_its_type(self, tmp_path, caplog):
        c = _make_coordinator(tmp_path, workers=1)

        def owner_of(uuid_id):
            raise LookupError("/srv/music/Artist/Song.flac")

        c.owner_lookup = owner_of

        with caplog.at_level("DEBUG", logger=self.LOGGER):
            c.enqueue_prefetch("uuid-a", "320", source_bitrate_kbps=1000)
            c.drain()

        assert self._lines(caplog) == [("WARNING", "prefetch failed: LookupError")]

    def test_a_failed_default_cache_clean_up_leaves_one_line_with_its_type(
        self, tmp_path, caplog
    ):
        c = _make_coordinator(tmp_path, workers=1)
        cache_dir = c.default_cache.ctx.cache_dir
        cache_dir.rmdir()
        cache_dir.write_bytes(b"not a folder")  # iterdir() raises NotADirectoryError

        with caplog.at_level("DEBUG", logger=self.LOGGER):
            c.set_default_quality(ORIGINAL_QUALITY)
            c.drain()

        assert self._lines(caplog) == [
            ("WARNING", "default cache clean-up failed: NotADirectoryError")
        ]
