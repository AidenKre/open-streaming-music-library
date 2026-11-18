"""7A.2c S9 (spec §4 `POST …/retry`: "`{expected_review_version}`; retryable
failed/interrupted/duplicate_conflict items only. Under state CAS, increment
review_version, invalidate old commit choices, retain valid source or return
allocated if retransmission needed. Retry re-runs the duplicate check (§5)
before returning to `review_ready`. Cancelled/expired/imported/duplicate
return 409 or terminal receipt, never revive."; §3 `duplicate_conflict`:
"`validating` after retry (the worker re-runs `find_duplicates` on the stored
staged identity, without re-hashing, then → `review_ready`)"; SC-16b bounded
body; SC-22; SC-28 foreign == unknown)."""

import json

import pytest

from app.services.storage_ledger import UPLOAD_SOURCE
from app.services.upload_errors import probe_timeout, upload_invalid_audio
from app.services.upload_validation import ValidationFailed
from tests.identity_worker_fixtures import add_track, sql
from tests.upload_validation_fixtures import (
    FakeCompute,
    FakeProbe,
    exact_for,
    identity_row,
    item_row,
    make_worker,
    source_rows,
    stage_item,
)

NOW = 1_700_000_000
UNKNOWN = "00000000-0000-4000-8000-0000000000ff"


@pytest.fixture
def client(app_client):
    from app.routers.uploads import upload_clock

    app_client.app.dependency_overrides[upload_clock] = lambda: NOW
    return app_client


class Wakes:
    def __init__(self):
        self.count = 0

    def wake(self):
        self.count += 1


class Env:
    def __init__(self, client):
        self.client = client
        self.db = client.app.state.database
        self.admin = client.app.state.admin_user_id
        self.root = client.app.state.upload_receipt.uploads_root
        self.root.mkdir(parents=True, exist_ok=True)
        self.wakes = client.app.state.upload_validation_worker = Wakes()

    def stage(self, **kwargs):
        kwargs.setdefault("owner_id", self.admin)
        return stage_item(self.db, self.root, **kwargs)

    def validate(self, **kwargs):
        return make_worker(self.db, self.root, **kwargs).process_one()

    def retry(self, staged_or_uuid, version=0, **kwargs):
        item = staged_or_uuid if isinstance(staged_or_uuid, str) else staged_or_uuid["item_uuid"]
        kwargs.setdefault("json", {"expected_review_version": version})
        return self.client.post(f"/tracks/uploads/items/{item}/retry", **kwargs)


@pytest.fixture
def env(client):
    yield Env(client)
    client.app.state.upload_validation_worker = None


def _failed(env, error, **kwargs):
    staged = env.stage(**kwargs)
    env.validate(probe=FakeProbe(ValidationFailed(error)))
    assert item_row(env.db, staged)["state"] == "failed"
    return staged


def test_a_retryable_failure_with_its_source_goes_back_to_validation(env):
    staged = _failed(env, probe_timeout(), content=b"abc")

    response = env.retry(staged, 0)

    assert response.status_code == 200, response.text
    body = response.json()
    assert (body["state"], body["review_version"], body["error"]) == ("validating", 1, None)
    assert (body["duplicate_check"], body["detected_metadata"]) == (None, None)
    assert env.wakes.count == 1
    assert source_rows(env.db, staged) == [{"purpose": UPLOAD_SOURCE, "bytes": 3}]
    env.validate()
    row = item_row(env.db, staged)
    assert (row["state"], row["review_version"]) == ("review_ready", 1)


def test_a_retry_revalidates_from_scratch(env):
    staged = _failed(env, probe_timeout())
    # A stale identity row from an earlier attempt must not short-cut the probe.
    sql(env.db, "INSERT INTO upload_item_audio_identity (owner_id, item_uuid, exact_state, computed_at, fp_state) "
                "VALUES (?, ?, 'failed', 1, 'unavailable')", (env.admin, staged["item_uuid"]))
    sql(env.db, "UPDATE upload_items SET detected_metadata = '{}' WHERE item_uuid = ?", (staged["item_uuid"],))

    assert env.retry(staged, 0).status_code == 200

    assert identity_row(env.db, staged) is None
    assert item_row(env.db, staged)["detected_metadata"] is None
    probe = FakeProbe()
    env.validate(probe=probe)
    assert len(probe.calls) == 1


def test_a_retryable_failure_whose_source_is_gone_returns_to_allocated(env):
    staged = _failed(env, probe_timeout(), content=b"abc")
    staged["source"].unlink()

    response = env.retry(staged, 0)

    assert response.status_code == 200, response.text
    body = response.json()
    assert (body["state"], body["review_version"], body["received_bytes"], body["error"]) == ("allocated", 1, 0, None)
    row = item_row(env.db, staged)
    assert (row["source_path"], row["received_sha256"]) == (None, None)
    assert source_rows(env.db, staged) == []
    assert env.wakes.count == 0


def test_a_duplicate_conflict_is_rechecked_from_the_stored_identity_without_rehashing(env):
    staged = env.stage(content=b"audio-A")
    env.validate()
    stored = identity_row(env.db, staged)
    metadata = item_row(env.db, staged)["detected_metadata"]
    track = add_track(env.db, "/m/arrived.flac", owner_id=env.admin, identity={
        "exact_state": "current", "exact_kind": "pcm_sha256", "exact_digest": exact_for(b"audio-A").digest,
        "sample_rate_hz": 44100, "channels": 2, "bits_per_sample": 16, "match_state": "current"})
    sql(env.db, "UPDATE upload_items SET state = 'duplicate_conflict', conflict_track_uuids = ? "
                "WHERE item_uuid = ?", (json.dumps([track]), staged["item_uuid"]))

    response = env.retry(staged, 0)

    assert response.status_code == 200, response.text
    assert (response.json()["state"], response.json()["duplicate_check"]) == ("validating", None)
    assert identity_row(env.db, staged) == stored
    assert item_row(env.db, staged)["detected_metadata"] == metadata
    assert item_row(env.db, staged)["conflict_track_uuids"] == json.dumps([track])
    probe, compute = FakeProbe(), FakeCompute()
    env.validate(probe=probe, compute=compute)
    assert (probe.calls, compute.calls) == ([], [])
    item = env.client.get(f"/tracks/uploads/items/{staged['item_uuid']}").json()
    assert (item["state"], item["review_version"]) == ("review_ready", 1)
    assert [m["track_uuid"] for m in item["duplicate_check"]["matches"]] == [track]


def test_a_stale_review_version_is_a_conflict_and_changes_nothing(env):
    staged = _failed(env, probe_timeout())
    before = item_row(env.db, staged)

    response = env.retry(staged, 5)

    assert response.status_code == 409
    detail = response.json()["detail"]
    assert (detail["error"], detail["review_version"], detail["retryable"]) == (
        "upload_review_version_conflict", 0, False)
    assert item_row(env.db, staged) == before


def test_a_repeated_retry_with_the_old_version_is_a_conflict(env):
    staged = _failed(env, probe_timeout())
    assert env.retry(staged, 0).status_code == 200

    response = env.retry(staged, 0)

    assert (response.status_code, response.json()["detail"]["error"]) == (409, "upload_review_version_conflict")
    assert response.json()["detail"]["review_version"] == 1


def test_a_failure_that_is_not_retryable_is_refused(env):
    staged = _failed(env, upload_invalid_audio())
    before = item_row(env.db, staged)

    response = env.retry(staged, 0)

    assert response.status_code == 409
    assert (response.json()["detail"]["error"], response.json()["detail"]["state"]) == (
        "upload_item_not_retryable", "failed")
    assert item_row(env.db, staged) == before


EXTRA = {"imported": ", result_track_uuid = 'x', result_revision = 1",
         "duplicate": ", result_track_uuid = 'x', duplicate_kind = 'exact'",
         "expanded": ", kind = 'zip'"}


@pytest.mark.parametrize("state", ["allocated", "receiving", "validating", "review_ready", "committing",
                                   "imported", "duplicate", "cancelled", "expired", "expanded"])
def test_no_other_state_is_ever_revived(env, state):
    staged = env.stage()
    sql(env.db, f"UPDATE upload_items SET state = ?{EXTRA.get(state, '')} WHERE item_uuid = ?",
        (state, staged["item_uuid"]))
    before = item_row(env.db, staged)

    response = env.retry(staged, 0)

    assert response.status_code == 409
    assert (response.json()["detail"]["error"], response.json()["detail"]["state"]) == (
        "upload_item_not_retryable", state)
    assert item_row(env.db, staged) == before
    assert env.wakes.count == 0


def test_a_foreign_item_answers_exactly_like_an_unknown_one(env):
    from tests.owned_database import add_test_user

    sam = add_test_user(env.db, "sam")
    theirs = stage_item(env.db, env.root, owner_id=sam)
    env.validate(probe=FakeProbe(ValidationFailed(probe_timeout())))
    before = item_row(env.db, theirs)

    foreign, unknown = env.retry(theirs, 0), env.retry(UNKNOWN, 0)

    assert (foreign.status_code, unknown.status_code) == (404, 404)
    assert foreign.json() == unknown.json()
    assert foreign.json()["detail"]["error"] == "upload_item_not_found"
    assert item_row(env.db, theirs) == before


@pytest.mark.parametrize("body", [
    {}, {"expected_review_version": -1}, {"expected_review_version": "0"},
    {"expected_review_version": 0, "extra": 1}, [], None,
], ids=["missing", "negative", "string", "extra-field", "list", "null"])
def test_an_invalid_body_is_a_422_without_echoing_it(env, body):
    staged = _failed(env, probe_timeout())

    response = env.retry(staged, json=body)

    assert response.status_code == 422
    assert all("input" not in error for error in response.json()["detail"])


def test_an_oversized_body_is_refused_before_it_is_read(env):
    staged = _failed(env, probe_timeout())

    response = env.retry(staged, content=b"{" + b" " * (256 * 1024 + 1) + b"}",
                         headers={"Content-Type": "application/json"}, json=None)

    assert response.status_code == 413
    assert item_row(env.db, staged)["state"] == "failed"
