"""``file_ops.rollback_move`` on its own (pre-merge D2-05): an import moved a
file into the library, the catalog write failed, and the move is undone.

These pin today's behaviour of each branch. The "original already exists"
branch leaves the moved file in the library (see the test's note)."""

import errno
from pathlib import Path

from app.services import file_ops


def _files(root: Path) -> dict[str, bytes]:
    return {str(p.relative_to(root)): p.read_bytes() for p in sorted(root.rglob("*")) if p.is_file()}


def _moved(tmp_path):
    """The state after the import's move: the file is at the library path, the
    import path's folder exists and is empty."""
    original = tmp_path / "import" / "inbox" / "song.flac"
    destination = tmp_path / "music" / "Artist" / "Album" / "song.flac"
    original.parent.mkdir(parents=True)
    destination.parent.mkdir(parents=True)
    destination.write_bytes(b"moved bytes")
    return original, destination


def test_the_moved_file_goes_back_to_its_original_path(tmp_path):
    original, destination = _moved(tmp_path)
    original.parent.rmdir()  # the folder went too: it is made again

    assert file_ops.rollback_move(destination_path=destination, original_path=original) is True

    assert _files(tmp_path) == {"import/inbox/song.flac": b"moved bytes"}


def test_without_a_file_at_the_destination_nothing_changes(tmp_path):
    original, destination = _moved(tmp_path)
    destination.unlink()

    assert file_ops.rollback_move(destination_path=destination, original_path=original) is False

    assert _files(tmp_path) == {}
    assert not original.exists()


def test_a_file_already_at_the_original_path_is_kept_and_so_is_the_moved_one(tmp_path):
    """Today: both files keep their bytes, and the moved one stays at the library
    path. After a failed catalog write no track names it (reported as a finding,
    not changed here)."""
    original, destination = _moved(tmp_path)
    original.write_bytes(b"copied again")

    assert file_ops.rollback_move(destination_path=destination, original_path=original) is False

    assert _files(tmp_path) == {
        "import/inbox/song.flac": b"copied again",
        "music/Artist/Album/song.flac": b"moved bytes",
    }


def test_a_move_back_that_the_disk_refuses_leaves_the_file_at_the_destination(tmp_path, monkeypatch):
    original, destination = _moved(tmp_path)
    tried = []

    def refuse(self, target):
        tried.append((self, target))
        raise PermissionError(errno.EACCES, "Permission denied")

    monkeypatch.setattr(Path, "replace", refuse)

    assert file_ops.rollback_move(destination_path=destination, original_path=original) is False

    monkeypatch.undo()
    assert tried == [(destination, original)]
    assert _files(tmp_path) == {"music/Artist/Album/song.flac": b"moved bytes"}
