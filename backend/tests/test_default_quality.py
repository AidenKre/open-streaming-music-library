"""Tests for default streaming quality persistence and two-tier cache."""

import importlib
import sys
import time
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app.models import Track, TrackMetaData
from app.services.encoded_cache import EncodedCache, EncodedCacheContext
from app.services.encoder_coordinator import EncoderCoordinator
from app.services.transcoder import ORIGINAL_QUALITY


# ── Fixtures ──────────────────────────────────────────────────────────────────

@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("APP_DATA_DIR", str(tmp_path / "data"))
    monkeypatch.setenv("MUSIC_LIBRARY_DIR", str(tmp_path / "music"))
    monkeypatch.setenv("IMPORT_DIR", str(tmp_path / "import"))
    monkeypatch.setenv("ENABLE_FILE_WATCHER", "false")

    sys.modules.pop("app.main", None)
    sys.modules.pop("app.config", None)
    import app.main
    importlib.reload(app.main)

    with TestClient(app.main.app) as c:
        yield c


def _add_track(client, tmp_path: Path, name: str = "track.mp3") -> Track:
    track_path = tmp_path / name
    track_path.write_bytes(b"audio-source" * 100)
    metadata = TrackMetaData(title=name, duration=1.0, codec="mp3", bitrate_kbps=320.0)
    track = Track(file_path=track_path, metadata=metadata)
    assert client.app.state.database.add_track(track=track)
    return track


def _install_fake_coordinator(client, payload=b"encoded" * 10):
    """Replace coordinator with a fast fake transcoder."""
    cache_dir = Path(client.app.state.encoded_cache.ctx.cache_dir)
    default_cache_dir = Path(client.app.state.default_cache.ctx.cache_dir)
    new_stream_cache = EncodedCache(
        ctx=EncodedCacheContext(cache_dir=cache_dir, max_size_bytes=10 * 1024 * 1024)
    )
    new_default_cache = EncodedCache(
        ctx=EncodedCacheContext(cache_dir=default_cache_dir, max_size_bytes=0)
    )

    def fake_transcode(src: Path, dst: Path, bitrate: int) -> bool:
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_bytes(payload)
        return True

    database = client.app.state.database
    coordinator = EncoderCoordinator(
        cache=new_stream_cache,
        source_lookup=client.app.state.encoder_coordinator.source_lookup,
        workers=2,
        transcode_fn=fake_transcode,
        default_cache=new_default_cache,
        default_quality=client.app.state.encoder_coordinator.default_quality,
        all_uuids_fn=lambda: database.get_all_track_uuids(),
    )
    client.app.state.encoded_cache = new_stream_cache
    client.app.state.default_cache = new_default_cache
    client.app.state.encoder_coordinator.shutdown()
    client.app.state.encoder_coordinator = coordinator
    return coordinator


# ── Unit tests: two-tier cache ────────────────────────────────────────────────

class TestTwoTierCache:
    def _make_coordinator(
        self, tmp_path: Path, source: Path, default_quality: str = "192"
    ) -> tuple[EncoderCoordinator, list[int]]:
        stream_cache = EncodedCache(
            ctx=EncodedCacheContext(
                cache_dir=tmp_path / "stream",
                max_size_bytes=10 * 1024 * 1024,
            )
        )
        default_cache = EncodedCache(
            ctx=EncodedCacheContext(
                cache_dir=tmp_path / "default",
                max_size_bytes=0,
            )
        )
        calls: list[int] = []

        def fake_transcode(src: Path, dst: Path, bitrate: int) -> bool:
            calls.append(bitrate)
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_bytes(b"encoded" * 10)
            return True

        coordinator = EncoderCoordinator(
            cache=stream_cache,
            source_lookup=lambda _: source,
            workers=2,
            transcode_fn=fake_transcode,
            default_cache=default_cache,
            default_quality=default_quality,
        )
        return coordinator, calls

    def test_default_quality_writes_to_default_cache(self, tmp_path):
        source = tmp_path / "t.mp3"
        source.write_bytes(b"audio" * 100)
        c, calls = self._make_coordinator(tmp_path, source, default_quality="192")

        result = c.encode_for_stream("uuid-a", "192", source_bitrate_kbps=320)

        assert result is not None
        assert result.transcoded is True
        assert c.default_cache.has("uuid-a", "192")
        assert not c.cache.has("uuid-a", "192")

    def test_non_default_quality_writes_to_stream_cache(self, tmp_path):
        source = tmp_path / "t.mp3"
        source.write_bytes(b"audio" * 100)
        c, _ = self._make_coordinator(tmp_path, source, default_quality="192")

        result = c.encode_for_stream("uuid-a", "320", source_bitrate_kbps=500)

        assert result is not None
        assert c.cache.has("uuid-a", "320")
        assert not c.default_cache.has("uuid-a", "320")

    def test_default_cache_checked_first(self, tmp_path):
        """If default_cache has an entry, stream_cache is not queried."""
        source = tmp_path / "t.mp3"
        source.write_bytes(b"audio" * 100)
        c, calls = self._make_coordinator(tmp_path, source, default_quality="192")

        # Prime default cache.
        c.encode_for_stream("uuid-a", "192", source_bitrate_kbps=320)
        assert calls == [192]

        # Second call should be a cache hit — no additional transcode.
        c.encode_for_stream("uuid-a", "192", source_bitrate_kbps=320)
        assert calls == [192]

    def test_stream_cache_fallback_for_default_quality(self, tmp_path):
        """If default_cache misses but stream_cache hits, return stream result."""
        source = tmp_path / "t.mp3"
        source.write_bytes(b"audio" * 100)
        c, calls = self._make_coordinator(tmp_path, source, default_quality="192")

        # Manually insert into stream cache (simulates a pre-existing entry).
        scratch = tmp_path / "scratch.m4a"
        scratch.write_bytes(b"stream-encoded" * 5)
        c.cache.insert("uuid-a", "192", scratch)

        # Should find it in stream_cache without transcoding.
        result = c.encode_for_stream("uuid-a", "192", source_bitrate_kbps=320)
        assert result is not None
        assert calls == []

    def test_quality_change_deletes_old_default_cache_files(self, tmp_path):
        source = tmp_path / "t.mp3"
        source.write_bytes(b"audio" * 100)
        c, _ = self._make_coordinator(tmp_path, source, default_quality="192")

        # Encode at the old default quality (goes to default_cache).
        c.encode_for_stream("uuid-a", "192", source_bitrate_kbps=320)
        assert c.default_cache.has("uuid-a", "192")
        assert not c.cache.has("uuid-a", "192")

        # Change to a new default quality; deletion runs in background.
        old_default_cache = c.default_cache
        c.set_default_quality("320")
        c._executor.shutdown(wait=True)

        # Old default-quality file should be deleted (not migrated to stream cache).
        assert not old_default_cache.has("uuid-a", "192")
        assert not c.cache.has("uuid-a", "192")

    def test_warm_all_tracks__empty_uuid_list__does_nothing(self, tmp_path):
        """_warm_all_tracks with an empty UUID list must not raise and must not encode."""
        source = tmp_path / "t.mp3"
        source.write_bytes(b"audio" * 100)
        encode_calls: list[str] = []

        def fake_transcode(src: Path, dst: Path, bitrate: int) -> bool:
            encode_calls.append(str(bitrate))
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_bytes(b"encoded" * 10)
            return True

        stream_cache = EncodedCache(
            ctx=EncodedCacheContext(
                cache_dir=tmp_path / "stream",
                max_size_bytes=10 * 1024 * 1024,
            )
        )
        default_cache = EncodedCache(
            ctx=EncodedCacheContext(
                cache_dir=tmp_path / "default",
                max_size_bytes=0,
            )
        )
        c = EncoderCoordinator(
            cache=stream_cache,
            source_lookup=lambda _: source,
            workers=2,
            transcode_fn=fake_transcode,
            default_cache=default_cache,
            default_quality="192",
            all_uuids_fn=lambda: [],  # empty library
        )

        # Should complete without error and without any transcode calls.
        c._submit_warm_tasks("256", c._warm_generation)
        c._executor.shutdown(wait=True)

        assert encode_calls == []

    def test_delete_default_cache_files__deletes_old_quality_only(self, tmp_path):
        """_delete_default_cache_files removes files for old_quality and leaves others."""
        source = tmp_path / "t.mp3"
        source.write_bytes(b"audio" * 100)
        c, _ = self._make_coordinator(tmp_path, source, default_quality="192")

        # Encode at the current default quality (goes to default_cache).
        c.encode_for_stream("uuid-a", "192", source_bitrate_kbps=320)
        assert c.default_cache.has("uuid-a", "192")

        # Manually place a file with a different quality suffix in the same dir
        # to verify _delete_default_cache_files only removes the target quality.
        other_file = c.default_cache.ctx.cache_dir / "uuid-b__q320.m4a"
        other_file.write_bytes(b"encoded" * 10)

        c._delete_default_cache_files(c.default_cache, "192")

        assert not c.default_cache.has("uuid-a", "192")
        assert other_file.exists()

    def test_set_default_quality__same_quality__returns_false_no_warm(self, tmp_path):
        source = tmp_path / "t.mp3"
        source.write_bytes(b"audio" * 100)
        c, calls = self._make_coordinator(tmp_path, source, default_quality="192")

        first = c.set_default_quality("192")  # no-op: already "192"
        assert first is False
        assert calls == []

    def test_set_default_quality__returns_true_when_warming_submitted(self, tmp_path):
        source = tmp_path / "t.mp3"
        source.write_bytes(b"audio" * 100)
        c, _ = self._make_coordinator(tmp_path, source, default_quality="192")
        c.all_uuids_fn = lambda: ["uuid-a"]

        result = c.set_default_quality("256")
        c._executor.shutdown(wait=True)

        assert result is True

    def test_set_default_quality__returns_false_for_original_quality(self, tmp_path):
        source = tmp_path / "t.mp3"
        source.write_bytes(b"audio" * 100)
        c, _ = self._make_coordinator(tmp_path, source, default_quality="192")

        result = c.set_default_quality(ORIGINAL_QUALITY)
        c._executor.shutdown(wait=True)

        assert result is False

    def test_parallel_warming__all_uuids_encoded_with_multiple_workers(self, tmp_path):
        source = tmp_path / "t.mp3"
        source.write_bytes(b"audio" * 100)
        uuids = [f"uuid-{i}" for i in range(10)]

        stream_cache = EncodedCache(
            ctx=EncodedCacheContext(cache_dir=tmp_path / "stream", max_size_bytes=10 * 1024 * 1024)
        )
        default_cache = EncodedCache(
            ctx=EncodedCacheContext(cache_dir=tmp_path / "default", max_size_bytes=0)
        )

        def fake_transcode(src: Path, dst: Path, bitrate: int) -> bool:
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_bytes(b"encoded" * 10)
            return True

        c = EncoderCoordinator(
            cache=stream_cache,
            source_lookup=lambda _: source,
            workers=4,
            transcode_fn=fake_transcode,
            default_cache=default_cache,
            default_quality="original",
            all_uuids_fn=lambda: uuids,
        )

        c.set_default_quality("192")
        c._executor.shutdown(wait=True)

        assert all(default_cache.has(uid, "192") for uid in uuids)

    def test_generation_counter__stale_warm_tasks_skipped(self, tmp_path):
        """Tasks queued for old quality bail out after quality changes."""
        import threading as _threading
        source = tmp_path / "t.mp3"
        source.write_bytes(b"audio" * 100)
        uuids = [f"uuid-{i}" for i in range(10)]
        gate = _threading.Event()

        stream_cache = EncodedCache(
            ctx=EncodedCacheContext(cache_dir=tmp_path / "stream", max_size_bytes=10 * 1024 * 1024)
        )
        default_cache = EncodedCache(
            ctx=EncodedCacheContext(cache_dir=tmp_path / "default", max_size_bytes=0)
        )

        def fake_transcode(src: Path, dst: Path, bitrate: int) -> bool:
            gate.wait()  # block until both quality changes have been submitted
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_bytes(b"encoded" * 10)
            return True

        c = EncoderCoordinator(
            cache=stream_cache,
            source_lookup=lambda _: source,
            workers=2,
            transcode_fn=fake_transcode,
            default_cache=default_cache,
            default_quality="original",
            all_uuids_fn=lambda: uuids,
        )

        c.set_default_quality("128")   # generation=1, queues 10 tasks
        c.set_default_quality("256")   # generation=2, queues 10 more tasks
        gate.set()                     # let all tasks proceed
        c._executor.shutdown(wait=True)

        # "128" tasks bail (generation mismatch) or write to stream_cache (not default_cache)
        assert not any(default_cache.has(uid, "128") for uid in uuids)
        # "256" tasks complete and land in default_cache
        assert all(default_cache.has(uid, "256") for uid in uuids)

    def test_startup__cleans_orphaned_scratch_files(self, tmp_path):
        source = tmp_path / "t.mp3"
        source.write_bytes(b"audio" * 100)

        stream_cache = EncodedCache(
            ctx=EncodedCacheContext(cache_dir=tmp_path / "stream", max_size_bytes=10 * 1024 * 1024)
        )
        default_cache = EncodedCache(
            ctx=EncodedCacheContext(cache_dir=tmp_path / "default", max_size_bytes=0)
        )
        c = EncoderCoordinator(
            cache=stream_cache,
            source_lookup=lambda _: source,
            workers=1,
            default_cache=default_cache,
            default_quality=ORIGINAL_QUALITY,
        )

        # Plant orphaned scratch files
        c._scratch_dir.mkdir(parents=True, exist_ok=True)
        (c._scratch_dir / "orphan1.m4a").write_bytes(b"partial")
        (c._scratch_dir / "orphan2.m4a").write_bytes(b"partial")

        c.startup()
        c._executor.shutdown(wait=True)

        remaining = list(c._scratch_dir.iterdir())
        assert remaining == []

    def test_startup__resumes_only_missing_tracks(self, tmp_path):
        source = tmp_path / "t.mp3"
        source.write_bytes(b"audio" * 100)
        uuids = ["uuid-0", "uuid-1", "uuid-2"]
        encoded_uuids: list[str] = []

        stream_cache = EncodedCache(
            ctx=EncodedCacheContext(cache_dir=tmp_path / "stream", max_size_bytes=10 * 1024 * 1024)
        )
        default_cache = EncodedCache(
            ctx=EncodedCacheContext(cache_dir=tmp_path / "default", max_size_bytes=0)
        )

        def fake_transcode(src: Path, dst: Path, bitrate: int) -> bool:
            # Figure out which uuid by reading its presence in encode_for_stream
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_bytes(b"encoded" * 10)
            return True

        c = EncoderCoordinator(
            cache=stream_cache,
            source_lookup=lambda _: source,
            workers=2,
            transcode_fn=fake_transcode,
            default_cache=default_cache,
            default_quality="192",
            all_uuids_fn=lambda: uuids,
        )

        # Pre-warm uuid-0 so it's already in default_cache
        c.encode_for_stream("uuid-0", "192", source_bitrate_kbps=320)
        assert default_cache.has("uuid-0", "192")

        # Track encodes via side-channel: count cache insertions after startup
        calls_before = sum(1 for uid in uuids if default_cache.has(uid, "192"))

        c.startup()
        c._executor.shutdown(wait=True)

        now_cached = [uid for uid in uuids if default_cache.has(uid, "192")]
        assert len(now_cached) == 3  # all three cached after startup
        # uuid-0 was pre-cached; only uuid-1 and uuid-2 should have been encoded by startup
        new_encodes = len(now_cached) - calls_before
        assert new_encodes == 2

    def test_startup__no_op_when_all_cached(self, tmp_path):
        source = tmp_path / "t.mp3"
        source.write_bytes(b"audio" * 100)
        uuids = ["uuid-0", "uuid-1"]
        encode_calls: list[int] = []

        stream_cache = EncodedCache(
            ctx=EncodedCacheContext(cache_dir=tmp_path / "stream", max_size_bytes=10 * 1024 * 1024)
        )
        default_cache = EncodedCache(
            ctx=EncodedCacheContext(cache_dir=tmp_path / "default", max_size_bytes=0)
        )

        def fake_transcode(src: Path, dst: Path, bitrate: int) -> bool:
            encode_calls.append(bitrate)
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_bytes(b"encoded" * 10)
            return True

        c = EncoderCoordinator(
            cache=stream_cache,
            source_lookup=lambda _: source,
            workers=2,
            transcode_fn=fake_transcode,
            default_cache=default_cache,
            default_quality="192",
            all_uuids_fn=lambda: uuids,
        )

        # Pre-warm all tracks
        for uid in uuids:
            c.encode_for_stream(uid, "192", source_bitrate_kbps=320)
        encode_calls.clear()

        c.startup()
        c._executor.shutdown(wait=True)

        assert encode_calls == []  # nothing re-encoded

    def test_startup__no_op_for_original_quality(self, tmp_path):
        source = tmp_path / "t.mp3"
        source.write_bytes(b"audio" * 100)
        encode_calls: list[int] = []

        stream_cache = EncodedCache(
            ctx=EncodedCacheContext(cache_dir=tmp_path / "stream", max_size_bytes=10 * 1024 * 1024)
        )
        default_cache = EncodedCache(
            ctx=EncodedCacheContext(cache_dir=tmp_path / "default", max_size_bytes=0)
        )

        def fake_transcode(src: Path, dst: Path, bitrate: int) -> bool:
            encode_calls.append(bitrate)
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_bytes(b"encoded" * 10)
            return True

        c = EncoderCoordinator(
            cache=stream_cache,
            source_lookup=lambda _: source,
            workers=2,
            transcode_fn=fake_transcode,
            default_cache=default_cache,
            default_quality=ORIGINAL_QUALITY,
            all_uuids_fn=lambda: ["uuid-a"],
        )

        c.startup()
        c._executor.shutdown(wait=True)

        assert encode_calls == []

    def test_warm_all_tracks_encodes_at_new_default(self, tmp_path):
        source = tmp_path / "t.mp3"
        source.write_bytes(b"audio" * 100)
        uuids_seen: list[str] = []

        def fake_transcode(src: Path, dst: Path, bitrate: int) -> bool:
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_bytes(b"encoded" * 10)
            return True

        stream_cache = EncodedCache(
            ctx=EncodedCacheContext(
                cache_dir=tmp_path / "stream",
                max_size_bytes=10 * 1024 * 1024,
            )
        )
        default_cache = EncodedCache(
            ctx=EncodedCacheContext(
                cache_dir=tmp_path / "default",
                max_size_bytes=0,
            )
        )
        c = EncoderCoordinator(
            cache=stream_cache,
            source_lookup=lambda _: source,
            workers=2,
            transcode_fn=fake_transcode,
            default_cache=default_cache,
            default_quality="192",
            all_uuids_fn=lambda: ["uuid-a", "uuid-b"],
        )

        c.set_default_quality("256")
        c._executor.shutdown(wait=True)

        assert c.default_cache.has("uuid-a", "256")
        assert c.default_cache.has("uuid-b", "256")


# ── API-level tests ───────────────────────────────────────────────────────────

class TestQualitySettingsAPI:
    def test_get_quality__returns_default(self, client):
        r = client.get("/settings/quality")
        assert r.status_code == 200
        assert r.json()["quality"] == "original"

    def test_put_quality__changes_default(self, client, tmp_path):
        _install_fake_coordinator(client)

        r = client.put("/settings/quality", json={"quality": "256"})
        assert r.status_code == 200
        data = r.json()
        assert data["quality"] == "256"
        assert data["warming"] is True

        r2 = client.get("/settings/quality")
        assert r2.json()["quality"] == "256"

    def test_put_quality__persists_to_db(self, client, tmp_path):
        _install_fake_coordinator(client)

        client.put("/settings/quality", json={"quality": "128"})

        stored = client.app.state.database.get_setting("default_streaming_quality")
        assert stored == "128"

    def test_put_quality__invalid_rejected(self, client):
        r = client.put("/settings/quality", json={"quality": "lossless-MQA"})
        assert r.status_code == 422

    def test_put_quality__original_warming_false(self, client):
        r = client.put("/settings/quality", json={"quality": "original"})
        assert r.status_code == 200
        assert r.json()["warming"] is False

    def test_put_quality__quality_change_reflected_immediately(self, client):
        """Setting quality updates the coordinator's default_quality synchronously."""
        _install_fake_coordinator(client)
        assert client.app.state.encoder_coordinator.default_quality == "original"

        client.put("/settings/quality", json={"quality": "320"})

        assert client.app.state.encoder_coordinator.default_quality == "320"

    def test_put_quality__same_quality__warming_false(self, client):
        """Sending the same quality twice returns warming: false on the second call."""
        _install_fake_coordinator(client)

        client.put("/settings/quality", json={"quality": "256"})
        r = client.put("/settings/quality", json={"quality": "256"})

        assert r.status_code == 200
        assert r.json()["warming"] is False

    def test_put_quality__same_quality__no_db_write(self, client):
        """PUT with the current quality must not write to the database."""
        # At startup, no quality has been persisted — get_setting returns None.
        db = client.app.state.database
        assert db.get_setting("default_streaming_quality") is None

        # PUT the same quality that the coordinator already has in memory.
        current = client.app.state.encoder_coordinator.default_quality
        r = client.put("/settings/quality", json={"quality": current})

        assert r.status_code == 200
        assert r.json()["warming"] is False
        # DB must remain untouched.
        assert db.get_setting("default_streaming_quality") is None

    def test_put_quality__db_write_failure__leaves_state_unchanged(self, client):
        """If set_setting raises, the coordinator's default_quality must not
        change and the response must surface an error."""
        _install_fake_coordinator(client)
        coordinator = client.app.state.encoder_coordinator
        db = client.app.state.database
        original_quality = coordinator.default_quality

        def boom(_key, _value):
            raise RuntimeError("simulated db failure")

        original_set = db.set_setting
        db.set_setting = boom
        try:
            r = client.put("/settings/quality", json={"quality": "256"})
        finally:
            db.set_setting = original_set

        assert r.status_code == 500
        assert coordinator.default_quality == original_quality

    def test_put_quality__concurrent_puts__live_matches_persisted(self, client):
        """Concurrent PUTs must leave the persisted setting equal to the
        coordinator's live default_quality (no torn state)."""
        import threading

        _install_fake_coordinator(client)
        db = client.app.state.database
        coordinator = client.app.state.encoder_coordinator
        qualities = ["96", "128", "192", "256", "320"]
        barrier = threading.Barrier(len(qualities))

        def worker(q):
            barrier.wait()
            client.put("/settings/quality", json={"quality": q})

        threads = [threading.Thread(target=worker, args=(q,)) for q in qualities]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        assert db.get_setting("default_streaming_quality") == coordinator.default_quality
        assert coordinator.default_quality in qualities
