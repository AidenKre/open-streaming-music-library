"""Tests for default streaming quality persistence and two-tier cache."""

import logging
import sqlite3
import threading
import time
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app.database.database import Database
from app.models import Track, TrackMetaData
from app.services.encoded_cache import EncodedCache, EncodedCacheContext
from app.services.encoder_coordinator import EncoderCoordinator
from app.services.transcoder import ORIGINAL_QUALITY
from tests.owned_database import add_test_user
from tests.encoder_pool_fixtures import stop_every_encoder_pool  # noqa: F401  (autouse fixture)
from tests.quality_fixtures import _store_quality

# The master admin's id: only its tracks are routed to default_cache (M.2a).
ADMIN_OWNER = 1



# ── Fixtures ──────────────────────────────────────────────────────────────────

@pytest.fixture
def client(app_client):
    return app_client


def _stored_quality(client, user_id=None):
    """The quality stored in ``user_settings`` (the admin's by default)."""
    user_id = client.app.state.admin_user_id if user_id is None else user_id
    conn = sqlite3.connect(client.app.state.database.context.database_path)
    try:
        row = conn.execute(
            "SELECT value FROM user_settings WHERE user_id = ? "
            "AND key = 'default_streaming_quality'",
            (user_id,),
        ).fetchone()
        return row[0] if row else None
    finally:
        conn.close()


def _add_track(client, tmp_path: Path, name: str = "track.mp3") -> Track:
    track_path = tmp_path / name
    track_path.write_bytes(b"audio-source" * 100)
    metadata = TrackMetaData(title=name, duration=1.0, codec="mp3", bitrate_kbps=320.0)
    track = Track(file_path=track_path, metadata=metadata)
    assert client.app.state.admin_library.add_track(track=track)
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
        all_uuids_fn=client.app.state.encoder_coordinator.all_uuids_fn,
        admin_owner_id=client.app.state.encoder_coordinator.admin_owner_id,
        owner_lookup=client.app.state.encoder_coordinator.owner_lookup,
    )
    client.app.state.encoded_cache = new_stream_cache
    client.app.state.default_cache = new_default_cache
    client.app.state.encoder_coordinator.shutdown()
    client.app.state.encoder_coordinator = coordinator
    return coordinator


# ── Unit tests: two-tier cache ────────────────────────────────────────────────

class TestTwoTierCache:
    def _make_coordinator(
        self, tmp_path: Path, source: Path, default_quality: str = "192", *,
        workers: int = 2, all_uuids: list[str] | None = None, transcode_fn=None,
    ) -> tuple[EncoderCoordinator, list[int]]:
        """A coordinator with a stream cache and an unlimited default cache. Its
        transcode records each bitrate in the returned list and writes a small
        file, unless the test passes its own ``transcode_fn``."""
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
            admin_owner_id=ADMIN_OWNER,
            cache=stream_cache,
            source_lookup=lambda _: source,
            workers=workers,
            transcode_fn=transcode_fn or fake_transcode,
            default_cache=default_cache,
            default_quality=default_quality,
            all_uuids_fn=None if all_uuids is None else (lambda: all_uuids),
        )
        return coordinator, calls

    def test_default_quality_writes_to_default_cache(self, tmp_path):
        source = tmp_path / "t.mp3"
        source.write_bytes(b"audio" * 100)
        c, calls = self._make_coordinator(tmp_path, source, default_quality="192")

        result = c.encode_for_stream("uuid-a", "192", source_bitrate_kbps=320, owner_id=ADMIN_OWNER)

        assert result is not None
        assert result.transcoded is True
        assert c.default_cache.has("uuid-a", "192")
        assert not c.cache.has("uuid-a", "192")

    def test_non_default_quality_writes_to_stream_cache(self, tmp_path):
        source = tmp_path / "t.mp3"
        source.write_bytes(b"audio" * 100)
        c, _ = self._make_coordinator(tmp_path, source, default_quality="192")

        result = c.encode_for_stream("uuid-a", "320", source_bitrate_kbps=500, owner_id=ADMIN_OWNER)

        assert result is not None
        assert c.cache.has("uuid-a", "320")
        assert not c.default_cache.has("uuid-a", "320")

    def test_default_cache_checked_first(self, tmp_path):
        """If default_cache has an entry, stream_cache is not queried."""
        source = tmp_path / "t.mp3"
        source.write_bytes(b"audio" * 100)
        c, calls = self._make_coordinator(tmp_path, source, default_quality="192")

        # Prime default cache.
        c.encode_for_stream("uuid-a", "192", source_bitrate_kbps=320, owner_id=ADMIN_OWNER)
        assert calls == [192]

        # Second call should be a cache hit — no additional transcode.
        c.encode_for_stream("uuid-a", "192", source_bitrate_kbps=320, owner_id=ADMIN_OWNER)
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
        result = c.encode_for_stream("uuid-a", "192", source_bitrate_kbps=320, owner_id=ADMIN_OWNER)
        assert result is not None
        assert calls == []

    def test_quality_change_deletes_old_default_cache_files(self, tmp_path):
        source = tmp_path / "t.mp3"
        source.write_bytes(b"audio" * 100)
        c, _ = self._make_coordinator(tmp_path, source, default_quality="192")

        # Encode at the old default quality (goes to default_cache).
        c.encode_for_stream("uuid-a", "192", source_bitrate_kbps=320, owner_id=ADMIN_OWNER)
        assert c.default_cache.has("uuid-a", "192")
        assert not c.cache.has("uuid-a", "192")

        # Change to a new default quality; deletion runs in background.
        old_default_cache = c.default_cache
        c.set_default_quality("320")
        c.drain()

        # Old default-quality file should be deleted (not migrated to stream cache).
        assert not old_default_cache.has("uuid-a", "192")
        assert not c.cache.has("uuid-a", "192")

    def test_warm_all_tracks__empty_uuid_list__does_nothing(self, tmp_path):
        """_warm_all_tracks with an empty UUID list must not raise and must not encode."""
        source = tmp_path / "t.mp3"
        source.write_bytes(b"audio" * 100)
        c, encode_calls = self._make_coordinator(
            tmp_path, source, default_quality="192", all_uuids=[]  # empty library
        )

        # Should complete without error and without any transcode calls.
        c._submit_warm_tasks("256", c.warm_generation)
        c.drain()

        assert encode_calls == []

    def test_quality_change_keeps_only_the_new_default_files(self, tmp_path):
        """U06-B-02: a default change leaves only the new default's files in
        the never-pruned default cache. An older default's encode (stranded by
        an encode that landed after an earlier cleanup, or by a crash before
        it ran) goes too, so old defaults do not pile up across changes."""
        source = tmp_path / "t.mp3"
        source.write_bytes(b"audio" * 100)
        c, _ = self._make_coordinator(tmp_path, source, default_quality="192")

        # Encode at the current default quality (goes to default_cache).
        c.encode_for_stream("uuid-a", "192", source_bitrate_kbps=320, owner_id=ADMIN_OWNER)
        assert c.default_cache.has("uuid-a", "192")
        cache_dir = c.default_cache.ctx.cache_dir
        stranded = cache_dir / "uuid-b__q256.m4a"  # an earlier default's encode
        stranded.write_bytes(b"encoded" * 10)
        new_default = cache_dir / "uuid-c__q320.m4a"  # already at the new default
        new_default.write_bytes(b"encoded" * 10)

        c.set_default_quality("320")
        c.drain()

        assert not c.default_cache.has("uuid-a", "192")
        assert not stranded.exists()
        assert new_default.exists()

    def test_quality_change_and_back_keeps_the_warmed_files(self, tmp_path):
        """U06-A-01: 192 -> 320 -> 192 before the background work runs. The
        cleanup queued by the first change must not delete the files of the
        default the admin went back to."""
        source = tmp_path / "t.mp3"
        source.write_bytes(b"audio" * 100)
        c, calls = self._make_coordinator(tmp_path, source, default_quality="192")
        c.all_uuids_fn = lambda: ["uuid-a"]
        c.encode_for_stream("uuid-a", "192", source_bitrate_kbps=320, owner_id=ADMIN_OWNER)
        assert calls == [192]

        # Hold both workers so the two changes land before any queued task runs.
        release = threading.Event()
        started = [threading.Event(), threading.Event()]
        for event in started:
            c._executor.submit(
                lambda e=event: (e.set(), release.wait(timeout=10)), priority=0
            )
        for event in started:
            assert event.wait(timeout=10)

        c.set_default_quality("320")
        c.set_default_quality("192")
        release.set()
        c.drain()

        assert c.default_cache.has("uuid-a", "192")
        assert calls == [192]  # the warmed file was kept, never re-encoded

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
        c.drain()

        assert result is True

    def test_set_default_quality__returns_false_for_original_quality(self, tmp_path):
        source = tmp_path / "t.mp3"
        source.write_bytes(b"audio" * 100)
        c, _ = self._make_coordinator(tmp_path, source, default_quality="192")

        result = c.set_default_quality(ORIGINAL_QUALITY)
        c.drain()

        assert result is False

    def test_parallel_warming__all_uuids_encoded_with_multiple_workers(self, tmp_path):
        source = tmp_path / "t.mp3"
        source.write_bytes(b"audio" * 100)
        uuids = [f"uuid-{i}" for i in range(10)]
        c, _ = self._make_coordinator(
            tmp_path, source, default_quality="original", workers=4, all_uuids=uuids
        )
        default_cache = c.default_cache

        c.set_default_quality("192")
        c.drain()

        assert all(default_cache.has(uid, "192") for uid in uuids)

    def test_generation_counter__stale_warm_tasks_skipped(self, tmp_path):
        """Tasks queued for old quality bail out after quality changes."""
        import threading as _threading
        source = tmp_path / "t.mp3"
        source.write_bytes(b"audio" * 100)
        uuids = [f"uuid-{i}" for i in range(10)]
        gate = _threading.Event()

        def fake_transcode(src: Path, dst: Path, bitrate: int) -> bool:
            assert gate.wait(10)  # block until both quality changes have been submitted
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_bytes(b"encoded" * 10)
            return True

        c, _ = self._make_coordinator(
            tmp_path, source, default_quality="original", all_uuids=uuids,
            transcode_fn=fake_transcode,
        )
        default_cache = c.default_cache

        c.set_default_quality("128")   # generation=1, queues 10 tasks
        c.set_default_quality("256")   # generation=2, queues 10 more tasks
        gate.set()                     # let all tasks proceed
        c.drain()

        # "128" tasks bail (generation mismatch) or write to stream_cache (not default_cache)
        assert not any(default_cache.has(uid, "128") for uid in uuids)
        # "256" tasks complete and land in default_cache
        assert all(default_cache.has(uid, "256") for uid in uuids)

    def test_startup__cleans_orphaned_scratch_files(self, tmp_path):
        source = tmp_path / "t.mp3"
        source.write_bytes(b"audio" * 100)
        c, _ = self._make_coordinator(
            tmp_path, source, default_quality=ORIGINAL_QUALITY, workers=1
        )

        # Plant orphaned scratch files
        c._scratch_dir.mkdir(parents=True, exist_ok=True)
        (c._scratch_dir / "orphan1.m4a").write_bytes(b"partial")
        (c._scratch_dir / "orphan2.m4a").write_bytes(b"partial")

        c.startup()
        c.drain()

        remaining = list(c._scratch_dir.iterdir())
        assert remaining == []

    def test_startup__resumes_only_missing_tracks(self, tmp_path):
        source = tmp_path / "t.mp3"
        source.write_bytes(b"audio" * 100)
        uuids = ["uuid-0", "uuid-1", "uuid-2"]
        c, _ = self._make_coordinator(tmp_path, source, default_quality="192", all_uuids=uuids)
        default_cache = c.default_cache

        # Pre-warm uuid-0 so it's already in default_cache
        c.encode_for_stream("uuid-0", "192", source_bitrate_kbps=320, owner_id=ADMIN_OWNER)
        assert default_cache.has("uuid-0", "192")

        # Track encodes via side-channel: count cache insertions after startup
        calls_before = sum(1 for uid in uuids if default_cache.has(uid, "192"))

        c.startup()
        c.drain()

        now_cached = [uid for uid in uuids if default_cache.has(uid, "192")]
        assert len(now_cached) == 3  # all three cached after startup
        # uuid-0 was pre-cached; only uuid-1 and uuid-2 should have been encoded by startup
        new_encodes = len(now_cached) - calls_before
        assert new_encodes == 2

    def test_startup__no_op_when_all_cached(self, tmp_path):
        source = tmp_path / "t.mp3"
        source.write_bytes(b"audio" * 100)
        uuids = ["uuid-0", "uuid-1"]
        c, encode_calls = self._make_coordinator(
            tmp_path, source, default_quality="192", all_uuids=uuids
        )

        # Pre-warm all tracks
        for uid in uuids:
            c.encode_for_stream(uid, "192", source_bitrate_kbps=320, owner_id=ADMIN_OWNER)
        encode_calls.clear()

        c.startup()
        c.drain()

        assert encode_calls == []  # nothing re-encoded

    def test_startup__no_op_for_original_quality(self, tmp_path):
        source = tmp_path / "t.mp3"
        source.write_bytes(b"audio" * 100)
        c, encode_calls = self._make_coordinator(
            tmp_path, source, default_quality=ORIGINAL_QUALITY, all_uuids=["uuid-a"]
        )

        c.startup()
        c.drain()

        assert encode_calls == []

    def test_startup__removes_other_qualities_from_the_default_cache(self, tmp_path):
        """U06-B-02 (review r1): a cleanup still queued at a stop (dropped
        with the rest of the backlog) or lost in a crash is redone at the next
        start, so an old default's files never stay for good."""
        source = tmp_path / "t.mp3"
        source.write_bytes(b"audio" * 100)
        c, calls = self._make_coordinator(tmp_path, source, default_quality="192")
        c.all_uuids_fn = lambda: ["uuid-a"]
        c.encode_for_stream("uuid-a", "192", source_bitrate_kbps=320, owner_id=ADMIN_OWNER)
        stranded = c.default_cache.ctx.cache_dir / "uuid-a__q256.m4a"
        stranded.write_bytes(b"encoded" * 10)

        c.startup()
        c.drain()

        assert not stranded.exists()
        assert c.default_cache.has("uuid-a", "192")
        assert calls == [192]

    def test_warm_all_tracks_encodes_at_new_default(self, tmp_path):
        source = tmp_path / "t.mp3"
        source.write_bytes(b"audio" * 100)
        c, _ = self._make_coordinator(
            tmp_path, source, default_quality="192", all_uuids=["uuid-a", "uuid-b"]
        )

        c.set_default_quality("256")
        c.drain()

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

    def test_put_quality__persists_to_the_admins_user_settings(self, client, tmp_path):
        _install_fake_coordinator(client)

        client.put("/settings/quality", json={"quality": "128"})

        assert _stored_quality(client) == "128"
        # One mechanism: the server-wide app_settings key is no longer used.
        assert client.app.state.database.get_setting("default_streaming_quality") is None

    def test_get_quality__reads_the_callers_user_settings(self, client):
        _store_quality(client, "192")

        assert client.get("/settings/quality").json()["quality"] == "192"

    def test_get_quality__invalid_stored_value_falls_back_to_env_then_original(
        self, open_app_client
    ):
        with open_app_client(env={"DEFAULT_STREAMING_QUALITY": "192"}) as c:
            _store_quality(c, "lossless-MQA")
            assert c.get("/settings/quality").json()["quality"] == "192"
        with open_app_client(env={"DEFAULT_STREAMING_QUALITY": "also-bogus"}) as c:
            _store_quality(c, "lossless-MQA")
            assert c.get("/settings/quality").json()["quality"] == "original"

    def test_put_quality__invalid_rejected(self, client):
        r = client.put("/settings/quality", json={"quality": "lossless-MQA"})
        assert r.status_code == 422
        assert "lossless-MQA" in r.json()["detail"]

    def test_put_quality__invalid_does_not_change_coordinator(self, client):
        _install_fake_coordinator(client)
        coordinator = client.app.state.encoder_coordinator
        original_quality = coordinator.default_quality

        r = client.put("/settings/quality", json={"quality": "bogus"})

        assert r.status_code == 422
        assert coordinator.default_quality == original_quality

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

    def test_put_quality__same_quality__no_db_write(self, client, monkeypatch):
        """PUT with the current quality must not write to the database."""
        writes = []
        monkeypatch.setattr(
            Database, "set_user_setting", lambda self, *a, **kw: writes.append((a, kw))
        )
        current = client.app.state.encoder_coordinator.default_quality

        r = client.put("/settings/quality", json={"quality": current})

        assert r.status_code == 200
        assert r.json()["warming"] is False
        assert writes == []

    def test_put_quality__repairs_an_invalid_stored_value_equal_to_the_live_default(
        self, open_app_client
    ):
        """U06-B-09: the PUT compares with the stored value, not the live one: an
        invalid stored value (live default from the env) is replaced by the PUT."""
        env = {"DEFAULT_STREAMING_QUALITY": "192"}
        with open_app_client(env=env) as c:
            _store_quality(c, "lossless-MQA")
        with open_app_client(env=env) as c:
            assert c.app.state.encoder_coordinator.default_quality == "192"

            r = c.put("/settings/quality", json={"quality": "192"})

            assert r.status_code == 200
            assert r.json()["warming"] is False
            assert _stored_quality(c) == "192"

    def test_put_quality__db_write_failure__leaves_state_unchanged(self, client, monkeypatch):
        """If persisting raises, the coordinator's default_quality and the stored
        value must not change, and the response must surface an error."""
        _install_fake_coordinator(client)
        coordinator = client.app.state.encoder_coordinator
        original_quality = coordinator.default_quality
        stored = _stored_quality(client)

        def boom(self, *args, **kwargs):
            raise RuntimeError("simulated db failure")

        monkeypatch.setattr(Database, "set_user_setting", boom)
        r = client.put("/settings/quality", json={"quality": "256"})

        assert r.status_code == 500
        assert coordinator.default_quality == original_quality
        assert _stored_quality(client) == stored

    def test_put_quality__concurrent_puts__live_matches_persisted(self, client):
        """Concurrent PUTs must leave the persisted setting equal to the
        coordinator's live default_quality (no torn state)."""
        import threading

        _install_fake_coordinator(client)
        coordinator = client.app.state.encoder_coordinator
        qualities = ["96", "128", "192", "256", "320"]
        barrier = threading.Barrier(len(qualities), timeout=10)

        def worker(q):
            barrier.wait()
            client.put("/settings/quality", json={"quality": q})

        threads = [threading.Thread(target=worker, args=(q,)) for q in qualities]
        for t in threads:
            t.start()
        for t in threads:
            t.join(timeout=10)

        assert not any(t.is_alive() for t in threads)
        assert _stored_quality(client) == coordinator.default_quality
        assert coordinator.default_quality in qualities


class TestStartupQualityValidation:
    """The coordinator's startup default is the master admin's stored quality,
    falling back to the env setting and then to original (spec §4.3)."""

    def _boot_app(self, configure_app, env_quality=None):
        return configure_app(
            env={"DEFAULT_STREAMING_QUALITY": env_quality} if env_quality is not None else None
        )

    def _seed_persisted_quality(self, configure_app, value, env=None):
        # Boot once to create the database and the admin, store the value, shutdown.
        bootstrap_main = configure_app(env=env)
        with TestClient(bootstrap_main.app) as c:
            _store_quality(c, value)

    def test_startup__invalid_persisted_falls_back_to_env(self, configure_app, caplog):
        self._seed_persisted_quality(
            configure_app, "lossless-MQA", env={"DEFAULT_STREAMING_QUALITY": "192"}
        )

        app_main = self._boot_app(configure_app, env_quality="192")
        with caplog.at_level(logging.DEBUG, logger="uvicorn.error"):
            with TestClient(app_main.app) as c:
                assert c.app.state.encoder_coordinator.default_quality == "192"
        # The fallback is logged for the operator.
        assert any(
            "lossless-MQA" in r.getMessage() and r.levelno == logging.WARNING
            for r in caplog.records if r.name == "uvicorn.error"
        )

    def test_startup__invalid_persisted_and_env_falls_back_to_original(self, configure_app):
        from app.services.transcoder import ORIGINAL_QUALITY as _ORIG

        self._seed_persisted_quality(
            configure_app, "lossless-MQA", env={"DEFAULT_STREAMING_QUALITY": "also-bogus"}
        )

        app_main = self._boot_app(configure_app, env_quality="also-bogus")
        with TestClient(app_main.app) as c:
            assert c.app.state.encoder_coordinator.default_quality == _ORIG

    def test_startup__valid_persisted_used(self, configure_app):
        self._seed_persisted_quality(configure_app, "320")

        app_main = self._boot_app(configure_app)
        with TestClient(app_main.app) as c:
            assert c.app.state.encoder_coordinator.default_quality == "320"

    def test_startup__the_admins_value_wins_over_another_users(self, configure_app):
        bootstrap_main = configure_app()
        with TestClient(bootstrap_main.app) as c:
            _store_quality(c, "128")
            other = add_test_user(c.app.state.database, "sam")
            _store_quality(c, "320", user_id=other)

        with TestClient(self._boot_app(configure_app).app) as c:
            assert c.app.state.encoder_coordinator.default_quality == "128"
