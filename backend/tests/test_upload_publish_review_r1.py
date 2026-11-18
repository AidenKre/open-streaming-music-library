"""7A.3b review r1 (7A.3b-review.md F1, F2, F3): the publisher records a failure
for an unexpected error anywhere in steps 3-5 (never leaves the item stuck in
``committing``); a ``moved`` journal handed back to it resumes at step 5 (the
in-transaction lookup still decides); a journal ``prepared`` whose final name is
already a second link of its own work file (crash after the link) continues
instead of reading its own link as a collision."""

import os
import sqlite3

import pytest

from app.services.upload_publish import SimulatedCrash
from tests.identity_worker_fixtures import make_db
from tests.upload_commit_fixtures import accept, journal, make_commit_worker, ready_item
from tests.upload_publish_fixtures import RecordingSeam, make_publisher, track_row
from tests.upload_validation_fixtures import item_row


@pytest.fixture
def db(tmp_path):
    return make_db(tmp_path)


@pytest.fixture
def music(tmp_path):
    path = tmp_path / "music"
    (path / ".uploads").mkdir(parents=True)
    return path


def _crash_at(db, music, point):
    commit = accept(db, ready_item(db, music / ".uploads"))
    worker = make_commit_worker(
        db, music, after_prepared=make_publisher(db, music, seam=RecordingSeam(crash_at=point)))
    with pytest.raises(SimulatedCrash):
        worker.process_one()
    return commit


@pytest.mark.parametrize("point", ["after_link", "after_moved_journal", "after_work_unlink"])
def test_a_journal_handed_back_after_a_crash_is_published_once(db, music, point):
    commit = _crash_at(db, music, point)
    final = journal(db, commit)["final_path"]

    assert make_publisher(db, music)(journal(db, commit)) == "imported"

    assert item_row(db, commit)["state"] == "imported"
    assert track_row(db, commit["track"])["file_path"] == final
    assert os.path.isfile(final)
    assert not commit["work"].exists()
    assert journal(db, commit)["state"] == "imported"


def test_an_unrelated_file_at_the_final_path_is_still_a_collision_after_a_crash(db, music):
    commit = _crash_at(db, music, "after_link")
    final = journal(db, commit)["final_path"]
    os.unlink(final)
    with open(final, "wb") as f:
        f.write(b"someone else's file")

    assert make_publisher(db, music)(journal(db, commit)) == "failed"

    assert open(final, "rb").read() == b"someone else's file"
    assert track_row(db, commit["track"]) is None


@pytest.mark.parametrize("method", ["upload_commit_preflight", "mark_upload_commit_moved"])
def test_an_unexpected_error_before_the_insert_is_recorded_as_a_failure(db, music, monkeypatch, method):
    commit = accept(db, ready_item(db, music / ".uploads"))
    version = item_row(db, commit)["review_version"]
    real = getattr(db, method)
    calls = []

    def flaky(**kwargs):
        if not calls:
            calls.append(1)
            raise sqlite3.OperationalError("disk I/O error")
        return real(**kwargs)

    monkeypatch.setattr(db, method, flaky)

    assert make_commit_worker(db, music, after_prepared=make_publisher(db, music)).process_one() == "failed"

    item = item_row(db, commit)
    assert (item["state"], item["review_version"], item["error_code"]) == (
        "review_ready", version + 1, "upload_commit_failed")
    assert journal(db, commit)["state"] == "failed"
    assert track_row(db, commit["track"]) is None
    assert not commit["work"].exists()


def test_a_failure_after_the_link_keeps_the_final_path_in_the_journal(db, music, monkeypatch):
    """The journal invariant 7A.3c relies on: a failed journal names a final path
    exactly when this operation placed a file there (here: the link happened, the
    moved journal write failed, then the process died before the clean-up)."""
    commit = accept(db, ready_item(db, music / ".uploads"))

    def broken(**kwargs):
        raise sqlite3.OperationalError("disk I/O error")

    monkeypatch.setattr(db, "mark_upload_commit_moved", broken)
    seam = RecordingSeam(crash_at="after_failure_journal")
    worker = make_commit_worker(db, music, after_prepared=make_publisher(db, music, seam=seam))

    with pytest.raises(SimulatedCrash):
        worker.process_one()

    row = journal(db, commit)
    assert row["state"] == "failed"
    assert row["final_path"] is not None
    assert os.path.isfile(row["final_path"])
