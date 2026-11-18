"""Two catalog rows must never come to name one file, and a deletion must
never take a file that another track's row names (pre-merge review B1-01).

The way in the review describes: track A's master is missing; a tag edit (or a
conversion to another file type) moves track B's file to the path A's row
still names; deleting A then moves "A's master" into the deletion's holding
folder and unlinks it: it is B's file.

The first test runs that story end to end over the real database and real
files: the real tag editor and the real conversion (the crash matrix's rig:
only the media tools are faked), then the real deletion executor.
"""

import os
import unicodedata
from pathlib import Path

import pytest

from app.services.cover_art_manager import CoverArtContext, CoverArtManager
from tests import deletion_world as deletion
from tests.replace_matrix_rig import WRITERS, build_world
from tests.track_paths import allow_two_tracks_on_one_path, set_track_path


def _deletion_view(world) -> deletion.World:
    """The rig's library as the deletion helpers see it: the same database,
    music folder and track locks."""
    database = world.db._real
    (world.music / ".deleting").mkdir(exist_ok=True)
    return deletion.World(
        tmp=world.tmp, db=database, music=world.music, owner=world.owner, sam=world.other,
        locks=world.locks,
        cover_art=CoverArtManager(
            CoverArtContext(cover_art_dir=world.tmp / "art", database=database)),
    )


def a_track_whose_master_is_missing(world, path: Path) -> str:
    """Track A: its row names ``path``, its file is gone (removed by hand)."""
    uuid_id = world.plant_track(path)
    with world.outside():
        path.unlink()
    return uuid_id


@pytest.mark.parametrize("name", ["W1", "W2"])
def test_deleting_a_track_never_takes_the_file_of_a_track_that_moved_to_its_path(
    tmp_path, monkeypatch, name
):
    """A's master is missing. B is edited (W1) or converted to another file
    type (W2) so that its new path is the one A's row names. Then A is deleted.
    Whatever each step answers, B still has its file afterwards."""
    world = build_world(tmp_path, monkeypatch, WRITERS[name])
    a = a_track_whose_master_is_missing(world, world.new)

    try:
        world.run_writer()
    except Exception:  # noqa: BLE001 - a refused edit is a fine answer here
        pass

    view = _deletion_view(world)
    op = deletion.accept_job(view, (a, deletion.revision(view, a)))
    with world.outside():
        deletion.drain(deletion.make_executor(view))

    assert deletion.item(view, op, a)["status"] == "deleted"
    assert deletion.tombstone(view, a) is not None
    b_path = Path(world.track()["file_path"])
    assert os.path.isfile(b_path), "track B's file is gone: the deletion of A took it"
    expected = world.writer.new_bytes if b_path == world.new else world.writer.old_bytes
    assert b_path.read_bytes() == expected
    assert deletion.files_under(world.music / ".deleting") == {}
    assert deletion.live(view, world.uuid)


# --- the deletion's side: a file another track's row names is left alone ------------------------------


@pytest.fixture
def library(tmp_path):
    return deletion.build_world(tmp_path)


REL = "Beyoncé/Lemonade/01 Formation.flac"  # NFC, as the import stores it


def _spelled(path: Path, spelling: str) -> str:
    """The same file under another spelling a caseless disk reads as one name."""
    if spelling == "another letter case":
        return str(path).replace("Beyoncé", "BEYONCÉ")
    if spelling == "another Unicode form":
        return unicodedata.normalize("NFD", str(path))
    return str(path)


@pytest.mark.parametrize("sharer", ["the owner's track", "another user's track"])
@pytest.mark.parametrize(
    "spelling", ["the same spelling", "another letter case", "another Unicode form"])
def test_a_deletion_never_moves_a_file_another_tracks_row_names(library, spelling, sharer):
    """Two rows name one file: A's own file is gone and B's file lies at the
    path A's row names (B's row spells it the same, in another letter case or
    in another Unicode form). Deleting A removes A's catalog entry, as for a
    missing master, and leaves the file alone: not moved, not unlinked."""
    world = library
    a = deletion.add_master(world, REL, create_file=False)
    path = world.root(world.owner) / REL
    # Two rows naming one file: the state the unique index now refuses.
    allow_two_tracks_on_one_path(world.db)
    b = deletion.add_master(
        world, REL, title="B", data=b"track B's audio",
        owner=world.owner if sharer == "the owner's track" else world.sam)
    if sharer == "another user's track":  # its row names the owner's path
        os.replace(world.root(world.sam) / REL, _made(path))
    set_track_path(world.db, b, _spelled(path, spelling))
    before = os.lstat(path)
    op = deletion.accept_job(world, (a, deletion.revision(world, a)))
    seen = {}

    deletion.make_executor(
        world, seam=lambda name: seen.setdefault(name, deletion.journal(world, a))).run_one()

    # The steps of a catalog-only deletion: nothing was moved or unlinked.
    assert list(seen) == ["after_claim", "after_journal", "after_commit", "after_evict"]
    row = seen["after_journal"]
    assert (row["master_missing"], row["quarantine_path"], row["src_ino"]) == (1, None, None)
    after = os.lstat(path)
    assert (after.st_ino, after.st_size, after.st_mtime_ns) == (
        before.st_ino, before.st_size, before.st_mtime_ns)
    assert path.read_bytes() == b"track B's audio"
    assert deletion.files_under(world.music / ".deleting") == {}
    assert deletion.item(world, op, a)["status"] == "deleted"
    assert deletion.item(world, op, a)["details"] == ["master_missing"]
    assert deletion.tombstone(world, a) is not None and deletion.journal(world, a) is None
    assert deletion.live(world, b)
    assert str(deletion.path_of(world, b)) == _spelled(path, spelling)


def _made(path: Path) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    return path


def test_a_track_alone_at_its_path_is_still_deleted_with_its_file(library):
    """The control: the same library without the second row. The file goes."""
    world = library
    a = deletion.add_master(world, REL, data=b"track A's audio")
    deletion.add_master(world, "Beyoncé/Lemonade/02 Sorry.flac", title="B")
    op = deletion.accept_job(world, (a, deletion.revision(world, a)))

    deletion.drain(deletion.make_executor(world))

    assert deletion.item(world, op, a) | {"tombstone_revision": None, "lease": None} == {
        "status": "deleted", "error": None, "details": [], "tombstone_revision": None,
        "lease": None,
    }
    assert sorted(deletion.files_under(world.music)) == ["owner/Beyoncé/Lemonade/02 Sorry.flac"]
