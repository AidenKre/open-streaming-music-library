"""7A.3a S4 (spec §4 commit row: "exact operation retry returns receipt via the
shared operation-receipt helper (SC-16c ...) ... Conflicting version or reuse
with different body 409; accepted durable job 202, terminal repeated result
200"; §6 step 1: "Lock item, verify review version/state, reserve stable track
UUID and operation, freeze edits/write mode, persist committing journal";
§4: "Unsupported tag-writing codec fails review with a retryable
change-of-choice path" (plan D16/O10: 422 `tag_write_unsupported` before
acceptance); §4 DELETE: "Commit already accepted returns 409/current receipt";
SC-16b bounded body; SC-22 envelope; SC-28 foreign == unknown; 7A.1c review
#4: an operation uuid reused on another item conflicts)."""

import json
import uuid

import pytest

from tests.identity_worker_fixtures import sql
from tests.owned_database import add_test_user
from tests.upload_validation_fixtures import FakeProbe, detected, item_row, make_worker, stage_item

NOW = 1_700_000_000
UNKNOWN = "00000000-0000-4000-8000-0000000000ff"
T1 = "aaaaaaaa-0000-4000-8000-000000000001"
T2 = "aaaaaaaa-0000-4000-8000-000000000002"
S1 = "bbbbbbbb-0000-4000-8000-000000000001"
WAV = detected(codec="pcm_s16le", container="wav", mime="audio/wav")


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
        self.wakes = client.app.state.upload_commit_worker = Wakes()

    def ready(self, meta=None, **kwargs):
        """A review_ready item of the admin (or ``owner_id``)."""
        kwargs.setdefault("owner_id", self.admin)
        staged = stage_item(self.db, self.root, **kwargs)
        worker = make_worker(self.db, self.root, probe=FakeProbe(meta or detected()))
        assert worker.process_one() == "review_ready"
        return staged

    def commit(self, staged_or_uuid, **overrides):
        item = staged_or_uuid if isinstance(staged_or_uuid, str) else staged_or_uuid["item_uuid"]
        data = {
            "operation_uuid": str(uuid.uuid4()),
            "base_review_version": 0,
            "edits": {},
            "write_tags": False,
            "acknowledged_duplicates": {"library_tracks": [], "staged_items": []},
        }
        raw = overrides.pop("raw", None)
        data.update(overrides)
        if raw is not None:
            return self.client.post(f"/tracks/uploads/items/{item}/commit", content=raw,
                                    headers={"Content-Type": "application/json"}), data
        return self.client.post(f"/tracks/uploads/items/{item}/commit", json=data), data

    def journals(self, owner=None):
        if owner is None:
            return sql(self.db, "SELECT * FROM upload_commit_journal ORDER BY created_at, operation_uuid")
        return sql(self.db, "SELECT * FROM upload_commit_journal WHERE owner_id = ?", (owner,))

    def receipts(self, kind="upload_commit"):
        return sql(self.db, "SELECT * FROM operation_receipts WHERE kind = ?", (kind,))


@pytest.fixture
def env(client):
    yield Env(client)
    client.app.state.upload_commit_worker = None


def _error(response):
    return response.json()["detail"]["error"]


# ── acceptance ──────────────────────────────────────────────────────────────

def test_an_accepted_commit_answers_202_with_the_committing_item(env):
    staged = env.ready()

    r, data = env.commit(staged, edits={"title": "New", "album": None}, write_tags=True,
                         acknowledged_duplicates={"library_tracks": [T2, T1], "staged_items": [S1]})

    assert r.status_code == 202, r.text
    item = r.json()
    assert (item["item_uuid"], item["state"], item["review_version"]) == (staged["item_uuid"], "committing", 0)
    assert env.client.get(f"/tracks/uploads/items/{staged['item_uuid']}").json() == item
    assert env.wakes.count == 1


def test_acceptance_freezes_the_choice_in_a_committing_journal(env):
    staged = env.ready()

    r, data = env.commit(staged, edits={"title": "New", "album": None}, write_tags=True,
                         acknowledged_duplicates={"library_tracks": [T2, T1, T2], "staged_items": [S1]})

    assert r.status_code == 202, r.text
    [journal] = env.journals()
    assert journal["owner_id"] == env.admin
    assert journal["operation_uuid"] == data["operation_uuid"]
    assert journal["item_uuid"] == staged["item_uuid"]
    assert journal["state"] == "committing"
    assert journal["base_review_version"] == 0
    assert str(uuid.UUID(journal["reserved_track_uuid"])) == journal["reserved_track_uuid"]
    assert json.loads(journal["edits"]) == {"title": "New", "album": None}
    assert journal["write_tags"] == 1
    assert json.loads(journal["acknowledged_duplicates"]) == {"library_tracks": [T1, T2], "staged_items": [S1]}
    assert journal["source_path"] == str(staged["source"])
    assert journal["work_path"] == str(staged["source"].parent / f"work-{data['operation_uuid']}.flac")
    assert journal["created_at"] == journal["updated_at"] == NOW
    for column in ("final_path", "final_metadata", "cover_art_id", "exact_state", "error_code"):
        assert journal[column] is None, column
    assert item_row(env.db, staged)["reserved_track_uuid"] == journal["reserved_track_uuid"]
    [receipt] = env.receipts()
    assert (receipt["owner_id"], receipt["operation_uuid"], receipt["result_ref"]) == (
        env.admin, data["operation_uuid"], staged["item_uuid"])


def test_a_skip_commit_freezes_empty_edits_and_no_tag_write(env):
    staged = env.ready()

    r, _ = env.commit(staged)

    assert r.status_code == 202, r.text
    [journal] = env.journals()
    assert (json.loads(journal["edits"]), journal["write_tags"]) == ({}, 0)
    assert json.loads(journal["acknowledged_duplicates"]) == {"library_tracks": [], "staged_items": []}


def test_each_commit_reserves_its_own_track_uuid(env):
    first, second = env.ready(), env.ready()

    assert env.commit(first)[0].status_code == 202
    assert env.commit(second)[0].status_code == 202

    reserved = {j["reserved_track_uuid"] for j in env.journals()}
    assert len(reserved) == 2


# ── replay and conflicts (SC-16c) ───────────────────────────────────────────

def test_an_exact_replay_answers_the_same_receipt_and_freezes_nothing_new(env):
    staged = env.ready()
    first, data = env.commit(staged, edits={"title": "New"})
    [journal] = env.journals()

    again = env.client.post(f"/tracks/uploads/items/{staged['item_uuid']}/commit", json=data)

    assert again.status_code == 202, again.text
    assert again.json() == first.json()
    assert env.journals() == [journal]
    assert len(env.receipts()) == 1


def test_a_replay_with_acknowledgements_in_another_order_is_the_same_operation(env):
    staged = env.ready()
    acks = {"library_tracks": [T1, T2], "staged_items": [S1]}
    _, data = env.commit(staged, acknowledged_duplicates=acks)

    data["acknowledged_duplicates"] = {"library_tracks": [T2, T1], "staged_items": [S1, S1]}
    again = env.client.post(f"/tracks/uploads/items/{staged['item_uuid']}/commit", json=data)

    assert again.status_code == 202, again.text
    assert len(env.journals()) == 1


def test_a_replay_after_the_operation_ended_answers_200(env):
    staged = env.ready()
    first, data = env.commit(staged)
    sql(env.db, "UPDATE upload_commit_journal SET state = 'failed', error_code = 'x'")

    again = env.client.post(f"/tracks/uploads/items/{staged['item_uuid']}/commit", json=data)

    assert again.status_code == 200, again.text
    assert again.json()["item_uuid"] == staged["item_uuid"]
    assert len(env.journals()) == 1


@pytest.mark.parametrize(
    "change",
    [
        {"edits": {"title": "Other"}},
        {"edits": {"title": None}},
        {"write_tags": True},
        {"acknowledged_duplicates": {"library_tracks": [T1], "staged_items": []}},
    ],
)
def test_the_same_operation_with_another_body_is_a_conflict(env, change):
    staged = env.ready()
    _, data = env.commit(staged)
    [journal] = env.journals()

    r = env.client.post(f"/tracks/uploads/items/{staged['item_uuid']}/commit", json={**data, **change})

    assert (r.status_code, _error(r)) == (409, "operation_conflict"), r.text
    assert r.json()["detail"]["retryable"] is False
    assert env.journals() == [journal]


def test_the_same_operation_on_another_item_is_a_conflict(env):
    first, second = env.ready(), env.ready()
    _, data = env.commit(first)

    r = env.client.post(f"/tracks/uploads/items/{second['item_uuid']}/commit", json=data)

    assert (r.status_code, _error(r)) == (409, "operation_conflict"), r.text
    assert item_row(env.db, second)["state"] == "review_ready"
    assert len(env.journals()) == 1


def test_a_stale_review_version_is_refused_and_stores_no_receipt(env):
    staged = env.ready()
    sql(env.db, "UPDATE upload_items SET review_version = 2 WHERE item_uuid = ?", (staged["item_uuid"],))

    r, data = env.commit(staged, base_review_version=1)

    assert (r.status_code, _error(r)) == (409, "upload_review_version_conflict"), r.text
    assert r.json()["detail"]["review_version"] == 2
    assert item_row(env.db, staged)["state"] == "review_ready"
    assert env.journals() == [] and env.receipts() == []
    # The refusal stored nothing, so the same operation with the current version is accepted.
    ok = env.client.post(f"/tracks/uploads/items/{staged['item_uuid']}/commit",
                         json={**data, "base_review_version": 2})
    assert ok.status_code == 202, ok.text


@pytest.mark.parametrize("state", ["validating", "failed", "duplicate_conflict", "cancelled", "allocated"])
def test_only_a_review_ready_item_can_be_committed(env, state):
    staged = env.ready()
    sql(env.db, "UPDATE upload_items SET state = ?, error_code = 'x' WHERE item_uuid = ?",
        (state, staged["item_uuid"]))

    r, _ = env.commit(staged)

    assert (r.status_code, _error(r)) == (409, "upload_item_not_committable"), r.text
    assert r.json()["detail"]["state"] == state
    assert env.journals() == [] and env.receipts() == []


def test_a_second_operation_on_a_committing_item_is_refused(env):
    staged = env.ready()
    assert env.commit(staged)[0].status_code == 202

    r, _ = env.commit(staged)

    assert (r.status_code, _error(r)) == (409, "upload_item_not_committable"), r.text
    assert r.json()["detail"]["state"] == "committing"
    assert len(env.journals()) == 1


# ── tag-write support (D16/O10) ─────────────────────────────────────────────

def test_writing_tags_to_a_wav_is_refused_before_acceptance(env):
    staged = env.ready(WAV)

    r, data = env.commit(staged, write_tags=True, edits={"title": "New"})

    assert (r.status_code, _error(r)) == (422, "tag_write_unsupported"), r.text
    assert r.json()["detail"]["retryable"] is True
    assert item_row(env.db, staged)["state"] == "review_ready"
    assert env.journals() == [] and env.receipts() == []
    # The change of choice: the same operation without the tag write is accepted.
    ok = env.client.post(f"/tracks/uploads/items/{staged['item_uuid']}/commit",
                         json={**data, "write_tags": False})
    assert ok.status_code == 202, ok.text
    assert env.journals()[0]["write_tags"] == 0
    assert env.journals()[0]["work_path"].endswith(".wav")


def test_a_wav_commit_without_tags_is_accepted(env):
    staged = env.ready(WAV)
    r, _ = env.commit(staged, edits={"title": "New"})
    assert r.status_code == 202, r.text


# ── unknown, foreign and malformed (SC-28, SC-16b, SC-22) ───────────────────

def test_a_foreign_item_answers_exactly_like_an_unknown_one(env):
    sam = add_test_user(env.db, "sam")
    theirs = env.ready(owner_id=sam)

    foreign, _ = env.commit(theirs)
    unknown, _ = env.commit(UNKNOWN)

    assert (foreign.status_code, unknown.status_code) == (404, 404), foreign.text
    assert foreign.json() == unknown.json()
    assert _error(foreign) == "upload_item_not_found"
    assert item_row(env.db, theirs)["state"] == "review_ready"
    assert env.journals() == [] and env.receipts() == []


def test_a_foreign_track_in_the_acknowledgements_answers_like_an_unknown_one(env):
    sam = add_test_user(env.db, "sam")
    from tests.identity_worker_fixtures import add_track

    their_track = add_track(env.db, env.root.parent / "sam" / "x.flac", owner_id=sam)
    one, two = env.ready(content=b"one"), env.ready(content=b"two")

    a, _ = env.commit(one, acknowledged_duplicates={"library_tracks": [their_track], "staged_items": []})
    b, _ = env.commit(two, acknowledged_duplicates={"library_tracks": [UNKNOWN], "staged_items": []})

    assert (a.status_code, b.status_code) == (202, 202), a.text
    strip = lambda item: {k: v for k, v in item.items() if k not in ("item_uuid", "batch_uuid", "filename",
                                                                       "selection_index", "expected_sha256",
                                                                       "expected_bytes", "received_bytes",
                                                                       "duplicate_check")}
    assert strip(a.json()) == strip(b.json())


def test_a_body_over_the_bound_is_413(env):
    staged = env.ready()
    r, _ = env.commit(staged, raw=b"{" + b" " * (300 * 1024) + b"}")
    assert r.status_code == 413
    assert env.journals() == []


def test_a_malformed_body_is_422_without_echoing_it(env):
    staged = env.ready()
    r, _ = env.commit(staged, edits={"title": "secret-title", "year": 123456})
    assert r.status_code == 422
    assert "secret-title" not in r.text and "123456" not in r.text
    assert env.journals() == []


def test_an_accepted_commit_can_no_longer_be_cancelled(env):
    staged = env.ready()
    assert env.commit(staged)[0].status_code == 202

    r = env.client.delete(f"/tracks/uploads/items/{staged['item_uuid']}")

    assert (r.status_code, _error(r)) == (409, "upload_item_not_cancellable"), r.text
    assert item_row(env.db, staged)["state"] == "committing"
    assert staged["source"].exists()
