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
        reconcile_journal(db)
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


# ── journal reconcile (no ffmpeg) ───────────────────────────────────────────

class TestReconcileJournal:
    def test_relocate_finish_when_db_advanced(self, tmp_path):
        db = _db(tmp_path)
        old = tmp_path / "old.m4a"; old.write_bytes(b"old")
        new = tmp_path / "sub" / "new.m4a"; new.parent.mkdir(); new.write_bytes(b"new")
        _add_track(db, new, "T", "Art")  # DB already points at new_path
        uuid = db.get_tracks()[0].uuid_id
        db.insert_journal_entry("relocate", uuid, str(old), str(new), None)

        reconcile_journal(db)

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

        reconcile_journal(db)

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

        reconcile_journal(db)

        assert target.read_bytes() == b"fresh"  # replace completed
        assert not temp.exists()
        assert db.list_journal_entries() == []

    def test_idempotent_clean_run_is_noop(self, tmp_path):
        db = _db(tmp_path)
        reconcile_journal(db)
        reconcile_journal(db)
        assert db.list_journal_entries() == []
