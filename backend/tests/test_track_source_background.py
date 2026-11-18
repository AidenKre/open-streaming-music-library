"""Piece 8A.3a (plan drift row D11, decision O7): queued prefetch / warm work
skips a UUID that is no longer live when its task starts. The app's encoder
coordinator resolves owner and source through ``track_source``'s
owner-resolved form, so a pending-deletion or tombstoned track is never
encoded in the background (no pool surgery, no cancel API)."""

from pathlib import Path

import pytest

from app.models import Track, TrackMetaData
from app.services import track_source
from app.services.encoded_cache import EncodedCache, EncodedCacheContext
from app.services.encoder_coordinator import EncoderCoordinator
from tests.pending_deletion import mark_pending_deletion


@pytest.fixture
def client(app_client):
    return app_client


def _db_path(client) -> Path:
    return Path(client.app.state.database.context.database_path)


def _add(client, tmp_path, name="song.mp3"):
    path = tmp_path / name
    path.write_bytes(b"original-bytes" * 50)
    track = Track(
        file_path=path,
        metadata=TrackMetaData(title=name, duration=1.0, codec="mp3", bitrate_kbps=320.0),
    )
    assert client.app.state.admin_library.add_track(track=track)
    return track.uuid_id, path


def _recording_coordinator(client, calls) -> EncoderCoordinator:
    """A coordinator with the app's own owner/source lookups and a fake
    transcode that records every source it encodes."""
    old: EncoderCoordinator = client.app.state.encoder_coordinator

    def transcode(src: Path, dst: Path, bitrate: int) -> bool:
        calls.append(Path(src))
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_bytes(b"aac")
        return True

    coordinator = EncoderCoordinator(
        cache=client.app.state.encoded_cache,
        source_lookup=old.source_lookup,
        workers=1,
        transcode_fn=transcode,
        default_cache=client.app.state.default_cache,
        default_quality="192",
        admin_owner_id=old.admin_owner_id,
        owner_lookup=old.owner_lookup,
    )
    old.shutdown()
    client.app.state.encoder_coordinator = coordinator
    return coordinator


def test_a_queued_prefetch_of_a_live_track_encodes_it(client, tmp_path):
    calls: list[Path] = []
    c = _recording_coordinator(client, calls)
    uuid_id, master = _add(client, tmp_path)

    c._prefetch_one(uuid_id, "128", None)

    assert calls == [master]
    assert client.app.state.encoded_cache.has(uuid_id, "128")


def test_a_queued_prefetch_skips_a_track_pending_deletion(client, tmp_path):
    calls: list[Path] = []
    c = _recording_coordinator(client, calls)
    uuid_id, _ = _add(client, tmp_path)
    mark_pending_deletion(_db_path(client), uuid_id)

    c._prefetch_one(uuid_id, "128", None)

    assert calls == []
    assert not client.app.state.encoded_cache.has(uuid_id, "128")


def test_a_queued_prefetch_skips_a_tombstoned_track(client, tmp_path):
    calls: list[Path] = []
    c = _recording_coordinator(client, calls)
    uuid_id, _ = _add(client, tmp_path)
    assert client.app.state.admin_library.delete_track(uuid_id)

    c._prefetch_one(uuid_id, "128", None)

    assert calls == []


def test_a_queued_warm_of_a_live_track_encodes_it(client, tmp_path):
    calls: list[Path] = []
    c = _recording_coordinator(client, calls)
    uuid_id, master = _add(client, tmp_path)

    c._warm_one(uuid_id, "192", c.warm_generation)

    assert calls == [master]


def test_a_queued_warm_skips_a_track_pending_deletion(client, tmp_path):
    calls: list[Path] = []
    c = _recording_coordinator(client, calls)
    uuid_id, _ = _add(client, tmp_path)
    mark_pending_deletion(_db_path(client), uuid_id)

    c._warm_one(uuid_id, "192", c.warm_generation)

    assert calls == []
    default = client.app.state.default_cache
    assert default is None or not default.has(uuid_id, "192")


def test_the_owner_resolved_form_answers_only_for_live_tracks(client, tmp_path):
    database = client.app.state.database
    live, live_path = _add(client, tmp_path, "live.mp3")
    pending, _ = _add(client, tmp_path, "pending.mp3")
    gone, _ = _add(client, tmp_path, "gone.mp3")
    mark_pending_deletion(_db_path(client), pending)
    assert client.app.state.admin_library.delete_track(gone)
    admin = client.app.state.admin_user_id

    assert track_source.live_track_owner(database, live) == admin
    assert Path(track_source.live_source_path(database, live)) == live_path
    for uuid_id in (pending, gone, "00000000-0000-4000-8000-000000000000"):
        assert track_source.live_track_owner(database, uuid_id) is None
        assert track_source.live_source_path(database, uuid_id) is None
