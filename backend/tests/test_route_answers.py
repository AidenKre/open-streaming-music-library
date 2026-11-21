"""The exact answers of the routes that lived in main.py, pinned before they moved into routers.

Characterization tests: each one asserts the exact status and the exact JSON
body (or header) a route answers today. A failure arm is reached by replacing
a method on an object or class the move does not touch (the app's Database
instance, ``TrackEditor``, ``ConversionOrchestrator``), never a name in
``app.main``; every such test also asserts the replacement was called.
"""

import sqlite3
from pathlib import Path

import pytest

from app.database import (
    ConversionJobActive,
    EmptyTrackEdit,
    RevisionConflict,
    TrackNotFound,
    TrackPendingDeletion,
)
from app.models import Track, TrackMetaData
from app.services.conversion import (
    ConversionOrchestrator,
    ConversionRequestInvalid,
    InsufficientDiskSpace,
    MasterNotFound,
    NoOpConversion,
    PendingRecovery,
    TargetPathTaken,
)
from app.services.metadata import TagWriteError
from app.services.track_editor import MasterSwapPending, MasterWriteError, TrackEditor
from tests.jobs_api_fixtures import _post_job
from tests.pending_deletion import mark_pending_deletion
from tests.test_api import add_tracks_to_client
from tests.test_jobs_api import _add_track_with_file as _add_convertible_track
from tests.test_jobs_api import _hold_worker
from tests.test_track_source import _install_coordinator

UNKNOWN = "00000000-0000-4000-8000-000000000000"
SOME_UUID = "00000000-0000-4000-8000-000000000001"

BUSY = {"detail": "Database busy, retry"}
PENDING_DELETION = {
    "detail": {
        "error": "track_pending_deletion",
        "message": "This track is being deleted.",
        "retryable": True,
    }
}
TOO_LARGE = {
    "detail": {
        "error": "request_too_large",
        "message": "Request body exceeds the size limit.",
        "retryable": False,
    }
}
REVISION_CONFLICT_7 = b'{"detail":{"error":"revision_conflict","current_revision":7}}'

# A JSON body one byte over the 64 KiB cap of these routes.
OVERSIZED_BODY = b'{"x":"' + b"a" * (64 * 1024 + 1 - 8) + b'"}'
assert len(OVERSIZED_BODY) == 64 * 1024 + 1


@pytest.fixture
def client(app_client):
    return app_client


def _replace(monkeypatch, owner, name, outcome) -> list:
    """Replace ``owner.name`` by a fake that records each call and raises
    ``outcome`` when it is an exception, else returns it."""
    calls: list = []

    def fake(*args, **kwargs):
        calls.append((args, kwargs))
        if isinstance(outcome, BaseException):
            raise outcome
        return outcome

    monkeypatch.setattr(owner, name, fake)
    return calls


def _db(client):
    """The app's Database instance; every Library call goes through it."""
    return client.app.state.database


# ── GET / ────────────────────────────────────────────────────────────────────


def test_root_answers_healthy(client):
    r = client.get("/")

    assert r.status_code == 200
    assert r.json() == {"message": "Healthy"}


# ── GET /tracks ──────────────────────────────────────────────────────────────


@pytest.mark.parametrize(
    ("cursor", "detail"),
    [
        ("not json", "Cursor could not be decoded for json"),
        ("[1, 2]", "Cursor did not decode to a dict"),
        ("{}", "Cursor could not be decoded for json"),
        ('{"order_parameters": []}', "Invalid dictionary keys for the cursor_dict"),
    ],
)
def test_tracks_bad_cursor_is_400(client, cursor, detail):
    r = client.get("/tracks", params={"cursor": cursor})

    assert r.status_code == 400
    assert r.json() == {"detail": detail}


def test_tracks_count_none_is_500(client, monkeypatch):
    calls = _replace(monkeypatch, _db(client), "get_tracks_count", None)

    r = client.get("/tracks")

    assert calls
    assert r.status_code == 500
    assert r.json() == {"detail": "Unable to get count of remaining tracks"}


def test_tracks_album_without_artist_is_422(client):
    r = client.get("/tracks", params={"album_id": 1})

    assert r.status_code == 422
    assert r.json() == {"detail": "album_id requires artist_id"}


def test_tracks_limit_zero_is_422(client):
    r = client.get("/tracks", params={"limit": 0})

    assert r.status_code == 422
    assert r.json() == {
        "detail": [
            {
                "type": "greater_than_equal",
                "loc": ["query", "limit"],
                "msg": "Input should be greater than or equal to 1",
                "input": "0",
                "ctx": {"ge": 1},
            }
        ]
    }


# ── GET /changes ─────────────────────────────────────────────────────────────


def test_changes_fetch_failure_is_500(client, monkeypatch):
    calls = _replace(monkeypatch, _db(client), "get_changes", RuntimeError("boom"))

    r = client.get("/changes")

    assert calls
    assert r.status_code == 500
    assert r.json() == {"detail": "Failed to fetch changes"}


def test_changes_negative_revision_is_422(client):
    r = client.get("/changes", params={"after_revision": -1})

    assert r.status_code == 422
    assert r.json() == {
        "detail": [
            {
                "type": "greater_than_equal",
                "loc": ["query", "after_revision"],
                "msg": "Input should be greater than or equal to 0",
                "input": "-1",
                "ctx": {"ge": 0},
            }
        ]
    }


# ── GET /artists ─────────────────────────────────────────────────────────────


@pytest.mark.parametrize(
    ("cursor", "detail"),
    [
        ("not json", "Cursor could not be decoded as JSON"),
        ("[1, 2]", "Cursor did not decode to a dict"),
        ('{"order_parameters": []}', "Invalid dictionary keys for the cursor"),
    ],
)
def test_artists_bad_cursor_is_400(client, cursor, detail):
    r = client.get("/artists", params={"cursor": cursor})

    assert r.status_code == 400
    assert r.json() == {"detail": detail}


def test_artists_count_none_is_500(client, monkeypatch):
    calls = _replace(monkeypatch, _db(client), "get_artists_count", None)

    r = client.get("/artists")

    assert calls
    assert r.status_code == 500
    assert r.json() == {"detail": "Unable to get count of remaining artists"}


def test_artists_fetch_none_is_500(client, monkeypatch):
    counted = _replace(monkeypatch, _db(client), "get_artists_count", 3)
    fetched = _replace(monkeypatch, _db(client), "get_artists", None)

    r = client.get("/artists")

    assert counted and fetched
    assert r.status_code == 500
    assert r.json() == {"detail": "Unable to fetch artists from the database"}


# ── GET /albums ──────────────────────────────────────────────────────────────


@pytest.mark.parametrize(
    ("cursor", "detail"),
    [
        ("not json", "Cursor could not be decoded as JSON"),
        ("[1, 2]", "Cursor did not decode to a dict"),
        ('{"order_parameters": []}', "Invalid dictionary keys for the cursor"),
    ],
)
def test_albums_bad_cursor_is_400(client, cursor, detail):
    r = client.get("/albums", params={"cursor": cursor})

    assert r.status_code == 400
    assert r.json() == {"detail": detail}


def test_albums_count_none_is_500(client, monkeypatch):
    calls = _replace(monkeypatch, _db(client), "get_albums_count", None)

    r = client.get("/albums")

    assert calls
    assert r.status_code == 500
    assert r.json() == {"detail": "Unable to get count"}


def test_albums_fetch_none_is_500(client, monkeypatch):
    counted = _replace(monkeypatch, _db(client), "get_albums_count", 3)
    fetched = _replace(monkeypatch, _db(client), "get_albums", None)

    r = client.get("/albums")

    assert counted and fetched
    assert r.status_code == 500
    assert r.json() == {"detail": "Unable to fetch albums from the backends database"}


def test_albums_limit_over_max_is_422(client):
    r = client.get("/albums", params={"limit": 1001})

    assert r.status_code == 422
    assert r.json() == {
        "detail": [
            {
                "type": "less_than_equal",
                "loc": ["query", "limit"],
                "msg": "Input should be less than or equal to 1000",
                "input": "1001",
                "ctx": {"le": 1000},
            }
        ]
    }


# ── GET /search ──────────────────────────────────────────────────────────────


def test_search_no_valid_types_is_400(client):
    r = client.get("/search", params={"q": "x", "types": "songs,people"})

    assert r.status_code == 400
    assert r.json() == {"detail": "No valid types specified"}


@pytest.mark.parametrize(
    ("params", "error"),
    [
        (
            {},
            {"type": "missing", "loc": ["query", "q"], "msg": "Field required", "input": None},
        ),
        (
            {"q": ""},
            {
                "type": "string_too_short",
                "loc": ["query", "q"],
                "msg": "String should have at least 1 character",
                "input": "",
                "ctx": {"min_length": 1},
            },
        ),
        (
            {"q": "x", "limit": 51},
            {
                "type": "less_than_equal",
                "loc": ["query", "limit"],
                "msg": "Input should be less than or equal to 50",
                "input": "51",
                "ctx": {"le": 50},
            },
        ),
    ],
    ids=["q-missing", "q-empty", "limit-51"],
)
def test_search_validation_is_422(client, params, error):
    r = client.get("/search", params=params)

    assert r.status_code == 422
    assert r.json() == {"detail": [error]}


# ── GET /cover_art/{id} ──────────────────────────────────────────────────────


def _own_art(client, tmp_path, name: str, data: bytes | None) -> int:
    """A cover art row at ``data/cover_art/<name>`` referenced by one of the
    admin's tracks; the file is written only when ``data`` is given."""
    state = client.app.state
    path = tmp_path / "data" / "cover_art" / name
    path.parent.mkdir(parents=True, exist_ok=True)
    if data is not None:
        path.write_bytes(data)
    art_id = state.database.insert_cover_art(
        sha256=name, phash="0" * 16, phash_prefix="00", file_path=str(path)
    )
    track = Track(
        file_path=tmp_path / "music" / "admin" / f"{name}.flac",
        metadata=TrackMetaData(
            title=name, artist="A", album="B", codec="flac", duration=1.0,
            has_album_art=True, cover_art_id=art_id,
        ),
    )
    assert state.admin_library.add_track(track)
    return art_id


def test_cover_art_own_row_with_missing_file_is_404(client, tmp_path):
    art_id = _own_art(client, tmp_path, "gone.png", None)

    r = client.get(f"/cover_art/{art_id}")

    assert r.status_code == 404
    assert r.json() == {"detail": "Cover art not found"}


@pytest.mark.parametrize(
    ("name", "content_type"),
    [("art.png", "image/png"), ("art.dat", "image/jpeg")],
)
def test_cover_art_content_type_and_cache_control(client, tmp_path, name, content_type):
    art_id = _own_art(client, tmp_path, name, b"image-bytes")

    r = client.get(f"/cover_art/{art_id}")

    assert r.status_code == 200
    assert r.content == b"image-bytes"
    assert r.headers["content-type"] == content_type
    assert r.headers["cache-control"] == "private, max-age=31536000, immutable"


def test_cover_art_busy_is_503(client, monkeypatch):
    calls = _replace(
        monkeypatch, _db(client), "get_owned_cover_art",
        sqlite3.OperationalError("database is locked"),
    )

    r = client.get("/cover_art/1")

    assert calls
    assert r.status_code == 503
    assert r.json() == BUSY


# ── GET /tracks/{uuid}/stream ────────────────────────────────────────────────


def _add_stream_track(client, tmp_path, name, codec, bitrate_kbps=None) -> Track:
    path = tmp_path / name
    path.write_bytes(b"source-bytes" * 20)
    track = Track(
        file_path=path,
        metadata=TrackMetaData(title=name, duration=1.0, codec=codec, bitrate_kbps=bitrate_kbps),
    )
    assert client.app.state.admin_library.add_track(track=track)
    return client.app.state.admin_library.get_track_by_uuid(track.uuid_id)


def test_stream_unsupported_quality_is_422(client):
    r = client.get(f"/tracks/{UNKNOWN}/stream", params={"quality": "999"})

    assert r.status_code == 422
    assert r.json() == {"detail": "Unsupported quality preset: 999"}


def test_stream_unknown_track_is_404(client):
    r = client.get(f"/tracks/{UNKNOWN}/stream")

    assert r.status_code == 404
    assert r.json() == {"detail": f"Could not find track with uuid: {UNKNOWN}"}


def test_stream_encode_failure_is_500(client, tmp_path):
    calls: list = []

    def failing_transcode(src, dst, bitrate):
        calls.append(bitrate)
        return False

    _install_coordinator(client, failing_transcode)
    track = _add_stream_track(client, tmp_path, "song.mp3", "mp3", 320.0)

    r = client.get(f"/tracks/{track.uuid_id}/stream", params={"quality": "128"})

    assert calls
    assert r.status_code == 500
    assert r.json() == {
        "detail": f"Unable to encode track {track.uuid_id} at quality 128"
    }


def test_stream_pending_deletion_is_410(client, tmp_path):
    track = _add_stream_track(client, tmp_path, "song.mp3", "mp3", 320.0)
    mark_pending_deletion(Path(_db(client).context.database_path), track.uuid_id)

    r = client.get(f"/tracks/{track.uuid_id}/stream")

    assert r.status_code == 410
    assert r.json() == PENDING_DELETION


def test_stream_unknown_codec_no_suffix_falls_back(client, tmp_path):
    track = _add_stream_track(client, tmp_path, "song", None)

    r = client.get(f"/tracks/{track.uuid_id}/stream", params={"quality": "original"})

    assert r.status_code == 200
    assert r.content == b"source-bytes" * 20
    assert r.headers["content-type"] == "audio/octet-stream"
    assert r.headers["x-audio-extension"] == "audio"
    assert r.headers["x-audio-codec"] == ""
    assert r.headers["x-track-revision"] == str(track.revision)
    assert "x-audio-bitrate-kbps" not in r.headers


def test_stream_unmapped_codec_uses_source_suffix(client, tmp_path):
    track = _add_stream_track(client, tmp_path, "song.opus", "opus", 96.0)

    r = client.get(f"/tracks/{track.uuid_id}/stream")

    assert r.status_code == 200
    assert r.headers["content-type"] == "audio/opus"
    assert r.headers["x-audio-extension"] == "opus"
    assert r.headers["x-audio-codec"] == "opus"
    assert r.headers["x-audio-bitrate-kbps"] == "96"
    assert r.headers["x-track-revision"] == str(track.revision)


def test_stream_transcoded_headers(client, tmp_path):
    calls: list = []

    def transcode(src, dst, bitrate):
        calls.append(bitrate)
        Path(dst).parent.mkdir(parents=True, exist_ok=True)
        Path(dst).write_bytes(b"encoded")
        return True

    _install_coordinator(client, transcode)
    track = _add_stream_track(client, tmp_path, "song.mp3", "mp3", 320.0)

    r = client.get(f"/tracks/{track.uuid_id}/stream", params={"quality": "128"})

    assert calls == [128]
    assert r.status_code == 200
    assert r.content == b"encoded"
    assert r.headers["content-type"] == "audio/mp4"
    assert r.headers["x-audio-extension"] == "m4a"
    assert r.headers["x-audio-codec"] == "aac"
    assert r.headers["x-audio-bitrate-kbps"] == "128"
    assert r.headers["x-track-revision"] == str(track.revision)


# ── POST /tracks/warm ────────────────────────────────────────────────────────


def test_warm_too_many_uuids_is_422(client):
    body = {"current_index": 0, "quality": "128", "track_uuids": [UNKNOWN] * 501}

    r = client.post("/tracks/warm", json=body)

    assert r.status_code == 422
    assert r.json() == {"detail": "Too many track_uuids: max 500"}


def test_warm_unsupported_quality_is_422(client):
    body = {"current_index": 0, "quality": "999", "track_uuids": [UNKNOWN]}

    r = client.post("/tracks/warm", json=body)

    assert r.status_code == 422
    assert r.json() == {"detail": "Unsupported quality preset: 999"}


def test_warm_body_validation_is_422(client):
    r = client.post("/tracks/warm", json={"current_index": 0, "track_uuids": []})

    assert r.status_code == 422
    assert r.json() == {
        "detail": [{"type": "missing", "loc": ["body", "quality"], "msg": "Field required"}]
    }


# ── GET/PUT /settings/quality ────────────────────────────────────────────────


def test_get_quality_default(client):
    r = client.get("/settings/quality")

    assert r.status_code == 200
    assert r.json() == {"quality": "original"}


def test_put_quality_unsupported_is_422(client):
    r = client.put("/settings/quality", json={"quality": "999"})

    assert r.status_code == 422
    assert r.json() == {"detail": "Unsupported quality preset: 999"}


def test_put_quality_persist_failure_is_500(client, monkeypatch):
    calls = _replace(monkeypatch, _db(client), "set_user_setting", RuntimeError("boom"))

    r = client.put("/settings/quality", json={"quality": "192"})

    assert calls
    assert r.status_code == 500
    assert r.json() == {"detail": "Failed to persist default quality setting"}


def test_put_quality_ok(client):
    r = client.put("/settings/quality", json={"quality": "192"})

    assert r.status_code == 200
    # The master admin's default moved off "original": a warm pass is submitted.
    assert r.json() == {"quality": "192", "warming": True}


# ── GET /tracks/{uuid} ───────────────────────────────────────────────────────


def test_get_track_unknown_is_404(client):
    r = client.get(f"/tracks/{UNKNOWN}")

    assert r.status_code == 404
    assert r.json() == {"detail": "Track not found"}


def test_get_track_ok(client):
    track = add_tracks_to_client(client)[0]

    r = client.get(f"/tracks/{track.uuid_id}")

    assert r.status_code == 200
    body = r.json()
    assert set(body) == {"uuid_id", "metadata", "created_at", "last_updated", "revision"}
    assert body["uuid_id"] == track.uuid_id
    stored = client.app.state.admin_library.get_track_by_uuid(track.uuid_id)
    assert body["revision"] == stored.revision


# ── PATCH /tracks/{uuid} ─────────────────────────────────────────────────────


@pytest.mark.parametrize(
    ("raised", "status", "body"),
    [
        (TrackNotFound(SOME_UUID), 404, {"detail": "Track not found"}),
        (TrackPendingDeletion(SOME_UUID), 409, PENDING_DELETION),
        (
            EmptyTrackEdit(),
            422,
            {"detail": "Edit would leave the track with no title, artist, album, or album artist"},
        ),
        (MasterSwapPending("x"), 503, {"detail": "Master file write failed: x"}),
        (TagWriteError("tags"), 500, {"detail": "Master file write failed: tags"}),
        (MasterWriteError("move"), 500, {"detail": "Master file write failed: move"}),
        (sqlite3.OperationalError("database is locked"), 503, BUSY),
    ],
    ids=[
        "not-found", "pending-deletion", "empty-edit", "swap-pending",
        "tag-write", "master-write", "busy",
    ],
)
def test_patch_error_answers(client, monkeypatch, raised, status, body):
    calls = _replace(monkeypatch, TrackEditor, "apply_edit", raised)

    r = client.patch(f"/tracks/{SOME_UUID}", json={"base_revision": 1, "title": "T"})

    assert len(calls) == 1
    assert r.status_code == status
    assert r.json() == body


def test_patch_revision_conflict_bytes(client, monkeypatch):
    calls = _replace(
        monkeypatch, TrackEditor, "apply_edit", RevisionConflict(SOME_UUID, 1, 7)
    )

    r = client.patch(f"/tracks/{SOME_UUID}", json={"base_revision": 1, "title": "T"})

    assert len(calls) == 1
    assert r.status_code == 409
    assert r.content == REVISION_CONFLICT_7


def test_patch_other_operational_error_propagates(client, monkeypatch):
    calls = _replace(
        monkeypatch, TrackEditor, "apply_edit", sqlite3.OperationalError("disk I/O error")
    )

    with pytest.raises(sqlite3.OperationalError, match="disk I/O error"):
        client.patch(f"/tracks/{SOME_UUID}", json={"base_revision": 1, "title": "T"})

    assert len(calls) == 1


def test_patch_replaced_success_body(client, monkeypatch):
    calls = _replace(monkeypatch, TrackEditor, "apply_edit", (5, True))

    r = client.patch(f"/tracks/{SOME_UUID}", json={"base_revision": 1, "title": "T"})

    assert len(calls) == 1
    assert r.status_code == 200
    assert r.json() == {"uuid_id": SOME_UUID, "revision": 5, "master_written": True}


def test_patch_real_db_only_edit(client):
    track = add_tracks_to_client(client)[0]
    before = client.app.state.admin_library.get_track_by_uuid(track.uuid_id)

    r = client.patch(
        f"/tracks/{track.uuid_id}",
        json={"base_revision": before.revision, "title": "New title"},
    )

    after = client.app.state.admin_library.get_track_by_uuid(track.uuid_id)
    assert after.revision != before.revision
    assert after.metadata.title == "New title"
    assert r.status_code == 200
    assert r.json() == {
        "uuid_id": track.uuid_id, "revision": after.revision, "master_written": False,
    }


# ── POST /jobs ───────────────────────────────────────────────────────────────


@pytest.mark.parametrize(
    ("raised", "status", "body"),
    [
        (TrackNotFound(SOME_UUID), 404, {"detail": "Track not found"}),
        (TrackPendingDeletion(SOME_UUID), 409, PENDING_DELETION),
        (MasterNotFound(SOME_UUID), 404, {"detail": "Master file not found"}),
        (
            ConversionJobActive(SOME_UUID, 42),
            409,
            {"detail": {"error": "job_active", "job_id": 42}},
        ),
        (
            TargetPathTaken(taken_by="file"),
            409,
            {"detail": {"error": "target_exists", "taken_by": "file"}},
        ),
        (
            TargetPathTaken(taken_by="track"),
            409,
            {"detail": {"error": "target_exists", "taken_by": "track"}},
        ),
        (PendingRecovery(SOME_UUID), 409, {"detail": {"error": "pending_recovery"}}),
        (
            NoOpConversion(SOME_UUID),
            422,
            {"detail": "Target codec is the same lossless codec as the source"},
        ),
        (ConversionRequestInvalid("some text"), 422, {"detail": "some text"}),
        (
            InsufficientDiskSpace(
                "insufficient_storage", "Not enough free disk space: 1000 bytes needed.",
                needed=1000, available=10,
            ),
            507,
            {
                "detail": {
                    "error": "insufficient_storage",
                    "message": "Not enough free disk space: 1000 bytes needed.",
                    "retryable": True,
                    "needed": 1000,
                }
            },
        ),
        (
            InsufficientDiskSpace(
                "free_space_unknown", "Free disk space could not be determined.",
                needed=1000, available=None,
            ),
            507,
            {
                "detail": {
                    "error": "free_space_unknown",
                    "message": "Free disk space could not be determined.",
                    "retryable": True,
                    "needed": 1000,
                }
            },
        ),
        (sqlite3.OperationalError("database is locked"), 503, BUSY),
    ],
    ids=[
        "not-found", "pending-deletion", "master-not-found", "job-active",
        "target-exists-file", "target-exists-track", "pending-recovery", "no-op",
        "request-invalid",
        "insufficient-storage", "free-space-unknown", "busy",
    ],
)
def test_post_job_error_answers(client, monkeypatch, raised, status, body):
    calls = _replace(monkeypatch, ConversionOrchestrator, "enqueue", raised)

    r = _post_job(client, SOME_UUID, "aac", 1, 192)

    assert len(calls) == 1
    assert r.status_code == status
    assert r.json() == body


def test_post_job_revision_conflict_bytes(client, monkeypatch):
    calls = _replace(
        monkeypatch, ConversionOrchestrator, "enqueue", RevisionConflict(SOME_UUID, 1, 7)
    )

    r = _post_job(client, SOME_UUID, "aac", 1, 192)

    assert len(calls) == 1
    assert r.status_code == 409
    assert r.content == REVISION_CONFLICT_7


def test_post_job_other_operational_error_propagates(client, monkeypatch):
    calls = _replace(
        monkeypatch, ConversionOrchestrator, "enqueue", sqlite3.OperationalError("disk I/O error")
    )

    with pytest.raises(sqlite3.OperationalError, match="disk I/O error"):
        _post_job(client, SOME_UUID, "aac", 1, 192)

    assert len(calls) == 1


def test_post_job_queued_job_full_body(client, tmp_path):
    held = _hold_worker(client)
    track = _add_convertible_track(client, tmp_path, codec="flac")

    r = _post_job(client, track.uuid_id, "aac", track.revision, 192)

    assert r.status_code == 200, r.text
    assert len(held.submitted) == 1
    body = r.json()
    row = client.app.state.admin_library.get_conversion_job(body["job_id"])
    assert r.json() == {
        "job_id": row["id"],
        "type": "conversion",
        "uuid_id": track.uuid_id,
        "target_codec": "aac",
        "target_container": "m4a",
        "target_bitrate": 192,
        "status": "queued",
        "error_text": None,
        "created_at": row["created_at"],
        "updated_at": row["updated_at"],
    }


# ── GET /jobs, DELETE /jobs/{id} ─────────────────────────────────────────────


@pytest.mark.parametrize(
    ("params", "detail"),
    [
        ({"type": "x"}, "unsupported job type: x"),
        ({"status": "queued,bogus"}, "unsupported job status: queued,bogus"),
        ({"status": ","}, "unsupported job status: ,"),
    ],
)
def test_jobs_bad_filter_is_422(client, params, detail):
    r = client.get("/jobs", params=params)

    assert r.status_code == 422
    assert r.json() == {"detail": detail}


def test_jobs_busy_is_503(client, monkeypatch):
    calls = _replace(
        monkeypatch, _db(client), "list_conversion_jobs",
        sqlite3.OperationalError("database is locked"),
    )

    r = client.get("/jobs")

    assert calls
    assert r.status_code == 503
    assert r.json() == BUSY


def test_jobs_negative_cursor_is_422(client):
    r = client.get("/jobs", params={"cursor": -1})

    assert r.status_code == 422
    assert r.json() == {
        "detail": [
            {
                "type": "greater_than_equal",
                "loc": ["query", "cursor"],
                "msg": "Input should be greater than or equal to 0",
                "input": "-1",
                "ctx": {"ge": 0},
            }
        ]
    }


def test_jobs_empty(client):
    r = client.get("/jobs")

    assert r.status_code == 200
    assert r.json() == {"data": [], "nextCursor": None}


def test_delete_unknown_job(client):
    r = client.delete("/jobs/999999")

    assert r.status_code == 200
    assert r.json() == {"cancelled": False}


# ── 413 on every JSON-body route ─────────────────────────────────────────────


@pytest.mark.parametrize(
    ("method", "path"),
    [
        ("POST", "/tracks/warm"),
        ("PUT", "/settings/quality"),
        ("PATCH", f"/tracks/{SOME_UUID}"),
        ("POST", "/jobs"),
    ],
)
def test_oversized_body_is_413(client, method, path):
    r = client.request(
        method, path, content=OVERSIZED_BODY, headers={"Content-Type": "application/json"}
    )

    assert r.status_code == 413
    assert r.json() == TOO_LARGE


# ── each app answers with its own settings ───────────────────────────────────


def _app_folders(name: str) -> dict:
    return {"data_dir": f"data-{name}", "music_dir": f"music-{name}", "import_dir": f"import-{name}"}


def test_two_apps_in_one_process_each_advertise_their_own_signup_switch(open_app_client):
    """The test fixture imports ``app.main`` and ``app.config`` afresh for each
    app while router modules stay loaded: a route that kept the settings of the
    first app it met would answer the second app with the first app's values."""
    answers = []
    for name, signup in (("one", "true"), ("two", "false")):
        with open_app_client(**_app_folders(name), env={"OSML_SIGNUP_ENABLED": signup}) as client:
            answers.append(client.get("/app/info").json()["auth"]["signup_enabled"])

    assert answers == [True, False]


def test_two_apps_in_one_process_each_answer_their_own_configured_quality(open_app_client):
    """As above, for the configured default quality a user without a stored
    setting gets (the master admin's is stored at start-up)."""
    answers = []
    for name, quality in (("one", "original"), ("two", "192")):
        with open_app_client(**_app_folders(name), env={"DEFAULT_STREAMING_QUALITY": quality}) as client:
            registered = client.post(
                "/auth/register", json={"username": "sam", "password": "correct horse battery"}
            )
            assert registered.status_code == 201, registered.text
            sam = {"Authorization": f"Bearer {registered.json()['token']}"}
            answers.append(client.get("/settings/quality", headers=sam).json())

    assert answers == [{"quality": "original"}, {"quality": "192"}]
