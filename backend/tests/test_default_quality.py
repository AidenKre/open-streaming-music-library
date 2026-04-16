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

    def test_migration_moves_default_files_to_stream_cache(self, tmp_path):
        source = tmp_path / "t.mp3"
        source.write_bytes(b"audio" * 100)
        c, _ = self._make_coordinator(tmp_path, source, default_quality="192")

        # Encode at the old default quality (goes to default_cache).
        c.encode_for_stream("uuid-a", "192", source_bitrate_kbps=320)
        assert c.default_cache.has("uuid-a", "192")
        assert not c.cache.has("uuid-a", "192")

        # Change to a new default quality; migration runs in background.
        old_default_cache = c.default_cache
        c.set_default_quality("320")
        c._executor.shutdown(wait=True)

        # Old default-quality file should now be in stream_cache.
        assert c.cache.has("uuid-a", "192")
        # And removed from default_cache dir.
        assert not old_default_cache.has("uuid-a", "192")

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
