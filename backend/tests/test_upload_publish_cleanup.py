"""7A.3b S6 (spec §6 step 6: "Remove source/work/journal only after receipt is
durable and cleanup verified"; §3 quota: "release each reservation once after
verified removal"). After the import commits, the staged source is removed and,
only once it is verifiably gone, the item's ``source_path`` is cleared and its
``upload_source`` row released in one transaction. The journal row stays as
the operation's durable record (its receipt replays 200). Crash seam:
``after_source_removed``."""

import os

import pytest

from app.services.upload_publish import SimulatedCrash
from tests.identity_worker_fixtures import make_db
from tests.upload_commit_fixtures import accept, journal, make_commit_worker, ready_item, reservations
from tests.upload_publish_fixtures import RecordingSeam, make_publisher
from tests.upload_validation_fixtures import item_row


@pytest.fixture
def db(tmp_path):
    return make_db(tmp_path)


@pytest.fixture
def music(tmp_path):
    path = tmp_path / "music"
    (path / ".uploads").mkdir(parents=True)
    return path


def _source_rows(db, commit):
    return [r for r in reservations(db, commit["owner_id"])
            if r["purpose"] == "upload_source" and r["subject_ref"] == commit["item_uuid"]]


def _run(db, music, **kwargs):
    return make_commit_worker(
        db, music, after_prepared=make_publisher(db, music, **kwargs)).process_one()


def test_an_import_gives_the_staged_source_back(db, music):
    commit = accept(db, ready_item(db, music / ".uploads"))

    assert _run(db, music) == "imported"

    assert not commit["source"].exists()
    item = item_row(db, commit)
    assert item["state"] == "imported"
    assert item["source_path"] is None
    assert _source_rows(db, commit) == []
    assert reservations(db, commit["owner_id"]) == []  # nothing staged is counted any more
    assert journal(db, commit)["state"] == "imported"
    assert os.path.isfile(journal(db, commit)["final_path"])


def test_a_source_that_cannot_be_removed_stays_counted(db, music, monkeypatch):
    commit = accept(db, ready_item(db, music / ".uploads"))
    from app.services import upload_publish

    real = upload_publish.remove_verified

    def keep_source(files, path):
        if str(path) == str(commit["source"]):
            return False
        return real(files, path)

    monkeypatch.setattr(upload_publish, "remove_verified", keep_source)

    assert _run(db, music) == "imported"

    assert commit["source"].exists()
    assert item_row(db, commit)["source_path"] == str(commit["source"])
    assert len(_source_rows(db, commit)) == 1


def test_a_crash_after_the_source_removal_leaves_the_row_for_recovery(db, music):
    commit = accept(db, ready_item(db, music / ".uploads"))
    seam = RecordingSeam(crash_at="after_source_removed")

    with pytest.raises(SimulatedCrash):
        _run(db, music, seam=seam)

    assert not commit["source"].exists()
    assert item_row(db, commit)["state"] == "imported"
    assert item_row(db, commit)["source_path"] == str(commit["source"])
    assert len(_source_rows(db, commit)) == 1
    assert seam.points[-2:] == ["after_insert_commit", "after_source_removed"]


def test_a_conflict_keeps_the_source(db, music):
    from tests.upload_publish_fixtures import library_track

    commit = accept(db, ready_item(db, music / ".uploads"))
    library_track(db, music)

    assert _run(db, music) == "duplicate_conflict"

    assert commit["source"].exists()
    assert item_row(db, commit)["source_path"] == str(commit["source"])
    assert len(_source_rows(db, commit)) == 1
