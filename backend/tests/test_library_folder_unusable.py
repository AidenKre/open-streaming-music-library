"""A user's library folder that the server refuses (``app.library.library_root``:
a link that leads outside the music folder) is a typed answer on every route
that reads that user's library, never a crash with a traceback: one stable
error, the same for a browse, a stream, an upload and an edit. Signing in and
the routes that do not read the library keep working, so the person can see
the message. One operator line names the user and the folder, once per
process, never an absolute path. A link to a folder inside the music folder
keeps working as before."""

import logging
import uuid

import pytest

from app.library import Library
from app.models import Track, TrackMetaData
from tests.conftest import bearer, log_in

PASSWORD = "correct horse battery"
UNUSABLE = ("This account's music folder on the server is not usable. The server's admin needs"
            " to fix it.")


@pytest.fixture
def sam(app_client, tmp_path):
    """Sam, signed up and holding one track in their library."""
    db = app_client.app.state.database
    body = app_client.post("/auth/register", json={"username": "Sam", "password": PASSWORD}).json()
    user_id = body["user"]["id"]
    folder = db.get_user(user_id)["library_folder"]
    source = tmp_path / "music" / folder / "Radiohead" / "Lucky.flac"
    source.parent.mkdir(parents=True, exist_ok=True)
    source.write_bytes(b"not really flac")
    track = Track(file_path=source, metadata=TrackMetaData(
        title="Lucky", artist="Radiohead", album="OK Computer", codec="flac", duration=1.0,
        bitrate_kbps=900.0, sample_rate_hz=44100, channels=2, track_number=1, disc_number=1))
    assert Library(db, user_id).add_track(track)
    revision = db.get_track_by_uuid(track.uuid_id, owner_id=user_id).revision
    return {"revision": revision, "id": user_id, "folder": folder, "token": body["token"], "media": body["media_token"],
            "track": track.uuid_id, "root": tmp_path / "music" / folder}


def _relink(sam, target):
    """Move Sam's library folder to ``target`` and leave a link in its place."""
    sam["root"].rename(target)
    sam["root"].symlink_to(target, target_is_directory=True)


def _requests(app_client, sam):
    headers = bearer(sam["token"])
    item = str(uuid.uuid4())
    admin = app_client.headers.pop("Authorization", None)  # a stream signs in by its URL
    try:
        stream = app_client.get(f"/tracks/{sam['track']}/stream",
                                params={"quality": "original", "access_token": sam["media"]})
    finally:
        if admin is not None:
            app_client.headers["Authorization"] = admin
    return {
        "browse": app_client.get("/changes", headers=headers),
        "stream": stream,
        "upload": app_client.post("/tracks/uploads", headers=headers, json={
            "batch_uuid": str(uuid.uuid4()),
            "items": [{"item_uuid": item, "filename": "a.flac", "byte_length": 3,
                       "sha256": "ab" * 32}]}),
        "edit": app_client.patch(f"/tracks/{sam['track']}", headers=headers,
                                 json={"base_revision": sam["revision"], "title": "Lucky (live)"}),
    }


def test_a_library_folder_linked_outside_the_music_folder_answers_one_typed_error(
        app_client, sam, tmp_path, caplog):
    _relink(sam, tmp_path / "outside")

    with caplog.at_level(logging.WARNING, logger="uvicorn.error"):
        answers = _requests(app_client, sam)
        again = app_client.get("/changes", headers=bearer(sam["token"]))

    for name, response in [*answers.items(), ("browse again", again)]:
        assert response.status_code == 503, (name, response.text)
        assert response.json()["detail"] == {
            "error": "library_folder_unusable", "message": UNUSABLE, "retryable": False}, name
    lines = [r for r in caplog.records if r.name == "uvicorn.error"
             and "library folder" in r.getMessage()]
    assert len(lines) == 1  # once, not per request
    message = lines[0].getMessage()
    assert str(sam["id"]) in message and sam["folder"] in message
    assert str(tmp_path) not in message
    assert not any(r.exc_info for r in caplog.records)  # no traceback anywhere


def test_signing_in_and_the_account_routes_keep_working(app_client, sam, tmp_path):
    _relink(sam, tmp_path / "outside")
    app_client.headers.pop("Authorization")

    signed_in = log_in(app_client, "Sam", PASSWORD)
    headers = bearer(signed_in["token"])

    assert app_client.get("/auth/me", headers=headers).status_code == 200
    assert app_client.get("/app/info", headers=headers).status_code == 200


def test_a_library_folder_linked_inside_the_music_folder_works_as_before(app_client, sam, tmp_path):
    _relink(sam, tmp_path / "music" / "zz-real-sam")

    answers = _requests(app_client, sam)

    assert answers["browse"].status_code == 200
    assert answers["edit"].status_code == 200, answers["edit"].text
    assert answers["upload"].status_code == 201, answers["upload"].text
    assert answers["stream"].status_code in (200, 206), answers["stream"].text
