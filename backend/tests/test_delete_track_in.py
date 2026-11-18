"""Phase 8A.3b (spec §5 step 4, SC-16a, plan D8/D9; review 8-U04): the
extracted in-transaction track delete.

``Database._delete_track_in(conn, uuid_id, *, owner_id) -> int`` runs inside
the caller's ``BEGIN IMMEDIATE``: it allocates the tombstone through
``_next_revision``, deletes metadata, track and FTS rows and prunes orphan
parents. It raises on failure and never opens or commits a transaction, so it
rolls back with its caller. An existing tombstone is never bumped again.

Every expected value is written out here or read with plain SQL, never derived
from the production statements.
"""

import sqlite3

import pytest

from app.database.database import Database, TrackAlreadyDeleted, TrackNotFound
from app.models.track import Track
from app.models.track_meta_data import TrackMetaData
from tests.pending_deletion import mark_pending_deletion
from tests.identity_worker_fixtures import make_db
from tests.owned_database import add_test_user


class Boom(Exception):
    pass


@pytest.fixture
def db(tmp_path):
    return make_db(tmp_path)


def add(db, tmp_path, uuid_id, title, artist, album, owner_id=None):
    metadata = TrackMetaData(
        codec="flac", duration=2.0, bitrate_kbps=900.0, sample_rate_hz=44100, channels=2,
    )
    metadata.title = title
    metadata.artist = artist
    metadata.album = album
    track = Track(file_path=tmp_path / f"{uuid_id}.flac", metadata=metadata)
    track.uuid_id = uuid_id
    kwargs = {} if owner_id is None else {"owner_id": owner_id}
    assert db.add_track(track=track, **kwargs)
    return uuid_id


def one(db, query, params=()):
    conn = sqlite3.connect(db.context.database_path)
    try:
        return conn.execute(query, params).fetchone()
    finally:
        conn.close()


def count(db, query, params=()):
    return one(db, query, params)[0]


def counter(db):
    return count(db, "SELECT value FROM revision_counter WHERE id = 0")


def fts(db, table, token):
    return count(db, f"SELECT count(*) FROM {table} WHERE {table} MATCH ?", (token,))


def track_present(db, uuid_id):
    return (
        count(db, "SELECT count(*) FROM tracks WHERE uuid_id = ?", (uuid_id,)),
        count(db, "SELECT count(*) FROM trackmetadata WHERE uuid_id = ?", (uuid_id,)),
    ) == (1, 1)


def tombstone(db, uuid_id):
    return one(
        db, "SELECT revision, owner_id, deleted_at FROM track_tombstones WHERE uuid_id = ?",
        (uuid_id,),
    )


def delete_in(db, uuid_id, owner_id=None):
    with db._connection(commit=True, immediate=True) as conn:
        return db._delete_track_in(
            conn, uuid_id, owner_id=db.owner_id if owner_id is None else owner_id
        )


@pytest.fixture
def library(db, tmp_path):
    """Lonely: the only track of its artist and album. Shared1/Shared2: one
    artist and one album between them."""
    add(db, tmp_path, "lonely", "Solitude", "Hermitband", "Islandrecord")
    add(db, tmp_path, "shared1", "Firstsong", "Crowdband", "Togetheralbum")
    add(db, tmp_path, "shared2", "Secondsong", "Crowdband", "Togetheralbum")
    return db


# --- the delete ------------------------------------------------------------------


def test_it_returns_the_new_tombstone_revision_and_removes_the_track(library):
    db = library
    before = counter(db)

    revision = delete_in(db, "lonely")

    assert revision == before + 1
    assert counter(db) == before + 1
    rev, owner, deleted_at = tombstone(db, "lonely")
    assert (rev, owner) == (revision, db.owner_id)
    assert deleted_at > 0
    assert not track_present(db, "lonely")
    assert track_present(db, "shared1") and track_present(db, "shared2")


def test_the_last_track_of_an_artist_and_album_takes_them_and_their_search_rows(library):
    db = library
    assert fts(db, "fts_tracks", "solitude") == 1
    assert fts(db, "fts_artists", "hermitband") == 1
    assert fts(db, "fts_albums", "islandrecord") == 1

    delete_in(db, "lonely")

    assert count(db, "SELECT count(*) FROM artists WHERE name = 'Hermitband'") == 0
    assert count(db, "SELECT count(*) FROM albums WHERE name = 'Islandrecord'") == 0
    assert fts(db, "fts_tracks", "solitude") == 0
    assert fts(db, "fts_artists", "hermitband") == 0
    assert fts(db, "fts_albums", "islandrecord") == 0


def test_a_shared_artist_and_album_stay_while_another_track_uses_them(library):
    db = library

    delete_in(db, "shared1")

    assert count(db, "SELECT count(*) FROM artists WHERE name = 'Crowdband'") == 1
    assert count(db, "SELECT count(*) FROM albums WHERE name = 'Togetheralbum'") == 1
    assert fts(db, "fts_tracks", "firstsong") == 0
    assert fts(db, "fts_tracks", "secondsong") == 1
    assert fts(db, "fts_artists", "crowdband") == 1
    assert fts(db, "fts_albums", "togetheralbum") == 1

    delete_in(db, "shared2")

    assert count(db, "SELECT count(*) FROM artists WHERE name = 'Crowdband'") == 0
    assert count(db, "SELECT count(*) FROM albums WHERE name = 'Togetheralbum'") == 0
    assert fts(db, "fts_artists", "crowdband") == 0
    assert fts(db, "fts_albums", "togetheralbum") == 0


# --- transaction ownership --------------------------------------------------------


def assert_untouched(db, before):
    assert track_present(db, "lonely")
    assert tombstone(db, "lonely") is None
    assert counter(db) == before
    assert count(db, "SELECT count(*) FROM artists WHERE name = 'Hermitband'") == 1
    assert count(db, "SELECT count(*) FROM albums WHERE name = 'Islandrecord'") == 1
    assert fts(db, "fts_tracks", "solitude") == 1
    assert fts(db, "fts_artists", "hermitband") == 1


def test_a_failure_in_the_caller_after_the_delete_leaves_no_tombstone(library):
    db = library
    before = counter(db)

    with pytest.raises(Boom):
        with db._connection(commit=True, immediate=True) as conn:
            db._delete_track_in(conn, "lonely", owner_id=db.owner_id)
            raise Boom()

    assert_untouched(db, before)


def test_a_failure_inside_after_the_tombstone_raises_and_rolls_back_with_the_caller(
    library, monkeypatch
):
    db = library
    before = counter(db)

    def fail(conn, artist_id):
        raise Boom()

    monkeypatch.setattr(Database, "_orphan_gc_artist", staticmethod(fail))

    with pytest.raises(Boom):
        delete_in(db, "lonely")

    assert_untouched(db, before)


def test_it_never_commits_on_its_own(library):
    db = library
    with db._connection(commit=True, immediate=True) as conn:
        db._delete_track_in(conn, "lonely", owner_id=db.owner_id)
        # Another connection still sees the last committed state.
        assert track_present(db, "lonely")
        assert tombstone(db, "lonely") is None
        conn.rollback()

    assert track_present(db, "lonely")
    assert tombstone(db, "lonely") is None


# --- not found and already deleted (SC-28, D9) ------------------------------------


def test_an_unknown_uuid_raises_not_found_and_writes_nothing(library):
    db = library
    before = counter(db)

    with pytest.raises(TrackNotFound):
        delete_in(db, "never-existed")

    assert counter(db) == before
    assert tombstone(db, "never-existed") is None


def test_another_users_track_is_not_found_and_untouched(library, tmp_path):
    db = library
    other = add_test_user(db, "other")
    add(db, tmp_path, "theirs", "Theirsong", "Theirband", "Theiralbum", owner_id=other)
    before = counter(db)

    with pytest.raises(TrackNotFound):
        delete_in(db, "theirs")

    assert track_present(db, "theirs")
    assert tombstone(db, "theirs") is None
    assert counter(db) == before


def test_another_users_tombstone_is_not_found_like_an_unknown_uuid(library, tmp_path):
    db = library
    other = add_test_user(db, "other")
    add(db, tmp_path, "theirs", "Theirsong", "Theirband", "Theiralbum", owner_id=other)
    their_revision = delete_in(db, "theirs", owner_id=other)
    before = counter(db)

    with pytest.raises(TrackNotFound) as raised:
        delete_in(db, "theirs")

    assert not isinstance(raised.value, TrackAlreadyDeleted)
    assert tombstone(db, "theirs")[:2] == (their_revision, other)
    assert counter(db) == before


def test_an_own_tombstone_reports_already_deleted_with_its_revision_and_no_bump(library):
    db = library
    first = delete_in(db, "lonely")
    stone = tombstone(db, "lonely")
    before = counter(db)

    with pytest.raises(TrackAlreadyDeleted) as raised:
        delete_in(db, "lonely")

    assert raised.value.revision == first
    assert tombstone(db, "lonely") == stone
    assert counter(db) == before


def test_the_wrapper_keeps_its_bool_and_never_bumps_a_tombstone(library):
    db = library
    assert db.delete_track(uuid_id="lonely") is True
    stone = tombstone(db, "lonely")
    before = counter(db)

    assert db.delete_track(uuid_id="lonely") is False
    assert db.delete_track(uuid_id="never-existed") is False

    assert tombstone(db, "lonely") == stone
    assert counter(db) == before


# --- with the pending-deletion marker ----------------------------------------------


def test_it_deletes_a_track_whose_journal_row_exists_and_leaves_the_row(library):
    db = library
    mark_pending_deletion(db.context.database_path, "lonely")

    with db._connection(commit=True, immediate=True) as conn:
        revision = db._delete_track_in(conn, "lonely", owner_id=db.owner_id)
        # The deletion worker marks its journal committed in the same transaction.
        conn.execute("UPDATE deletion_journal SET stage = 'committed' WHERE uuid_id = ?", ("lonely",))

    assert tombstone(db, "lonely")[0] == revision
    assert not track_present(db, "lonely")
    assert one(db, "SELECT stage FROM deletion_journal WHERE uuid_id = 'lonely'") == ("committed",)
