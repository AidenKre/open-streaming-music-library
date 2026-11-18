"""7A.3b S1: ``Database.upload_commit_preflight`` (spec 6 step 3: the exact layer
of ``find_duplicates`` for the committing owner, uncapped, digest-bearing
``pending`` rows included; a match is acknowledged by the frozen library list,
by a listed staged item that published it, or symmetrically by the publishing
item's persisted acknowledgements; fingerprints are never enforced; SC-28:
foreign uuids acknowledge nothing)."""

import pytest

from app.services.audio_identity import AudioIdentity, identity_to_columns
from tests.identity_worker_fixtures import make_db, sql
from tests.owned_database import add_test_user
from tests.upload_publish_fixtures import import_item, library_track, prepared_commit
from tests.upload_validation_fixtures import exact_for, new_uuid, print_of

TABLES = ("upload_commit_journal", "upload_items", "upload_item_acknowledgements",
          "track_duplicate_candidates")


@pytest.fixture
def db(tmp_path):
    return make_db(tmp_path)


@pytest.fixture
def music(tmp_path):
    path = tmp_path / "music"
    (path / ".uploads").mkdir(parents=True)
    return path


def preflight(db, commit):
    return db.upload_commit_preflight(owner_id=commit["owner_id"], operation_uuid=commit["op"])


def test_no_library_match_is_empty(db, music):
    library_track(db, music, b"other-audio")
    assert preflight(db, prepared_commit(db, music)) == []


def test_one_unacknowledged_match(db, music):
    t = library_track(db, music)
    assert preflight(db, prepared_commit(db, music)) == [t]


def test_directly_acknowledged_library_track(db, music):
    t = library_track(db, music)
    assert preflight(db, prepared_commit(db, music, acks={"library_tracks": [t]})) == []


def test_staged_item_acknowledges_only_when_imported_with_that_result(db, music):
    t = library_track(db, music)
    published = import_item(db, music, t)
    assert preflight(db, prepared_commit(db, music, acks={"staged_items": [published["item_uuid"]]})) == []


def test_listed_staged_item_not_imported_acknowledges_nothing(db, music):
    t = library_track(db, music)
    pending = import_item(db, music, t, state="review_ready")
    assert preflight(db, prepared_commit(db, music, acks={"staged_items": [pending["item_uuid"]]})) == [t]


def test_imported_staged_item_with_another_result_acknowledges_nothing(db, music):
    t = library_track(db, music)
    other = library_track(db, music, b"different")
    published = import_item(db, music, other)
    assert preflight(db, prepared_commit(db, music, acks={"staged_items": [published["item_uuid"]]})) == [t]


def test_symmetric_acknowledgement_lists_this_item(db, music):
    t = library_track(db, music)
    commit = prepared_commit(db, music)
    import_item(db, music, t, acks_for=(commit["item_uuid"],))
    assert preflight(db, commit) == []


def test_symmetric_acknowledgement_listing_another_item_does_not_count(db, music):
    t = library_track(db, music)
    commit = prepared_commit(db, music)
    import_item(db, music, t, acks_for=(new_uuid(),))
    assert preflight(db, commit) == [t]


def test_symmetric_rows_of_an_item_that_did_not_publish_do_not_count(db, music):
    t = library_track(db, music)
    commit = prepared_commit(db, music)
    import_item(db, music, t, state="review_ready", acks_for=(commit["item_uuid"],))
    assert preflight(db, commit) == [t]


def test_mixed_rules_leave_only_the_unacknowledged_track(db, music):
    direct, staged_t, sym_t, open_t = (library_track(db, music) for _ in range(4))
    published = import_item(db, music, staged_t)
    commit = prepared_commit(db, music, acks={"library_tracks": [direct],
                                              "staged_items": [published["item_uuid"]]})
    import_item(db, music, sym_t, acks_for=(commit["item_uuid"],))
    assert preflight(db, commit) == [open_t]


def test_stale_pending_row_with_digest_still_matches(db, music):
    t = library_track(db, music, exact_state="pending")
    assert preflight(db, prepared_commit(db, music)) == [t]


def test_pending_without_digest_and_missing_identity_do_not_match(db, music):
    library_track(db, music, exact_state="pending", digest=None)
    library_track(db, music, identity={"_none": True})
    assert preflight(db, prepared_commit(db, music)) == []


def test_fingerprint_only_match_is_never_returned(db, music):
    print_identity = AudioIdentity(exact=exact_for(b"audio-A"), fingerprint=print_of(),
                                   tool_versions="ffmpeg 8.1", computed_at=1700)
    commit = prepared_commit(db, music, identity=print_identity)
    cols = identity_to_columns(print_identity)
    t = library_track(db, music, b"different-audio", identity={"fp_state": "current"})
    sql(db, "INSERT INTO track_audio_fingerprint (uuid_id, backend, algorithm, duration_s, item_count, data)"
            " VALUES (?, ?, ?, ?, ?, ?)",
        (t, cols["fp_backend"], cols["fp_algorithm"], cols["fp_duration_s"], cols["fp_item_count"],
         cols["fp_data"]))
    assert preflight(db, commit) == []


def test_matches_are_uncapped(db, music):
    tracks = sorted(library_track(db, music) for _ in range(6))
    assert preflight(db, prepared_commit(db, music)) == tracks
    assert preflight(db, prepared_commit(db, music, acks={"library_tracks": tracks})) == []


def test_two_users_identical_audio_is_never_paired(db, music):
    other = add_test_user(db, "bob")
    library_track(db, music, owner_id=other)
    assert preflight(db, prepared_commit(db, music)) == []


def test_foreign_acknowledgements_acknowledge_nothing(db, music):
    other = add_test_user(db, "bob")
    mine = library_track(db, music)
    theirs = library_track(db, music, owner_id=other)
    their_item = import_item(db, music, theirs, owner_id=other)
    commit = prepared_commit(db, music, acks={"library_tracks": [theirs, new_uuid()],
                                              "staged_items": [their_item["item_uuid"], new_uuid()]})
    assert preflight(db, commit) == [mine]


def test_foreign_item_acknowledgement_rows_do_not_acknowledge_my_match(db, music):
    other = add_test_user(db, "bob")
    mine = library_track(db, music)
    commit = prepared_commit(db, music)
    # Bob's item imported Bob's track and lists Alice's item uuid; also a row claiming Alice's track.
    theirs = library_track(db, music, owner_id=other)
    import_item(db, music, theirs, owner_id=other, acks_for=(commit["item_uuid"],))
    assert preflight(db, commit) == [mine]


def test_foreign_item_claiming_my_track_uuid_does_not_acknowledge_it(db, music):
    other = add_test_user(db, "bob")
    mine = library_track(db, music)
    foreign_item = import_item(db, music, mine, owner_id=other)  # Bob's item "published" Alice's uuid
    commit = prepared_commit(db, music, acks={"staged_items": [foreign_item["item_uuid"]]})
    assert preflight(db, commit) == [mine]
    commit2 = prepared_commit(db, music)
    sql(db, "UPDATE upload_items SET result_track_uuid = ? WHERE owner_id = ? AND item_uuid = ?",
        (mine, other, foreign_item["item_uuid"]))
    sql(db, "INSERT INTO upload_item_acknowledgements VALUES (?, ?, 'staged_item', ?)",
        (other, foreign_item["item_uuid"], commit2["item_uuid"]))
    assert preflight(db, commit2) == [mine]


def test_unknown_unrelated_acknowledgements_change_nothing(db, music):
    t = library_track(db, music)
    commit = prepared_commit(db, music, acks={"library_tracks": [new_uuid()], "staged_items": [new_uuid()]})
    assert preflight(db, commit) == [t]


def test_none_for_unknown_foreign_and_unprepared_operations(db, music):
    library_track(db, music)
    other = add_test_user(db, "bob")
    commit = prepared_commit(db, music)
    assert db.upload_commit_preflight(owner_id=commit["owner_id"], operation_uuid=new_uuid()) is None
    assert db.upload_commit_preflight(owner_id=other, operation_uuid=commit["op"]) is None
    for state in ("committing", "moved", "imported", "duplicate_conflict", "failed"):
        assert preflight(db, prepared_commit(db, music, state=state)) is None


def test_preflight_writes_nothing(db, music):
    t = library_track(db, music)
    commit = prepared_commit(db, music)
    before = {name: sql(db, f"SELECT * FROM {name} ORDER BY 1, 2") for name in TABLES}
    assert preflight(db, commit) == [t]
    assert {name: sql(db, f"SELECT * FROM {name} ORDER BY 1, 2") for name in TABLES} == before
