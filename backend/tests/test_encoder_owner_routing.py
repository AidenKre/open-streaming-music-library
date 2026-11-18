"""Phase M.2a (M-U14, spec §6.1, SC-16j Phase M): only ``_write_cache`` takes
the owner. A new encode lands in ``default_cache`` only when the track's owner
is the master admin **and** the quality is the admin's default; everything else
goes to the LRU stream cache. ``_lookup_cached``/``_has_cached`` stay owner-free.
"""

from pathlib import Path

import pytest

from app.services.encoded_cache import EncodedCache, EncodedCacheContext
from app.services.encoder_coordinator import EncoderCoordinator, PrefetchOutcome

ADMIN = 1
SAM = 2


def _fake_transcode(src: Path, dst: Path, bitrate: int) -> bool:
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_bytes(b"encoded" * 10)
    return True


def _coordinator(
    tmp_path, *, owners, default_quality="192", uuids=None, events=None, admin_owner_id=ADMIN
):
    source = tmp_path / "source.mp3"
    source.write_bytes(b"audio" * 100)
    stream = EncodedCache(
        ctx=EncodedCacheContext(cache_dir=tmp_path / "stream", max_size_bytes=10 * 1024 * 1024)
    )
    default = EncodedCache(
        ctx=EncodedCacheContext(cache_dir=tmp_path / "default", max_size_bytes=0)
    )

    def source_lookup(uuid_id):
        if events is not None:
            events.append(("source", uuid_id))
        return source

    def owner_lookup(uuid_id):
        if events is not None:
            events.append(("owner", uuid_id))
        return owners.get(uuid_id)

    coordinator = EncoderCoordinator(
        cache=stream,
        source_lookup=source_lookup,
        workers=2,
        transcode_fn=_fake_transcode,
        default_cache=default,
        default_quality=default_quality,
        all_uuids_fn=(lambda: list(uuids)) if uuids is not None else None,
        admin_owner_id=admin_owner_id,
        owner_lookup=owner_lookup,
    )
    return coordinator, stream, default


def _drain(coordinator):
    coordinator._executor.shutdown(wait=True)


class TestWriteRouting:
    def test_the_admins_track_at_the_admins_default_goes_to_default_cache(self, tmp_path):
        c, stream, default = _coordinator(tmp_path, owners={})

        c.encode_for_stream("a", "192", owner_id=ADMIN)

        assert default.has("a", "192")
        assert not stream.has("a", "192")

    def test_a_friends_track_at_the_admins_default_goes_to_the_stream_cache(self, tmp_path):
        c, stream, default = _coordinator(tmp_path, owners={})

        c.encode_for_stream("s", "192", owner_id=SAM)

        assert stream.has("s", "192")
        assert not default.has("s", "192")

    def test_the_admins_track_at_another_quality_goes_to_the_stream_cache(self, tmp_path):
        c, stream, default = _coordinator(tmp_path, owners={})

        c.encode_for_stream("a", "256", owner_id=ADMIN)

        assert stream.has("a", "256")
        assert not default.has("a", "256")

    def test_without_a_known_admin_nothing_goes_to_default_cache(self, tmp_path):
        """Review r1 m-R1-28: the admin-only tier needs a known admin; an
        unset ``admin_owner_id`` routes every owner's encode to the LRU cache."""
        c, stream, default = _coordinator(tmp_path, owners={}, admin_owner_id=None)

        for uuid_id, owner in (("a", ADMIN), ("s", SAM)):
            c.encode_for_stream(uuid_id, "192", owner_id=owner)

        assert stream.has("a", "192") and stream.has("s", "192")
        assert not default.has("a", "192") and not default.has("s", "192")

    def test_owner_id_is_a_required_keyword(self, tmp_path):
        c, _, _ = _coordinator(tmp_path, owners={})

        with pytest.raises(TypeError):
            c.encode_for_stream("a", "192")

    def test_lookup_stays_owner_free(self, tmp_path):
        """A friend's request still finds an admin pre-warmed entry (the cache
        is shared, keyed by global UUID; ownership is checked by the route)."""
        c, stream, default = _coordinator(tmp_path, owners={})
        c.encode_for_stream("a", "192", owner_id=ADMIN)
        cached = default.get("a", "192")

        result = c.encode_for_stream("a", "192", owner_id=SAM)

        assert result.path == cached
        assert not stream.has("a", "192")


class TestWorkersPassTheOwner:
    def test_warming_after_a_quality_change_fills_default_cache(self, tmp_path):
        c, stream, default = _coordinator(
            tmp_path, owners={}, default_quality="original", uuids=["a1", "a2"]
        )

        assert c.set_default_quality("192") is True
        _drain(c)

        assert default.has("a1", "192") and default.has("a2", "192")
        assert not stream.has("a1", "192") and not stream.has("a2", "192")

    def test_startup_warming_fills_default_cache(self, tmp_path):
        c, stream, default = _coordinator(tmp_path, owners={}, uuids=["a1", "a2"])

        c.startup()
        _drain(c)

        assert default.has("a1", "192") and default.has("a2", "192")
        assert not stream.has("a1", "192")

    def test_prefetch_of_a_friends_track_goes_to_the_stream_cache(self, tmp_path):
        c, stream, default = _coordinator(tmp_path, owners={"s": SAM})

        assert c.enqueue_prefetch("s", "192") == PrefetchOutcome.QUEUED
        _drain(c)

        assert stream.has("s", "192")
        assert not default.has("s", "192")

    def test_prefetch_of_the_admins_track_goes_to_default_cache(self, tmp_path):
        c, stream, default = _coordinator(tmp_path, owners={"a": ADMIN})

        c.enqueue_prefetch("a", "192")
        _drain(c)

        assert default.has("a", "192")
        assert not stream.has("a", "192")

    def test_prefetch_of_an_unknown_track_encodes_nothing(self, tmp_path):
        c, stream, default = _coordinator(tmp_path, owners={})

        c.enqueue_prefetch("gone", "192")
        _drain(c)

        assert not stream.has("gone", "192")
        assert not default.has("gone", "192")

    def test_prefetch_resolves_the_owner_before_the_generation_capture(
        self, tmp_path, monkeypatch
    ):
        """SC-16j: the generation is captured before the source is read; the
        owner (immutable) is resolved before both."""
        events = []
        c, stream, default = _coordinator(tmp_path, owners={"s": SAM}, events=events)
        for cache in (stream, default):
            real = cache.generation
            monkeypatch.setattr(
                cache,
                "generation",
                lambda uuid_id, _real=real: events.append(("generation", uuid_id)) or _real(uuid_id),
            )

        c.enqueue_prefetch("s", "192")
        _drain(c)

        assert events == [("owner", "s"), ("generation", "s"), ("source", "s")]
        assert stream.has("s", "192")
