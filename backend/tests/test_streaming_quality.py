import importlib
import sys
import threading
import time
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app.models import Track, TrackMetaData
from app.services.encoded_cache import EncodedCache, EncodedCacheContext
from app.services.encoder_coordinator import EncoderCoordinator, EncodeResult


def _fake_transcode_factory(payload_for_quality):
    """Returns a transcode_fn that writes a deterministic byte payload.

    Avoids invoking real ffmpeg in tests so they stay quick + deterministic.
    """

    def fake_transcode(source: Path, dest: Path, bitrate: int) -> bool:
        if not source.exists():
            return False
        dest.parent.mkdir(parents=True, exist_ok=True)
        body = payload_for_quality(bitrate)
        dest.write_bytes(body)
        return True

    return fake_transcode


def _install_fake_coordinator(client, payload_for_quality, max_size_bytes=10 * 1024 * 1024):
    """Replace the app's encoder coordinator with a fake-driven one."""
    cache_dir = Path(client.app.state.encoded_cache.ctx.cache_dir)
    new_cache = EncodedCache(
        ctx=EncodedCacheContext(cache_dir=cache_dir, max_size_bytes=max_size_bytes)
    )
    coordinator = EncoderCoordinator(
        cache=new_cache,
        source_lookup=client.app.state.encoder_coordinator.source_lookup,
        workers=2,
        transcode_fn=_fake_transcode_factory(payload_for_quality),
    )
    client.app.state.encoded_cache = new_cache
    client.app.state.encoder_coordinator.shutdown()
    client.app.state.encoder_coordinator = coordinator
    return coordinator


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


def _add_track_with_file(
    client,
    tmp_path: Path,
    name: str = "track.mp3",
    bitrate_kbps: float = 0.0,
    codec: str = "mp3",
):
    track_path = tmp_path / name
    track_path.write_bytes(b"original-source-bytes" * 100)
    metadata = TrackMetaData(title=name, duration=1.0, codec=codec, bitrate_kbps=bitrate_kbps)
    track = Track(file_path=track_path, metadata=metadata)
    assert client.app.state.database.add_track(track=track)
    return track


class TestStreamQuality:
    def test_stream__no_quality__returns_original(self, client, tmp_path):
        track = _add_track_with_file(client, tmp_path)
        original_bytes = track.file_path.read_bytes()

        # Use a fake transcoder so a programming error would still let us catch
        # accidental transcoding (its bytes would differ).
        _install_fake_coordinator(
            client, payload_for_quality=lambda br: b"FAKE-ENCODED" * 10
        )

        with client.stream("GET", f"/tracks/{track.uuid_id}/stream") as resp:
            assert resp.status_code == 200, resp.text
            body = b"".join(resp.iter_bytes())

        assert body == original_bytes

    def test_stream__original_quality__returns_original(self, client, tmp_path):
        track = _add_track_with_file(client, tmp_path)
        original_bytes = track.file_path.read_bytes()
        _install_fake_coordinator(
            client, payload_for_quality=lambda br: b"FAKE-ENCODED" * 10
        )

        with client.stream(
            "GET", f"/tracks/{track.uuid_id}/stream?quality=original"
        ) as resp:
            assert resp.status_code == 200, resp.text
            body = b"".join(resp.iter_bytes())

        assert body == original_bytes

    @pytest.mark.parametrize("quality,expected_bitrate", [
        ("320", 320),
        ("256", 256),
        ("192", 192),
        ("128", 128),
    ])
    def test_stream__quality_preset__transcodes(
        self, client, tmp_path, quality, expected_bitrate
    ):
        track = _add_track_with_file(client, tmp_path)
        seen_bitrates: list[int] = []

        def payload(bitrate: int) -> bytes:
            seen_bitrates.append(bitrate)
            return f"BR={bitrate}-".encode("utf-8") * 50

        _install_fake_coordinator(client, payload_for_quality=payload)

        with client.stream(
            "GET", f"/tracks/{track.uuid_id}/stream?quality={quality}"
        ) as resp:
            assert resp.status_code == 200, resp.text
            assert resp.headers["content-type"].startswith("audio/mp4")
            body = b"".join(resp.iter_bytes())

        assert seen_bitrates == [expected_bitrate]
        assert f"BR={expected_bitrate}-".encode("utf-8") in body

    def test_stream__transcoded__returns_bitrate_and_extension_headers(
        self, client, tmp_path
    ):
        track = _add_track_with_file(client, tmp_path)
        _install_fake_coordinator(
            client, payload_for_quality=lambda br: b"FAKE" * 20
        )

        with client.stream(
            "GET", f"/tracks/{track.uuid_id}/stream?quality=192"
        ) as resp:
            assert resp.status_code == 200
            assert resp.headers["x-audio-bitrate-kbps"] == "192"
            assert resp.headers["x-audio-extension"] == "m4a"
            _ = b"".join(resp.iter_bytes())

    def test_stream__original_quality__returns_source_extension_header(
        self, client, tmp_path
    ):
        track = _add_track_with_file(client, tmp_path, codec="flac")
        _install_fake_coordinator(
            client, payload_for_quality=lambda br: b"FAKE" * 20
        )

        with client.stream(
            "GET", f"/tracks/{track.uuid_id}/stream?quality=original"
        ) as resp:
            assert resp.status_code == 200
            assert resp.headers["x-audio-extension"] == "flac"
            _ = b"".join(resp.iter_bytes())

    def test_stream__passthrough__serves_source_when_bitrate_below_requested(
        self, client, tmp_path
    ):
        """When source bitrate <= requested quality, source is served as-is."""
        track = _add_track_with_file(
            client, tmp_path, name="low.mp3", bitrate_kbps=96.0
        )
        original_bytes = track.file_path.read_bytes()
        transcoded = {"calls": 0}

        def payload(bitrate: int) -> bytes:
            transcoded["calls"] += 1
            return b"TRANSCODED" * 20

        _install_fake_coordinator(client, payload_for_quality=payload)

        with client.stream(
            "GET", f"/tracks/{track.uuid_id}/stream?quality=320"
        ) as resp:
            assert resp.status_code == 200
            # Source bitrate (96) <= requested (320) → passthrough, not audio/mp4
            assert not resp.headers["content-type"].startswith("audio/mp4")
            assert resp.headers["x-audio-bitrate-kbps"] == "96"
            assert resp.headers["x-audio-extension"] == "mp3"
            body = b"".join(resp.iter_bytes())

        assert body == original_bytes
        assert transcoded["calls"] == 0

    def test_stream__passthrough__range_request_works(self, client, tmp_path):
        """Passthrough still handles Range requests correctly."""
        track = _add_track_with_file(
            client, tmp_path, name="low.mp3", bitrate_kbps=64.0
        )
        _install_fake_coordinator(
            client, payload_for_quality=lambda br: b"TRANSCODED" * 20
        )

        with client.stream(
            "GET",
            f"/tracks/{track.uuid_id}/stream?quality=256",
            headers={"Range": "bytes=0-9"},
        ) as resp:
            assert resp.status_code == 206
            assert resp.headers["x-audio-bitrate-kbps"] == "64"
            body = b"".join(resp.iter_bytes())

        assert len(body) == 10

    def test_stream__invalid_quality__returns_422(self, client, tmp_path):
        track = _add_track_with_file(client, tmp_path)
        r = client.get(f"/tracks/{track.uuid_id}/stream?quality=999")
        assert r.status_code == 422, r.text

    def test_stream__quality_uses_cache_on_repeat(self, client, tmp_path):
        track = _add_track_with_file(client, tmp_path)
        encode_count = {"n": 0}

        def payload(bitrate: int) -> bytes:
            encode_count["n"] += 1
            return f"call-{encode_count['n']}-".encode() * 50

        _install_fake_coordinator(client, payload_for_quality=payload)

        for _ in range(3):
            with client.stream(
                "GET", f"/tracks/{track.uuid_id}/stream?quality=192"
            ) as resp:
                assert resp.status_code == 200
                _ = b"".join(resp.iter_bytes())

        assert encode_count["n"] == 1

    def test_stream__quality_range_request__works(self, client, tmp_path):
        track = _add_track_with_file(client, tmp_path)
        encoded_payload = b"X" * 200
        _install_fake_coordinator(client, payload_for_quality=lambda br: encoded_payload)

        with client.stream(
            "GET",
            f"/tracks/{track.uuid_id}/stream?quality=128",
            headers={"Range": "bytes=10-29"},
        ) as resp:
            assert resp.status_code == 206
            assert int(resp.headers["content-length"]) == 20
            body = b"".join(resp.iter_bytes())

        assert body == encoded_payload[10:30]


class TestEncodedCache:
    def _make_cache(self, tmp_path: Path, max_bytes: int) -> EncodedCache:
        return EncodedCache(
            ctx=EncodedCacheContext(
                cache_dir=tmp_path / "cache",
                max_size_bytes=max_bytes,
            )
        )

    def _stage_source(self, tmp_path: Path, name: str, body: bytes) -> Path:
        scratch = tmp_path / "scratch"
        scratch.mkdir(exist_ok=True)
        src = scratch / name
        src.write_bytes(body)
        return src

    def test_cache_miss_then_hit(self, tmp_path):
        cache = self._make_cache(tmp_path, 10 * 1024 * 1024)
        assert cache.get("uuid-a", "192") is None
        src = self._stage_source(tmp_path, "a.m4a", b"hello-cache")
        cache.insert("uuid-a", "192", src)
        path = cache.get("uuid-a", "192")
        assert path is not None
        assert path.read_bytes() == b"hello-cache"

    def test_cache_evicts_when_over_budget(self, tmp_path):
        # 100 byte budget; insert four 60-byte entries; cache should hold ~1.
        cache = self._make_cache(tmp_path, 100)
        for i in range(4):
            src = self._stage_source(tmp_path, f"e{i}.m4a", b"x" * 60)
            cache.insert(f"uuid-{i}", "192", src)
        total = cache.total_size_bytes()
        assert total <= 100

    def test_cache_lru_keeps_recent(self, tmp_path):
        cache = self._make_cache(tmp_path, 130)
        for i in range(2):
            src = self._stage_source(tmp_path, f"e{i}.m4a", b"x" * 60)
            cache.insert(f"uuid-{i}", "192", src)
        # Touch uuid-0 so it becomes most recent.
        assert cache.get("uuid-0", "192") is not None
        # Insert a third entry; eviction should choose uuid-1.
        src = self._stage_source(tmp_path, "e2.m4a", b"x" * 60)
        cache.insert("uuid-2", "192", src)
        assert cache.has("uuid-0", "192")
        assert not cache.has("uuid-1", "192")
        assert cache.has("uuid-2", "192")

    def test_cache_clear_removes_all(self, tmp_path):
        cache = self._make_cache(tmp_path, 10 * 1024 * 1024)
        for i in range(3):
            src = self._stage_source(tmp_path, f"e{i}.m4a", b"x" * 10)
            cache.insert(f"uuid-{i}", "192", src)
        cache.clear()
        assert cache.total_size_bytes() == 0


class TestQueueSync:
    def test_sync__stores_state_and_prefetches(self, client, tmp_path):
        track1 = _add_track_with_file(client, tmp_path, name="t1.mp3")
        track2 = _add_track_with_file(client, tmp_path, name="t2.mp3")

        encoded = {"calls": 0}

        def payload(bitrate: int) -> bytes:
            encoded["calls"] += 1
            return b"SYNCED" * 30

        coordinator = _install_fake_coordinator(client, payload_for_quality=payload)

        body = {
            "session_id": "sess-1",
            "current_index": 0,
            "quality": "192",
            "track_uuids": [track1.uuid_id, track2.uuid_id],
        }
        r = client.post("/queue/sync", json=body)
        assert r.status_code == 200, r.text
        data = r.json()
        assert data["accepted"] is True
        assert data["prefetch_queued"] == 2

        coordinator._executor.shutdown(wait=True)

        assert client.app.state.encoded_cache.has(track1.uuid_id, "192")
        assert client.app.state.encoded_cache.has(track2.uuid_id, "192")
        assert encoded["calls"] == 2

        # Verify state was persisted in DB.
        state = client.app.state.database.get_queue_sync_state("sess-1")
        assert state is not None
        assert state["current_index"] == 0
        assert state["quality"] == "192"

    def test_sync__updates_existing_state(self, client, tmp_path):
        track = _add_track_with_file(client, tmp_path)
        _install_fake_coordinator(client, payload_for_quality=lambda br: b"x" * 10)

        r = client.post("/queue/sync", json={
            "session_id": "sess-1",
            "current_index": 0,
            "quality": "192",
            "track_uuids": [track.uuid_id],
        })
        assert r.status_code == 200

        # Update with new current_index
        r = client.post("/queue/sync", json={
            "session_id": "sess-1",
            "current_index": 5,
            "quality": "256",
            "track_uuids": [track.uuid_id],
        })
        assert r.status_code == 200

        state = client.app.state.database.get_queue_sync_state("sess-1")
        assert state is not None
        assert state["current_index"] == 5
        assert state["quality"] == "256"

    def test_sync__invalid_quality__rejected(self, client, tmp_path):
        track = _add_track_with_file(client, tmp_path)
        r = client.post("/queue/sync", json={
            "session_id": "sess-1",
            "current_index": 0,
            "quality": "garbage",
            "track_uuids": [track.uuid_id],
        })
        assert r.status_code == 422, r.text

    def test_sync__original_quality__no_encoding(self, client, tmp_path):
        track = _add_track_with_file(client, tmp_path)
        encoded = {"calls": 0}

        def payload(bitrate: int) -> bytes:
            encoded["calls"] += 1
            return b"x" * 10

        coordinator = _install_fake_coordinator(client, payload_for_quality=payload)

        r = client.post("/queue/sync", json={
            "session_id": "sess-1",
            "current_index": 0,
            "quality": "original",
            "track_uuids": [track.uuid_id],
        })
        assert r.status_code == 200
        coordinator._executor.shutdown(wait=True)
        assert encoded["calls"] == 0

    def test_sync__too_many_uuids__rejected(self, client):
        uuids = [f"u-{i}" for i in range(501)]
        r = client.post("/queue/sync", json={
            "session_id": "sess-1",
            "current_index": 0,
            "quality": "192",
            "track_uuids": uuids,
        })
        assert r.status_code == 422, r.text

    def test_sync__prefetch_served_on_subsequent_stream(self, client, tmp_path):
        track = _add_track_with_file(client, tmp_path)
        encoded = {"calls": 0}

        def payload(bitrate: int) -> bytes:
            encoded["calls"] += 1
            return b"PRE" * 100

        coordinator = _install_fake_coordinator(client, payload_for_quality=payload)

        r = client.post("/queue/sync", json={
            "session_id": "sess-1",
            "current_index": 0,
            "quality": "256",
            "track_uuids": [track.uuid_id],
        })
        assert r.status_code == 200
        coordinator._executor.shutdown(wait=True)
        assert encoded["calls"] == 1

        with client.stream(
            "GET", f"/tracks/{track.uuid_id}/stream?quality=256"
        ) as resp:
            assert resp.status_code == 200
            _ = b"".join(resp.iter_bytes())

        assert encoded["calls"] == 1

class TestBitratePassthrough:
    """Unit tests for encode_for_stream passthrough behaviour."""

    def _make_coordinator(self, tmp_path: Path, source: Path) -> tuple[EncoderCoordinator, list]:
        cache = EncodedCache(
            ctx=EncodedCacheContext(
                cache_dir=tmp_path / "cache",
                max_size_bytes=10 * 1024 * 1024,
            )
        )
        transcode_calls: list[int] = []

        def fake_transcode(src: Path, dst: Path, bitrate: int) -> bool:
            transcode_calls.append(bitrate)
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_bytes(b"encoded" * 10)
            return True

        coordinator = EncoderCoordinator(
            cache=cache,
            source_lookup=lambda _: source,
            workers=2,
            transcode_fn=fake_transcode,
        )
        return coordinator, transcode_calls

    def test_passthrough_when_source_bitrate_below_requested(self, tmp_path):
        source = tmp_path / "track.mp3"
        source.write_bytes(b"original" * 100)
        coordinator, calls = self._make_coordinator(tmp_path, source)

        result = coordinator.encode_for_stream("uuid-a", "320", source_bitrate_kbps=96)

        assert result is not None
        assert result.transcoded is False
        assert result.bitrate_kbps == 96
        assert result.path == source
        assert calls == []  # No transcode occurred

    def test_passthrough_when_source_bitrate_equals_requested(self, tmp_path):
        source = tmp_path / "track.mp3"
        source.write_bytes(b"original" * 100)
        coordinator, calls = self._make_coordinator(tmp_path, source)

        result = coordinator.encode_for_stream("uuid-a", "192", source_bitrate_kbps=192)

        assert result is not None
        assert result.transcoded is False
        assert calls == []

    def test_transcodes_when_source_bitrate_above_requested(self, tmp_path):
        source = tmp_path / "track.mp3"
        source.write_bytes(b"original" * 100)
        coordinator, calls = self._make_coordinator(tmp_path, source)

        result = coordinator.encode_for_stream("uuid-a", "128", source_bitrate_kbps=320)

        assert result is not None
        assert result.transcoded is True
        assert result.bitrate_kbps == 128
        assert calls == [128]

    def test_transcodes_when_source_bitrate_unknown(self, tmp_path):
        """None source_bitrate_kbps + ffprobe fails → transcode proceeds."""
        source = tmp_path / "track.mp3"
        source.write_bytes(b"not-real-audio")  # ffprobe will fail on this
        coordinator, calls = self._make_coordinator(tmp_path, source)

        result = coordinator.encode_for_stream("uuid-a", "192", source_bitrate_kbps=None)

        # ffprobe returns None → no passthrough → transcode runs
        assert result is not None
        assert result.transcoded is True
        assert calls == [192]

    def test_original_quality_returns_source_not_transcoded(self, tmp_path):
        source = tmp_path / "track.mp3"
        source.write_bytes(b"original" * 100)
        coordinator, calls = self._make_coordinator(tmp_path, source)

        result = coordinator.encode_for_stream("uuid-a", "original", source_bitrate_kbps=256)

        assert result is not None
        assert result.transcoded is False
        assert result.path == source
        assert result.bitrate_kbps == 256
        assert calls == []

    def test_passthrough_lock_cleaned_up(self, tmp_path):
        source = tmp_path / "track.mp3"
        source.write_bytes(b"original" * 100)
        coordinator, _ = self._make_coordinator(tmp_path, source)

        coordinator.encode_for_stream("uuid-a", "320", source_bitrate_kbps=64)

        assert ("uuid-a", "320") not in coordinator._key_locks


class TestEncoderCoordinatorLocks:
    """Unit tests for _key_locks memory-leak fix."""

    def _make_coordinator(self, tmp_path: Path, source: Path) -> EncoderCoordinator:
        cache = EncodedCache(
            ctx=EncodedCacheContext(
                cache_dir=tmp_path / "cache",
                max_size_bytes=10 * 1024 * 1024,
            )
        )

        def fake_transcode(src: Path, dst: Path, bitrate: int) -> bool:
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_bytes(b"encoded" * 10)
            return True

        return EncoderCoordinator(
            cache=cache,
            source_lookup=lambda _: source,
            workers=4,
            transcode_fn=fake_transcode,
        )

    def test_lock_pruned_after_encode(self, tmp_path):
        """_key_locks entry is removed once encode_for_stream returns."""
        source = tmp_path / "track.mp3"
        source.write_bytes(b"audio")
        coordinator = self._make_coordinator(tmp_path, source)

        coordinator.encode_for_stream("uuid-a", "192")

        assert ("uuid-a", "192") not in coordinator._key_locks

    def test_locks_empty_after_multiple_encodes(self, tmp_path):
        """_key_locks stays empty across many different (uuid, quality) pairs."""
        source = tmp_path / "track.mp3"
        source.write_bytes(b"audio")
        coordinator = self._make_coordinator(tmp_path, source)

        for i in range(10):
            for q in ("128", "192", "256", "320"):
                coordinator.encode_for_stream(f"uuid-{i}", q)

        assert coordinator._key_locks == {}

    def test_concurrent_requests_encode_once(self, tmp_path):
        """Concurrent requests for the same (uuid, quality) only encode once.

        Only 1 thread executes the transcode (holding the per-key lock); the
        remaining threads block on that lock, then find the cached result.
        """
        source = tmp_path / "track.mp3"
        source.write_bytes(b"audio")

        encode_count = {"n": 0}

        cache = EncodedCache(
            ctx=EncodedCacheContext(
                cache_dir=tmp_path / "cache",
                max_size_bytes=10 * 1024 * 1024,
            )
        )

        def slow_transcode(src: Path, dst: Path, bitrate: int) -> bool:
            encode_count["n"] += 1
            time.sleep(0.05)  # Hold the lock briefly so other threads pile up.
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_bytes(b"encoded" * 10)
            return True

        coordinator = EncoderCoordinator(
            cache=cache,
            source_lookup=lambda _: source,
            workers=8,
            transcode_fn=slow_transcode,
        )

        results = []
        lock = threading.Lock()

        def call():
            r = coordinator.encode_for_stream("uuid-x", "192")
            with lock:
                results.append(r)

        threads = [threading.Thread(target=call) for _ in range(8)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        assert encode_count["n"] == 1
        assert all(r is not None for r in results)
        assert ("uuid-x", "192") not in coordinator._key_locks

    def test_lock_pruned_after_second_thread_finds_cache(self, tmp_path):
        """A thread waiting on the lock finds the cached result and the lock is cleaned up."""
        source = tmp_path / "track.mp3"
        source.write_bytes(b"audio")

        encode_count = {"n": 0}
        ready = threading.Event()
        proceed = threading.Event()

        cache = EncodedCache(
            ctx=EncodedCacheContext(
                cache_dir=tmp_path / "cache",
                max_size_bytes=10 * 1024 * 1024,
            )
        )

        def gating_transcode(src: Path, dst: Path, bitrate: int) -> bool:
            encode_count["n"] += 1
            ready.set()    # Signal that encoding has started.
            proceed.wait() # Wait for second thread to be queued on the lock.
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_bytes(b"encoded" * 10)
            return True

        coordinator = EncoderCoordinator(
            cache=cache,
            source_lookup=lambda _: source,
            workers=2,
            transcode_fn=gating_transcode,
        )

        result1 = [None]
        result2 = [None]

        def first():
            result1[0] = coordinator.encode_for_stream("uuid-y", "192")

        def second():
            ready.wait()   # Wait until first thread is inside transcode.
            proceed.set()  # Let first thread finish encoding.
            result2[0] = coordinator.encode_for_stream("uuid-y", "192")

        t1 = threading.Thread(target=first)
        t2 = threading.Thread(target=second)
        t1.start()
        t2.start()
        t1.join()
        t2.join()

        assert encode_count["n"] == 1
        assert result1[0] is not None
        assert result2[0] is not None
        assert result1[0] == result2[0]
        assert ("uuid-y", "192") not in coordinator._key_locks


    def test_sync__current_index_skips_earlier_tracks(self, client, tmp_path):
        track1 = _add_track_with_file(client, tmp_path, name="t1.mp3")
        track2 = _add_track_with_file(client, tmp_path, name="t2.mp3")
        track3 = _add_track_with_file(client, tmp_path, name="t3.mp3")

        encoded = {"calls": 0}

        def payload(bitrate: int) -> bytes:
            encoded["calls"] += 1
            return b"ENC" * 30

        coordinator = _install_fake_coordinator(client, payload_for_quality=payload)

        # current_index=1 means start prefetching from track2 onward.
        r = client.post("/queue/sync", json={
            "session_id": "sess-1",
            "current_index": 1,
            "quality": "192",
            "track_uuids": [track1.uuid_id, track2.uuid_id, track3.uuid_id],
        })
        assert r.status_code == 200
        coordinator._executor.shutdown(wait=True)

        # track1 should NOT be prefetched (before current_index).
        assert not client.app.state.encoded_cache.has(track1.uuid_id, "192")
        assert client.app.state.encoded_cache.has(track2.uuid_id, "192")
        assert client.app.state.encoded_cache.has(track3.uuid_id, "192")
