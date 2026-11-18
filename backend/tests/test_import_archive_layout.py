"""Round 2 review fix: import-folder archive members are unpacked flat
(``<unpack>/<position>/<file name>``) instead of at their path inside the
archive (``<unpack>/Album/Disc 1/01.flac``, the earlier layout). Pinned
here: what a person ends up with does not depend on that layout. The
organizer reads only the member's file name and its tags (``organizer.py``:
``sanitize_file_name(file_path.name)`` and ``get_track_metadata``; cover art is
the embedded picture only; there is no title/album/artist/track fallback from
folder names and no ``.cue``/``.lrc``/cover-file pickup), so the library path,
the numbering of a taken name, the refusals and ``.imported/`` are the same."""

import contextlib
import shutil
import zipfile
from pathlib import Path
from unittest.mock import patch

import pytest

from app.database import DatabaseContext
from app.models import TrackMetaData
from app.services import ingestion
from app.services.cover_art_manager import CoverArtContext, CoverArtManager
from app.services.import_outcome import ImportOutcome
from app.services.pipeline import make_pipeline
from tests.owned_database import OwnedTestDatabase, add_test_user
from tests.schema_fixtures import INIT_SQL

# Tags per file name (an untagged member has none).
TAGS = {
    "01 Song.flac": TrackMetaData(title="Song", artist="Radiohead", album="OK Computer", duration=1.0),
}


def _env(root: Path):
    root.mkdir(parents=True, exist_ok=True)
    db = OwnedTestDatabase(DatabaseContext(database_path=root / "db.sqlite", init_sql_path=INIT_SQL))
    assert db.initialize()
    manager = CoverArtManager(CoverArtContext(cover_art_dir=root / "art", database=db))
    sam = add_test_user(db, "Sam")
    organizer, ingestor = make_pipeline(db.get_user(sam), database=db, cover_art_manager=manager,
                                        music_library_dir=root / "music",
                                        workspace_root=root / "data" / "workspace")
    return db, sam, organizer, ingestor


@contextlib.contextmanager
def _tags_by_name(names_to_tags):
    def metadata(file_path):
        return names_to_tags.get(Path(file_path).name)

    with (
        patch("app.services.organizer.get_track_metadata", side_effect=metadata),
        patch("app.services.organizer.extract_cover_art_bytes", return_value=None),
        patch.object(ingestion, "does_music_pass_quick_check", return_value=True),
    ):
        yield


def _library(root: Path):
    music = root / "music"
    return sorted(str(p.relative_to(music)) for p in music.rglob("*") if p.is_file()) if music.exists() else []


@pytest.mark.parametrize("old_layout,new_layout,expected", [
    ("unpack-old/Album/Disc 1/01 Song.flac", "unpack-new/0/01 Song.flac",
     (ImportOutcome.IMPORTED, ["sam/Radiohead/OK Computer/01 Song.flac"])),
    ("unpack-old/untagged/x.mp3", "unpack-new/3/x.mp3", (ImportOutcome.FAILS_CHECK, [])),
])
def test_the_library_result_does_not_depend_on_the_unpack_folder(tmp_path, old_layout, new_layout, expected):
    """The same member at its old place and at its new place: same outcome,
    same library path (tagged), same refusal (untagged)."""
    results = []
    for layout, name in (("old", old_layout), ("new", new_layout)):
        root = tmp_path / layout
        _, _, organizer, _ = _env(root)
        member = root / "data" / "workspace" / name
        member.parent.mkdir(parents=True)
        member.write_bytes(b"audio bytes")
        with _tags_by_name(TAGS):
            outcome = organizer.organize(member)
        results.append((outcome, _library(root)))

    assert results[0] == results[1] == expected


def test_an_archive_imports_by_tags_and_file_names_only(tmp_path):
    """Two discs of one album in two folders of the archive, a cover file and
    a cue sheet beside them, a macOS helper, and an untagged file."""
    db, sam, _, ingestor = _env(tmp_path)
    folder = tmp_path / "import-users" / "sam"
    folder.mkdir(parents=True)
    archive = folder / "album.zip"
    with zipfile.ZipFile(archive, "w") as z:
        z.writestr("OK Computer/Disc 1/01 Song.flac", b"disc one audio")
        z.writestr("OK Computer/Disc 2/01 Song.flac", b"disc two audio")
        z.writestr("OK Computer/cover.jpg", b"jpeg")
        z.writestr("OK Computer/folder.jpg", b"jpeg")
        z.writestr("OK Computer/album.cue", b"cue")
        z.writestr("OK Computer/Disc 1/01 Song.lrc", b"lyrics")
        z.writestr("__MACOSX/OK Computer/._cover.jpg", b"mac")
        z.writestr("untagged/x.mp3", b"no tags")
    disc_tags = {"01 Song.flac": TAGS["01 Song.flac"]}  # both discs' file has the same name

    seen = []
    with _tags_by_name(disc_tags):
        real = ingestor._ingest_member

        def member(path):
            seen.append(path.name)
            return real(path)

        with patch.object(ingestor, "_ingest_member", side_effect=member):
            outcome = ingestor.ingest(archive, imported_dir=folder / ".imported")

    assert outcome is ImportOutcome.IMPORTED
    assert sorted(seen) == ["01 Song.flac", "01 Song.flac", "x.mp3"]  # audio only, by name
    # One album folder from the tags; the second disc's taken name is numbered;
    # covers, cue and lyrics files are never imported (before or after).
    tracks = db.get_tracks(owner_id=sam)
    assert len(tracks) == 2
    assert {Path(t.file_path).parent.name for t in tracks} == {"OK Computer"}
    assert sorted(Path(t.file_path).name for t in tracks) == ["01 Song (2).flac", "01 Song.flac"]
    # The untagged member is refused for its own content: the archive goes to
    # .imported/ whole, and nothing of it stays in the workspace.
    assert [p.name for p in (folder / ".imported").iterdir()] == ["album.zip"]
    workspace = tmp_path / "data" / "workspace"
    assert [p for p in workspace.rglob("*") if p.is_file()] == []
    shutil.rmtree(tmp_path / "import-users")
