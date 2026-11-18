"""Piece 8A.3a (spec §5 "Reader and mutation coordination", O3, O9):
``Database.is_pending_deletion`` tells "the owner's track exists but is not
live" (a pending deletion) apart from live, tombstoned, unknown and foreign
tracks, through ``live_tracks`` alone."""

import pytest

from app.database import DatabaseContext
from app.library import Library
from app.models import Track, TrackMetaData
from app.services.deletion_errors import TRACK_PENDING_DELETION, track_pending_deletion_error
from tests.owned_database import OwnedTestDatabase, add_test_user
from tests.pending_deletion import clear_pending_deletion, mark_pending_deletion
from tests.schema_fixtures import INIT_SQL


@pytest.fixture
def db(tmp_path):
    database = OwnedTestDatabase(
        DatabaseContext(database_path=tmp_path / "db.sqlite", init_sql_path=INIT_SQL)
    )
    assert database.initialize()
    return database


def _add(db, title, *, owner_id=None):
    track = Track(
        file_path=f"/music/{title}.flac",
        metadata=TrackMetaData(title=title, artist="A", album="B", codec="flac", duration=1.0),
    )
    kwargs = {} if owner_id is None else {"owner_id": owner_id}
    assert db.add_track(track=track, **kwargs)
    return track.uuid_id


def test_a_live_track_is_not_pending(db):
    uuid_id = _add(db, "live")

    assert db.is_pending_deletion(uuid_id) is False


def test_a_marked_track_is_pending_and_a_rollback_makes_it_live_again(db):
    uuid_id = _add(db, "marked")
    mark_pending_deletion(db.context.database_path, uuid_id)

    assert db.is_pending_deletion(uuid_id) is True

    clear_pending_deletion(db.context.database_path, uuid_id)
    assert db.is_pending_deletion(uuid_id) is False


def test_the_marker_touches_only_its_own_track(db):
    marked = _add(db, "marked")
    other = _add(db, "other")
    mark_pending_deletion(db.context.database_path, marked)

    assert db.is_pending_deletion(other) is False


def test_unknown_and_tombstoned_tracks_are_not_pending(db):
    gone = _add(db, "gone")
    assert db.delete_track(gone)

    assert db.is_pending_deletion(gone) is False
    assert db.is_pending_deletion("00000000-0000-4000-8000-000000000000") is False


def test_another_owners_pending_track_is_not_pending_for_me(db):
    sam = add_test_user(db, "sam")
    theirs = _add(db, "theirs", owner_id=sam)
    mark_pending_deletion(db.context.database_path, theirs)

    assert db.is_pending_deletion(theirs) is False
    assert db.is_pending_deletion(theirs, owner_id=sam) is True


def test_a_library_exposes_the_predicate_bound_to_its_owner(db):
    uuid_id = _add(db, "mine")
    mark_pending_deletion(db.context.database_path, uuid_id)

    assert Library(db, db.owner_id).is_pending_deletion(uuid_id) is True


def test_the_pending_deletion_error_uses_the_shared_envelope():
    exc = track_pending_deletion_error(410)

    assert TRACK_PENDING_DELETION == "track_pending_deletion"
    assert exc.status_code == 410
    assert exc.detail["error"] == "track_pending_deletion"
    assert exc.detail["retryable"] is True
    assert "/" not in exc.detail["message"]
