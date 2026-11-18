"""Other-issues row 47 (U07-B-03): the HTTP answers of failures that are not
"the database is busy", pinned as they are today.

- ``PATCH /tracks/{uuid}`` that writes the file, when the file write fails:
  500 "Master file write failed: <reason>"; the catalog and the file stay.
- The same route for a track that a kept journal row blocks: 500 "Master file
  write failed: an earlier file operation on this track could not be
  finished" (since BE-REPLACE).
- The history routes when the database fails: 503 ``history_unavailable``,
  retryable.

The "Database busy" answers are pinned with Phase 10's typed busy answer (E1).
"""

import sqlite3

import pytest

import app.services.track_editor as track_editor_mod
from app.database.database import Database
from app.services.metadata import TagWriteError
from tests.auth_helpers import flac_track

HISTORY_UNAVAILABLE = {
    "detail": {
        "error": "history_unavailable",
        "message": "History is temporarily unavailable. Try again later.",
        "retryable": True,
    }
}


@pytest.fixture
def track(app_client):
    library = app_client.app.state.admin_library
    added = flac_track(library.root / "Radiohead" / "Airbag.flac", "Airbag")
    assert library.add_track(added)
    return library.get_track_by_uuid(added.uuid_id)


def _patch_title(client, track, title="New"):
    return client.patch(
        f"/tracks/{track.uuid_id}",
        json={"title": title, "base_revision": track.revision, "write_mode": "db_and_master"},
    )


def _title_and_bytes(client, track):
    current = client.app.state.admin_library.get_track_by_uuid(track.uuid_id)
    return current.metadata.title, current.revision, track.file_path.read_bytes()


def test_a_failed_file_write_answers_500_and_changes_nothing(app_client, track, monkeypatch):
    def refuse(*args, **kwargs):
        raise TagWriteError("the tag writer stopped")

    monkeypatch.setattr(track_editor_mod, "write_metadata_tags", refuse)
    before = _title_and_bytes(app_client, track)

    response = _patch_title(app_client, track)

    assert response.status_code == 500
    assert response.json() == {"detail": "Master file write failed: the tag writer stopped"}
    assert _title_and_bytes(app_client, track) == before


def test_an_edit_of_a_track_a_kept_journal_row_blocks_answers_500(app_client, track, monkeypatch):
    library = app_client.app.state.admin_library
    library.insert_journal_entry(
        "relocate", track.uuid_id, str(track.file_path),
        str(track.file_path.with_name("Moved.flac")), str(track.file_path.with_name("Moved.tmp")),
    )
    # Recovery cannot finish the row (as when its files cannot be proven).
    monkeypatch.setattr(track_editor_mod, "finish_track_journal_rows", lambda *a, **k: None)
    before = _title_and_bytes(app_client, track)

    response = _patch_title(app_client, track)

    assert response.status_code == 500
    assert response.json() == {
        "detail": "Master file write failed: an earlier file operation on this track "
                  "could not be finished"
    }
    assert _title_and_bytes(app_client, track) == before
    assert library.has_journal_entry_for_uuid(track.uuid_id)


def test_history_changes_answer_history_unavailable_when_the_database_fails(app_client, monkeypatch):
    def fail(self, *args, **kwargs):
        raise sqlite3.OperationalError("disk I/O error")

    monkeypatch.setattr(Database, "get_history_changes", fail)

    response = app_client.get("/history/changes")

    assert (response.status_code, response.json()) == (503, HISTORY_UNAVAILABLE)


def test_a_history_post_answers_history_unavailable_when_the_database_fails(app_client, monkeypatch):
    def fail(self, *args, **kwargs):
        raise sqlite3.OperationalError("disk I/O error")

    monkeypatch.setattr(Database, "insert_history_events", fail)
    event = {
        "event_uuid": "7a1f0d2e-1b2c-4d3e-8f4a-5b6c7d8e9f01", "kind": "listen", "entity_type": "track",
        "entity_ref": "t", "occurred_at": 1, "seconds_played": 1.0, "track_length": 2.0,
    }

    response = app_client.post("/history", json={"events": [event]})

    assert (response.status_code, response.json()) == (503, HISTORY_UNAVAILABLE)
