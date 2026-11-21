"""A link below a user's library folder, met by an upload on its way from the
commit to the published track, gets the same answer wherever it is noticed
first: ``upload_library_changed``, for good, with its sentence and one operator
line naming the entry relative to the music folder. Driven as the server
drives it: the commit worker with the publisher behind it, or the start-up
step; real folders, a real link put in place before the commit.

An entry that cannot be examined, and a link at the file name itself, stay the
retryable refusal; the library folder itself may be a link inside the music
folder (see ``test_upload_final_link_refused.py``)."""

import logging
import os
from pathlib import Path

import pytest

from app.services.upload_recovery import reconcile_upload_commits
from tests.identity_worker_fixtures import sql
from tests.upload_commit_fixtures import (
    FakeCoverArt, FakeExact, accept, journal, library_root, make_commit_worker, ready_item,
)
from tests.upload_publish_fixtures import make_publisher, prepared_commit, track_row
from tests.upload_validation_fixtures import item_row

REFUSED = ("This file could not be imported: the server's library folder was changed outside the"
           " server. After the server's admin fixes it, cancel this upload and add the file again.")


@pytest.fixture
def music(tmp_path):
    path = tmp_path / "music"
    (path / ".uploads").mkdir(parents=True)
    return path


def _commit_and_run(db, music, content):
    """Accept a commit of a new staged file and let the worker run it to its end."""
    commit = accept(db, ready_item(db, music / ".uploads", content=content))
    outcome = make_commit_worker(db, music, after_prepared=make_publisher(db, music)).process_one()
    return commit, outcome


def _artist_folder(db, music):
    """Import one file and return the user's library folder and the artist
    folder its tags put it in (where the next file with the same tags lands)."""
    commit, outcome = _commit_and_run(db, music, b"audio-A")
    assert outcome == "imported"
    [row] = sql(db, "SELECT file_path FROM tracks WHERE uuid_id = ?", (commit["track"],))
    root = library_root(db, music, commit["owner_id"])
    artist = Path(row["file_path"]).relative_to(root).parts[0]
    return root, artist


def _refusal(db, commit):
    item = item_row(db, commit)
    return item["state"], item["error_code"], item["error_message"], item["error_retryable"]


def _operator_lines(caplog):
    return [r.getMessage() for r in caplog.records
            if r.name == "uvicorn.error" and "changed outside the server" in r.getMessage()]


@pytest.mark.parametrize("where", ["outside the music folder", "inside the library folder"])
def test_an_artist_folder_replaced_by_a_link_is_refused_for_good_by_the_commit(
        db, music, tmp_path, caplog, where):
    root, artist = _artist_folder(db, music)
    target = tmp_path / "outside" if where == "outside the music folder" else root / "Elsewhere"
    (root / artist).rename(target)
    (root / artist).symlink_to(target, target_is_directory=True)
    before = sorted(p.name for p in target.rglob("*"))

    with caplog.at_level(logging.WARNING, logger="uvicorn.error"):
        commit, outcome = _commit_and_run(db, music, b"audio-B")

    assert outcome == "failed"
    assert _refusal(db, commit) == ("review_ready", "upload_library_changed", REFUSED, 0)
    [line] = _operator_lines(caplog)
    assert f"{root.name}/{artist} " in line and str(tmp_path) not in line
    assert sorted(p.name for p in target.rglob("*")) == before  # nothing placed through it
    assert track_row(db, commit["track"]) is None


@pytest.mark.requires_chmod_denial
def test_an_artist_folder_that_cannot_be_examined_stays_retryable(db, music, caplog):
    root, artist = _artist_folder(db, music)
    (root / artist).chmod(0)
    try:
        with caplog.at_level(logging.WARNING, logger="uvicorn.error"):
            commit, outcome = _commit_and_run(db, music, b"audio-B")
    finally:
        (root / artist).chmod(0o755)

    assert outcome == "failed"
    state, code, _message, retryable = _refusal(db, commit)
    assert (state, code, retryable) == ("review_ready", "upload_commit_failed", 1)
    assert _operator_lines(caplog) == []


def test_a_library_folder_linked_outside_the_music_folder_is_refused_for_good_by_the_commit(
        db, music, tmp_path, caplog):
    root, _artist = _artist_folder(db, music)
    outside = tmp_path / "outside"
    root.rename(outside)
    root.symlink_to(outside, target_is_directory=True)
    before = sorted(p.name for p in outside.rglob("*"))

    with caplog.at_level(logging.WARNING, logger="uvicorn.error"):
        commit, outcome = _commit_and_run(db, music, b"audio-B")

    assert outcome == "failed"
    assert _refusal(db, commit) == ("review_ready", "upload_library_changed", REFUSED, 0)
    [line] = _operator_lines(caplog)
    assert f" {root.name} " in line and str(tmp_path) not in line
    assert sorted(p.name for p in outside.rglob("*")) == before


def test_the_start_up_step_refuses_a_placed_file_behind_a_folder_link_for_good(
        db, music, tmp_path, caplog):
    """A moved journal whose artist folder became a link to an empty folder:
    the start-up check finds no file there, and the failure it records says
    why, for good, instead of "Try again"."""
    commit = prepared_commit(db, music)
    Path(commit["work"]).write_bytes(b"audio-A")
    root = library_root(db, music, commit["owner_id"])
    root.mkdir(parents=True)
    (tmp_path / "outside").mkdir()
    (root / "Artist").symlink_to(tmp_path / "outside", target_is_directory=True)
    sql(db, "UPDATE upload_commit_journal SET state = 'moved', final_path = ?"
            " WHERE owner_id = ? AND operation_uuid = ?",
        (str(root / "Artist" / f"{commit['track']}.flac"), commit["owner_id"], commit["op"]))

    with caplog.at_level(logging.WARNING, logger="uvicorn.error"):
        reconcile_upload_commits(
            db, publisher=make_publisher(db, music), uploads_root=music / ".uploads",
            music_library_dir=music, cover_art=FakeCoverArt(), compute_exact=FakeExact())

    assert journal(db, commit)["state"] == "failed"
    assert _refusal(db, commit) == ("review_ready", "upload_library_changed", REFUSED, 0)
    [line] = _operator_lines(caplog)
    assert f"{root.name}/Artist " in line
    assert os.path.islink(root / "Artist") and list((tmp_path / "outside").iterdir()) == []
