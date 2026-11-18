"""What each writer of a track's path answers when the database itself refuses
the row (pre-merge PM-BE-PATHKEY).

Every writer asks first whether the path is taken (the import's name choice,
``track_path_in_use`` before an upload's placement, an edit's move, a
conversion, recovery). The unique index on the folded path is what is left
when that answer was true a moment ago and is not any more: another writer's
row came to name the path in between. Each test here lets the writer's own
check pass and then plants that row, so the index is what refuses; the writer
must give the answer it gives for a taken path, with its file put back.

The import and the leftover file of start-up recovery are here; the tag
edit's move and the conversion are in ``tests/test_move_to_named_path.py``,
the upload in ``tests/test_upload_publish_failures.py``, recovery's adoption
in ``tests/test_journal_settle.py``.
"""

from pathlib import Path
from unittest.mock import patch

import pytest

from app.models import Track
from app.services.cover_art_manager import CoverArtAddResult
from app.services.import_outcome import ImportOutcome
from app.services.organizer import Organizer, OrganizerContext
from tests.name_clash_rig import META, Rig
from tests.track_paths import stale_path_rows


@pytest.fixture
def rig(tmp_path, monkeypatch):
    return Rig(tmp_path, monkeypatch)


def _another_writer_commits_after_the_read(rig, monkeypatch, path: Path) -> list[Track]:
    """The import reads the folder's tracks; right after that read another
    writer's row comes to name ``path`` (its file is not there: on a disk that
    tells letter case apart it lies under the other spelling)."""
    read = rig.db.track_identities_in_folder
    planted: list[Track] = []

    def read_then_commit(folder, **kwargs):
        rows = read(folder, **kwargs)
        if not planted:
            planted.append(Track(file_path=path, metadata=META))
            assert rig.db.add_track(planted[0])
        return rows

    monkeypatch.setattr(rig.db, "track_identities_in_folder", read_then_commit)
    return planted


def _import(rig, source: Path, how: str):
    if how == "a loose file":
        return rig.organize(source)
    with (  # an archive's member reaches the same organizer through the ingestor
        patch("app.services.ingestion.does_music_pass_quick_check", return_value=True),
        patch("app.services.organizer.get_track_metadata", return_value=META),
        patch("app.services.organizer.extract_cover_art_bytes", return_value=None),
    ):
        return rig.ingestor._ingest_member(source)


@pytest.mark.parametrize("how", ["a loose file", "an archive's member"])
@pytest.mark.parametrize("name", ["song.flac", "SONG.flac"])
def test_an_import_whose_row_the_database_refuses_gets_a_numbered_name(rig, monkeypatch, how, name):
    """The name was free when it was chosen; the row is refused. The file is
    taken back out of the library and the name chosen again: the numbered
    name, as for any name a different track already has."""
    planted = _another_writer_commits_after_the_read(rig, monkeypatch, rig.folder / name)
    source = rig.source("b", "song.flac", b"two|t")

    assert _import(rig, source, how) is ImportOutcome.IMPORTED

    assert rig.names() == ["song (2).flac"]
    assert rig.track_names() == sorted([name, "song (2).flac"])
    assert (rig.folder / "song (2).flac").read_bytes() == b"two|t"
    assert not source.exists()
    assert [t.uuid_id for t in planted] == [
        t.uuid_id for t in rig.db.get_tracks(owner_id=rig.db.owner_id)
        if Path(t.file_path).name == name]
    assert stale_path_rows(rig.db) == []


def test_an_import_that_cannot_take_its_file_back_fails_like_any_failed_row_write(rig, monkeypatch):
    """The import's undo of a failed row write is to move the file back; when
    that cannot be done (here: something took its place in the import folder)
    the import ends as it always did for a row it could not write."""
    _another_writer_commits_after_the_read(rig, monkeypatch, rig.folder / "SONG.flac")
    source = rig.source("b", "song.flac", b"two|t")
    moved = []

    def move_then_block_the_way_back(file_path, destination_path):
        from app.services.file_ops import move_file

        done = move_file(file_path=file_path, destination_path=destination_path)
        moved.append(destination_path)
        file_path.write_bytes(b"something else took the place")
        return done

    monkeypatch.setattr("app.services.organizer.move_file", move_then_block_the_way_back)

    assert rig.organize(source) is ImportOutcome.DATABASE_ERROR

    assert len(moved) == 1
    assert rig.track_names() == ["SONG.flac"]
    assert stale_path_rows(rig.db) == []
    # Where that leaves the file (an open item, stated here so it is not a
    # surprise): in the library, under the name it was moved to, with no row of
    # its own. The row that was planted names a spelling of that name.
    assert moved[0] == rig.folder / "song.flac"
    assert moved[0].read_bytes() == b"two|t"
    assert source.read_bytes() == b"something else took the place"


def test_a_leftover_file_whose_row_the_database_refuses_does_not_become_a_track(rig):
    """Start-up recovery registers a leftover file where it lies
    (``register_in_place``). Its check passed; the row is refused: no track,
    the file untouched, art made for it released (the answer for a path that
    is in use)."""
    leftover = rig.folder / "song.flac"
    leftover.parent.mkdir(parents=True)
    leftover.write_bytes(b"two|t")
    assert rig.db.add_track(Track(file_path=rig.folder / "SONG.flac", metadata=META))
    released = []
    organizer = Organizer(OrganizerContext(
        music_library_dir=rig.root, should_organize_files=True, should_copy_files=False,
        add_to_database=lambda track: rig.db.add_track(track),
        add_cover_art=lambda image: CoverArtAddResult(cover_art_id=7, was_created=True),
        release_cover_art=lambda art_id: released.append(art_id) or True,
        path_in_use=lambda path: False,  # asked before the other row was committed
    ))

    with patch("app.services.organizer.extract_cover_art_bytes", return_value=b"img"):
        made = organizer.register_in_place(leftover, META.model_copy(update={"has_album_art": True}))

    assert made is None
    assert leftover.read_bytes() == b"two|t"
    assert rig.track_names() == ["SONG.flac"]
    assert released == [7]
