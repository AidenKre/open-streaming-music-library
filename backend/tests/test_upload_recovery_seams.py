"""7A.3c S1 (spec §6 crash list, 7-U07): a crash-injection seam at every
boundary of an upload commit: after the work fsync, after art registration
(before it is journaled), before and after the prepared journal, before and
after the move, before and after the DB commit, and during clean-up. A seam is
a test-only callable; ``SimulatedCrash`` (a BaseException) stops everything
dead at that point, like a process kill."""

import errno
import os

import pytest

from app.services import organizer, upload_commit, upload_publish
from app.services.upload_publish import SimulatedCrash
from tests.upload_commit_fixtures import (
    FakeArt,
    accept,
    journal,
    make_commit_worker,
    ready_item,
)
from tests.upload_publish_fixtures import RecordingSeam, make_publisher, track_row
from tests.upload_recovery_fixtures import art_ids, art_manager, png
from tests.upload_validation_fixtures import FakeProbe, detected, item_row

WORKER_POINTS = ["after_work_fsync", "after_art_registered", "before_prepared_journal",
                 "after_prepared_journal"]
PUBLISHER_IMPORT_POINTS = ["before_link", "after_link", "after_moved_journal", "after_work_unlink",
                           "before_insert_commit", "after_insert_commit", "after_source_removed"]


@pytest.fixture
def music(tmp_path):
    path = tmp_path / "music"
    (path / ".uploads").mkdir(parents=True)
    return path


def _run(db, music, seam):
    """One accepted commit with embedded art (real cover art), through the real
    worker and publisher."""
    cover_art = art_manager(db, music.parent / "art")
    image = png()
    commit = accept(db, ready_item(db, music / ".uploads"))
    art_meta = {**detected(), "has_album_art": True}
    worker = make_commit_worker(
        db, music, seam=seam, probe=FakeProbe(art_meta), art=FakeArt(image),
        cover_art=cover_art,
        after_prepared=make_publisher(db, music, seam=seam, cover_art=cover_art,
                                      extract_art=FakeArt(image)))
    return commit, worker


def test_every_boundary_is_reached_in_order_on_an_import(db, music):
    seam = RecordingSeam()
    commit, worker = _run(db, music, seam)

    assert worker.process_one() == "imported"

    assert seam.points == WORKER_POINTS + PUBLISHER_IMPORT_POINTS
    assert set(WORKER_POINTS) <= set(upload_commit.SEAM_POINTS)
    assert set(PUBLISHER_IMPORT_POINTS) <= set(upload_publish.SEAM_POINTS)


def test_the_worker_without_a_seam_behaves_as_before(db, music):
    commit = accept(db, ready_item(db, music / ".uploads"))
    worker = make_commit_worker(db, music, after_prepared=make_publisher(db, music))

    assert worker.process_one() == "imported"
    assert item_row(db, commit)["state"] == "imported"


def _crash(db, music, point):
    seam = RecordingSeam(crash_at=point)
    commit, worker = _run(db, music, seam)
    with pytest.raises(SimulatedCrash):
        worker.process_one()
    assert seam.points[-1] == point  # nothing after the crash point ran
    return commit


def test_a_crash_after_the_work_fsync_leaves_the_work_file_and_a_committing_journal(db, music):
    commit = _crash(db, music, "after_work_fsync")

    row = journal(db, commit)
    assert row["state"] == "committing"
    assert commit["work"].read_bytes() == commit["content"]
    assert row["cover_art_id"] is None
    assert item_row(db, commit)["state"] == "committing"


def test_a_crash_after_art_registration_leaves_the_art_unjournaled(db, music):
    commit = _crash(db, music, "after_art_registered")

    assert len(art_ids(db)) == 1  # the art row exists
    assert journal(db, commit)["cover_art_id"] is None
    assert journal(db, commit)["state"] == "committing"


def test_a_crash_before_the_prepared_journal_keeps_the_journal_committing(db, music):
    commit = _crash(db, music, "before_prepared_journal")

    row = journal(db, commit)
    assert row["state"] == "committing"
    assert row["cover_art_id"] == art_ids(db)[0]  # journaled at registration
    assert row["final_path"] is None
    assert commit["work"].exists()


def test_a_crash_after_the_prepared_journal_leaves_it_prepared_with_nothing_moved(db, music):
    commit = _crash(db, music, "after_prepared_journal")

    row = journal(db, commit)
    assert row["state"] == "prepared"
    assert commit["work"].exists()
    assert not os.path.lexists(row["final_path"])


def test_a_crash_before_the_link_leaves_a_prepared_journal_and_no_final_file(db, music):
    commit = _crash(db, music, "before_link")

    row = journal(db, commit)
    assert row["state"] == "prepared"
    assert commit["work"].exists()
    assert not os.path.lexists(row["final_path"])


def test_a_crash_before_the_insert_commit_leaves_a_moved_journal_and_no_track(db, music):
    commit = _crash(db, music, "before_insert_commit")

    row = journal(db, commit)
    assert row["state"] == "moved"
    assert os.path.isfile(row["final_path"])
    assert track_row(db, commit["track"]) is None
    assert item_row(db, commit)["state"] == "committing"


# ── sign-off DEV-7-25 link fallback: the fallback's own boundaries ─────────

@pytest.mark.parametrize("err, fallback", [
    (errno.ENOTSUP, ["after_place_record"]),
    (errno.EXDEV, ["after_place_record", "mid_copy", "after_copy", "after_temp_placed"]),
])
def test_every_boundary_is_reached_in_order_on_a_fallback_import(db, music, monkeypatch, err, fallback):
    def refuse(src, dst, *args, **kwargs):
        raise OSError(err, os.strerror(err))

    monkeypatch.setattr(organizer.os, "link", refuse)
    seam = RecordingSeam()
    commit, worker = _run(db, music, seam)

    assert worker.process_one() == "imported"

    first, rest = PUBLISHER_IMPORT_POINTS[:1], PUBLISHER_IMPORT_POINTS[1:]
    assert seam.points == WORKER_POINTS + first + fallback + rest
    assert set(fallback) <= set(upload_publish.SEAM_POINTS)
