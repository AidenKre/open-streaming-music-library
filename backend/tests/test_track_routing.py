"""Phase 7A.1a (7-U02, SC-24 routing rule, spec §4 "Routing under /tracks"):
every parameterized track route uses the UUID path converter, so a literal
child of ``/tracks`` (``warm``, ``uploads`` (7A.1d), Phase 8's
``deletions``/``duplicates``) is never read as a track ID, whatever the
declaration order. A UUID still reaches the track route; a non-UUID segment
answers 404; a well-formed but unknown UUID answers exactly as before."""

import uuid

import pytest
from fastapi.routing import APIRoute

from app.models import Track, TrackMetaData

UNKNOWN = "00000000-0000-4000-8000-000000000000"


def _add_track(client, title="Lucky"):
    library = client.app.state.admin_library
    source = library.root / "Radiohead" / f"{title}.flac"
    source.parent.mkdir(parents=True, exist_ok=True)
    source.write_bytes(b"not really flac")
    track = Track(
        file_path=source,
        metadata=TrackMetaData(
            title=title, artist="Radiohead", album="OK Computer", codec="flac",
            duration=1.0, bitrate_kbps=900.0, sample_rate_hz=44100, channels=2,
        ),
    )
    assert library.add_track(track)
    return library.get_track_by_uuid(track.uuid_id)


def _place_uploads_list(app, *, first: bool):
    """Move 7A.1d's real ``GET /tracks/uploads`` to the front or the end of
    the app's routes, so the test holds whatever the declaration order."""
    routes = app.router.routes
    [route] = [
        r for r in routes
        if isinstance(r, APIRoute) and r.path == "/tracks/uploads" and "GET" in r.methods
    ]
    routes.remove(route)
    if first:
        routes.insert(0, route)
    else:
        routes.append(route)


# ── literal children reach their own routes ────────────────────────────────

@pytest.mark.parametrize("first", [True, False], ids=["declared-first", "declared-last"])
def test_a_literal_child_reaches_its_route_in_either_order(app_client, first):
    _place_uploads_list(app_client.app, first=first)

    response = app_client.get("/tracks/uploads")

    assert (response.status_code, response.json()) == (200, {"batches": [], "next_after": None})


def test_the_warm_literal_is_never_read_as_a_track_id(app_client):
    # warm is a POST route; a GET or PATCH on its path must not be captured by
    # the track routes (which answered "Track not found" before the converter).
    assert app_client.get("/tracks/warm").status_code == 405
    assert app_client.patch("/tracks/warm", json={}).status_code == 405
    response = app_client.post(
        "/tracks/warm", json={"current_index": 0, "quality": "128", "count": 1, "track_uuids": []}
    )
    assert response.status_code == 200, response.text


# ── a UUID still reaches the track routes ──────────────────────────────────

def test_a_uuid_reaches_the_track_routes(app_client):
    track = _add_track(app_client)

    got = app_client.get(f"/tracks/{track.uuid_id}")
    assert got.status_code == 200, got.text
    assert got.json()["uuid_id"] == track.uuid_id

    patched = app_client.patch(
        f"/tracks/{track.uuid_id}",
        json={"base_revision": track.revision, "title": "Renamed", "write_mode": "db_only"},
    )
    assert patched.status_code == 200, patched.text
    assert patched.json()["uuid_id"] == track.uuid_id  # a plain string, as before

    streamed = app_client.get(f"/tracks/{track.uuid_id}/stream", params={"quality": "original"})
    assert streamed.status_code == 200, streamed.text
    assert streamed.content == b"not really flac"


def test_the_handlers_receive_the_canonical_string(app_client):
    track = _add_track(app_client)
    spelled = str(uuid.UUID(track.uuid_id)).upper()

    response = app_client.get(f"/tracks/{spelled}")

    assert response.status_code == 200, response.text
    assert response.json()["uuid_id"] == track.uuid_id


# ── non-UUID segments answer 404 ───────────────────────────────────────────

# ``uploads`` left this list in 7A.1d: it is now a real literal child
# (tests/test_uploads_api.py), covered by the literal-child tests above.
@pytest.mark.parametrize("segment", ["nope", "123", "deletions", UNKNOWN + "x"])
def test_a_non_uuid_segment_answers_404_on_every_track_route(app_client, segment):
    assert app_client.get(f"/tracks/{segment}").status_code == 404
    assert app_client.get(f"/tracks/{segment}/stream").status_code == 404
    valid_body = {"base_revision": 1, "title": "x", "write_mode": "db_only"}
    assert app_client.patch(f"/tracks/{segment}", json=valid_body).status_code == 404
    # The route never matches, so the body is never validated (was 422).
    assert app_client.patch(f"/tracks/{segment}", json={"bogus": 1}).status_code == 404


def test_a_bad_quality_on_a_non_uuid_stream_answers_404(app_client):
    response = app_client.get("/tracks/nope/stream", params={"quality": "bogus"})

    assert response.status_code == 404


# ── a well-formed unknown UUID: behavior unchanged ─────────────────────────

def test_an_unknown_uuid_answers_as_before(app_client):
    assert app_client.get(f"/tracks/{UNKNOWN}").json() == {"detail": "Track not found"}
    assert app_client.get(f"/tracks/{UNKNOWN}").status_code == 404

    patched = app_client.patch(
        f"/tracks/{UNKNOWN}", json={"base_revision": 1, "title": "x", "write_mode": "db_only"}
    )
    assert (patched.status_code, patched.json()) == (404, {"detail": "Track not found"})

    streamed = app_client.get(f"/tracks/{UNKNOWN}/stream")
    assert (streamed.status_code, streamed.json()) == (
        404, {"detail": f"Could not find track with uuid: {UNKNOWN}"},
    )

    bad_quality = app_client.get(f"/tracks/{UNKNOWN}/stream", params={"quality": "bogus"})
    assert bad_quality.status_code == 422
    assert app_client.patch(f"/tracks/{UNKNOWN}", json={"bogus": 1}).status_code == 422


def test_the_track_routes_declare_the_uuid_converter(app_client):
    paths = {
        (method, route.path)
        for route in app_client.app.routes
        if isinstance(route, APIRoute) and route.path.startswith("/tracks/")
        for method in route.methods
    }

    assert {
        ("GET", "/tracks/{uuid_id:uuid}"),
        ("PATCH", "/tracks/{uuid_id:uuid}"),
        ("GET", "/tracks/{uuid_id:uuid}/stream"),
    } <= paths
    assert not {p for _, p in paths if "{uuid_id}" in p}


# ── every accepted spelling is keyed by the canonical id ───────────────────

def _spellings(canonical):
    value = uuid.UUID(canonical)
    return [canonical, str(value).upper(), value.hex, value.hex.upper()]


def test_every_spelling_reaches_downstream_as_the_canonical_id(app_client, monkeypatch):
    # Cache keys, encoded-file names, track locks and the edit path all key on
    # the string the handler passes on; two spellings must never make two keys.
    track = _add_track(app_client)
    coordinator = app_client.app.state.encoder_coordinator
    editor = app_client.app.state.track_editor
    locks = app_client.app.state.track_locks
    seen = {"encode": [], "edit": [], "lock": []}
    real_encode, real_edit, real_lock = (
        coordinator.encode_for_stream, editor.apply_edit, locks.lock,
    )

    def encode(uuid_id, *args, **kwargs):
        seen["encode"].append(uuid_id)
        return real_encode(uuid_id, *args, **kwargs)

    def edit(library, *, uuid_id, **kwargs):
        seen["edit"].append(uuid_id)
        return real_edit(library, uuid_id=uuid_id, **kwargs)

    def lock(uuid_id):
        seen["lock"].append(uuid_id)
        return real_lock(uuid_id)

    monkeypatch.setattr(coordinator, "encode_for_stream", encode)
    monkeypatch.setattr(editor, "apply_edit", edit)
    monkeypatch.setattr(locks, "lock", lock)

    revision = track.revision
    for spelling in _spellings(track.uuid_id):
        got = app_client.get(f"/tracks/{spelling}")
        assert (got.status_code, got.json()["uuid_id"]) == (200, track.uuid_id)
        streamed = app_client.get(f"/tracks/{spelling}/stream", params={"quality": "original"})
        assert streamed.status_code == 200, streamed.text
        patched = app_client.patch(
            f"/tracks/{spelling}",
            json={"base_revision": revision, "title": f"T{revision}", "write_mode": "db_only"},
        )
        assert patched.status_code == 200, patched.text
        assert patched.json()["uuid_id"] == track.uuid_id
        revision = patched.json()["revision"]

    assert set(seen["encode"]) == {track.uuid_id} and len(seen["encode"]) == 4
    assert set(seen["edit"]) == {track.uuid_id} and len(seen["edit"]) == 4
    assert set(seen["lock"]) == {track.uuid_id}


def test_a_foreign_track_in_any_spelling_looks_absent(app_client):
    from app.library import Library
    from tests.owned_database import add_test_user

    db = app_client.app.state.database
    sam = Library(db, add_test_user(db, "sam"))
    source = app_client.app.state.admin_library.root.parent / "sam" / "Theirs.flac"
    source.parent.mkdir(parents=True, exist_ok=True)
    source.write_bytes(b"sam's bytes")
    theirs = Track(
        file_path=source,
        metadata=TrackMetaData(title="Theirs", artist="Sam", codec="flac", duration=1.0),
    )
    assert sam.add_track(theirs)

    for spelling in _spellings(theirs.uuid_id):
        assert app_client.get(f"/tracks/{spelling}").status_code == 404
        assert app_client.get(
            f"/tracks/{spelling}/stream", params={"quality": "original"}
        ).status_code == 404
        r = app_client.patch(
            f"/tracks/{spelling}",
            json={"base_revision": 1, "title": "Stolen", "write_mode": "db_only"},
        )
        assert r.status_code == 404
    assert sam.get_track_by_uuid(theirs.uuid_id).metadata.title == "Theirs"
