import os
import shutil
import subprocess
from pathlib import Path

import pytest

from app.database.database import Database, DatabaseContext
from app.models.track import Track
from app.models.track_meta_data import TrackMetaData
from app.services import metadata as metadata_mod
from app.services.metadata import TagWriteError, is_wav, write_metadata_tags
from app.services.path_sanitize import UnsafePathComponent, sanitize_path_component
from app.services.track_edit import WriteMode
from app.services.track_editor import TrackEditor, reconcile_journal

_INIT_SQL = Path(__file__).parent.parent / "app" / "database" / "init.sql"
_HAS_FFMPEG = shutil.which("ffmpeg") is not None and shutil.which("ffprobe") is not None
requires_ffmpeg = pytest.mark.skipif(not _HAS_FFMPEG, reason="ffmpeg/ffprobe not available")


def _make_audio(path: Path, **tags) -> None:
    """Generate a tiny real AAC/m4a file with the given tags via ffmpeg."""
    path.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
        "-f", "lavfi", "-i", "sine=frequency=440:duration=0.3",
        "-c:a", "aac",
    ]
    for k, v in tags.items():
        cmd += ["-metadata", f"{k}={v}"]
    cmd.append(str(path))
    subprocess.run(cmd, check=True)


def _db(tmp_path: Path) -> Database:
    db = Database(context=DatabaseContext(
        database_path=tmp_path / "database.db", init_sql_path=_INIT_SQL))
    assert db.initialize()
    return db


def _add_track(db: Database, file_path: Path, title, artist, album=None) -> Track:
    meta = TrackMetaData(
        codec="aac", duration=1.0, bitrate_kbps=128.0, sample_rate_hz=44100,
        channels=2, title=title, artist=artist, album=album,
    )
    track = Track(file_path=file_path, metadata=meta)
    assert db.add_track(track)
    return track


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
        return TrackEditor(db, library, library / ".staging")

    def test_inplace_rewrites_tags_same_path(self, tmp_path):
        library = tmp_path / "music"
        audio = library / "Art" / "song.m4a"
        _make_audio(audio, title="Old", artist="Art")
        db = _db(tmp_path)
        track = _add_track(db, audio, "Old", "Art")

        rev, master_written = self._editor(db, library).apply_edit(
            track.uuid_id, {"title": "New"}, track.revision, WriteMode.db_and_master
        )

        assert master_written is True
        assert audio.exists()  # artist unchanged → in-place
        assert metadata_mod.get_track_metadata(audio).title == "New"
        assert rev > track.revision
        assert db.get_track_file_path(track.uuid_id) == str(audio)

    def test_relocation_moves_master_and_updates_path(self, tmp_path):
        library = tmp_path / "music"
        audio = library / "Old" / "song.m4a"
        _make_audio(audio, title="T", artist="Old")
        db = _db(tmp_path)
        track = _add_track(db, audio, "T", "Old")

        _, master_written = self._editor(db, library).apply_edit(
            track.uuid_id, {"artist": "New"}, track.revision, WriteMode.db_and_master
        )

        new_path = library / "New" / "song.m4a"
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
        audio = library / "Old" / "song.m4a"
        _make_audio(audio, title="T", artist="Old")
        db = _db(tmp_path)
        track = _add_track(db, audio, "T", "Old")

        self._editor(db, library).apply_edit(
            track.uuid_id, {"artist": "New"}, track.revision, WriteMode.db_and_master
        )

        new_path = library / "New" / "song.m4a"
        assert new_path.exists()  # the track landed at its new home...
        assert not audio.exists()  # ...and the old file itself is gone...
        # ...but its now-empty parent directory should be too, and isn't.
        assert not (library / "Old").exists(), (
            "orphaned empty artist directory left behind after relocation"
        )

    def test_relocation_keeps_directory_when_sibling_track_remains(self, tmp_path):
        # Two tracks share "Old"; only one relocates. Its sibling means "Old"
        # is not actually empty and must survive.
        library = tmp_path / "music"
        moved = library / "Old" / "song1.m4a"
        sibling = library / "Old" / "song2.m4a"
        _make_audio(moved, title="T1", artist="Old")
        _make_audio(sibling, title="T2", artist="Old")
        db = _db(tmp_path)
        track = _add_track(db, moved, "T1", "Old")

        self._editor(db, library).apply_edit(
            track.uuid_id, {"artist": "New"}, track.revision, WriteMode.db_and_master
        )

        assert (library / "New" / "song1.m4a").exists()
        assert not moved.exists()
        assert (library / "Old").exists(), "sibling's directory was pruned"
        assert sibling.exists()

    def test_relocation_prunes_multiple_empty_ancestor_levels(self, tmp_path):
        # Artist+album relocation empties both the album dir and, since it
        # was the only album, the artist dir above it too.
        library = tmp_path / "music"
        audio = library / "Old" / "Album" / "song.m4a"
        _make_audio(audio, title="T", artist="Old", album="Album")
        db = _db(tmp_path)
        track = _add_track(db, audio, "T", "Old", album="Album")

        self._editor(db, library).apply_edit(
            track.uuid_id, {"artist": "New"}, track.revision, WriteMode.db_and_master
        )

        assert (library / "New" / "Album" / "song.m4a").exists()
        assert not (library / "Old" / "Album").exists()
        assert not (library / "Old").exists(), (
            "emptied artist directory was left behind above the pruned album"
        )

    def test_relocation_conflict_reverts_file(self, tmp_path):
        library = tmp_path / "music"
        audio = library / "Old" / "song.m4a"
        _make_audio(audio, title="T", artist="Old")
        db = _db(tmp_path)
        track = _add_track(db, audio, "T", "Old")

        from app.database.database import RevisionConflict

        with pytest.raises(RevisionConflict):
            self._editor(db, library).apply_edit(
                track.uuid_id, {"artist": "New"},
                track.revision + 999, WriteMode.db_and_master,
            )

        # DB unchanged, old master intact, no orphaned new file or journal rows.
        assert audio.exists()
        assert not (library / "New" / "song.m4a").exists()
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
        audio = library / "Old" / "song.m4a"
        _make_audio(audio, title="T", artist="Old")
        db = _db(tmp_path)
        track = _add_track(db, audio, "T", "Old")

        def _boom(*args, **kwargs):
            raise RuntimeError("simulated db failure after move")

        monkeypatch.setattr(db, "apply_track_metadata_edit", _boom)

        with pytest.raises(RuntimeError):
            self._editor(db, library).apply_edit(
                track.uuid_id, {"artist": "New"}, track.revision,
                WriteMode.db_and_master,
            )

        assert audio.exists(), "old master kept since the DB never advanced"
        assert not (library / "New" / "song.m4a").exists()
        assert not (library / "New").exists(), (
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
        audio = library / "Art" / "song.m4a"
        # The file's title has drifted away from the DB's title.
        _make_audio(audio, title="StaleFileTitle", artist="Art")
        db = _db(tmp_path)
        track = _add_track(db, audio, "DbTitle", "Art")

        rev, master_written = self._editor(db, library).apply_edit(
            track.uuid_id, {}, track.revision, WriteMode.db_and_master
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
        audio = library / "Art" / "song.m4a"
        _make_audio(audio, title="StaleTitle", artist="Art", genre="StaleGenre")
        db = _db(tmp_path)
        track = _add_track(db, audio, "DbTitle", "Art")

        # Edit only the genre via master write.
        self._editor(db, library).apply_edit(
            track.uuid_id, {"genre": "Rock"}, track.revision,
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
        audio = library / "Art" / "song.m4a"
        _make_audio(audio, title="T", artist="Art", genre="FileOnlyGenre")
        db = _db(tmp_path)
        track = _add_track(db, audio, "T", "Art")  # DB row: genre = NULL

        self._editor(db, library).apply_edit(
            track.uuid_id, {"title": "NewTitle"}, track.revision,
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
        audio = library / "Old" / "song.m4a"
        _make_audio(audio, title="T", artist="Old")
        db = _db(tmp_path)
        track = _add_track(db, audio, "T", "Old")

        self._editor(db, library).apply_edit(
            # "Cafe" + combining acute (decomposed form)
            track.uuid_id, {"artist": "Cafe\u0301"}, track.revision,
            WriteMode.db_and_master,
        )

        composed = library / "Caf\u00e9" / "song.m4a"  # single-codepoint \u00e9
        assert composed.exists()
        assert db.get_track_file_path(track.uuid_id) == str(composed)

    def test_inplace_replace_failure_is_recoverable(self, tmp_path, monkeypatch):
        # A caught os.replace error (soft failure, not a hard crash) after the
        # DB commit + journal write must leave temp + journal row intact so
        # reconcile_journal can redo the replace. Regression: the old blanket
        # `finally: temp.unlink()` deleted the temp the journal referenced,
        # voiding the redo and stranding file=old/DB=new.
        library = tmp_path / "music"
        audio = library / "Art" / "song.m4a"
        _make_audio(audio, title="Old", artist="Art")
        db = _db(tmp_path)
        track = _add_track(db, audio, "Old", "Art")
        editor = self._editor(db, library)

        def boom(src, dst):
            raise OSError("simulated replace failure")

        monkeypatch.setattr(os, "replace", boom)
        with pytest.raises(OSError):
            editor.apply_edit(
                track.uuid_id, {"title": "New"}, track.revision,
                WriteMode.db_and_master,
            )

        # DB advanced, but the file is untouched and the staged temp + its
        # journal row survive for recovery.
        temp = library / ".staging" / f"{track.uuid_id}.m4a"
        assert temp.exists()
        assert db.get_tracks()[0].revision > track.revision
        assert metadata_mod.get_track_metadata(audio).title == "Old"
        entries = db.list_journal_entries()
        assert len(entries) == 1 and entries[0]["intent"] == "inplace"

        # Recovery completes the replace and clears the journal.
        monkeypatch.undo()
        reconcile_journal(db, library)
        assert metadata_mod.get_track_metadata(audio).title == "New"
        assert not temp.exists()
        assert db.list_journal_entries() == []

    def test_wav_degrades_to_db_only(self, tmp_path):
        library = tmp_path / "music"
        wav = library / "Art" / "song.wav"
        wav.parent.mkdir(parents=True)
        wav.write_bytes(b"RIFFfake")
        db = _db(tmp_path)
        track = _add_track(db, wav, "Old", "Art")

        rev, master_written = self._editor(db, library).apply_edit(
            track.uuid_id, {"title": "New"}, track.revision, WriteMode.db_and_master
        )

        assert master_written is False  # WAV master left untouched
        assert rev > track.revision  # but the DB edit still applied


# ── year/date normalization (no ffmpeg) ─────────────────────────────────────

class TestTemporalNormalization:
    def _editor(self, db, tmp_path):
        return TrackEditor(db, tmp_path / "music", tmp_path / "music" / ".staging")

    def test_editing_date_derives_year(self, tmp_path):
        db = _db(tmp_path)
        track = _add_track(db, tmp_path / "song.m4a", "T", "Art")
        self._editor(db, tmp_path).apply_edit(
            track.uuid_id, {"date": "2019-05-01"}, track.revision, WriteMode.db_only
        )
        meta = db.get_tracks()[0].metadata
        assert meta.date == "2019-05-01"
        assert meta.year == 2019  # derived from the date's leading digits

    def test_editing_year_sets_date(self, tmp_path):
        db = _db(tmp_path)
        track = _add_track(db, tmp_path / "song.m4a", "T", "Art")
        self._editor(db, tmp_path).apply_edit(
            track.uuid_id, {"year": 2020}, track.revision, WriteMode.db_only
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
        old = tmp_path / "old.m4a"; old.write_bytes(b"old")
        new = tmp_path / "sub" / "new.m4a"; new.parent.mkdir(); new.write_bytes(b"new")
        _add_track(db, new, "T", "Art")  # DB already points at new_path
        uuid = db.get_tracks()[0].uuid_id
        db.insert_journal_entry("relocate", uuid, str(old), str(new), None)

        reconcile_journal(db, tmp_path)

        assert not old.exists()  # leftover old master removed
        assert new.exists()
        assert db.list_journal_entries() == []

    def test_relocate_revert_when_db_not_advanced(self, tmp_path):
        db = _db(tmp_path)
        old = tmp_path / "old.m4a"; old.write_bytes(b"old")
        new = tmp_path / "sub" / "new.m4a"; new.parent.mkdir(); new.write_bytes(b"new")
        _add_track(db, old, "T", "Art")  # DB still points at old_path
        uuid = db.get_tracks()[0].uuid_id
        db.insert_journal_entry("relocate", uuid, str(old), str(new), None)

        reconcile_journal(db, tmp_path)

        assert old.exists()  # old master kept
        assert not new.exists()  # uncommitted new copy removed
        assert db.list_journal_entries() == []

    def test_inplace_redoes_pending_replace(self, tmp_path):
        db = _db(tmp_path)
        target = tmp_path / "song.m4a"; target.write_bytes(b"stale")
        temp = tmp_path / "temp.m4a"; temp.write_bytes(b"fresh")
        _add_track(db, target, "T", "Art")
        uuid = db.get_tracks()[0].uuid_id
        db.insert_journal_entry("inplace", uuid, str(target), None, str(temp))

        reconcile_journal(db, tmp_path)

        assert target.read_bytes() == b"fresh"  # replace completed
        assert not temp.exists()
        assert db.list_journal_entries() == []

    def test_idempotent_clean_run_is_noop(self, tmp_path):
        db = _db(tmp_path)
        reconcile_journal(db, tmp_path)
        reconcile_journal(db, tmp_path)
        assert db.list_journal_entries() == []

    def test_relocate_finish_prunes_emptied_source_directory(self, tmp_path):
        db = _db(tmp_path)
        old = tmp_path / "Old" / "old.m4a"; old.parent.mkdir(); old.write_bytes(b"old")
        new = tmp_path / "New" / "new.m4a"; new.parent.mkdir(); new.write_bytes(b"new")
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
        old = tmp_path / "Old" / "old.m4a"; old.parent.mkdir(); old.write_bytes(b"old")
        new = tmp_path / "New" / "new.m4a"; new.parent.mkdir(); new.write_bytes(b"new")
        _add_track(db, old, "T", "Art")  # DB still points at old_path
        uuid = db.get_tracks()[0].uuid_id
        db.insert_journal_entry("relocate", uuid, str(old), str(new), None)

        reconcile_journal(db, tmp_path)

        assert old.exists()  # old master kept
        assert not new.exists()  # uncommitted new copy removed
        assert not new.parent.exists(), (
            "orphaned empty destination directory left behind after a "
            "reverted crash-recovered relocation"
        )
        assert db.list_journal_entries() == []
