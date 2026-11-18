"""7A.2c S5 (spec §4 `GET item`: "detected metadata ... and `duplicate_check`
(SC-25 `DuplicateReport`: per-layer `LayerCoverage` ..., ranked matches with
track summaries — title, artist, album, codec, bitrate, sample rate, duration
— or staged item UUID/filename). `duplicate_check` is null until validation
finishes ... an empty list means "none found" only under the SC-25 coverage
rule. ... The paged items endpoint returns the same field."; plan D13, O8:
refs are stored, summaries are looked up when read; a track deleted meanwhile
shows as unavailable)."""

import json

import pytest

from app.library import Library
from app.models import Track, TrackMetaData
from tests.fingerprint_fixtures import random_print
from tests.identity_worker_fixtures import sql
from tests.owned_database import add_test_user
from tests.pending_deletion import mark_pending_deletion
from tests.upload_validation_fixtures import (
    FINGERPRINTER,
    FakeCompute,
    detected,
    exact_for,
    make_worker,
    print_of,
    stage_item,
)

NOW = 1_700_000_000
EMPTY = {"library_pending": 0, "library_failed": 0, "library_not_comparable": 0}


@pytest.fixture
def client(app_client):
    from app.routers.uploads import upload_clock

    app_client.app.dependency_overrides[upload_clock] = lambda: NOW
    return app_client


class Env:
    def __init__(self, client, tmp_path):
        self.client = client
        self.db = client.app.state.database
        self.admin = client.app.state.admin_user_id
        self.root = client.app.state.upload_receipt.uploads_root
        self.root.mkdir(parents=True, exist_ok=True)
        self.tmp_path = tmp_path
        self.compute = FakeCompute()

    def stage(self, **kwargs):
        kwargs.setdefault("owner_id", self.admin)
        return stage_item(self.db, self.root, **kwargs)

    def validate(self, *, fingerprinter=None, runs=1):
        worker = make_worker(self.db, self.root, compute=self.compute, fingerprinter=fingerprinter)
        for _ in range(runs):
            worker.process_one()

    def get(self, staged):
        response = self.client.get(f"/tracks/uploads/items/{staged['item_uuid']}")
        assert response.status_code == 200, response.text
        return response.json()

    def track(self, content: bytes, *, owner_id=None, title="Airbag"):
        """A library track whose exact identity equals the staged ``content``'s."""
        owner = owner_id or self.admin
        path = self.tmp_path / "music" / f"{title}-{owner}.flac"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"x")
        track = Track(file_path=path, metadata=TrackMetaData(
            title=title, artist="Radiohead", album="OK Computer", codec="flac", duration=287.5,
            bitrate_kbps=920.0, sample_rate_hz=48000, channels=2,
        ))
        assert Library(self.db, owner).add_track(track)
        exact = exact_for(content)
        sql(self.db, "DELETE FROM track_audio_identity WHERE uuid_id = ?", (track.uuid_id,))
        sql(self.db, "INSERT INTO track_audio_identity (uuid_id, generation, exact_state, exact_kind, "
                     "exact_digest, sample_rate_hz, channels, bits_per_sample, fp_state, match_state, priority) "
                     "VALUES (?, 1, 'current', ?, ?, ?, ?, ?, 'unavailable', 'current', 1)",
            (track.uuid_id, exact.kind, exact.digest, exact.sample_rate_hz, exact.channels, exact.bits_per_sample))
        return track.uuid_id


@pytest.fixture
def env(client, tmp_path):
    return Env(client, tmp_path)


def test_before_validation_both_fields_are_null(env):
    staged = env.stage()

    item = env.get(staged)

    assert item["state"] == "validating"
    assert (item["detected_metadata"], item["duplicate_check"]) == (None, None)


def test_after_validation_the_item_carries_its_detected_metadata(env):
    staged = env.stage()
    env.validate()

    assert env.get(staged)["detected_metadata"] == detected()


def test_a_library_match_carries_the_tracks_summary(env):
    track = env.track(b"audio-A")
    staged = env.stage(content=b"audio-A")
    env.validate()

    check = env.get(staged)["duplicate_check"]

    assert check == {
        "version": 1,
        "status": "complete",
        "no_duplicates_found": False,
        "exact": {"subject_state": "current", **EMPTY},
        # The track was never fingerprinted: unknown on that layer, counted.
        "fingerprint": {"subject_state": "unavailable", **EMPTY, "library_pending": 1},
        "matches": [{
            "subject_kind": "library_track", "track_uuid": track, "item_uuid": None,
            "kind": "exact", "band": "exact", "score": None, "available": True,
            "track": {"title": "Airbag", "artist": "Radiohead", "album": "OK Computer", "codec": "flac",
                      "bitrate_kbps": 920.0, "sample_rate_hz": 48000, "duration_s": 287.5},
            "staged_item": None,
        }],
    }


def test_a_staged_match_carries_the_other_items_name_and_batch(env):
    first = env.stage(content=b"same", filename="other.flac", batch_created_at=1234, progress_at=1)
    later = env.stage(content=b"same", progress_at=2)
    env.validate(runs=2)

    [match] = env.get(later)["duplicate_check"]["matches"]

    assert match == {
        "subject_kind": "staged_item", "track_uuid": None, "item_uuid": first["item_uuid"],
        "kind": "exact", "band": "exact", "score": None, "available": True, "track": None,
        "staged_item": {"filename": "other.flac", "batch_uuid": first["batch_uuid"], "batch_created_at": 1234},
    }


def test_no_duplicates_is_claimed_only_when_both_layers_were_fully_checked(env):
    staged = env.stage(content=b"a")
    env.compute.prints[b"a"] = print_of(random_print(3), 200.0)
    env.validate(fingerprinter=FINGERPRINTER)

    check = env.get(staged)["duplicate_check"]

    assert check["matches"] == []
    assert check["no_duplicates_found"] is True
    assert check["exact"]["subject_state"] == check["fingerprint"]["subject_state"] == "current"


def test_without_the_fingerprint_layer_an_empty_list_is_not_a_claim(env):
    staged = env.stage()
    env.validate(fingerprinter=None)

    check = env.get(staged)["duplicate_check"]

    assert check["matches"] == []
    assert check["no_duplicates_found"] is False
    assert check["fingerprint"]["subject_state"] == "unavailable"


def test_partial_library_coverage_is_counted_and_never_worded_as_none_found(env):
    pending = env.track(b"unrelated", title="Pending")
    sql(env.db, "UPDATE track_audio_identity SET exact_state = 'pending', exact_digest = NULL, "
                "exact_kind = NULL, fp_state = 'pending' WHERE uuid_id = ?", (pending,))
    staged = env.stage(content=b"a")
    env.compute.prints[b"a"] = print_of(random_print(3), 200.0)
    env.validate(fingerprinter=FINGERPRINTER)

    check = env.get(staged)["duplicate_check"]

    assert check["matches"] == []
    assert check["no_duplicates_found"] is False
    assert check["exact"]["library_pending"] == 1
    assert check["fingerprint"]["library_pending"] == 1


def test_a_track_deleted_after_validation_reads_as_unavailable(env):
    track = env.track(b"audio-A")
    staged = env.stage(content=b"audio-A")
    env.validate()
    assert Library(env.db, env.admin).delete_track(track)

    [match] = env.get(staged)["duplicate_check"]["matches"]

    assert (match["track_uuid"], match["available"], match["track"]) == (track, False, None)


def test_a_track_pending_deletion_reads_as_unavailable(env):
    """Review r1 8-R1-07: one liveness definition (live_tracks): a track whose
    deletion is pending is not offered as the library copy to keep."""
    track = env.track(b"audio-A")
    staged = env.stage(content=b"audio-A")
    env.validate()
    mark_pending_deletion(env.db.context.database_path, track)

    [match] = env.get(staged)["duplicate_check"]["matches"]

    assert (match["track_uuid"], match["available"], match["track"]) == (track, False, None)


def test_a_staged_item_gone_after_validation_reads_as_unavailable(env):
    first = env.stage(content=b"same", progress_at=1)
    later = env.stage(content=b"same", progress_at=2)
    env.validate(runs=2)
    sql(env.db, "DELETE FROM upload_items WHERE item_uuid = ?", (first["item_uuid"],))

    [match] = env.get(later)["duplicate_check"]["matches"]

    assert (match["item_uuid"], match["available"], match["staged_item"]) == (first["item_uuid"], False, None)


def test_a_failed_check_is_reported_failed_never_as_none_found(env):
    staged = env.stage()
    env.validate()
    sql(env.db, "UPDATE upload_items SET duplicate_report = ? WHERE item_uuid = ?", (json.dumps(
        {"v": 1, "status": "failed", "exact": None, "fingerprint": None, "matches": []}), staged["item_uuid"]))

    check = env.get(staged)["duplicate_check"]

    assert check == {"version": 1, "status": "failed", "no_duplicates_found": False,
                     "exact": None, "fingerprint": None, "matches": []}


def test_a_report_naming_another_users_data_reveals_nothing(env):
    # Defence in depth: even a stored ref to another user's track or staged
    # item (which the worker never writes) is looked up as the caller's.
    sam = add_test_user(env.db, "sam")
    theirs = env.track(b"audio-A", owner_id=sam, title="Theirs")
    their_item = stage_item(env.db, env.root, owner_id=sam, filename="theirs.flac")
    staged = env.stage()
    env.validate(runs=2)
    report = {"v": 1, "status": "complete",
              "exact": {"subject_state": "current", **EMPTY}, "fingerprint": {"subject_state": "unavailable", **EMPTY},
              "matches": [{"ref": "library_track", "id": theirs, "kind": "exact", "band": "exact", "score": None},
                          {"ref": "staged_item", "id": their_item["item_uuid"], "kind": "exact", "band": "exact",
                           "score": None}]}
    sql(env.db, "UPDATE upload_items SET duplicate_report = ? WHERE owner_id = ? AND item_uuid = ?",
        (json.dumps(report), env.admin, staged["item_uuid"]))

    body = env.client.get(f"/tracks/uploads/items/{staged['item_uuid']}").text

    assert "Theirs" not in body and "theirs.flac" not in body and their_item["batch_uuid"] not in body
    matches = json.loads(body)["duplicate_check"]["matches"]
    assert [(m["available"], m["track"], m["staged_item"]) for m in matches] == [(False, None, None)] * 2


def test_the_items_page_carries_the_same_fields(env):
    env.track(b"audio-A")
    staged = env.stage(content=b"audio-A")
    env.validate()

    page = env.client.get(f"/tracks/uploads/{staged['batch_uuid']}/items").json()

    [item] = page["items"]
    assert item["duplicate_check"] == env.get(staged)["duplicate_check"]
    assert item["detected_metadata"] == detected()
