"""Phase M.2a (M-U14, spec §6.1): streaming quality is per caller, and the
pre-warm tier (``default_cache``) belongs to the master admin alone.

A friend's ``PUT /settings/quality`` writes only the friend's own
``user_settings`` row. It never changes ``EncoderCoordinator.default_quality``
(the admin's), so it neither deletes nor re-warms either cache tier.
"""

import pytest
from fastapi.testclient import TestClient

from app.library import Library
from app.models import Track, TrackMetaData
from app.services.encoded_cache import CACHE_FILE_SUFFIX
from app.services.encoder_coordinator import EncoderCoordinator
from tests.conftest import bearer
from tests.owned_database import add_test_user
from tests.quality_fixtures import _store_quality
from tests.test_default_quality import (
    _install_fake_coordinator,
    _stored_quality,
)

PASSWORD = "correct horse battery"


@pytest.fixture
def client(app_client):
    return app_client


def _register(client, username):
    response = client.post(
        "/auth/register", json={"username": username, "password": PASSWORD}
    )
    assert response.status_code == 201, response.text
    body = response.json()
    return body["user"]["id"], bearer(body["token"])


def _cache_files(cache):
    return sorted(p.name for p in cache.ctx.cache_dir.iterdir() if p.is_file())


class TestPerCallerQuality:
    def test_a_friends_put_does_not_change_the_admins_default(self, client):
        """M.1b review finding #1: one user's PUT used to change the
        server-wide encoder default."""
        coordinator = _install_fake_coordinator(client)
        assert client.put("/settings/quality", json={"quality": "192"}).status_code == 200
        _, sam = _register(client, "sam")

        response = client.put("/settings/quality", json={"quality": "128"}, headers=sam)

        assert response.status_code == 200
        assert response.json() == {"quality": "128", "warming": False}
        assert coordinator.default_quality == "192"
        assert _stored_quality(client) == "192"

    def test_a_friends_put_persists_to_the_friends_own_settings(self, client):
        _install_fake_coordinator(client)
        sam_id, sam = _register(client, "sam")

        client.put("/settings/quality", json={"quality": "128"}, headers=sam)

        assert _stored_quality(client, user_id=sam_id) == "128"
        assert client.get("/settings/quality", headers=sam).json()["quality"] == "128"
        # The admin still reads its own value (env fallback: original).
        assert client.get("/settings/quality").json()["quality"] == "original"

    def test_a_friends_put_touches_neither_cache_tier(self, client, monkeypatch):
        coordinator = _install_fake_coordinator(client)
        assert client.put("/settings/quality", json={"quality": "192"}).status_code == 200
        _, sam = _register(client, "sam")
        default_before = _cache_files(client.app.state.default_cache)
        stream_before = _cache_files(client.app.state.encoded_cache)
        submitted = []
        monkeypatch.setattr(
            coordinator._executor, "submit", lambda fn, *a, **kw: submitted.append(fn)
        )

        client.put("/settings/quality", json={"quality": "320"}, headers=sam)

        assert submitted == []  # no cache-file deletion, no warm task
        assert _cache_files(client.app.state.default_cache) == default_before
        assert _cache_files(client.app.state.encoded_cache) == stream_before

    def test_a_friends_put_of_the_admins_quality_is_still_only_the_friends(self, client):
        coordinator = _install_fake_coordinator(client)
        sam_id, sam = _register(client, "sam")

        response = client.put("/settings/quality", json={"quality": "256"}, headers=sam)

        assert response.json() == {"quality": "256", "warming": False}
        assert coordinator.default_quality == "original"
        assert _stored_quality(client) == "original"  # the bootstrap seed
        assert _stored_quality(client, user_id=sam_id) == "256"

    def test_a_friends_invalid_put_is_rejected_and_stores_nothing(self, client):
        sam_id, sam = _register(client, "sam")

        response = client.put("/settings/quality", json={"quality": "bogus"}, headers=sam)

        assert response.status_code == 422
        assert _stored_quality(client, user_id=sam_id) is None

    def test_the_admins_put_still_changes_the_default(self, client):
        coordinator = _install_fake_coordinator(client)
        _register(client, "sam")

        response = client.put("/settings/quality", json={"quality": "256"})

        assert response.json() == {"quality": "256", "warming": True}
        assert coordinator.default_quality == "256"

    def test_the_admins_later_put_of_the_friends_value_still_persists(self, client):
        """M.1b review #1 probe: after a friend's PUT 128, the admin's PUT 128
        used to answer ``warming: false`` and persist nothing."""
        coordinator = _install_fake_coordinator(client)
        _, sam = _register(client, "sam")
        client.put("/settings/quality", json={"quality": "128"}, headers=sam)

        response = client.put("/settings/quality", json={"quality": "128"})

        assert response.json() == {"quality": "128", "warming": True}
        assert _stored_quality(client) == "128"
        assert coordinator.default_quality == "128"
        assert client.get("/settings/quality").json()["quality"] == "128"


# ── M-U14 cache contents: default_cache holds only the admin's tracks ────────

def _add_owned_track(client, tmp_path, library, name):
    path = tmp_path / name
    path.write_bytes(b"audio-source" * 100)
    track = Track(
        file_path=path,
        metadata=TrackMetaData(title=name, duration=1.0, codec="mp3", bitrate_kbps=320.0),
    )
    assert library.add_track(track=track)
    return track.uuid_id


def _drain(client):
    client.app.state.encoder_coordinator.drain()


def _uuids_in(cache, quality):
    suffix = f"__q{quality}{CACHE_FILE_SUFFIX}"
    return {
        p.name[: -len(suffix)]
        for p in cache.ctx.cache_dir.iterdir()
        if p.is_file() and p.name.endswith(suffix)
    }


@pytest.fixture
def two_users(client, tmp_path):
    """The admin and sam each own one track; the admin's quality is 192."""
    _install_fake_coordinator(client)
    sam_id, sam = _register(client, "sam")
    admin_track = _add_owned_track(
        client, tmp_path, client.app.state.admin_library, "admin.mp3"
    )
    sam_track = _add_owned_track(
        client, tmp_path, Library(client.app.state.database, sam_id), "sam.mp3"
    )
    assert client.put("/settings/quality", json={"quality": "192"}).status_code == 200
    _drain(client)
    _install_fake_coordinator(client)  # a fresh pool, same caches and default
    return sam, admin_track, sam_track


class TestCacheContents:
    def test_streams_at_the_admins_quality_prewarm_only_the_admins_track(
        self, client, two_users
    ):
        sam, admin_track, sam_track = two_users

        assert client.get(f"/tracks/{admin_track}/stream?quality=192").status_code == 200
        assert (
            client.get(f"/tracks/{sam_track}/stream?quality=192", headers=sam).status_code
            == 200
        )

        assert _uuids_in(client.app.state.default_cache, "192") == {admin_track}
        assert _uuids_in(client.app.state.encoded_cache, "192") == {sam_track}

    def test_a_friends_warm_at_the_admins_quality_goes_to_the_stream_cache(
        self, client, two_users
    ):
        sam, admin_track, sam_track = two_users

        response = client.post(
            "/tracks/warm",
            json={"track_uuids": [sam_track], "current_index": 0, "quality": "192"},
            headers=sam,
        )
        _drain(client)

        assert response.json()["prefetch_queued"] == 1
        assert _uuids_in(client.app.state.encoded_cache, "192") == {sam_track}
        assert sam_track not in _uuids_in(client.app.state.default_cache, "192")

    def test_an_admin_quality_change_rewarms_only_the_admins_tracks(
        self, client, two_users
    ):
        sam, admin_track, sam_track = two_users
        assert _uuids_in(client.app.state.default_cache, "192") == {admin_track}

        assert client.put("/settings/quality", json={"quality": "256"}).json()["warming"]
        _drain(client)

        assert _uuids_in(client.app.state.default_cache, "192") == set()
        assert _uuids_in(client.app.state.default_cache, "256") == {admin_track}
        assert _uuids_in(client.app.state.encoded_cache, "256") == set()

    def test_a_friends_quality_change_touches_neither_tier(self, client, two_users):
        sam, admin_track, sam_track = two_users
        client.get(f"/tracks/{sam_track}/stream?quality=192", headers=sam)
        default_before = _cache_files(client.app.state.default_cache)
        stream_before = _cache_files(client.app.state.encoded_cache)

        client.put("/settings/quality", json={"quality": "256"}, headers=sam)
        _drain(client)

        assert _cache_files(client.app.state.default_cache) == default_before
        assert _cache_files(client.app.state.encoded_cache) == stream_before


def test_startup_prewarms_only_the_admins_tracks(configure_app, tmp_path, monkeypatch):
    """Warming iterates the admin's UUIDs only (spec §6.1 "Warm set")."""
    with TestClient(configure_app().app) as c:
        sam_id = add_test_user(c.app.state.database, "sam")
        admin_track = _add_owned_track(c, tmp_path, c.app.state.admin_library, "a.mp3")
        _add_owned_track(c, tmp_path, Library(c.app.state.database, sam_id), "s.mp3")
        _store_quality(c, "192")
    warmed = []
    monkeypatch.setattr(
        EncoderCoordinator,
        "_warm_one",
        lambda self, uuid_id, quality, generation: warmed.append((uuid_id, quality)),
    )

    with TestClient(configure_app().app) as c:
        c.app.state.encoder_coordinator.drain()

    assert warmed == [(admin_track, "192")]
