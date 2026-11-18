import os
from pathlib import Path

import pytest

from app.library import Library
from tests.owned_database import add_test_user
from tests.track_editor_fixtures import _add_track, _db, _lib, _make_audio
from app.models.track import Track
from app.models.track_meta_data import TrackMetaData
from app.services import metadata as metadata_mod
from app.services.metadata import TagWriteError, is_wav, write_metadata_tags
from app.services.path_sanitize import PathEscapesRoot, UnsafePathComponent, sanitize_path_component
from app.services.track_edit import WriteMode
from app.services.track_editor import MasterSwapPending, TrackEditor, reconcile_journal

# Registered marker (plan D16): tests/conftest.py skips without ffmpeg/ffprobe.
requires_ffmpeg = pytest.mark.requires_ffmpeg


# ── sanitization (no ffmpeg) ────────────────────────────────────────────────

class TestSanitize:
    def test_replaces_separators_and_controls(self):
        assert sanitize_path_component("AC/DC") == "AC_DC"
        assert sanitize_path_component("a\\b") == "a_b"
        assert sanitize_path_component("a\x00b") == "a_b"

    def test_strips_trailing_space_and_dot(self):
        assert sanitize_path_component("Album. ") == "Album"

    def test_rejects_dot_specials_and_empty(self):
        # "/" is not here — it sanitizes to "_" (a valid name), covered above.
        for bad in (".", "..", "   ", ""):
            with pytest.raises(UnsafePathComponent):
                sanitize_path_component(bad)

    def test_length_capped(self):
        assert len(sanitize_path_component("x" * 500)) <= 200


# ── tag writer (ffmpeg) ─────────────────────────────────────────────────────

@requires_ffmpeg
class TestTagWriter:
    def test_roundtrip_writes_tags(self, tmp_path):
        src = tmp_path / "in.m4a"
        _make_audio(src, title="Old", artist="A")
        dest = tmp_path / "out.m4a"

        write_metadata_tags(src, dest, {"title": "New Title", "artist": "New Artist"})

        meta = metadata_mod.get_track_metadata(dest)
        assert meta is not None
        assert meta.title == "New Title"
        assert meta.artist == "New Artist"

    def test_clearing_a_tag(self, tmp_path):
        src = tmp_path / "in.m4a"
        _make_audio(src, title="HasTitle")
        dest = tmp_path / "out.m4a"

        write_metadata_tags(src, dest, {"title": None})

        meta = metadata_mod.get_track_metadata(dest)
        assert meta is None or not meta.title

    def test_corrupt_source_raises(self, tmp_path):
        bogus = tmp_path / "notaudio.m4a"
        bogus.write_bytes(b"this is not audio")
        with pytest.raises(TagWriteError):
            write_metadata_tags(bogus, tmp_path / "out.m4a", {"title": "X"})

    def test_audio_bytes_preserved(self, tmp_path):
        # -c copy must not re-encode; the audio stream duration stays the same.
        src = tmp_path / "in.m4a"
        _make_audio(src, title="A")
        dest = tmp_path / "out.m4a"
        write_metadata_tags(src, dest, {"title": "B"})
        assert metadata_mod.get_track_metadata(dest).duration == pytest.approx(
            metadata_mod.get_track_metadata(src).duration, abs=0.05
        )


def test_is_wav():
    assert is_wav(Path("/x/song.wav"))
    assert is_wav(Path("/x/SONG.WAV"))
    assert not is_wav(Path("/x/song.m4a"))


# ── TrackEditor with a real master (ffmpeg) ─────────────────────────────────

@requires_ffmpeg
class TestTrackEditorMaster:
    def _editor(self, db, library):
        return TrackEditor(library, library / ".staging")

    def test_inplace_rewrites_tags_same_path(self, tmp_path):
        library = tmp_path / "music"
        audio = library / "owner" / "Art" / "song.m4a"
        _make_audio(audio, title="Old", artist="Art")
        db = _db(tmp_path)
        track = _add_track(db, audio, "Old", "Art")

        rev, master_written = self._editor(db, library).apply_edit(
            _lib(db), track.uuid_id, {"title": "New"}, track.revision, WriteMode.db_and_master
        )

        assert master_written is True
        assert audio.exists()  # artist unchanged → in-place
        assert metadata_mod.get_track_metadata(audio).title == "New"
        assert rev > track.revision
        assert db.get_track_file_path(track.uuid_id) == str(audio)

    def test_relocation_moves_master_and_updates_path(self, tmp_path):
        library = tmp_path / "music"
        audio = library / "owner" / "Old" / "song.m4a"
        _make_audio(audio, title="T", artist="Old")
        db = _db(tmp_path)
        track = _add_track(db, audio, "T", "Old")

        _, master_written = self._editor(db, library).apply_edit(
            _lib(db), track.uuid_id, {"artist": "New"}, track.revision, WriteMode.db_and_master
        )

        new_path = library / "owner" / "New" / "song.m4a"
        assert master_written is True
        assert new_path.exists()
        assert not audio.exists()  # old master removed after commit
        assert db.get_track_file_path(track.uuid_id) == str(new_path)
        assert metadata_mod.get_track_metadata(new_path).artist == "New"
        assert db.list_journal_entries() == []  # journal cleared

    def test_relocation_leaves_orphaned_empty_source_directory(self, tmp_path):
        # When a track is the LAST one under its artist and gets renamed to a
        # different artist, `_relocate` (track_editor.py) moves the file into
        # the new artist's directory and unlinks the old file — but it never
        # looks at whether that removal just emptied "Old"'s directory.
        # `move_file`/`organizer.py` only ever creates destination
        # directories; nothing in this codebase ever prunes a source
        # directory. The empty "Old" folder is left behind on disk forever —
        # no sync, no restart, nothing currently cleans it up.
        library = tmp_path / "music"
        audio = library / "owner" / "Old" / "song.m4a"
        _make_audio(audio, title="T", artist="Old")
        db = _db(tmp_path)
        track = _add_track(db, audio, "T", "Old")

        self._editor(db, library).apply_edit(
            _lib(db), track.uuid_id, {"artist": "New"}, track.revision, WriteMode.db_and_master
        )

        new_path = library / "owner" / "New" / "song.m4a"
        assert new_path.exists()  # the track landed at its new home...
        assert not audio.exists()  # ...and the old file itself is gone...
        # ...but its now-empty parent directory should be too, and isn't.
        assert not (library / "owner" / "Old").exists(), (
            "orphaned empty artist directory left behind after relocation"
        )

    def test_relocation_keeps_directory_when_sibling_track_remains(self, tmp_path):
        # Two tracks share "Old"; only one relocates. Its sibling means "Old"
        # is not actually empty and must survive.
        library = tmp_path / "music"
        moved = library / "owner" / "Old" / "song1.m4a"
        sibling = library / "owner" / "Old" / "song2.m4a"
        _make_audio(moved, title="T1", artist="Old")
        _make_audio(sibling, title="T2", artist="Old")
        db = _db(tmp_path)
        track = _add_track(db, moved, "T1", "Old")

        self._editor(db, library).apply_edit(
            _lib(db), track.uuid_id, {"artist": "New"}, track.revision, WriteMode.db_and_master
        )

        assert (library / "owner" / "New" / "song1.m4a").exists()
        assert not moved.exists()
        assert (library / "owner" / "Old").exists(), "sibling's directory was pruned"
        assert sibling.exists()

    def test_relocation_prunes_multiple_empty_ancestor_levels(self, tmp_path):
        # Artist+album relocation empties both the album dir and, since it
        # was the only album, the artist dir above it too.
        library = tmp_path / "music"
        audio = library / "owner" / "Old" / "Album" / "song.m4a"
        _make_audio(audio, title="T", artist="Old", album="Album")
        db = _db(tmp_path)
        track = _add_track(db, audio, "T", "Old", album="Album")

        self._editor(db, library).apply_edit(
            _lib(db), track.uuid_id, {"artist": "New"}, track.revision, WriteMode.db_and_master
        )

        assert (library / "owner" / "New" / "Album" / "song.m4a").exists()
        assert not (library / "owner" / "Old" / "Album").exists()
        assert not (library / "owner" / "Old").exists(), (
            "emptied artist directory was left behind above the pruned album"
        )

    def test_relocation_conflict_reverts_file(self, tmp_path):
        library = tmp_path / "music"
        audio = library / "owner" / "Old" / "song.m4a"
        _make_audio(audio, title="T", artist="Old")
        db = _db(tmp_path)
        track = _add_track(db, audio, "T", "Old")

        from app.database.database import RevisionConflict

        with pytest.raises(RevisionConflict):
            self._editor(db, library).apply_edit(
                _lib(db), track.uuid_id, {"artist": "New"},
                track.revision + 999, WriteMode.db_and_master,
            )

        # DB unchanged, old master intact, no orphaned new file or journal rows.
        assert audio.exists()
        assert not (library / "owner" / "New" / "song.m4a").exists()
        assert db.get_track_file_path(track.uuid_id) == str(audio)
        assert db.list_journal_entries() == []

    def test_relocation_db_failure_after_move_prunes_new_directory(
        self, tmp_path, monkeypatch
    ):
        # Unlike test_relocation_conflict_reverts_file (which fails the
        # pre-flight revision check before move_file ever runs), this fails
        # AFTER move_file has already created the new artist directory and
        # placed the file — exercising _relocate's post-move except handler.
        library = tmp_path / "music"
        audio = library / "owner" / "Old" / "song.m4a"
        _make_audio(audio, title="T", artist="Old")
        db = _db(tmp_path)
        track = _add_track(db, audio, "T", "Old")

        def _boom(*args, **kwargs):
            raise RuntimeError("simulated db failure after move")

        monkeypatch.setattr(db, "apply_track_metadata_edit", _boom)

        with pytest.raises(RuntimeError):
            self._editor(db, library).apply_edit(
                _lib(db), track.uuid_id, {"artist": "New"}, track.revision,
                WriteMode.db_and_master,
            )

        assert audio.exists(), "old master kept since the DB never advanced"
        assert not (library / "owner" / "New" / "song.m4a").exists()
        assert not (library / "owner" / "New").exists(), (
            "orphaned empty artist directory left behind by move_file's mkdir"
        )
        assert db.get_track_file_path(track.uuid_id) == str(audio)
        assert db.list_journal_entries() == []

    def test_empty_field_master_write_retags_file(self, tmp_path):
        # Enabling master-write with no field edits reconciles the FILE to the
        # current DB metadata (not a bare remux): on-disk tags that drifted from
        # the DB — e.g. after an earlier db_only edit — are rewritten to match.
        # Must not trip EmptyTrackEdit (the merged DB state still has a title).
        library = tmp_path / "music"
        audio = library / "owner" / "Art" / "song.m4a"
        # The file's title has drifted away from the DB's title.
        _make_audio(audio, title="StaleFileTitle", artist="Art")
        db = _db(tmp_path)
        track = _add_track(db, audio, "DbTitle", "Art")

        rev, master_written = self._editor(db, library).apply_edit(
            _lib(db), track.uuid_id, {}, track.revision, WriteMode.db_and_master
        )

        assert master_written is True
        assert rev > track.revision
        assert audio.exists()  # artist unchanged → in-place re-tag
        # The file now carries the DB's value, proving the full-DB retag (the
        # old behavior left "StaleFileTitle" in place).
        assert metadata_mod.get_track_metadata(audio).title == "DbTitle"

    def test_master_write_pushes_full_db_metadata_to_file(self, tmp_path):
        # A master write that edits ONE field still reconciles every field: the
        # file ends up matching the full merged DB state, not just the edit.
        library = tmp_path / "music"
        audio = library / "owner" / "Art" / "song.m4a"
        _make_audio(audio, title="StaleTitle", artist="Art", genre="StaleGenre")
        db = _db(tmp_path)
        track = _add_track(db, audio, "DbTitle", "Art")

        # Edit only the genre via master write.
        self._editor(db, library).apply_edit(
            _lib(db), track.uuid_id, {"genre": "Rock"}, track.revision,
            WriteMode.db_and_master,
        )

        on_disk = metadata_mod.get_track_metadata(audio)
        assert on_disk.genre == "Rock"        # the edit landed
        assert on_disk.title == "DbTitle"     # and the drifted title was fixed

    def test_master_write_must_not_erase_file_tags_unknown_to_db(self, tmp_path):
        # A NULL DB column is not the same as "cleared by the user": ingest
        # only captures what ffprobe surfaces (e.g. track numbers like "A1" or
        # "1 of 12" parse to None, external taggers can add tags post-ingest).
        # Reconciling the file to the DB must not blanket-clear those tags —
        # here the file's genre was never in the DB and the edit never touched
        # genre, so `-metadata genre=` destroys master-file data.
        library = tmp_path / "music"
        audio = library / "owner" / "Art" / "song.m4a"
        _make_audio(audio, title="T", artist="Art", genre="FileOnlyGenre")
        db = _db(tmp_path)
        track = _add_track(db, audio, "T", "Art")  # DB row: genre = NULL

        self._editor(db, library).apply_edit(
            _lib(db), track.uuid_id, {"title": "NewTitle"}, track.revision,
            WriteMode.db_and_master,
        )

        on_disk = metadata_mod.get_track_metadata(audio)
        assert on_disk.title == "NewTitle"          # the edit landed
        assert on_disk.genre == "FileOnlyGenre"     # untouched tag survives

    def test_relocation_uses_nfc_folder_for_decomposed_artist(self, tmp_path):
        # The destination path must be derived from the same bytes the DB
        # stores. A decomposed-Unicode artist edit ("e" + combining acute)
        # NFC-normalizes before path computation, so the file lands in the
        # composed folder instead of a byte-different duplicate.
        library = tmp_path / "music"
        audio = library / "owner" / "Old" / "song.m4a"
        _make_audio(audio, title="T", artist="Old")
        db = _db(tmp_path)
        track = _add_track(db, audio, "T", "Old")

        self._editor(db, library).apply_edit(
            _lib(db), # "Cafe" + combining acute (decomposed form)
            track.uuid_id, {"artist": "Cafe\u0301"}, track.revision,
            WriteMode.db_and_master,
        )

        composed = library / "owner" / "Caf\u00e9" / "song.m4a"  # single-codepoint \u00e9
        assert composed.exists()
        assert db.get_track_file_path(track.uuid_id) == str(composed)

    def test_inplace_replace_failure_is_recoverable(self, tmp_path, monkeypatch):
        # A caught os.replace error (soft failure, not a hard crash) after the
        # DB commit + journal write must leave temp + journal row intact so
        # reconcile_journal can redo the replace. Regression: the old blanket
        # `finally: temp.unlink()` deleted the temp the journal referenced,
        # voiding the redo and stranding file=old/DB=new.
        library = tmp_path / "music"
        audio = library / "owner" / "Art" / "song.m4a"
        _make_audio(audio, title="Old", artist="Art")
        db = _db(tmp_path)
        track = _add_track(db, audio, "Old", "Art")
        editor = self._editor(db, library)

        def boom(src, dst):
            raise OSError("simulated replace failure")

        monkeypatch.setattr(os, "replace", boom)
        with pytest.raises(MasterSwapPending):
            editor.apply_edit(
                _lib(db), track.uuid_id, {"title": "New"}, track.revision,
                WriteMode.db_and_master,
            )

        # DB advanced, but the file is untouched and the staged temp + its
        # journal row survive for recovery.
        entries = db.list_journal_entries()
        assert len(entries) == 1 and entries[0]["intent"] == "inplace"
        temp = Path(entries[0]["temp_path"])  # the staged copy, named per operation
        assert temp.parent == library / ".staging"
        assert temp.exists()
        assert db.get_tracks()[0].revision > track.revision
        assert metadata_mod.get_track_metadata(audio).title == "Old"

        # Recovery completes the replace and clears the journal.
        monkeypatch.undo()
        reconcile_journal(db, library)
        assert metadata_mod.get_track_metadata(audio).title == "New"
        assert not temp.exists()
        assert db.list_journal_entries() == []


    def test_journal_row_belongs_to_the_tracks_owner(self, tmp_path, monkeypatch):
        library = tmp_path / "music"
        audio = library / "other" / "Art" / "song.m4a"
        _make_audio(audio, title="Old", artist="Art")
        db = _db(tmp_path)
        with db._connection(commit=True) as conn:
            other = conn.execute(
                "INSERT INTO users (username, username_key, password_hash, "
                "library_folder, created_at) VALUES ('other', 'other', 'h', 'other', 0)"
            ).lastrowid
        meta = TrackMetaData(
            codec="aac", duration=1.0, bitrate_kbps=128.0, sample_rate_hz=44100,
            channels=2, title="Old", artist="Art",
        )
        track = Track(file_path=audio, metadata=meta)
        assert db.add_track(track, owner_id=other)
        editor = self._editor(db, library)

        def boom(src, dst):
            raise OSError("simulated replace failure")

        monkeypatch.setattr(os, "replace", boom)
        with pytest.raises(MasterSwapPending):
            editor.apply_edit(
                Library(db, other, root=library / "other"), track.uuid_id, {"title": "New"},
                db.get_track_by_uuid(track.uuid_id, owner_id=other).revision,
                WriteMode.db_and_master,
            )

        [entry] = db.list_journal_entries(owner_id=other)
        assert entry["owner_id"] == other

    # ── Phase M: per-user roots (S5) ────────────────────────────────────────

    def test_second_users_relocation_lands_under_their_root(self, tmp_path):
        music = tmp_path / "music"
        audio = music / "sam" / "Old" / "song.m4a"
        _make_audio(audio, title="T", artist="Old")
        db = _db(tmp_path)
        sam = add_test_user(db, "sam")
        track = Track(file_path=audio, metadata=TrackMetaData(
            codec="aac", duration=1.0, bitrate_kbps=128.0, sample_rate_hz=44100,
            channels=2, title="T", artist="Old"))
        assert db.add_track(track, owner_id=sam)
        lib = Library(db, sam, root=music / "sam")

        self._editor(db, music).apply_edit(
            lib, track.uuid_id, {"artist": "New"}, track.revision,
            WriteMode.db_and_master,
        )

        new_path = music / "sam" / "New" / "song.m4a"
        assert new_path.exists()
        assert not audio.exists()
        assert db.get_track_file_path(track.uuid_id, owner_id=sam) == str(new_path)
        assert not (music / "owner").exists()
        assert not (music / "New").exists()
        assert sorted(p.name for p in music.iterdir() if p.name != ".staging") == ["sam"]

    def test_pruning_stops_at_the_owners_root(self, tmp_path):
        music = tmp_path / "music"
        root = music / "owner"
        audio = root / "Old" / "Album" / "song.m4a"
        _make_audio(audio, title="T", artist="Old", album="Album")
        db = _db(tmp_path)
        track = _add_track(db, audio, "T", "Old", album="Album")

        self._editor(db, music).apply_edit(
            _lib(db), track.uuid_id, {"artist": "New"}, track.revision,
            WriteMode.db_and_master,
        )

        assert (root / "New" / "Album" / "song.m4a").exists()
        assert not (root / "Old").exists()
        assert root.is_dir() and music.is_dir()

    # ── Phase M: path containment (S6) ──────────────────────────────────────

    def _assert_nothing_staged(self, music):
        staging = music / ".staging"
        assert not staging.exists() or [p for p in staging.rglob("*") if p.is_file()] == []

    def test_relocate_escaping_root_via_symlink_is_refused(self, tmp_path):
        music = tmp_path / "music"
        outside = tmp_path / "outside"
        outside.mkdir()
        root = music / "owner"
        audio = root / "Old" / "song.m4a"
        _make_audio(audio, title="T", artist="Old")
        (root / "Evil").symlink_to(outside, target_is_directory=True)
        db = _db(tmp_path)
        track = _add_track(db, audio, "T", "Old")
        before = audio.read_bytes()

        with pytest.raises(PathEscapesRoot):
            self._editor(db, music).apply_edit(
                _lib(db), track.uuid_id, {"artist": "Evil"}, track.revision,
                WriteMode.db_and_master,
            )

        assert list(outside.iterdir()) == []
        assert audio.read_bytes() == before
        assert metadata_mod.get_track_metadata(audio).artist == "Old"
        row = db.get_track_by_uuid(track.uuid_id)
        assert row.revision == track.revision
        assert db.get_track_file_path(track.uuid_id) == str(audio)
        assert row.metadata.artist == "Old"
        assert db.list_journal_entries() == []
        self._assert_nothing_staged(music)

    def test_a_user_folder_that_is_a_symlink_out_of_the_library_is_refused(self, tmp_path):
        """Review r1 m-R1-27: the root itself must be inside the music dir; a
        symlinked ``music/owner`` would otherwise make every path "inside"."""
        music = tmp_path / "music"
        outside = tmp_path / "outside"
        audio = outside / "Old" / "song.m4a"
        _make_audio(audio, title="T", artist="Old")
        music.mkdir()
        (music / "owner").symlink_to(outside, target_is_directory=True)
        db = _db(tmp_path)
        track = _add_track(db, music / "owner" / "Old" / "song.m4a", "T", "Old")
        before = audio.read_bytes()

        with pytest.raises(PathEscapesRoot):
            self._editor(db, music).apply_edit(
                _lib(db), track.uuid_id, {"artist": "New"}, track.revision,
                WriteMode.db_and_master,
            )

        assert sorted(p.name for p in outside.iterdir()) == ["Old"]
        assert audio.read_bytes() == before
        assert db.get_track_by_uuid(track.uuid_id).revision == track.revision
        self._assert_nothing_staged(music)

    def test_inplace_edit_of_master_resolving_outside_root_is_refused(self, tmp_path):
        music = tmp_path / "music"
        outside = tmp_path / "outside"
        root = music / "owner"
        root.mkdir(parents=True)
        (root / "Art").symlink_to(outside.resolve() if outside.exists() else outside,
                                  target_is_directory=True)
        audio = root / "Art" / "song.m4a"
        _make_audio(outside / "song.m4a", title="Old", artist="Art")
        db = _db(tmp_path)
        track = _add_track(db, audio, "Old", "Art")
        before = (outside / "song.m4a").read_bytes()

        with pytest.raises(PathEscapesRoot):
            self._editor(db, music).apply_edit(
                _lib(db), track.uuid_id, {"title": "New"}, track.revision,
                WriteMode.db_and_master,
            )

        assert (outside / "song.m4a").read_bytes() == before
        assert sorted(p.name for p in outside.iterdir()) == ["song.m4a"]
        row = db.get_track_by_uuid(track.uuid_id)
        assert row.revision == track.revision
        assert row.metadata.title == "Old"
        assert db.list_journal_entries() == []
        self._assert_nothing_staged(music)

    def test_master_in_another_users_folder_is_refused(self, tmp_path):
        music = tmp_path / "music"
        audio = music / "sam" / "Old" / "song.m4a"
        _make_audio(audio, title="T", artist="Old")
        db = _db(tmp_path)
        track = _add_track(db, audio, "T", "Old")
        before = audio.read_bytes()

        with pytest.raises(PathEscapesRoot):
            self._editor(db, music).apply_edit(
                _lib(db), track.uuid_id, {"artist": "New"}, track.revision,
                WriteMode.db_and_master,
            )

        assert audio.read_bytes() == before
        assert not (music / "sam" / "New").exists()
        assert not (music / "owner").exists()
        row = db.get_track_by_uuid(track.uuid_id)
        assert row.revision == track.revision
        assert db.get_track_file_path(track.uuid_id) == str(audio)
        assert db.list_journal_entries() == []
        self._assert_nothing_staged(music)

    def test_wav_degrades_to_db_only(self, tmp_path):
        library = tmp_path / "music"
        wav = library / "owner" / "Art" / "song.wav"
        wav.parent.mkdir(parents=True)
        wav.write_bytes(b"RIFFfake")
        db = _db(tmp_path)
        track = _add_track(db, wav, "Old", "Art")

        rev, master_written = self._editor(db, library).apply_edit(
            _lib(db), track.uuid_id, {"title": "New"}, track.revision, WriteMode.db_and_master
        )

        assert master_written is False  # WAV master left untouched
        assert rev > track.revision  # but the DB edit still applied


# ── year/date normalization (no ffmpeg) ─────────────────────────────────────

class TestTemporalNormalization:
    def _editor(self, db, tmp_path):
        return TrackEditor(tmp_path / "music", tmp_path / "music" / ".staging")

    def test_editing_date_derives_year(self, tmp_path):
        db = _db(tmp_path)
        track = _add_track(db, tmp_path / "song.m4a", "T", "Art")
        self._editor(db, tmp_path).apply_edit(
            _lib(db), track.uuid_id, {"date": "2019-05-01"}, track.revision, WriteMode.db_only
        )
        meta = db.get_tracks()[0].metadata
        assert meta.date == "2019-05-01"
        assert meta.year == 2019  # derived from the date's leading digits

    def test_editing_year_sets_date(self, tmp_path):
        db = _db(tmp_path)
        track = _add_track(db, tmp_path / "song.m4a", "T", "Art")
        self._editor(db, tmp_path).apply_edit(
            _lib(db), track.uuid_id, {"year": 2020}, track.revision, WriteMode.db_only
        )
        meta = db.get_tracks()[0].metadata
        assert meta.year == 2020
        assert meta.date == "2020"  # date column kept consistent

    def test_normalize_helper_edge_cases(self):
        from app.database.database import normalize_edit_fields
        # date is canonical and overrides a co-submitted year
        assert normalize_edit_fields({"date": "1999", "year": 2000})["year"] == 1999
        # unparseable / cleared date clears year
        assert normalize_edit_fields({"date": None})["year"] is None
        assert normalize_edit_fields({"date": "n/a"})["year"] is None
        # clearing year clears the date column
        assert normalize_edit_fields({"year": None})["date"] is None
        # an untouched temporal field is left untouched
        assert normalize_edit_fields({"title": "x"}) == {"title": "x"}
        # every string value is NFC-normalized (e + combining acute -> é)
        assert normalize_edit_fields({"artist": "Cafe\u0301"})["artist"] == "Caf\u00e9"


# ── journal reconcile (no ffmpeg) ───────────────────────────────────────────

class TestReconcileJournal:
    def test_relocate_finish_when_db_advanced(self, tmp_path):
        db = _db(tmp_path)
        (tmp_path / "owner").mkdir()
        old = tmp_path / "owner" / "old.m4a"; old.write_bytes(b"old")
        new = tmp_path / "owner" / "sub" / "new.m4a"; new.parent.mkdir(parents=True); new.write_bytes(b"new")
        _add_track(db, new, "T", "Art")  # DB already points at new_path
        uuid = db.get_tracks()[0].uuid_id
        db.insert_journal_entry("relocate", uuid, str(old), str(new), None)

        reconcile_journal(db, tmp_path)

        assert not old.exists()  # leftover old master removed
        assert new.exists()
        assert db.list_journal_entries() == []

    def test_relocate_revert_when_db_not_advanced(self, tmp_path):
        db = _db(tmp_path)
        (tmp_path / "owner").mkdir()
        old = tmp_path / "owner" / "old.m4a"; old.write_bytes(b"old")
        new = tmp_path / "owner" / "sub" / "new.m4a"; new.parent.mkdir(parents=True); new.write_bytes(b"new")
        _add_track(db, old, "T", "Art")  # DB still points at old_path
        uuid = db.get_tracks()[0].uuid_id
        db.insert_journal_entry("relocate", uuid, str(old), str(new),
                                str(tmp_path / ".staging" / "moved.m4a"))  # the move consumed it

        reconcile_journal(db, tmp_path)

        assert old.exists()  # old master kept
        assert not new.exists()  # uncommitted new copy removed
        assert db.list_journal_entries() == []

    def test_inplace_redoes_pending_replace(self, tmp_path):
        db = _db(tmp_path)
        (tmp_path / "owner").mkdir()
        target = tmp_path / "owner" / "song.m4a"; target.write_bytes(b"stale")
        temp = tmp_path / ".staging" / "temp.m4a"; temp.parent.mkdir(parents=True); temp.write_bytes(b"fresh")
        _add_track(db, target, "T", "Art")
        uuid = db.get_tracks()[0].uuid_id
        db.insert_journal_entry("inplace", uuid, str(target), None, str(temp))

        reconcile_journal(db, tmp_path)

        assert target.read_bytes() == b"fresh"  # replace completed
        assert not temp.exists()
        assert db.list_journal_entries() == []

    def test_idempotent_clean_run_is_noop(self, tmp_path):
        db = _db(tmp_path)
        (tmp_path / "owner").mkdir()
        reconcile_journal(db, tmp_path)
        reconcile_journal(db, tmp_path)
        assert db.list_journal_entries() == []

    def test_relocate_finish_prunes_emptied_source_directory(self, tmp_path):
        db = _db(tmp_path)
        (tmp_path / "owner").mkdir()
        old = tmp_path / "owner" / "Old" / "old.m4a"; old.parent.mkdir(parents=True); old.write_bytes(b"old")
        new = tmp_path / "owner" / "New" / "new.m4a"; new.parent.mkdir(parents=True); new.write_bytes(b"new")
        _add_track(db, new, "T", "Art")  # DB already points at new_path
        uuid = db.get_tracks()[0].uuid_id
        db.insert_journal_entry("relocate", uuid, str(old), str(new), None)

        reconcile_journal(db, tmp_path)

        assert not old.exists()
        assert not old.parent.exists(), (
            "orphaned empty source directory left behind after a "
            "crash-recovered relocation"
        )
        assert new.exists()
        assert db.list_journal_entries() == []

    def test_relocate_revert_prunes_emptied_new_directory(self, tmp_path):
        db = _db(tmp_path)
        (tmp_path / "owner").mkdir()
        old = tmp_path / "owner" / "Old" / "old.m4a"; old.parent.mkdir(parents=True); old.write_bytes(b"old")
        new = tmp_path / "owner" / "New" / "new.m4a"; new.parent.mkdir(parents=True); new.write_bytes(b"new")
        _add_track(db, old, "T", "Art")  # DB still points at old_path
        uuid = db.get_tracks()[0].uuid_id
        db.insert_journal_entry("relocate", uuid, str(old), str(new),
                                str(tmp_path / ".staging" / "moved.m4a"))  # the move consumed it

        reconcile_journal(db, tmp_path)

        assert old.exists()  # old master kept
        assert not new.exists()  # uncommitted new copy removed
        assert not new.parent.exists(), (
            "orphaned empty destination directory left behind after a "
            "reverted crash-recovered relocation"
        )
        assert db.list_journal_entries() == []

    def test_convert_with_new_path_finishes_like_relocate(self, tmp_path):
        # A conversion that changed the extension (e.g. .flac -> .m4a) and
        # committed should behave exactly like a finished relocate.
        db = _db(tmp_path)
        (tmp_path / "owner").mkdir()
        old = tmp_path / "owner" / "old.flac"; old.write_bytes(b"old")
        new = tmp_path / "owner" / "new.m4a"; new.write_bytes(b"new")
        _add_track(db, new, "T", "Art")  # DB already points at new_path
        uuid = db.get_tracks()[0].uuid_id
        db.insert_journal_entry("convert", uuid, str(old), str(new), None)

        reconcile_journal(db, tmp_path)

        assert not old.exists()
        assert new.exists()
        assert db.list_journal_entries() == []

    def test_convert_with_new_path_reverts_when_db_not_advanced(self, tmp_path):
        db = _db(tmp_path)
        (tmp_path / "owner").mkdir()
        old = tmp_path / "owner" / "old.flac"; old.write_bytes(b"old")
        new = tmp_path / "owner" / "new.m4a"; new.write_bytes(b"new")
        _add_track(db, old, "T", "Art")  # DB still points at old_path
        uuid = db.get_tracks()[0].uuid_id
        db.insert_journal_entry("convert", uuid, str(old), str(new),
                                str(tmp_path / ".staging" / "moved.m4a"))  # the move consumed it

        reconcile_journal(db, tmp_path)

        assert old.exists()
        assert not new.exists()
        assert db.list_journal_entries() == []

    def test_convert_same_path_redoes_pending_replace_like_inplace(self, tmp_path):
        # A same-codec re-encode (path unchanged) behaves like inplace.
        db = _db(tmp_path)
        (tmp_path / "owner").mkdir()
        target = tmp_path / "owner" / "song.mp3"; target.write_bytes(b"stale")
        temp = tmp_path / ".staging" / "temp.mp3"; temp.parent.mkdir(parents=True); temp.write_bytes(b"fresh")
        _add_track(db, target, "T", "Art")
        uuid = db.get_tracks()[0].uuid_id
        db.insert_journal_entry("convert", uuid, str(target), None, str(temp))

        reconcile_journal(db, tmp_path)

        assert target.read_bytes() == b"fresh"
        assert not temp.exists()
        assert db.list_journal_entries() == []

    # ── Phase M: recovery resolves each row's root (S9) ─────────────────────

    def _row_track(self, db, path, owner_id=None):
        track = Track(file_path=path, metadata=TrackMetaData(
            codec="aac", duration=1.0, bitrate_kbps=128.0, sample_rate_hz=44100,
            channels=2, title="T", artist="Art"))
        if owner_id is None:
            assert db.add_track(track)
        else:
            assert db.add_track(track, owner_id=owner_id)
        return track.uuid_id

    def test_row_with_old_path_in_another_users_folder_is_left_alone(self, tmp_path):
        db = _db(tmp_path)
        foreign = tmp_path / "sam" / "Old" / "old.m4a"
        foreign.parent.mkdir(parents=True); foreign.write_bytes(b"sams")
        new = tmp_path / "owner" / "New" / "new.m4a"
        new.parent.mkdir(parents=True); new.write_bytes(b"new")
        bad = self._row_track(db, new)
        db.insert_journal_entry("relocate", bad, str(foreign), str(new), None)
        # a second, valid row in the same pass
        old2 = tmp_path / "owner" / "Old2" / "old.m4a"
        old2.parent.mkdir(parents=True); old2.write_bytes(b"old2")
        new2 = tmp_path / "owner" / "New2" / "new.m4a"
        new2.parent.mkdir(parents=True); new2.write_bytes(b"new2")
        good = self._row_track(db, new2)
        db.insert_journal_entry("relocate", good, str(old2), str(new2), None)

        reconcile_journal(db, tmp_path)

        assert foreign.read_bytes() == b"sams"
        assert new.exists()
        assert [e["uuid_id"] for e in db.list_journal_entries()] == [bad]
        assert not old2.exists() and new2.exists()

    def test_row_with_new_path_escaping_via_symlink_is_left_alone(self, tmp_path):
        db = _db(tmp_path)
        root = tmp_path / "owner"
        outside = tmp_path / "outside"
        outside.mkdir()
        victim = outside / "new.m4a"; victim.write_bytes(b"not ours")
        root.mkdir()
        (root / "Evil").symlink_to(outside, target_is_directory=True)
        old = root / "Old" / "old.m4a"
        old.parent.mkdir(); old.write_bytes(b"old")
        uuid = self._row_track(db, old)  # DB not advanced: revert case
        db.insert_journal_entry("relocate", uuid, str(old), str(root / "Evil" / "new.m4a"), None)

        reconcile_journal(db, tmp_path)

        assert victim.read_bytes() == b"not ours"
        assert old.exists()
        assert len(db.list_journal_entries()) == 1

    def test_row_with_temp_path_outside_the_music_dir_is_left_alone(self, tmp_path):
        music = tmp_path / "music"
        db = _db(tmp_path)
        target = music / "owner" / "song.m4a"
        target.parent.mkdir(parents=True); target.write_bytes(b"stale")
        temp = tmp_path / "elsewhere" / "temp.m4a"
        temp.parent.mkdir(); temp.write_bytes(b"fresh")
        uuid = self._row_track(db, target)
        db.insert_journal_entry("inplace", uuid, str(target), None, str(temp))

        reconcile_journal(db, music)

        assert target.read_bytes() == b"stale"
        assert temp.read_bytes() == b"fresh"
        assert len(db.list_journal_entries()) == 1

    # Review r1 #1: a temp must be a staging file, never another master.
    @pytest.mark.parametrize("intent", ["relocate", "inplace"])
    @pytest.mark.parametrize("where", ["sam", "owner"])
    def test_row_whose_temp_is_a_library_file_is_left_alone(self, tmp_path, intent, where):
        music = tmp_path / "music"
        db = _db(tmp_path)
        victim = music / where / "B" / "master.m4a"
        victim.parent.mkdir(parents=True); victim.write_bytes(b"victim")
        target = music / "owner" / "A" / "song.m4a"
        target.parent.mkdir(parents=True, exist_ok=True); target.write_bytes(b"mine")
        uuid = self._row_track(db, target)
        if intent == "relocate":
            db.insert_journal_entry(
                "relocate", uuid, str(music / "owner" / "Gone" / "x.m4a"), str(target), str(victim)
            )
        else:
            db.insert_journal_entry("inplace", uuid, str(target), None, str(victim))

        reconcile_journal(db, music)

        assert victim.read_bytes() == b"victim"
        assert target.read_bytes() == b"mine"
        assert len(db.list_journal_entries()) == 1

    def test_revert_prune_stops_at_the_owners_root(self, tmp_path):
        db = _db(tmp_path)
        root = tmp_path / "owner"
        new = root / "New" / "new.m4a"
        new.parent.mkdir(parents=True); new.write_bytes(b"new")
        missing_old = root / "Old" / "old.m4a"  # never on disk
        uuid = self._row_track(db, missing_old)  # DB not advanced
        db.insert_journal_entry("relocate", uuid, str(missing_old), str(new),
                                str(tmp_path / ".staging" / "moved.m4a"))  # the move consumed it

        reconcile_journal(db, tmp_path)

        # OPEN-A-03 (2026-11-14): the old master is missing, so the moved copy is the
        # track's last one; since OPEN-6.5-05 (2026-11-16) it is adopted (state-table
        # row 6) and the row goes. Nothing is pruned. (The root guard stays covered by
        # test_second_users_row_is_reconciled_against_their_root.)
        assert new.read_bytes() == b"new"
        assert db.get_track_file_path(uuid) == str(new)
        assert root.is_dir(), "pruning walked past the owner's root"
        assert db.list_journal_entries() == []

    def test_second_users_row_is_reconciled_against_their_root(self, tmp_path):
        db = _db(tmp_path)
        alex = add_test_user(db, "alex")
        root = tmp_path / "alex"
        old = root / "Old" / "old.m4a"
        old.parent.mkdir(parents=True); old.write_bytes(b"old")
        new = root / "New" / "new.m4a"
        new.parent.mkdir(parents=True); new.write_bytes(b"new")
        uuid = self._row_track(db, new, owner_id=alex)
        db.insert_journal_entry("relocate", uuid, str(old), str(new), None, owner_id=alex)
        # alex's only content moves out of Old; Old is pruned, the root stays

        reconcile_journal(db, tmp_path)

        assert not old.exists() and not (root / "Old").exists()
        assert new.exists()
        assert root.is_dir()
        assert db.list_journal_entries(owner_id=alex) == []


# ── 7-fix-r0 F0-1b: master-write errors name no server path (SC-22) ─────────

@requires_ffmpeg
class TestMasterWriteErrorsCarryNoPaths:
    def test_a_relocation_onto_an_occupied_path_is_refused_without_paths(self, tmp_path):
        from app.services.track_editor import MasterWriteError

        library = tmp_path / "music"
        audio = library / "owner" / "Old" / "song.m4a"
        _make_audio(audio, title="T", artist="Old")
        occupied = library / "owner" / "New" / "song.m4a"
        occupied.parent.mkdir(parents=True)
        occupied.write_bytes(b"someone else's file")
        db = _db(tmp_path)
        track = _add_track(db, audio, "T", "Old")
        editor = TrackEditor(library, library / ".staging")

        with pytest.raises(MasterWriteError) as raised:
            editor.apply_edit(
                _lib(db), track.uuid_id, {"artist": "New"}, track.revision,
                WriteMode.db_and_master,
            )

        assert str(tmp_path) not in str(raised.value)
        assert "song.m4a" not in str(raised.value)
        assert occupied.read_bytes() == b"someone else's file"
        assert audio.exists()

    def test_a_failed_tag_write_names_no_path(self, tmp_path):
        bogus = tmp_path / "notaudio.m4a"
        bogus.write_bytes(b"this is not audio")

        with pytest.raises(TagWriteError) as raised:
            write_metadata_tags(bogus, tmp_path / "out.m4a", {"title": "X"})

        assert str(tmp_path) not in str(raised.value)
        assert "notaudio" not in str(raised.value)


# ── 7-fix-r0 F0-2: an artist named like an internal dir ─────────────────────

@requires_ffmpeg
class TestRelocationToAnInternalDirName:
    def test_the_folder_is_suffixed_and_pruned_when_the_track_moves_on(self, tmp_path):
        library = tmp_path / "music"
        audio = library / "owner" / "Old" / "song.m4a"
        _make_audio(audio, title="T", artist="Old")
        db = _db(tmp_path)
        track = _add_track(db, audio, "T", "Old")
        editor = TrackEditor(library, library / ".staging")

        rev, written = editor.apply_edit(
            _lib(db), track.uuid_id, {"artist": ".uploads"}, track.revision,
            WriteMode.db_and_master,
        )

        placed = library / "owner" / ".uploads_" / "song.m4a"
        assert written is True
        assert db.get_track_file_path(track.uuid_id) == str(placed)
        assert placed.exists()
        assert not (library / "owner" / ".uploads").exists()

        editor.apply_edit(
            _lib(db), track.uuid_id, {"artist": "New"}, rev, WriteMode.db_and_master,
        )

        assert (library / "owner" / "New" / "song.m4a").exists()
        assert not (library / "owner" / ".uploads_").exists()  # pruned when empty
