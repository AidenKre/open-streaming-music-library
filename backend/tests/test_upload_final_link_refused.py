"""A commit journal's final path is the server's own, but the name, or a folder
on the way to it, can be swapped for a symbolic link after it was written. A
link is never a file this operation placed (it places a regular file by hard
link, rename or copy): wherever the journaled final is trusted, a link there
is refused. The publisher never publishes it, and neither the publisher's
failure path nor the start-up clean-up removes it or what it points to, even
when it points to another file inside the owner's library."""

import os
from pathlib import Path

import pytest

from app.services import upload_recovery
from tests.identity_worker_fixtures import sql
from tests.owned_database import add_test_user
from tests.upload_commit_fixtures import (
    FakeCoverArt, accept, journal, library_root, make_commit_worker, ready_item,
)
from tests.upload_publish_fixtures import make_publisher, prepared_commit, track_row
from tests.upload_validation_fixtures import item_row


@pytest.fixture
def music(tmp_path):
    path = tmp_path / "music"
    (path / ".uploads").mkdir(parents=True)
    return path


def _journal(db, commit, *, state, final):
    sql(db, "UPDATE upload_commit_journal SET state = ?, final_path = ?"
            " WHERE owner_id = ? AND operation_uuid = ?",
        (state, str(final), commit["owner_id"], commit["op"]))


def _commit_with_linked_final(db, music, *, state, link="name"):
    """A journal in ``state`` whose final name inside the owner's library leads,
    through a symbolic link (the name itself, or its folder), to another file
    inside the same library: a track's master that is not this operation's."""
    commit = prepared_commit(db, music)
    Path(commit["work"]).write_bytes(b"audio-A")
    root = library_root(db, music, commit["owner_id"])
    master = root / "Real" / f"{commit['track']}.flac"
    master.parent.mkdir(parents=True)
    master.write_bytes(b"someone else's master")
    if link == "name":
        final = root / "Artist" / f"{commit['track']}.flac"
        final.parent.mkdir(parents=True)
        final.symlink_to(master)
    else:  # the folder on the way is the link
        (root / "Artist").symlink_to(root / "Real", target_is_directory=True)
        final = root / "Artist" / master.name
    _journal(db, commit, state=state, final=final)
    return commit, final, master


def _assert_untouched(final, master):
    assert os.path.lexists(final)
    assert master.read_bytes() == b"someone else's master"


@pytest.mark.parametrize("link", ["name", "folder"])
def test_a_moved_journal_whose_final_is_a_link_is_never_published(db, music, link):
    commit, final, master = _commit_with_linked_final(db, music, state="moved", link=link)

    assert make_publisher(db, music)(journal(db, commit)) != "imported"

    assert track_row(db, commit["track"]) is None
    assert journal(db, commit)["state"] == "failed"
    assert item_row(db, commit)["state"] == "review_ready"
    _assert_untouched(final, master)


@pytest.mark.parametrize("link", ["name", "folder"])
def test_a_recovered_failure_never_removes_a_linked_final(db, music, link):
    commit, final, master = _commit_with_linked_final(db, music, state="moved", link=link)

    make_publisher(db, music).fail_recovered(journal(db, commit))

    _assert_untouched(final, master)


@pytest.mark.parametrize("state", ["failed", "duplicate_conflict"])
@pytest.mark.parametrize("link", ["name", "folder"])
def test_the_start_up_clean_up_never_removes_a_linked_final(db, music, state, link):
    commit, final, master = _commit_with_linked_final(db, music, state=state, link=link)
    row = journal(db, commit)

    try:
        cleaned = upload_recovery.clean_finished_journal(
            db, row, uploads_root=music / ".uploads", music_library_dir=music,
            cover_art=FakeCoverArt())
    except ValueError:  # refused; the start-up step logs it and goes on
        cleaned = False

    assert cleaned is False
    _assert_untouched(final, master)
    assert journal(db, commit)["final_path"] == str(final)  # kept for the next pass


def test_a_prepared_journal_never_places_its_file_through_a_linked_folder(db, music):
    commit = prepared_commit(db, music)
    Path(commit["work"]).write_bytes(b"audio-A")
    root = library_root(db, music, commit["owner_id"])
    (root / "Real").mkdir(parents=True)
    (root / "Artist").symlink_to(root / "Real", target_is_directory=True)
    _journal(db, commit, state="prepared", final=root / "Artist" / f"{commit['track']}.flac")

    assert make_publisher(db, music)(journal(db, commit)) != "imported"

    assert track_row(db, commit["track"]) is None
    assert list((root / "Real").iterdir()) == []
    assert item_row(db, commit)["state"] == "review_ready"


REFUSED = ("This file could not be imported: the server's library folder was changed outside the"
           " server. After the server's admin fixes it, cancel this upload and add the file again.")


@pytest.mark.parametrize(("state", "link", "found"), [
    ("moved", "folder", "Artist"),
    ("prepared", "folder", "Artist"),
])
def test_the_refusal_is_final_and_names_what_was_found_for_the_operator(
        db, music, caplog, state, link, found):
    """Trying again builds the same folders and is refused again, so the item
    is not offered a retry; the operator line names the link found, relative
    to the music folder (the user's library folder first), never as an
    absolute path."""
    if state == "moved":
        commit, final, _master = _commit_with_linked_final(db, music, state="moved", link=link)
    else:
        commit = prepared_commit(db, music)
        Path(commit["work"]).write_bytes(b"audio-A")
        root = library_root(db, music, commit["owner_id"])
        (root / "Real").mkdir(parents=True)
        (root / "Artist").symlink_to(root / "Real", target_is_directory=True)
        _journal(db, commit, state="prepared", final=root / "Artist" / f"{commit['track']}.flac")

    with caplog.at_level("WARNING", logger="uvicorn.error"):
        assert make_publisher(db, music)(journal(db, commit)) == "failed"

    item = item_row(db, commit)
    assert (item["state"], item["error_code"], item["error_message"], item["error_retryable"]) == (
        "review_ready", "upload_library_changed", REFUSED, 0)
    operator = [r.getMessage() for r in caplog.records if r.name == "uvicorn.error"]
    [line] = [m for m in operator if "changed outside the server" in m]
    folder = library_root(db, music, commit["owner_id"]).name
    assert f"{folder}/" + found.format(track=commit["track"]) in line
    assert str(music) not in line


def _refused_publish(db, music, caplog, commit):
    with caplog.at_level("WARNING", logger="uvicorn.error"):
        assert make_publisher(db, music)(journal(db, commit)) == "failed"
    item = item_row(db, commit)
    lines = [r.getMessage() for r in caplog.records
             if r.name == "uvicorn.error" and "changed outside the server" in r.getMessage()]
    return (item["error_code"], item["error_retryable"]), lines


def _moved_commit(db, music):
    commit = prepared_commit(db, music)
    Path(commit["work"]).write_bytes(b"audio-A")
    return commit, library_root(db, music, commit["owner_id"])


def test_a_plain_file_where_a_folder_must_be_is_a_final_refusal_naming_it(db, music, caplog):
    commit, root = _moved_commit(db, music)
    root.mkdir(parents=True)
    (root / "Artist").write_bytes(b"not a folder")
    _journal(db, commit, state="moved", final=root / "Artist" / f"{commit['track']}.flac")

    error, lines = _refused_publish(db, music, caplog, commit)

    assert error == ("upload_library_changed", 0)
    [line] = lines
    assert f"{root.name}/Artist " in line and str(music) not in line
    assert (root / "Artist").read_bytes() == b"not a folder"


def test_a_link_at_the_final_name_itself_is_refused_but_stays_retryable(db, music, caplog):
    """Each commit names its file after a new track id, so trying again uses
    another name: the refusal is the retryable one, with no operator line, and
    the link and what it points to stay."""
    commit, final, master = _commit_with_linked_final(db, music, state="moved", link="name")

    error, lines = _refused_publish(db, music, caplog, commit)

    assert error == ("upload_commit_failed", 1)
    assert lines == []
    assert track_row(db, commit["track"]) is None
    _assert_untouched(final, master)


def test_a_library_folder_that_is_a_plain_file_is_a_final_refusal_naming_it(db, music, caplog):
    commit, root = _moved_commit(db, music)
    root.write_bytes(b"not a folder")
    _journal(db, commit, state="moved", final=root / "Artist" / f"{commit['track']}.flac")

    error, lines = _refused_publish(db, music, caplog, commit)

    assert error == ("upload_library_changed", 0)
    [line] = lines
    assert f" {root.name} in their music library" in line and str(music) not in line
    assert root.read_bytes() == b"not a folder"


# A user's library folder (and the music folder above it) may be a link, as far
# as ``app.library.library_root`` accepts it: it must lead inside the music
# folder. Only entries below the library folder may never be links.

def _linked_library_folder(db, music, owner_id, target):
    root = library_root(db, music, owner_id)
    target.mkdir(parents=True, exist_ok=True)
    root.symlink_to(target, target_is_directory=True)
    return root


def _import(db, music, staged):
    commit = accept(db, staged)
    worker = make_commit_worker(db, music, after_prepared=make_publisher(db, music))
    return commit, worker.process_one()


def test_a_library_folder_that_is_a_link_inside_the_music_folder_still_imports(db, music):
    staged = ready_item(db, music / ".uploads", content=b"audio-A")
    root = _linked_library_folder(db, music, staged["owner_id"], music / "real-folder")

    commit, outcome = _import(db, music, staged)

    assert outcome == "imported"
    [row] = sql(db, "SELECT file_path FROM tracks WHERE uuid_id = ?", (commit["track"],))
    path = Path(row["file_path"])
    assert path.is_relative_to(root) and path.read_bytes() == b"audio-A"
    assert (music / "real-folder" / path.relative_to(root)).exists()


def test_a_library_folder_linked_to_another_users_folder_imports_and_leaves_their_files(db, music):
    """``library_root`` accepts a link to any folder inside the music folder,
    another user's included (a choice of the server's admin); uploads follow
    the same rule and never touch a file they did not place."""
    sam = add_test_user(db, "sam")
    sams_root = library_root(db, music, sam)
    (sams_root / "Artist").mkdir(parents=True)
    (sams_root / "Artist" / "theirs.flac").write_bytes(b"sam's master")
    staged = ready_item(db, music / ".uploads", content=b"audio-A")
    root = library_root(db, music, staged["owner_id"])
    root.symlink_to(sams_root, target_is_directory=True)

    commit, outcome = _import(db, music, staged)

    assert outcome == "imported"
    assert (sams_root / "Artist" / "theirs.flac").read_bytes() == b"sam's master"


def test_the_clean_up_of_a_failed_commit_in_a_linked_library_folder_stays_inside_it(db, music):
    commit, root = _moved_commit(db, music)
    target = music / "real-folder"
    _linked_library_folder(db, music, commit["owner_id"], target)
    (target / "Artist").mkdir()
    final = root / "Artist" / f"{commit['track']}.flac"
    final.write_bytes(b"audio-A")  # this operation's placed file
    (target / "Artist" / "neighbour.flac").write_bytes(b"another track's master")
    _journal(db, commit, state="failed", final=final)

    assert upload_recovery.clean_finished_journal(
        db, journal(db, commit), uploads_root=music / ".uploads", music_library_dir=music,
        cover_art=FakeCoverArt())

    assert not final.exists()
    assert (target / "Artist" / "neighbour.flac").read_bytes() == b"another track's master"


@pytest.mark.parametrize("state", ["moved", "failed"])
def test_a_folder_link_below_a_linked_library_folder_is_still_refused(db, music, caplog, state):
    commit, root = _moved_commit(db, music)
    target = music / "real-folder"
    _linked_library_folder(db, music, commit["owner_id"], target)
    master = target / "Real" / f"{commit['track']}.flac"
    master.parent.mkdir()
    master.write_bytes(b"someone else's master")
    (target / "Artist").symlink_to(target / "Real", target_is_directory=True)
    final = root / "Artist" / master.name
    _journal(db, commit, state=state, final=final)

    if state == "moved":
        error, lines = _refused_publish(db, music, caplog, commit)
        assert error == ("upload_library_changed", 0)
        [line] = lines
        assert f"{root.name}/Artist " in line
    else:
        try:
            upload_recovery.clean_finished_journal(
                db, journal(db, commit), uploads_root=music / ".uploads", music_library_dir=music,
                cover_art=FakeCoverArt())
        except ValueError:
            pass
    assert master.read_bytes() == b"someone else's master"
    assert track_row(db, commit["track"]) is None


@pytest.mark.requires_chmod_denial
def test_an_entry_that_cannot_be_examined_is_refused_but_stays_retryable(db, music, caplog):
    """Unknown is not "changed": a folder the server cannot search (a
    permission problem the admin may fix) refuses this attempt as before, with
    the retryable error and no operator line claiming a change."""
    commit, root = _moved_commit(db, music)
    final = root / "Artist" / f"{commit['track']}.flac"
    final.parent.mkdir(parents=True)
    final.write_bytes(b"audio-A")
    _journal(db, commit, state="moved", final=final)
    final.parent.chmod(0)
    try:
        error, lines = _refused_publish(db, music, caplog, commit)
    finally:
        final.parent.chmod(0o755)

    assert error == ("upload_commit_failed", 1)
    assert lines == []
    assert track_row(db, commit["track"]) is None
