"""Piece 8A.3a (SC-16j): the cache generation is captured *before* the track
row is resolved. ``EncoderCoordinator.capture_generation`` returns a token
holding the target cache and its generation; ``encode_for_stream(...,
generation=token)`` then drops an encode whose uuid was evicted after the
capture, even when the eviction landed before the encode itself began."""

from pathlib import Path

from app.services.encoded_cache import EncodedCache, EncodedCacheContext
from app.services.encoder_coordinator import EncoderCoordinator

ADMIN = 1
SAM = 2


def _coordinator(tmp_path, *, default_quality="192"):
    source = tmp_path / "source.mp3"
    source.write_bytes(b"audio" * 100)
    stream = EncodedCache(
        ctx=EncodedCacheContext(cache_dir=tmp_path / "stream", max_size_bytes=10 * 1024 * 1024)
    )
    default = EncodedCache(ctx=EncodedCacheContext(cache_dir=tmp_path / "default", max_size_bytes=0))
    transcodes = []

    def transcode(src: Path, dst: Path, bitrate: int) -> bool:
        transcodes.append(src)
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_bytes(b"encoded" * 10)
        return True

    coordinator = EncoderCoordinator(
        cache=stream,
        source_lookup=lambda uuid_id: source,
        workers=1,
        transcode_fn=transcode,
        default_cache=default,
        default_quality=default_quality,
        admin_owner_id=ADMIN,
    )
    return coordinator, stream, default, source, transcodes


def test_an_eviction_after_the_capture_drops_the_encode(tmp_path):
    c, stream, default, source, transcodes = _coordinator(tmp_path)
    token = c.capture_generation("s", "128", owner_id=SAM)
    stream.remove_all_for_uuid("s")  # a conversion replaced the master meanwhile

    result = c.encode_for_stream("s", "128", source_path=source, owner_id=SAM, generation=token)

    assert result is None
    assert not stream.has("s", "128")
    c.shutdown()


def test_without_an_eviction_the_token_encode_is_cached(tmp_path):
    c, stream, default, source, transcodes = _coordinator(tmp_path)
    token = c.capture_generation("s", "128", owner_id=SAM)

    result = c.encode_for_stream("s", "128", source_path=source, owner_id=SAM, generation=token)

    assert result is not None and result.transcoded
    assert stream.has("s", "128")
    c.shutdown()


def test_the_token_names_the_owners_write_tier(tmp_path):
    c, stream, default, source, transcodes = _coordinator(tmp_path)
    admin_token = c.capture_generation("a", "192", owner_id=ADMIN)
    sam_token = c.capture_generation("s", "192", owner_id=SAM)
    default.remove_all_for_uuid("a")  # only the admin's default tier moved

    assert admin_token.moved() is True
    assert sam_token.moved() is False
    assert c.encode_for_stream("a", "192", source_path=source, owner_id=ADMIN, generation=admin_token) is None
    assert not default.has("a", "192")
    c.shutdown()


def test_a_token_reports_whether_its_generation_moved(tmp_path):
    c, stream, default, source, transcodes = _coordinator(tmp_path)
    token = c.capture_generation("s", "original", owner_id=SAM)

    assert token.moved() is False
    stream.remove_all_for_uuid("s")
    assert token.moved() is True
    c.shutdown()


def test_without_a_token_the_generation_is_still_captured_inside_the_lock(tmp_path):
    # Unchanged behaviour for background callers (prefetch / warm).
    c, stream, default, source, transcodes = _coordinator(tmp_path)
    stream.remove_all_for_uuid("s")

    result = c.encode_for_stream("s", "128", owner_id=SAM)

    assert result is not None and stream.has("s", "128")
    c.shutdown()
