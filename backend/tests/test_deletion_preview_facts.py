"""Piece 8A.2b S2 (spec §4 preview row and para 4, plan D15, D21, SC-28 rule 4):
``Database.get_deletion_preview_facts`` reads, for the caller only, what the
deletion preview needs about each requested UUID: a live track's title,
artist, album, revision and master path plus whether it is busy; an own
tombstone's revision. Another user's live track or tombstone is absent from
the result, exactly like a UUID nobody has. It writes nothing.

Busy (spec §5 "Reader and mutation coordination"): an active (queued or
running) conversion, an edit journal row, a non-terminal upload commit
journal row naming the track, or a pending deletion (a deletion journal row).
"""

import sqlite3

import pytest

from app.library import Library
from app.models import Track, TrackMetaData
from tests.owned_database import add_test_user
from tests.pending_deletion import mark_pending_deletion
from tests.sqlite_helpers import sql_exec

UNKNOWN = "00000000-0000-4000-8000-0000000000ee"


@pytest.fixture
def me(db):
    return Library(db, db.owner_id)


@pytest.fixture
def sam(db):
    return Library(db, add_test_user(db, "sam"))


def _add(library, title, *, artist="Radiohead", album="OK Computer"):
    track = Track(
        file_path=f"/music/{library.owner_id}/{title}.flac",
        metadata=TrackMetaData(title=title, artist=artist, album=album, codec="flac", duration=1.0),
    )
    assert library.add_track(track=track)
    return track.uuid_id


def _dump(db):
    conn = sqlite3.connect(db.context.database_path)
    try:
        tables = [r[0] for r in conn.execute(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
            " ORDER BY name")]
        return {t: conn.execute(f"SELECT * FROM {t}").fetchall() for t in tables}
    finally:
        conn.close()


def test_an_own_live_track_reports_its_identity_revision_and_path(me):
    uuid_id = _add(me, "Airbag")
    revision = me.get_track_by_uuid(uuid_id).revision

    facts = me.get_deletion_preview_facts([uuid_id])

    assert facts == {
        uuid_id: {
            "state": "live",
            "revision": revision,
            "title": "Airbag",
            "artist": "Radiohead",
            "album": "OK Computer",
            "file_path": f"/music/{me.owner_id}/Airbag.flac",
            "busy": False,
        }
    }


def test_an_own_tombstone_reports_its_existing_revision(db, me):
    uuid_id = _add(me, "Gone")
    assert me.delete_track(uuid_id)
    [tombstone_revision] = [
        r[0] for r in sqlite3.connect(db.context.database_path).execute(
            "SELECT revision FROM track_tombstones WHERE uuid_id = ?", (uuid_id,))
    ]

    facts = me.get_deletion_preview_facts([uuid_id])

    assert facts == {uuid_id: {"state": "tombstone", "revision": tombstone_revision}}


def test_unknown_foreign_live_and_foreign_tombstone_are_all_absent(me, sam):
    their_live = _add(sam, "Lucky")
    their_gone = _add(sam, "Gone")
    assert sam.delete_track(their_gone)
    mine = _add(me, "Airbag")

    facts = me.get_deletion_preview_facts([UNKNOWN, their_live, their_gone, mine])

    assert set(facts) == {mine}
    # Control: sam sees his own.
    assert sam.get_deletion_preview_facts([their_live, their_gone])[their_live]["state"] == "live"
    assert sam.get_deletion_preview_facts([their_gone])[their_gone]["state"] == "tombstone"


def test_many_targets_in_one_call(me):
    uuids = [_add(me, f"t{i}") for i in range(100)]

    facts = me.get_deletion_preview_facts(uuids)

    assert set(facts) == set(uuids)
    assert {f["title"] for f in facts.values()} == {f"t{i}" for i in range(100)}


@pytest.mark.parametrize("status,busy", [
    ("queued", True), ("running", True),
    ("completed", False), ("failed", False), ("cancelled", False),
])
def test_an_active_conversion_makes_the_track_busy(me, status, busy):
    uuid_id = _add(me, "Converting")
    job_id = me.insert_conversion_job(uuid_id, "aac", "m4a", 192)
    if status != "queued":
        sql_exec(me.database, "UPDATE conversion_jobs SET status = ? WHERE id = ?", (status, job_id))

    assert me.get_deletion_preview_facts([uuid_id])[uuid_id]["busy"] is busy


def test_an_edit_journal_row_makes_the_track_busy(me):
    uuid_id = _add(me, "Editing")
    me.insert_journal_entry("relocate", uuid_id, old_path="/a", new_path="/b")

    assert me.get_deletion_preview_facts([uuid_id])[uuid_id]["busy"] is True


@pytest.mark.parametrize("state,busy", [
    ("committing", True), ("prepared", True), ("moved", True),
    ("imported", False), ("duplicate_conflict", False), ("failed", False),
])
def test_a_non_terminal_upload_commit_journal_makes_the_track_busy(me, state, busy):
    uuid_id = _add(me, "Publishing")
    sql_exec(
        me.database,
        "INSERT INTO upload_commit_journal (owner_id, operation_uuid, item_uuid, state,"
        " base_review_version, reserved_track_uuid, edits, write_tags,"
        " acknowledged_duplicates, source_path, created_at, updated_at)"
        " VALUES (?, 'op', 'item', ?, 0, ?, '{}', 0, '{}', '/s', 0, 0)",
        (me.owner_id, state, uuid_id),
    )

    assert me.get_deletion_preview_facts([uuid_id])[uuid_id]["busy"] is busy


def test_a_pending_deletion_makes_the_track_busy(me):
    uuid_id = _add(me, "Deleting")
    mark_pending_deletion(me.database.context.database_path, uuid_id)

    facts = me.get_deletion_preview_facts([uuid_id])

    assert facts[uuid_id]["state"] == "live"
    assert facts[uuid_id]["busy"] is True


def test_another_users_busy_rows_do_not_make_my_track_busy(me, sam):
    # Track UUIDs are global, but a foreign row naming my UUID is not mine.
    uuid_id = _add(me, "Mine")
    sql_exec(me.database,
         "INSERT INTO edit_journal (intent, uuid_id, created_at, owner_id) VALUES ('x', ?, 0, ?)",
         (uuid_id, sam.owner_id))
    sql_exec(me.database,
         "INSERT INTO conversion_jobs (uuid_id, target_codec, target_container, status, owner_id)"
         " VALUES (?, 'aac', 'm4a', 'running', ?)", (uuid_id, sam.owner_id))

    assert me.get_deletion_preview_facts([uuid_id])[uuid_id]["busy"] is False


def test_reading_the_facts_writes_nothing(db, me, sam):
    mine = _add(me, "Mine")
    gone = _add(me, "Gone")
    assert me.delete_track(gone)
    theirs = _add(sam, "Theirs")
    before = _dump(db)

    me.get_deletion_preview_facts([mine, gone, theirs, UNKNOWN])

    assert _dump(db) == before
