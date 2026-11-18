"""Phase 6.5A.2b: the Phase 1 master writers as identity writers (spec §6.2, plan D8).

A writer bumps ``generation`` only after the new bytes are at the master
path. The relocating write marks ``tag_write`` in its commit
(``master_rewritten=True`` only from ``_relocate``); the in-place write marks
in a short transaction after ``os.replace`` and before the journal row is
deleted; journal recovery marks by intent. A DB-only edit, a WAV or a missing
master leaves identity byte-identical. Every mark signals after its commit.
"""

import os
import sqlite3
from pathlib import Path

import pytest

import app.services.track_editor as track_editor_mod
from app.database.database import Database
from app.services.track_edit import WriteMode
from app.services.track_editor import TrackEditor, reconcile_journal
from tests.owned_database import add_test_user
from tests.test_track_editor import _add_track, _db, _lib, _make_audio

DIGEST = "ef" * 32


def _identity(db, uuid_id):
    conn = sqlite3.connect(db.context.database_path)
    conn.row_factory = sqlite3.Row
    try:
        row = conn.execute("SELECT * FROM track_audio_identity WHERE uuid_id = ?", (uuid_id,)).fetchone()
        return dict(row) if row else None
    finally:
        conn.close()


def _settle(db, uuid_id):
    """The worker's finished state: every layer current, generation 3."""
    conn = sqlite3.connect(db.context.database_path)
    try:
        conn.execute(
            "UPDATE track_audio_identity SET exact_state = 'current', exact_kind = 'packets_sha256', "
            "exact_digest = ?, fp_state = 'current', fp_algorithm = 'chromaprint-2', "
            "match_state = 'current', matcher_version = 'm1', priority = 1, generation = 3 "
            "WHERE uuid_id = ?", (DIGEST, uuid_id))
        conn.commit()
    finally:
        conn.close()
    return _identity(db, uuid_id)


def _tag_write_marked(row):
    return (row["generation"], row["exact_state"], row["exact_digest"], row["fp_state"],
            row["match_state"], row["priority"]) == (4, "pending", DIGEST, "current", "pending", 0)


class SpyWakeup:
    """Records the committed generation (seen by a fresh connection) at each notify."""

    def __init__(self, db, uuid_id):
        self.db, self.uuid_id, self.seen = db, uuid_id, []

    def notify(self):
        self.seen.append(_identity(self.db, self.uuid_id)["generation"])


def _editor(library, wakeup=None):
    return TrackEditor(library, library / ".staging", identity_signal=wakeup)


def _world(tmp_path, name="song.m4a"):
    library = tmp_path / "music"
    audio = library / "owner" / "Art" / name
    _make_audio(audio, title="Old", artist="Art")
    db = _db(tmp_path)
    track = _add_track(db, audio, "Old", "Art")
    before = _settle(db, track.uuid_id)
    return library, audio, db, track, before


# --- the DB spine: master_rewritten ------------------------------------------------


def _plain_track(tmp_path):
    db = _db(tmp_path)
    track = _add_track(db, tmp_path / "music" / "owner" / "a.m4a", "T", "Art")
    return db, track, _settle(db, track.uuid_id)


def test_a_plain_metadata_edit_never_touches_identity(tmp_path):
    db, track, before = _plain_track(tmp_path)

    db.apply_track_metadata_edit(track.uuid_id, {"title": "New"}, track.revision)

    assert _identity(db, track.uuid_id) == before


def test_a_rewritten_master_marks_the_exact_layer_stale_in_the_edit_commit(tmp_path):
    db, track, _ = _plain_track(tmp_path)

    db.apply_track_metadata_edit(track.uuid_id, {"title": "New"}, track.revision, master_rewritten=True)

    assert _tag_write_marked(_identity(db, track.uuid_id))


def test_a_refused_edit_leaves_identity_untouched(tmp_path):
    db, track, before = _plain_track(tmp_path)

    with pytest.raises(Exception):
        db.apply_track_metadata_edit(track.uuid_id, {"title": "New"}, track.revision - 1,
                                     master_rewritten=True)

    assert _identity(db, track.uuid_id) == before


# --- relocation (the move happens before the commit) --------------------------------


@pytest.mark.requires_ffmpeg
def test_a_relocating_edit_marks_after_the_move_and_signals_after_commit(tmp_path):
    library, audio, db, track, _ = _world(tmp_path)
    wakeup = SpyWakeup(db, track.uuid_id)

    _editor(library, wakeup).apply_edit(
        _lib(db), track.uuid_id, {"artist": "New"}, track.revision, WriteMode.db_and_master
    )

    assert (library / "owner" / "New" / "song.m4a").is_file()
    assert _tag_write_marked(_identity(db, track.uuid_id))
    assert wakeup.seen == [4]


@pytest.mark.requires_ffmpeg
def test_a_relocation_whose_commit_fails_leaves_identity_untouched(tmp_path, monkeypatch):
    library, audio, db, track, before = _world(tmp_path)
    wakeup = SpyWakeup(db, track.uuid_id)

    def boom(*args, **kwargs):
        raise RuntimeError("commit failed after the move")

    monkeypatch.setattr(db, "apply_track_metadata_edit", boom)
    with pytest.raises(RuntimeError):
        _editor(library, wakeup).apply_edit(
            _lib(db), track.uuid_id, {"artist": "New"}, track.revision, WriteMode.db_and_master
        )

    assert _identity(db, track.uuid_id) == before
    assert wakeup.seen == []


# --- edits that never rewrite the master ------------------------------------------


@pytest.mark.requires_ffmpeg
def test_a_db_only_edit_leaves_identity_byte_identical(tmp_path):
    library, audio, db, track, before = _world(tmp_path)
    wakeup = SpyWakeup(db, track.uuid_id)

    _editor(library, wakeup).apply_edit(
        _lib(db), track.uuid_id, {"artist": "New"}, track.revision, WriteMode.db_only
    )

    assert _identity(db, track.uuid_id) == before
    assert wakeup.seen == []


def test_a_wav_master_edit_leaves_identity_byte_identical(tmp_path):
    library = tmp_path / "music"
    wav = library / "owner" / "Art" / "song.wav"
    wav.parent.mkdir(parents=True)
    wav.write_bytes(b"RIFFfake")
    db = _db(tmp_path)
    track = _add_track(db, wav, "Old", "Art")
    before = _settle(db, track.uuid_id)
    wakeup = SpyWakeup(db, track.uuid_id)

    _, written = _editor(library, wakeup).apply_edit(
        _lib(db), track.uuid_id, {"artist": "New"}, track.revision, WriteMode.db_and_master
    )

    assert written is False
    assert _identity(db, track.uuid_id) == before
    assert wakeup.seen == []


def test_a_missing_master_edit_leaves_identity_byte_identical(tmp_path):
    library = tmp_path / "music"
    db = _db(tmp_path)
    track = _add_track(db, library / "owner" / "Art" / "gone.m4a", "Old", "Art")
    before = _settle(db, track.uuid_id)
    wakeup = SpyWakeup(db, track.uuid_id)

    _, written = _editor(library, wakeup).apply_edit(
        _lib(db), track.uuid_id, {"artist": "New"}, track.revision, WriteMode.db_and_master
    )

    assert written is False
    assert _identity(db, track.uuid_id) == before
    assert wakeup.seen == []


# --- in place (the DB commits before os.replace) ----------------------------------



@pytest.mark.requires_ffmpeg
def test_an_in_place_edit_marks_after_the_replace_and_before_the_journal_delete(tmp_path, monkeypatch):
    library, audio, db, track, before = _world(tmp_path)
    wakeup = SpyWakeup(db, track.uuid_id)
    at_replace, at_journal_delete = [], []
    real_replace, real_delete = os.replace, db.delete_journal_entry

    def replace(src, dst):
        at_replace.append(_identity(db, track.uuid_id)["generation"])
        return real_replace(src, dst)

    def delete_journal_entry(entry_id, **kwargs):
        at_journal_delete.append(_identity(db, track.uuid_id)["generation"])
        return real_delete(entry_id, **kwargs)

    monkeypatch.setattr(track_editor_mod.os, "replace", replace)
    monkeypatch.setattr(db, "delete_journal_entry", delete_journal_entry)
    _, written = _editor(library, wakeup).apply_edit(
        _lib(db), track.uuid_id, {"title": "New"}, track.revision, WriteMode.db_and_master
    )

    assert written is True and audio.is_file()
    assert at_replace == [3], "the edit's own commit must not mark: the bytes are not in place yet"
    assert at_journal_delete == [4]
    assert _tag_write_marked(_identity(db, track.uuid_id))
    assert wakeup.seen == [4]


@pytest.mark.requires_ffmpeg
def test_a_failed_replace_leaves_identity_untouched_and_the_journal_for_recovery(tmp_path, monkeypatch):
    """Fault injection between the commit and os.replace: nothing is marked."""
    library, audio, db, track, before = _world(tmp_path)
    wakeup = SpyWakeup(db, track.uuid_id)

    def replace(src, dst):
        raise OSError("disk full")

    monkeypatch.setattr(track_editor_mod.os, "replace", replace)
    with pytest.raises(track_editor_mod.MasterSwapPending):
        _editor(library, wakeup).apply_edit(
            _lib(db), track.uuid_id, {"title": "New"}, track.revision, WriteMode.db_and_master
        )

    assert _identity(db, track.uuid_id) == before
    assert wakeup.seen == []
    assert [e["intent"] for e in db.list_journal_entries()] == ["inplace"]


# --- journal recovery marks by intent (plan D8) ------------------------------------



def _recovery_world(tmp_path):
    db = _db(tmp_path)
    (tmp_path / "owner" / "sub").mkdir(parents=True)
    (tmp_path / ".staging").mkdir()
    old = tmp_path / "owner" / "old.m4a"
    new = tmp_path / "owner" / "sub" / "new.m4a"
    temp = tmp_path / ".staging" / "temp.m4a"
    return db, old, new, temp


def _conversion_marked(row):
    return (row["generation"], row["exact_state"], row["exact_digest"], row["fp_state"],
            row["match_state"], row["priority"]) == (4, "pending", DIGEST, "pending", "pending", 0)


@pytest.mark.parametrize("temp_left", [True, False])
def test_recovering_an_in_place_edit_marks_a_tag_write(tmp_path, temp_left):
    db, old, _, temp = _recovery_world(tmp_path)
    old.write_bytes(b"stale")
    if temp_left:
        temp.write_bytes(b"fresh")
    track = _add_track(db, old, "T", "Art")
    _settle(db, track.uuid_id)
    db.insert_journal_entry("inplace", track.uuid_id, str(old), None, str(temp))
    wakeup = SpyWakeup(db, track.uuid_id)

    reconcile_journal(db, tmp_path, identity_signal=wakeup)

    assert _tag_write_marked(_identity(db, track.uuid_id))
    assert wakeup.seen == [4]
    assert db.list_journal_entries() == []


def test_recovering_a_committed_relocation_marks_a_tag_write(tmp_path):
    db, old, new, _ = _recovery_world(tmp_path)
    old.write_bytes(b"old")
    new.write_bytes(b"new")
    track = _add_track(db, new, "T", "Art")  # the DB already points at new_path
    _settle(db, track.uuid_id)
    db.insert_journal_entry("relocate", track.uuid_id, str(old), str(new), None)

    reconcile_journal(db, tmp_path)

    assert _tag_write_marked(_identity(db, track.uuid_id))


@pytest.mark.parametrize("intent", ["relocate", "convert"])
def test_recovering_an_uncommitted_move_leaves_identity_untouched(tmp_path, intent):
    db, old, new, _ = _recovery_world(tmp_path)
    old.write_bytes(b"old")
    new.write_bytes(b"new")
    track = _add_track(db, old, "T", "Art")  # the DB still points at old_path
    before = _settle(db, track.uuid_id)
    db.insert_journal_entry(intent, track.uuid_id, str(old), str(new), None)
    wakeup = SpyWakeup(db, track.uuid_id)

    reconcile_journal(db, tmp_path, identity_signal=wakeup)

    assert _identity(db, track.uuid_id) == before
    assert wakeup.seen == []


def test_recovering_an_in_place_conversion_marks_every_layer(tmp_path):
    db, old, _, temp = _recovery_world(tmp_path)
    old.write_bytes(b"alac")
    temp.write_bytes(b"aac")
    track = _add_track(db, old, "T", "Art")
    _settle(db, track.uuid_id)
    db.insert_journal_entry("convert", track.uuid_id, str(old), None, str(temp))

    reconcile_journal(db, tmp_path)

    assert old.read_bytes() == b"aac"
    assert _conversion_marked(_identity(db, track.uuid_id))


def test_recovering_a_committed_relocating_conversion_marks_every_layer(tmp_path):
    db, old, new, _ = _recovery_world(tmp_path)
    old.write_bytes(b"flac")
    new.write_bytes(b"alac")
    track = _add_track(db, new, "T", "Art")
    _settle(db, track.uuid_id)
    db.insert_journal_entry("convert", track.uuid_id, str(old), str(new), None)

    reconcile_journal(db, tmp_path)

    assert _conversion_marked(_identity(db, track.uuid_id))


def test_recovery_marks_only_through_the_journal_owners_track(tmp_path):
    """SC-28: a journal row naming another owner's track marks nothing."""
    db, _, _, _ = _recovery_world(tmp_path)
    alex = add_test_user(db, "Alex")
    target = tmp_path / "alex" / "song.m4a"
    target.parent.mkdir()
    target.write_bytes(b"x")
    track = _add_track(db, tmp_path / "owner" / "song.m4a", "T", "Art")  # the test owner's
    before = _settle(db, track.uuid_id)
    db.insert_journal_entry("inplace", track.uuid_id, str(target), None, None, owner_id=alex)

    reconcile_journal(db, tmp_path)

    assert _identity(db, track.uuid_id) == before


# --- review r1 regressions ------------------------------------------------------------


class JournalSpyWakeup:
    """Records how many journal rows exist at each notify (the worker skips a
    uuid that still has one, so a wake-up before the delete is wasted)."""

    def __init__(self, db):
        self.db, self.journal_rows = db, []

    def notify(self):
        self.journal_rows.append(len(self.db.list_journal_entries()))


@pytest.mark.requires_ffmpeg
def test_a_relocating_edit_signals_only_after_its_journal_row_is_gone(tmp_path):
    """Review F5: the wake-up comes after the journal delete, so the worker
    never wakes to a uuid it must skip."""
    library, audio, db, track, _ = _world(tmp_path)
    wakeup = JournalSpyWakeup(db)

    _editor(library, wakeup).apply_edit(
        _lib(db), track.uuid_id, {"artist": "New"}, track.revision, WriteMode.db_and_master
    )

    assert wakeup.journal_rows == [0]


@pytest.mark.requires_ffmpeg
def test_an_in_place_edit_whose_mark_fails_still_succeeds_and_recovery_marks(tmp_path, monkeypatch):
    """Review F4: the edit and the new bytes are both committed when the mark
    runs, so a locked database there must not fail the edit (a retry would
    409). The journal row stays, nothing is signalled, and recovery marks."""
    library, audio, db, track, before = _world(tmp_path)
    wakeup = SpyWakeup(db, track.uuid_id)

    def locked(*args, **kwargs):
        raise sqlite3.OperationalError("database is locked")

    monkeypatch.setattr(db, "mark_audio_identity_stale", locked)
    rev, written = _editor(library, wakeup).apply_edit(
        _lib(db), track.uuid_id, {"title": "New"}, track.revision, WriteMode.db_and_master
    )

    assert written is True and rev > track.revision
    assert _identity(db, track.uuid_id) == before
    assert wakeup.seen == []
    assert [e["intent"] for e in db.list_journal_entries()] == ["inplace"]

    monkeypatch.undo()
    reconcile_journal(db, library)

    assert _tag_write_marked(_identity(db, track.uuid_id))
    assert db.list_journal_entries() == []
