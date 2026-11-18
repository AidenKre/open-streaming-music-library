"""7A.3a S2 (spec §4 commit row: "`{operation_uuid, base_review_version, edits,
write_tags, acknowledged_duplicates}`, where `acknowledged_duplicates` is
`{library_tracks: [uuid…], staged_items: [item_uuid…]}` ... canonicalized as
sorted sets in the SC-16c request hash ... edits validated against shared
editable fields"; §4: "Missing edit means unchanged; explicit null clears";
plan D16: "`edits` validated by a staged model sharing
`EDIT_FIELD_SPECS`/`TrackPatchRequest` field rules (no `base_revision`/
`write_mode`)" and "Item DTO gets `tag_write_supported: bool` (from the probed
codec through the same `is_wav` rule)"; 7A.1c review #4: the hashed model
carries the path's item uuid; review 7-U05 "metadata pure validation")."""

import json
import uuid

import pytest
from pydantic import ValidationError

from app.database.operation_receipts import request_hash
from app.models.edit_fields import EDIT_FIELD_SPECS
from app.models.uploads import CommitOperation, CommitRequest, StagedEdits
from app.services.upload_commit import tag_write_supported, validated_extension
from tests.upload_validation_fixtures import FakeProbe, detected, make_worker, stage_item

OP = "11111111-1111-4111-8111-111111111111"
ITEM = "22222222-2222-4222-8222-222222222222"
OTHER_ITEM = "33333333-3333-4333-8333-333333333333"
T1 = "aaaaaaaa-0000-4000-8000-000000000001"
T2 = "aaaaaaaa-0000-4000-8000-000000000002"
S1 = "bbbbbbbb-0000-4000-8000-000000000001"


def body(**overrides):
    data = {
        "operation_uuid": OP,
        "base_review_version": 0,
        "edits": {},
        "write_tags": False,
        "acknowledged_duplicates": {"library_tracks": [], "staged_items": []},
    }
    data.update(overrides)
    return data


def parse(data) -> CommitRequest:
    return CommitRequest.model_validate_json(json.dumps(data))


def hashed(data, item=ITEM) -> str:
    return request_hash(CommitOperation(item_uuid=item, request=parse(data)))


# ── the request model ───────────────────────────────────────────────────────

def test_a_skip_commit_parses():
    request = parse(body())
    assert request.write_tags is False
    assert request.edits.edit_fields() == {}
    assert request.acknowledged_duplicates.library_tracks == frozenset()


@pytest.mark.parametrize(
    "field", ["operation_uuid", "base_review_version", "edits", "write_tags", "acknowledged_duplicates"]
)
def test_every_top_level_field_is_required(field):
    data = body()
    del data[field]
    with pytest.raises(ValidationError):
        parse(data)


@pytest.mark.parametrize("field", ["library_tracks", "staged_items"])
def test_both_acknowledgement_sets_are_required(field):
    acks = {"library_tracks": [], "staged_items": []}
    del acks[field]
    with pytest.raises(ValidationError):
        parse(body(acknowledged_duplicates=acks))


@pytest.mark.parametrize(
    "overrides",
    [
        {"extra": 1},
        {"base_review_version": -1},
        {"base_review_version": "1"},
        {"base_review_version": 1.5},
        {"write_tags": "true"},
        {"write_tags": 1},
        {"operation_uuid": "not-a-uuid"},
        {"edits": {"base_revision": 3}},
        {"edits": {"write_mode": "db_only"}},
        {"edits": {"codec": "flac"}},
        {"edits": {"year": 10000}},
        {"edits": {"year": -1}},
        {"edits": {"track_number": -1}},
        {"edits": {"disc_number": -2}},
        {"acknowledged_duplicates": {"library_tracks": ["nope"], "staged_items": []}},
        {"acknowledged_duplicates": {"library_tracks": [], "staged_items": [], "other": []}},
        {"edits": []},
    ],
)
def test_an_invalid_commit_body_is_rejected(overrides):
    with pytest.raises(ValidationError):
        parse(body(**overrides))


def test_the_staged_edits_accept_exactly_the_shared_editable_fields():
    assert set(StagedEdits.model_fields) == {spec.key for spec in EDIT_FIELD_SPECS}


def test_a_missing_edit_is_untouched_and_an_explicit_null_clears():
    request = parse(body(edits={"title": "New", "album": None, "year": 1997}))
    assert request.edits.edit_fields() == {"title": "New", "album": None, "year": 1997}


def test_acknowledgements_are_sets():
    request = parse(body(acknowledged_duplicates={"library_tracks": [T2, T1, T2], "staged_items": [S1]}))
    assert request.acknowledged_duplicates.library_tracks == frozenset({uuid.UUID(T1), uuid.UUID(T2)})
    assert request.acknowledged_duplicates.staged_items == frozenset({uuid.UUID(S1)})


# ── the receipt hash (SC-16c) ───────────────────────────────────────────────

def test_the_hash_ignores_acknowledgement_order_and_repeats():
    a = body(acknowledged_duplicates={"library_tracks": [T1, T2], "staged_items": [S1]})
    b = body(acknowledged_duplicates={"library_tracks": [T2, T1, T1], "staged_items": [S1]})
    assert hashed(a) == hashed(b)


def test_the_hash_binds_the_path_item():
    assert hashed(body(), item=ITEM) != hashed(body(), item=OTHER_ITEM)


@pytest.mark.parametrize(
    "other",
    [
        body(edits={"title": None}),
        body(edits={"title": "x"}),
        body(write_tags=True),
        body(base_review_version=1),
        body(acknowledged_duplicates={"library_tracks": [T1], "staged_items": []}),
        body(acknowledged_duplicates={"library_tracks": [], "staged_items": [T1]}),
    ],
)
def test_every_choice_changes_the_hash(other):
    assert hashed(other) != hashed(body())


def test_an_explicit_null_edit_hashes_unlike_an_absent_one():
    assert hashed(body(edits={"genre": None})) != hashed(body(edits={}))


# ── the validated extension and tag-write support (D16, O10) ────────────────

@pytest.mark.parametrize(
    "container, codec, ext, supported",
    [
        ("flac", "flac", ".flac", True),
        ("mp3", "mp3", ".mp3", True),
        ("mov,mp4,m4a,3gp,3g2,mj2", "aac", ".m4a", True),
        ("mov,mp4,m4a,3gp,3g2,mj2", "alac", ".m4a", True),
        ("wav", "pcm_s16le", ".wav", False),
        ("wav", "pcm_f32le", ".wav", False),
    ],
)
def test_the_probed_container_gives_the_extension_and_tag_support(container, codec, ext, supported):
    meta = detected(codec=codec, container=container)
    assert validated_extension(meta) == ext
    assert tag_write_supported(meta) is supported


def test_before_validation_tag_support_is_unknown():
    assert validated_extension(None) is None
    assert tag_write_supported(None) is None


def test_an_unknown_container_has_no_extension_and_unknown_support():
    meta = detected(codec="vorbis", container="ogg")
    assert validated_extension(meta) is None
    assert tag_write_supported(meta) is None


# ── the item DTO ────────────────────────────────────────────────────────────

NOW = 1_700_000_000


@pytest.fixture
def client(app_client):
    from app.routers.uploads import upload_clock

    app_client.app.dependency_overrides[upload_clock] = lambda: NOW
    return app_client


def _validated(client, meta):
    db = client.app.state.database
    root = client.app.state.upload_receipt.uploads_root
    root.mkdir(parents=True, exist_ok=True)
    staged = stage_item(db, root, owner_id=client.app.state.admin_user_id)
    if meta is not None:
        assert make_worker(db, root, probe=FakeProbe(meta)).process_one() == "review_ready"
    return client.get(f"/tracks/uploads/items/{staged['item_uuid']}").json()


def test_the_item_says_a_flac_can_take_tags(client):
    assert _validated(client, detected())["tag_write_supported"] is True


def test_the_item_says_a_wav_cannot_take_tags(client):
    meta = detected(codec="pcm_s16le", container="wav", mime="audio/wav")
    assert _validated(client, meta)["tag_write_supported"] is False


def test_an_item_not_yet_validated_has_unknown_tag_support(client):
    item = _validated(client, None)
    assert item["state"] == "validating"
    assert item["tag_write_supported"] is None
