"""No track is ever given a path another track's row names (pre-merge review
B1-01, the writers' side).

A tag edit that moves the file and a conversion to another file type used to
ask only whether a file is on disk at the new path. A track whose master is
missing still names its path, so the move went ahead and two rows named one
file (``tests/test_shared_master_path.py`` shows what a deletion then did).
Now both are refused exactly as when a file is at the path. The comparison is
the catalog's own (``track_path_in_use``): any owner, letter case and Unicode
form folded.

The real tag editor and the real conversion run over the crash matrix's rig
(real database, real files; only the media tools are faked).
"""

import os
from pathlib import Path

import pytest

from app.services import conversion as conversion_module
from app.services import master_replace
from app.services.conversion import TargetPathTaken
from app.services.track_editor import MasterWriteError
from tests.replace_matrix_rig import ANY_TEXT, OLD, WRITERS, Expect, build_world, check_settled
from tests.test_shared_master_path import a_track_whose_master_is_missing




def _other_case(path: Path) -> Path:
    return path.parent.parent / path.parent.name.upper() / path.name


@pytest.mark.parametrize("spelling", ["the same spelling", "another letter case"])
@pytest.mark.parametrize("name", ["W1", "W2"])
def test_a_file_is_never_moved_to_a_path_another_tracks_row_names(
    tmp_path, monkeypatch, name, spelling
):
    """A's row names the path B's edit (W1) or conversion (W2) would move B's
    file to; A's own file is missing, so nothing is on disk there. The move is
    refused as it is when a file is at the path: the edit answers "could not
    place the master at its new location", the conversion's job fails, and B
    keeps its file, its path and its revision."""
    world = build_world(tmp_path, monkeypatch, WRITERS[name])
    a_path = world.new if spelling == "the same spelling" else _other_case(world.new)
    a = a_track_whose_master_is_missing(world, a_path)
    with world.outside():
        if a_path.parent != world.old.parent and not any(a_path.parent.iterdir()):
            a_path.parent.rmdir()

    if name == "W1":
        with pytest.raises(MasterWriteError, match="could not place the master at its new location"):
            world.run_writer()
    else:
        world.run_writer()
        assert world.job() == ("failed", "The conversion failed. The original was kept.")

    assert not os.path.lexists(world.new)
    assert world.track(a)["file_path"] == str(a_path)
    check_settled(world, Expect(OLD, 0, "kept", job=("failed", ANY_TEXT)))


def test_a_conversion_is_not_placed_at_a_path_another_track_came_to_name_while_it_ran(
    tmp_path, monkeypatch
):
    """The path was free when the job started; while it transcoded, another
    track's row came to name it (no file there). The move under the track's
    lock refuses, like a file on disk at the path: the job fails with "could
    not place the converted master" and the original stays."""
    world = build_world(tmp_path, monkeypatch, WRITERS["W2"])
    transcode = conversion_module.transcode
    planted = []

    def transcode_while_the_path_is_taken(*args, **kwargs):
        result = transcode(*args, **kwargs)
        planted.append(a_track_whose_master_is_missing(world, world.new))
        return result

    monkeypatch.setattr(conversion_module, "transcode", transcode_while_the_path_is_taken)

    world.run_writer()

    assert world.job() == ("failed", "could not place the converted master")
    assert not os.path.lexists(world.new)
    assert world.track_naming(world.new) == planted
    check_settled(world, Expect(OLD, 0, "kept", job=("failed", ANY_TEXT)))


@pytest.mark.parametrize("spelling", ["the same spelling", "another letter case"])
@pytest.mark.parametrize("name", ["W1", "W2"])
def test_a_row_that_takes_the_path_after_the_check_undoes_the_move(
    tmp_path, monkeypatch, name, spelling
):
    """The move's own question was answered "free"; before the commit another
    track's row comes to name the path (two writers racing for it). The
    database refuses the commit (the unique index), and the moving sequence
    undoes what it did: the new copy leaves the library, the journal row goes,
    the staged copy is dropped. The edit answers "could not place the master at
    its new location" and the conversion's job fails with "could not place the
    converted master": what each answers for a file at the path."""
    world = build_world(tmp_path, monkeypatch, WRITERS[name])
    a_path = world.new if spelling == "the same spelling" else _other_case(world.new)
    flush = master_replace.flush_journal_row
    planted = []

    def the_other_writer_commits(*args, **kwargs):
        # After the question and the journal row, before the file is moved.
        planted.append(a_track_whose_master_is_missing(world, a_path))
        with world.outside():
            if a_path.parent != world.old.parent and not any(a_path.parent.iterdir()):
                a_path.parent.rmdir()
        return flush(*args, **kwargs)

    monkeypatch.setattr(master_replace, "flush_journal_row", the_other_writer_commits)

    if name == "W1":
        with pytest.raises(MasterWriteError, match="could not place the master at its new location"):
            world.run_writer()
    else:
        world.run_writer()
        assert world.job() == ("failed", "could not place the converted master")

    assert len(planted) == 1
    assert not os.path.lexists(world.new)
    assert world.track(planted[0])["file_path"] == str(a_path)
    assert world.journal() == [] and world.staged() == []
    check_settled(world, Expect(OLD, 0, "kept", job=("failed", ANY_TEXT)))


def test_a_conversion_request_is_refused_when_another_tracks_row_names_the_new_path(
    tmp_path, monkeypatch
):
    """At the request, as for a file on disk at the path: ``TargetPathTaken``
    (the route answers 409 ``target_exists``), and no job is queued."""
    world = build_world(tmp_path, monkeypatch, WRITERS["W3"])
    a_track_whose_master_is_missing(world, world.old.with_suffix(".mp3"))

    with pytest.raises(TargetPathTaken):
        world.orchestrator.enqueue(
            world.library(), world.uuid, "mp3", 128, world.track()["revision"])

    assert world.sql("SELECT COUNT(*) AS n FROM conversion_jobs")[0]["n"] == 0
    check_settled(world, Expect(OLD, 0, "kept"))
