"""7A.2c S10b (spec §4 `GET …/preview`: "For review-ready audio only, bounded
Range/file response of staged source; never arbitrary filesystem path. Does
not publish a track."; Phase M §5.3: the media token is accepted on media
routes only, "Phase 7's preview joins later"; SC-22; SC-28 foreign == unknown;
review 7-U10 route scope): the preview serves only the owner's own review-ready
staged file, with a content type from the server's probe, as a download-safe
audio response."""

import os

import pytest

from tests.conftest import bearer, log_in
from tests.identity_worker_fixtures import sql
from tests.owned_database import add_test_user
from tests.upload_validation_fixtures import FakeProbe, detected, make_worker, stage_item

DATA = b"0123456789"
UNKNOWN = "00000000-0000-4000-8000-0000000000ff"


class Env:
    def __init__(self, client):
        self.client = client
        self.db = client.app.state.database
        self.admin = client.app.state.admin_user_id
        self.root = client.app.state.upload_receipt.uploads_root
        self.root.mkdir(parents=True, exist_ok=True)

    def ready(self, owner_id=None, content=DATA, mime="audio/flac", codec="flac", container="flac"):
        staged = stage_item(self.db, self.root, owner_id=owner_id or self.admin, content=content)
        probe = FakeProbe(detected(codec, mime=mime, container=container))
        make_worker(self.db, self.root, probe=probe).process_one()
        return staged

    def preview(self, item_uuid, **kwargs):
        return self.client.get(f"/tracks/uploads/items/{item_uuid}/preview", **kwargs)


@pytest.fixture
def env(app_client):
    return Env(app_client)


def test_the_owner_previews_a_review_ready_item(env):
    staged = env.ready()

    response = env.preview(staged["item_uuid"])

    assert response.status_code == 200
    assert response.content == DATA
    assert response.headers["content-type"] == "audio/flac"
    assert response.headers["accept-ranges"] == "bytes"
    assert response.headers["content-length"] == str(len(DATA))
    assert response.headers["x-content-type-options"] == "nosniff"
    assert response.headers["content-disposition"].startswith("attachment")
    assert "no-store" in response.headers["cache-control"]


@pytest.mark.parametrize("mime, codec, container", [
    ("audio/mpeg", "mp3", "mp3"),
    ("audio/mp4", "aac", "mov,mp4,m4a,3gp,3g2,mj2"),
    ("audio/wav", "pcm_s16le", "wav"),
])
def test_the_content_type_is_the_servers_probe_never_the_clients_name(env, mime, codec, container):
    staged = env.ready(mime=mime, codec=codec, container=container)  # its filename says .flac

    assert env.preview(staged["item_uuid"]).headers["content-type"] == mime


@pytest.mark.parametrize("header, status, body, content_range", [
    ("bytes=2-5", 206, b"2345", "bytes 2-5/10"),
    ("bytes=7-", 206, b"789", "bytes 7-9/10"),
    ("bytes=-3", 206, b"789", "bytes 7-9/10"),
    ("bytes=-20", 206, DATA, "bytes 0-9/10"),
    ("bytes=0-0", 206, b"0", "bytes 0-0/10"),
    ("bytes=9-9", 206, b"9", "bytes 9-9/10"),
    # Review r1 7-R1-15 (RFC 9110 §14.1.2): a last position at or past the end clamps.
    ("bytes=0-9", 206, DATA, "bytes 0-9/10"),
    ("bytes=0-10", 206, DATA, "bytes 0-9/10"),
    ("bytes=3-999999", 206, b"3456789", "bytes 3-9/10"),
])
def test_a_range_is_served_from_the_staged_file(env, header, status, body, content_range):
    staged = env.ready()

    response = env.preview(staged["item_uuid"], headers={"Range": header})

    assert response.status_code == status
    assert response.content == body
    assert response.headers["content-range"] == content_range
    assert response.headers["content-length"] == str(len(body))
    assert response.headers["content-type"] == "audio/flac"


@pytest.mark.parametrize("header", [
    "bytes=10-", "bytes=5-2", "bytes=0-1,3-4", "bytes=abc", "bytes=-0", "bytes=", "nonsense",
])
def test_an_unsatisfiable_range_is_a_typed_416_that_echoes_nothing(env, header):
    staged = env.ready()

    response = env.preview(staged["item_uuid"], headers={"Range": header})

    assert response.status_code == 416
    detail = response.json()["detail"]
    assert (detail["error"], detail["retryable"]) == ("range_not_satisfiable", False)
    assert header not in response.text
    assert str(env.root) not in response.text


def _same_as_unknown(env, item_uuid):
    mine, unknown = env.preview(item_uuid), env.preview(UNKNOWN)
    assert (mine.status_code, unknown.status_code) == (404, 404), mine.text
    assert mine.json() == unknown.json()
    assert mine.json()["detail"]["error"] == "upload_item_not_found"
    assert str(env.root) not in mine.text


@pytest.mark.parametrize("state", ["allocated", "receiving", "validating", "committing", "failed",
                                   "duplicate_conflict", "cancelled", "expired"])
def test_an_item_that_is_not_review_ready_has_no_preview(env, state):
    staged = env.ready()
    extra = ", error_code = 'x'" if state == "failed" else ""
    sql(env.db, f"UPDATE upload_items SET state = ?{extra} WHERE item_uuid = ?", (state, staged["item_uuid"]))

    _same_as_unknown(env, staged["item_uuid"])


def test_another_users_review_ready_item_answers_like_an_unknown_one(env):
    sam = add_test_user(env.db, "sam")
    theirs = env.ready(owner_id=sam)

    _same_as_unknown(env, theirs["item_uuid"])


def test_a_staged_file_that_is_gone_answers_like_an_unknown_item(env):
    staged = env.ready()
    staged["source"].unlink()

    _same_as_unknown(env, staged["item_uuid"])


def test_a_recorded_path_outside_the_uploads_tree_is_never_served(env, tmp_path):
    staged = env.ready()
    outside = tmp_path / "secret.txt"
    outside.write_bytes(b"secret")
    sql(env.db, "UPDATE upload_items SET source_path = ? WHERE item_uuid = ?", (str(outside), staged["item_uuid"]))

    _same_as_unknown(env, staged["item_uuid"])


def _open_fds() -> int:
    return len(os.listdir("/dev/fd"))


@pytest.mark.parametrize("headers", [{}, {"Range": "bytes=2-5"}, {"Range": "bytes=50-"}],
                         ids=["whole", "range", "bad-range"])
def test_the_file_handle_is_closed_on_every_exit(env, headers):
    staged = env.ready()
    env.preview(staged["item_uuid"], headers=headers)  # warm up any lazily opened handles
    before = _open_fds()

    for _ in range(5):
        env.preview(staged["item_uuid"], headers=headers)

    assert _open_fds() == before


# ── the media token (Phase M §5.3) ────────────────────────────────────────

@pytest.fixture
def tokens(env):
    tokens = log_in(env.client)
    env.client.headers.pop("Authorization")
    return tokens


def test_the_media_token_alone_previews_the_owners_item(env, tokens):
    staged = env.ready()

    response = env.preview(staged["item_uuid"], params={"access_token": tokens["media_token"]})

    assert (response.status_code, response.content) == (200, DATA)


def test_the_media_token_is_not_accepted_next_to_an_authorization_header(env, tokens):
    staged = env.ready()

    response = env.preview(staged["item_uuid"], params={"access_token": tokens["media_token"]},
                           headers={"Authorization": "Bearer not-a-token"})

    assert response.status_code == 401


def test_the_api_token_is_not_a_media_token(env, tokens):
    staged = env.ready()

    response = env.preview(staged["item_uuid"], params={"access_token": tokens["token"]})

    assert response.status_code == 401


def test_without_any_token_the_preview_needs_auth(env, tokens):
    staged = env.ready()

    response = env.preview(staged["item_uuid"])

    assert (response.status_code, response.json()["detail"]["error"]) == (401, "auth_required")


def test_another_users_media_token_finds_nothing(env, tokens):
    from tests.auth_helpers import create_session

    staged = env.ready()
    sam = add_test_user(env.db, "sam")
    sams = create_session(env.db, sam)

    response = env.preview(staged["item_uuid"], params={"access_token": sams.media_token})

    assert response.status_code == 404


def test_the_bearer_token_still_works(env, tokens):
    staged = env.ready()

    response = env.preview(staged["item_uuid"], headers=bearer(tokens["token"]))

    assert response.status_code == 200


@pytest.mark.parametrize("header", [
    "bytes=10-", "bytes=5-2", "bytes=0-1,3-4", "bytes=abc", "bytes=-0", "bytes=", "nonsense",
])
def test_a_416_names_the_files_size_in_content_range(env, header):
    """RFC 9110 §15.5.17: a 416 carries ``Content-Range: bytes */<size>`` (7-fix-r0 F0-5)."""
    staged = env.ready()

    response = env.preview(staged["item_uuid"], headers={"Range": header})

    assert response.status_code == 416
    assert response.headers.get("content-range") == f"bytes */{len(DATA)}"


@pytest.mark.parametrize("header", ["items=0-1", "Items=2-5"])
def test_a_range_in_another_unit_is_ignored_and_the_whole_file_served(env, header):
    """Review r1 7-R1-15 (RFC 9110 §14.2): a Range header in a unit the server
    does not understand is ignored, here as on the track stream."""
    staged = env.ready()

    response = env.preview(staged["item_uuid"], headers={"Range": header})

    assert response.status_code == 200
    assert response.content == DATA
    assert "content-range" not in response.headers
