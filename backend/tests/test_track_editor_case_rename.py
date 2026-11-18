"""A tag edit that changes only the letter case of the artist or album folder
(U07-B-01 / OPEN-A-02).

On a case-insensitive disk (the Mac default) the "new" path is another spelling
of the same file: the edit is written in place, the stored path keeps the
spelling that is on disk, and the next edit of the track works too. On a
case-sensitive disk the two spellings are different folders and the master
moves, as before. Each test detects the kind of disk of its own temp directory
at run time and is skipped on the other kind."""
from pathlib import Path

import pytest

from app.services import master_replace
from app.services import metadata as metadata_mod
from app.services import track_editor as track_editor_mod
from app.services.track_edit import WriteMode
from app.services.track_editor import TrackEditor, reconcile_journal
from tests.track_editor_fixtures import _add_track, _db, _lib, _make_audio

requires_ffmpeg = pytest.mark.requires_ffmpeg


def _case_insensitive(directory: Path) -> bool:
    probe = directory / "case-probe"
    probe.mkdir()
    (probe / "a").write_bytes(b"")
    return (probe / "A").exists()


@pytest.fixture
def ci_tmp(tmp_path):
    if not _case_insensitive(tmp_path):
        pytest.skip("needs a case-insensitive temp directory (the macOS default disk)")
    return tmp_path


@pytest.fixture
def cs_tmp(tmp_path):
    if _case_insensitive(tmp_path):
        pytest.skip("needs a case-sensitive temp directory (Linux, or a case-sensitive volume)")
    return tmp_path


def _world(tmp_path, artist, album, parts):
    library = tmp_path / "music"
    audio = library.joinpath("owner", *parts, "song.m4a")
    _make_audio(audio, title="T", artist=artist, album=album)
    db = _db(tmp_path)
    track = _add_track(db, audio, "T", artist, album=album)
    return library, audio, db, track


def _edit(db, library, track_uuid, fields, mode=WriteMode.db_and_master):
    rev = db.get_track_by_uuid(track_uuid).revision
    return TrackEditor(library, library / ".staging").apply_edit(
        _lib(db), track_uuid, fields, rev, mode)


def _names(directory: Path) -> list[str]:
    return sorted(p.name for p in directory.iterdir())


def _assert_clean(db, library):
    assert db.list_journal_entries() == []
    staging = library / ".staging"
    assert not staging.exists() or list(staging.iterdir()) == []


# -- case-insensitive disk: written in place --------------------------------


@requires_ffmpeg
@pytest.mark.parametrize("fields,parts,expect_artist,expect_album", [
    ({"artist": "Metallica"}, ("metallica", "Album"), "Metallica", "Album"),
    ({"album": "Album"}, ("Art", "album"), "Art", "Album"),
    ({"artist": "Metallica", "album": "Album"}, ("metallica", "album"), "Metallica", "Album"),
], ids=["artist-only", "album-only", "both"])
def test_a_case_only_edit_is_written_in_place(ci_tmp, fields, parts, expect_artist, expect_album):
    old_artist, old_album = parts
    library, audio, db, track = _world(ci_tmp, old_artist, old_album, parts)
    sibling = audio.parent / "other.m4a"
    sibling.write_bytes(b"another track's master")

    _, written = _edit(db, library, track.uuid_id, fields)

    assert written is True
    stored = db.get_track_file_path(track.uuid_id)
    assert stored == str(audio)  # the spelling on disk
    tags = metadata_mod.get_track_metadata(Path(stored))
    assert (tags.artist, tags.album) == (expect_artist, expect_album)
    meta = db.get_track_by_uuid(track.uuid_id).metadata
    assert (meta.artist, meta.album) == (expect_artist, expect_album)
    # The folders keep their old capitals; nothing else in them is touched.
    assert _names(library / "owner") == [old_artist]
    assert _names(library / "owner" / old_artist) == [old_album]
    assert _names(audio.parent) == ["other.m4a", "song.m4a"]
    assert sibling.read_bytes() == b"another track's master"
    _assert_clean(db, library)

    # The next edit of the track works too.
    _edit(db, library, track.uuid_id, {"title": "Next"})
    assert metadata_mod.get_track_metadata(audio).title == "Next"
    assert db.get_track_file_path(track.uuid_id) == str(audio)
    _assert_clean(db, library)


@requires_ffmpeg
def test_a_file_edit_after_a_database_only_case_fix_is_written_in_place(ci_tmp):
    library, audio, db, track = _world(ci_tmp, "metallica", "Album", ("metallica", "Album"))
    _, written = _edit(db, library, track.uuid_id, {"artist": "Metallica"}, WriteMode.db_only)
    assert written is False

    _, written = _edit(db, library, track.uuid_id, {"title": "New Title"})

    assert written is True
    assert db.get_track_file_path(track.uuid_id) == str(audio)
    tags = metadata_mod.get_track_metadata(audio)
    assert (tags.title, tags.artist) == ("New Title", "Metallica")
    assert db.get_track_by_uuid(track.uuid_id).metadata.title == "New Title"
    assert _names(library / "owner") == ["metallica"]
    _assert_clean(db, library)


@requires_ffmpeg
def test_a_case_change_with_a_real_album_rename_moves_the_master(ci_tmp):
    library, audio, db, track = _world(ci_tmp, "metallica", "Old", ("metallica", "Old"))

    _edit(db, library, track.uuid_id, {"artist": "Metallica", "album": "New"})

    new_path = library / "owner" / "Metallica" / "New" / "song.m4a"
    stored = db.get_track_file_path(track.uuid_id)
    assert stored == str(new_path)
    assert Path(stored).exists()
    assert metadata_mod.get_track_metadata(Path(stored)).album == "New"
    # The existing artist folder is reused under its old capitals.
    assert _names(library / "owner") == ["metallica"]
    assert _names(library / "owner" / "metallica") == ["New"]
    _assert_clean(db, library)

    _edit(db, library, track.uuid_id, {"title": "Next"})
    assert metadata_mod.get_track_metadata(new_path).title == "Next"
    _assert_clean(db, library)


@requires_ffmpeg
def test_a_forced_case_only_relocate_never_deletes_the_new_master(ci_tmp, monkeypatch):
    """The guarantee behind the fix: even if the in-place decision missed a
    case-only spelling and the move were allowed, the committed relocate must not
    unlink the source when it is the same file as the new master."""
    library, audio, db, track = _world(ci_tmp, "metallica", "Album", ("metallica", "Album"))
    monkeypatch.setattr(track_editor_mod, "_another_spelling_of", lambda dest, source: False)

    def unchecked_move(file_path, destination_path):
        destination_path.parent.mkdir(parents=True, exist_ok=True)
        file_path.replace(destination_path)
        return True

    monkeypatch.setattr(master_replace, "move_file", unchecked_move)

    _edit(db, library, track.uuid_id, {"artist": "Metallica"})

    stored = Path(db.get_track_file_path(track.uuid_id))
    assert stored.exists()
    assert metadata_mod.get_track_metadata(stored).artist == "Metallica"
    _assert_clean(db, library)


@requires_ffmpeg
def test_a_folder_spelled_in_another_unicode_form_is_written_in_place(ci_tmp):
    nfd = "beyonce\u0301"  # decomposed on disk; the edit's destination is NFC
    library, audio, db, track = _world(ci_tmp, nfd, "Album", (nfd, "Album"))

    _edit(db, library, track.uuid_id, {"artist": "Beyonc\u00e9"})

    stored = Path(db.get_track_file_path(track.uuid_id))
    assert stored.samefile(audio)
    assert metadata_mod.get_track_metadata(stored).artist == "Beyonc\u00e9"
    assert len(_names(library / "owner")) == 1
    _assert_clean(db, library)


@requires_ffmpeg
def test_a_crash_before_the_in_place_replace_is_finished_by_recovery(ci_tmp, monkeypatch):
    library, audio, db, track = _world(ci_tmp, "metallica", "Album", ("metallica", "Album"))
    real_replace = track_editor_mod.os.replace

    def crash(src, dst):
        raise OSError("simulated crash before the replace")

    monkeypatch.setattr(track_editor_mod.os, "replace", crash)
    with pytest.raises(track_editor_mod.MasterSwapPending):
        _edit(db, library, track.uuid_id, {"artist": "Metallica"})
    monkeypatch.setattr(track_editor_mod.os, "replace", real_replace)
    rows = db.list_journal_entries()
    assert [(e["intent"], e["old_path"]) for e in rows] == [("inplace", str(audio))]

    reconcile_journal(db, library)  # restart

    assert db.get_track_file_path(track.uuid_id) == str(audio)
    assert metadata_mod.get_track_metadata(audio).artist == "Metallica"
    _assert_clean(db, library)


# -- case-sensitive disk: the master still moves ------------------------------


@requires_ffmpeg
def test_on_a_case_sensitive_disk_a_case_only_edit_moves_the_master(cs_tmp):
    library, audio, db, track = _world(cs_tmp, "metallica", "Album", ("metallica", "Album"))

    _, written = _edit(db, library, track.uuid_id, {"artist": "Metallica"})

    assert written is True
    new_path = library / "owner" / "Metallica" / "Album" / "song.m4a"
    assert db.get_track_file_path(track.uuid_id) == str(new_path)
    assert metadata_mod.get_track_metadata(new_path).artist == "Metallica"
    assert not audio.exists()
    assert _names(library / "owner") == ["Metallica"]
    _assert_clean(db, library)
