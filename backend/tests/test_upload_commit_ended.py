"""Other-issues row 43 (U12-B-09), pinned before Phase 10's P2c: what the commit
worker and the publisher do with an operation that is no longer running.

- The commit worker's in-process retry of an outcome it could not record is
  dropped for good once the item has left ``committing``.
- The publisher answers ``error`` and touches nothing for a journal in any
  state other than ``prepared`` or ``moved``.
"""

import sqlite3

import pytest

from tests.identity_worker_fixtures import sql
from tests.upload_commit_fixtures import accept, journal, library_root, make_commit_worker, ready_item
from tests.upload_publish_fixtures import make_publisher, prepared_commit, track_row
from tests.upload_test_fixtures import music, uploads_root  # noqa: F401
from tests.upload_validation_fixtures import item_row


class _AlwaysBusy:
    """A database write that is busy every time, counting its calls."""

    def __init__(self):
        self.calls = 0

    def __call__(self, **kwargs):
        self.calls += 1
        raise sqlite3.OperationalError("database is locked")


def _set_item_state(db, commit, state):
    sql(db, "UPDATE upload_items SET state = ? WHERE owner_id = ? AND item_uuid = ?",
        (state, commit["owner_id"], commit["item_uuid"]))


def test_a_retry_is_dropped_for_good_once_the_item_has_left_committing(db, music, uploads_root, monkeypatch):
    commit = accept(db, ready_item(db, uploads_root))
    publisher = make_publisher(db, music)
    handed_over = []

    def counting(prepared):
        handed_over.append(prepared["operation_uuid"])
        return publisher(prepared)

    moved = _AlwaysBusy()
    monkeypatch.setattr(db, "mark_upload_commit_moved", moved)
    monkeypatch.setattr(db, "fail_upload_publish", _AlwaysBusy())
    worker = make_commit_worker(db, music, after_prepared=counting)

    assert worker.process_one() == "error"  # the outcome could not be recorded: kept for a retry
    assert (handed_over, moved.calls) == ([commit["op"]], 1)

    _set_item_state(db, commit, "review_ready")  # the item left committing
    assert worker.process_one() == "idle"
    _set_item_state(db, commit, "committing")  # even if it came back, the retry is gone

    assert [worker.process_one() for _ in range(3)] == ["idle"] * 3
    assert (handed_over, moved.calls) == ([commit["op"]], 1)


@pytest.mark.parametrize("state", ["committing", "imported", "duplicate_conflict", "failed"])
def test_the_publisher_answers_error_and_touches_nothing_outside_prepared_and_moved(db, music, state):
    """Everything else about the journal is a placed, moved operation's (work
    file, final file inside the owner's library), so only the state stops it."""
    commit = prepared_commit(db, music, state=state)
    final = library_root(db, music, commit["owner_id"]) / "Artist" / "Album" / "01.flac"
    final.parent.mkdir(parents=True)
    final.write_bytes(b"audio-A")
    sql(db, "UPDATE upload_commit_journal SET final_path = ? WHERE owner_id = ? AND operation_uuid = ?",
        (str(final), commit["owner_id"], commit["op"]))
    before = journal(db, commit)
    item_before = item_row(db, commit)
    work = before["work_path"]
    with open(work, "wb") as handle:  # the operation's work file, as step 2 leaves it
        handle.write(b"audio-A")

    assert make_publisher(db, music)(before) == "error"

    assert journal(db, commit) == before
    assert item_row(db, commit) == item_before
    assert open(work, "rb").read() == b"audio-A"
    assert final.read_bytes() == b"audio-A"
    assert commit["source"].read_bytes() == b"audio-A"
    assert track_row(db, commit["track"]) is None
