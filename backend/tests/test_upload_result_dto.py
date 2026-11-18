"""7A.3b S7 (spec §3: ``duplicate`` "carries the chosen existing track and
whether the match was exact or fingerprint"; ``imported`` carries the result
track and revision; ``duplicate_conflict`` "retain[s] the matching track
identities"): the item DTO gains ``result_track_uuid``, ``result_revision``,
``duplicate_kind`` and ``conflict_matches`` (non-null only while the item is
``duplicate_conflict``; same shape as a ``duplicate_check.matches`` entry,
built through the caller's library so a track the caller cannot see reads
``available: false``)."""

import json
import uuid

import pytest

from tests.identity_worker_fixtures import add_track, sql
from tests.owned_database import add_test_user
from tests.upload_validation_fixtures import stage_item

NOW = 1_700_000_000
NEW_FIELDS = ("result_track_uuid", "result_revision", "duplicate_kind", "conflict_matches")
UNKNOWN = "00000000-0000-4000-8000-0000000000ff"


@pytest.fixture
def client(app_client):
    from app.routers.uploads import upload_clock

    app_client.app.dependency_overrides[upload_clock] = lambda: NOW
    return app_client


class Env:
    def __init__(self, client):
        self.client = client
        self.db = client.app.state.database
        self.admin = client.app.state.admin_user_id
        self.root = client.app.state.upload_receipt.uploads_root
        self.root.mkdir(parents=True, exist_ok=True)

    def item(self, state="review_ready", **columns):
        staged = stage_item(self.db, self.root, owner_id=self.admin, state="review_ready")
        if state != "review_ready" or columns:
            names = ["state", *columns]
            sql(self.db, "UPDATE upload_items SET " + ", ".join(f"{n} = ?" for n in names)
                         + " WHERE owner_id = ? AND item_uuid = ?",
                (state, *columns.values(), self.admin, staged["item_uuid"]))
        return staged

    def track(self, title="Airbag", owner_id=None):
        track = add_track(self.db, self.root.parent / f"{uuid.uuid4()}.flac", owner_id=owner_id or self.admin)
        sql(self.db, "UPDATE trackmetadata SET title = ?, artist = 'Radiohead', album = 'OK Computer',"
                     " codec = 'flac', bitrate_kbps = 900.0, sample_rate_hz = 44100, duration = 12.5"
                     " WHERE uuid_id = ?", (title, track))
        return track

    def get(self, staged):
        r = self.client.get(f"/tracks/uploads/items/{staged['item_uuid']}")
        assert r.status_code == 200, r.text
        return r.json()


@pytest.fixture
def env(client):
    return Env(client)


def entry(track_uuid, *, available, summary):
    return {"subject_kind": "library_track", "track_uuid": track_uuid, "item_uuid": None, "kind": "exact",
            "band": "exact", "score": None, "available": available, "track": summary, "staged_item": None}


def test_an_imported_item_carries_its_result_track_and_revision(env):
    track = env.track()
    staged = env.item("imported", result_track_uuid=track, result_revision=7)

    body = env.get(staged)

    assert body["state"] == "imported"
    assert (body["result_track_uuid"], body["result_revision"]) == (track, 7)
    assert (body["duplicate_kind"], body["conflict_matches"]) == (None, None)


def test_a_duplicate_item_carries_the_chosen_track_and_kind(env):
    track = env.track()
    staged = env.item("duplicate", result_track_uuid=track, duplicate_kind="fingerprint")

    body = env.get(staged)

    assert body["state"] == "duplicate"
    assert (body["result_track_uuid"], body["duplicate_kind"]) == (track, "fingerprint")
    assert (body["result_revision"], body["conflict_matches"]) == (None, None)


def test_a_duplicate_conflict_lists_its_retained_matches_in_stored_order(env):
    own = env.track("Airbag")
    gone = str(uuid.uuid4())
    staged = env.item("duplicate_conflict", conflict_track_uuids=json.dumps([own, gone]))

    body = env.get(staged)

    assert body["conflict_matches"] == [
        entry(own, available=True, summary={
            "title": "Airbag", "artist": "Radiohead", "album": "OK Computer", "codec": "flac",
            "bitrate_kbps": 900.0, "sample_rate_hz": 44100, "duration_s": 12.5}),
        entry(gone, available=False, summary=None),
    ]
    assert (body["result_track_uuid"], body["result_revision"], body["duplicate_kind"]) == (None, None, None)


def test_a_conflict_match_the_caller_cannot_see_reads_unavailable(env):
    other = add_test_user(env.db, "bob")
    theirs = env.track("Secret", owner_id=other)
    staged = env.item("duplicate_conflict", conflict_track_uuids=json.dumps([theirs]))

    body = env.get(staged)

    assert body["conflict_matches"] == [entry(theirs, available=False, summary=None)]
    assert "Secret" not in json.dumps(body)


def test_a_stale_conflict_value_on_a_review_ready_item_is_not_reported(env):
    own = env.track()
    staged = env.item("review_ready", conflict_track_uuids=json.dumps([own]))

    body = env.get(staged)

    assert body["state"] == "review_ready"
    assert body["conflict_matches"] is None


def test_a_fresh_item_has_all_four_fields_null(env):
    staged = env.item("allocated")

    body = env.get(staged)

    assert {k: body[k] for k in NEW_FIELDS} == dict.fromkeys(NEW_FIELDS)


def test_the_items_page_carries_the_same_fields(env):
    own = env.track()
    staged = env.item("duplicate_conflict", conflict_track_uuids=json.dumps([own]))

    r = env.client.get(f"/tracks/uploads/{staged['batch_uuid']}/items")

    assert r.status_code == 200, r.text
    [item] = r.json()["items"]
    assert [m["track_uuid"] for m in item["conflict_matches"]] == [own]
    assert all(k in item for k in NEW_FIELDS)
