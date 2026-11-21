"""A master edit first finishes the track's kept journal rows (review r3, 6-5-R3-01).

A journal row can outlive its file operation: an in-place edit whose
``os.replace`` failed keeps its row and staged temp until recovery, and a row
whose delete hit a locked database is kept too. Edit temps are named per
operation, so a later edit of the same track no longer overwrites (and so
neutralises) an older row's temp. Replaying such an old row after the track has
moved on would write stale bytes over whatever is at its path now: another
track's master, or a newer edit of the same track.

So a ``db_and_master`` edit, which runs under the track lock, first finishes
the track's kept rows through the same recovery startup uses (nothing newer
has happened yet, so finishing them is correct at that point). A row that
recovery cannot finish refuses the edit with the existing ``MasterWriteError``
and nothing is written.
"""

import os
import sqlite3
from pathlib import Path

import pytest

from app.services import metadata as metadata_mod
from app.services.track_edit import WriteMode
from app.services.track_editor import (
    MasterSwapPending,
    MasterWriteError,
    finish_kept_journal_rows,
    reconcile_journal,
)
from app.services.track_locks import TrackLocks
from tests.identity_editor_fixtures import _editor, _world
from tests.track_editor_fixtures import _add_track, _lib, _make_audio

pytestmark = pytest.mark.requires_ffmpeg


def _replace_fails_once(monkeypatch, target):
    """``os.replace`` of a staged temp onto ``target`` fails once (a transient error)."""
    real = os.replace
    state = {"n": 0}

    def flaky(src, dst, *a, **k):
        if Path(dst) == Path(target) and ".staging" in str(src) and state["n"] == 0:
            state["n"] += 1
            raise PermissionError("transient")
        return real(src, dst, *a, **k)

    monkeypatch.setattr(os, "replace", flaky)


def _delete_locked_once(monkeypatch, db):
    real = db.delete_journal_entry
    calls = []

    def flaky(*args, **kwargs):
        calls.append(args)
        if len(calls) == 1:
            raise sqlite3.OperationalError("database is locked")
        return real(*args, **kwargs)

    monkeypatch.setattr(db, "delete_journal_entry", flaky)


def _inplace_edit_whose_replace_failed(tmp_path, monkeypatch):
    """Edit 1 (title "New", in place): the DB commits, ``os.replace`` fails, the row
    and its temp are kept (the idle finisher skips a row whose temp is present)."""
    library, audio, db, track, before = _world(tmp_path)
    _replace_fails_once(monkeypatch, audio)
    with pytest.raises(MasterSwapPending):
        _editor(library).apply_edit(
            _lib(db), track.uuid_id, {"title": "New"}, track.revision, WriteMode.db_and_master)
    monkeypatch.undo()
    rows = db.list_journal_entries()
    assert [e["intent"] for e in rows] == ["inplace"]
    assert Path(rows[0]["temp_path"]).exists()
    return library, audio, db, track


def _staging(library):
    return sorted(p.name for p in (library / ".staging").iterdir())


# --- 6-5-R3-01 (a): the retry relocates, another track lands at the old path ------------------


def test_a_retry_that_relocates_never_lets_the_old_row_overwrite_a_later_tracks_master(
    tmp_path, monkeypatch
):
    library, audio, db, track = _inplace_edit_whose_replace_failed(tmp_path, monkeypatch)
    rev = db.get_track_by_uuid(track.uuid_id).revision

    _editor(library).apply_edit(
        _lib(db), track.uuid_id, {"artist": "Other"}, rev, WriteMode.db_and_master)
    moved = library / "owner" / "Other" / audio.name
    assert db.get_track_file_path(track.uuid_id) == str(moved)
    assert not audio.exists()
    audio.parent.mkdir(parents=True, exist_ok=True)
    audio.write_bytes(b"track B master")
    _add_track(db, audio, "B", "Art")

    finish_kept_journal_rows(db, library, TrackLocks())
    reconcile_journal(db, library)  # restart

    assert audio.read_bytes() == b"track B master"
    tags = metadata_mod.get_track_metadata(moved)
    assert (tags.title, tags.artist) == ("New", "Other")  # both edits are in the master
    assert db.list_journal_entries() == []
    assert _staging(library) == []


# --- 6-5-R3-01 (b): the retry edits in place ------------------------------------------------


def test_a_retry_in_place_is_never_undone_by_the_old_row_at_restart(tmp_path, monkeypatch):
    library, audio, db, track = _inplace_edit_whose_replace_failed(tmp_path, monkeypatch)
    rev = db.get_track_by_uuid(track.uuid_id).revision

    _editor(library).apply_edit(
        _lib(db), track.uuid_id, {"title": "Newer"}, rev, WriteMode.db_and_master)
    after_edit_2 = audio.read_bytes()
    assert metadata_mod.get_track_metadata(audio).title == "Newer"

    reconcile_journal(db, library)  # restart

    assert audio.read_bytes() == after_edit_2
    assert db.get_track_by_uuid(track.uuid_id).metadata.title == "Newer"
    assert db.list_journal_entries() == []
    assert _staging(library) == []


# --- a committed row kept by a locked delete, then a retry ------------------------------------


@pytest.mark.parametrize("edit_artist,other_dir", [
    ("Élan", "élan"),       # a non-ASCII case variant
    ("Café", "Café"),      # NFC vs NFD
])
@pytest.mark.parametrize("recovery", ["finisher", "startup"])
def test_a_retry_after_a_kept_committed_row_never_costs_a_master_at_another_spelling(
    tmp_path, monkeypatch, edit_artist, other_dir, recovery
):
    """Edit 1 relocates A and commits, but its row's delete hits a locked database.
    The user edits A again before the finisher ran. Track B then lands at a path that
    is another spelling of edit 1's destination (the same file on APFS)."""
    library, audio, db, track, before = _world(tmp_path)
    _delete_locked_once(monkeypatch, db)
    with pytest.raises(sqlite3.OperationalError):
        _editor(library).apply_edit(
            _lib(db), track.uuid_id, {"artist": edit_artist}, track.revision, WriteMode.db_and_master)
    monkeypatch.undo()
    rows = db.list_journal_entries()
    assert [e["intent"] for e in rows] == ["relocate"]
    first = Path(rows[0]["new_path"])
    assert db.get_track_file_path(track.uuid_id) == str(first)
    rev = db.get_track_by_uuid(track.uuid_id).revision

    _editor(library).apply_edit(
        _lib(db), track.uuid_id, {"artist": "Other"}, rev, WriteMode.db_and_master)
    assert not first.exists()
    b = library / "owner" / other_dir / audio.name
    b.parent.mkdir(parents=True)
    b.write_bytes(b"track B master")
    _add_track(db, b, "B", other_dir)
    if not first.exists():
        pytest.skip("filesystem distinguishes the two spellings")

    if recovery == "finisher":
        finish_kept_journal_rows(db, library, TrackLocks())
    else:
        reconcile_journal(db, library)

    assert b.read_bytes() == b"track B master"
    assert db.list_journal_entries() == []


# --- a row recovery cannot finish refuses the edit ----------------------------------------------


def test_an_edit_is_refused_while_a_kept_row_cannot_be_finished(tmp_path):
    """A kept relocate row whose ``new_path`` is now another track's master cannot
    show the file is its own, so recovery keeps it. The edit fails as an ordinary
    master-write failure, before it stages or writes anything."""
    library, audio, db, track, before = _world(tmp_path)
    other = library / "owner" / "Other" / audio.name
    other.parent.mkdir(parents=True)
    other.write_bytes(b"track B master")
    _add_track(db, other, "B", "Other")
    gone_temp = library / ".staging" / f"{track.uuid_id}.0a1b.edit.m4a"  # consumed by the move
    gone_temp.parent.mkdir(parents=True, exist_ok=True)
    db.insert_journal_entry("relocate", track.uuid_id, str(audio), str(other), str(gone_temp))
    original = audio.read_bytes()

    with pytest.raises(MasterWriteError):
        _editor(library).apply_edit(
            _lib(db), track.uuid_id, {"title": "X"}, track.revision, WriteMode.db_and_master)

    assert db.get_track_by_uuid(track.uuid_id).revision == track.revision
    assert db.get_track_by_uuid(track.uuid_id).metadata.title == "Old"
    assert audio.read_bytes() == original
    assert other.read_bytes() == b"track B master"
    assert [e["intent"] for e in db.list_journal_entries()] == ["relocate"]
    assert _staging(library) == []


def test_an_edit_is_refused_while_the_kept_rows_replace_still_fails(tmp_path, monkeypatch):
    library, audio, db, track = _inplace_edit_whose_replace_failed(tmp_path, monkeypatch)
    rev = db.get_track_by_uuid(track.uuid_id).revision
    kept_temp = Path(db.list_journal_entries()[0]["temp_path"])
    original = audio.read_bytes()

    def refused(src, dst, *a, **k):
        raise PermissionError("still refused")

    monkeypatch.setattr(os, "replace", refused)
    with pytest.raises(MasterWriteError):
        _editor(library).apply_edit(
            _lib(db), track.uuid_id, {"title": "Newer"}, rev, WriteMode.db_and_master)
    monkeypatch.undo()

    assert db.get_track_by_uuid(track.uuid_id).revision == rev
    assert audio.read_bytes() == original
    assert [e["intent"] for e in db.list_journal_entries()] == ["inplace"]
    assert kept_temp.exists()
    assert _staging(library) == [kept_temp.name]


# --- a kept in-place conversion row, then an edit -----------------------------------------------


def test_an_edit_waits_for_startup_while_a_converted_temp_is_not_in_place(tmp_path):
    """A same-path conversion committed, then its ``os.replace`` failed: the row and
    the converted temp are kept, and the database already describes the converted
    master. Placing those bytes changes the audio, and only startup evicts the
    encodes made from the old bytes, so the edit is refused until a restart has
    placed them. After the restart the edit goes through."""
    from app.main import _interrupted_conversion_uuids
    from app.services.encoded_cache import evict_track_caches
    from app.services.encoded_cache import EncodedCache, EncodedCacheContext

    library, audio, db, track, before = _world(tmp_path)
    converted = library / ".staging" / f"{track.uuid_id}.7.tagged.m4a"
    _make_audio(converted, title="Old", artist="Art", comment="converted")
    db.insert_journal_entry("convert", track.uuid_id, str(audio), None, str(converted))
    cache = EncodedCache(EncodedCacheContext(cache_dir=tmp_path / "cache", max_size_bytes=10**9))
    cache.path_for(track.uuid_id, "320").write_bytes(b"encode of the pre-conversion bytes")
    original = audio.read_bytes()

    with pytest.raises(MasterWriteError):
        _editor(library).apply_edit(
            _lib(db), track.uuid_id, {"title": "Edited"}, track.revision, WriteMode.db_and_master)

    assert audio.read_bytes() == original
    assert converted.exists()
    assert [e["intent"] for e in db.list_journal_entries()] == ["convert"]
    assert db.get_track_by_uuid(track.uuid_id).revision == track.revision

    # restart, in main.py's order
    uuids = _interrupted_conversion_uuids(db)
    reconcile_journal(db, library)
    for u in uuids:
        evict_track_caches(u, cache, None)
    assert not cache.has(track.uuid_id, "320")
    # Putting the converted bytes in place bumps the revision (U06-B-06, review
    # finding 10), so the edit is made against the revision after the restart.
    restarted = db.get_track_by_uuid(track.uuid_id)
    assert restarted.revision > track.revision

    _editor(library).apply_edit(
        _lib(db), track.uuid_id, {"title": "Edited"}, restarted.revision, WriteMode.db_and_master)
    probe = metadata_mod.ffprobe_for_metadata(audio)
    tags = {k.lower(): v for k, v in probe["format"]["tags"].items()}
    assert (tags["title"], tags["comment"]) == ("Edited", "converted")
    assert db.list_journal_entries() == []
    assert _staging(library) == []


# --- recovery outside startup never deletes a library file (review of this fix, F2) ---------------


@pytest.mark.parametrize("trigger", ["fence", "finisher"])
def test_recovery_while_running_never_deletes_a_master_another_track_is_moving_in(
    tmp_path, monkeypatch, trigger
):
    """A's relocate committed and removed its old master, but the row's delete hit a
    locked database. Track B is relocated to A's old path; between B's move and B's
    commit, A's row is finished while the server runs (A's next edit, or the idle
    finisher under A's lock). B's row does not name that path yet, so only startup,
    when nothing else moves, may decide about a file there."""
    library, audio, db, track, before = _world(tmp_path)
    _delete_locked_once(monkeypatch, db)
    with pytest.raises(sqlite3.OperationalError):
        _editor(library).apply_edit(
            _lib(db), track.uuid_id, {"artist": "Moved"}, track.revision, WriteMode.db_and_master)
    monkeypatch.undo()
    assert not audio.exists()
    a_rev = db.get_track_by_uuid(track.uuid_id).revision

    b_src = library / "owner" / "Zed" / audio.name
    _make_audio(b_src, title="B", artist="Zed")
    b = _add_track(db, b_src, "B", "Zed")
    real = db.apply_track_metadata_edit
    outcome = {}
    locks = TrackLocks()  # the server's: B's PATCH holds B's lock throughout

    def b_commits_late(uuid_id, *args, **kwargs):
        if uuid_id == b.uuid_id and kwargs.get("new_file_path") and not outcome:
            assert audio.exists()  # B's bytes are at A's old path, uncommitted
            if trigger == "fence":
                try:
                    _editor(library).apply_edit(
                        _lib(db), track.uuid_id, {"title": "X"}, a_rev, WriteMode.db_and_master)
                    outcome["a"] = "edited"
                except MasterWriteError:
                    outcome["a"] = "refused"
            else:
                outcome["a"] = finish_kept_journal_rows(db, library, locks)
        return real(uuid_id, *args, **kwargs)

    monkeypatch.setattr(db, "apply_track_metadata_edit", b_commits_late)
    with locks.lock(b.uuid_id):
        _editor(library).apply_edit(
            _lib(db), b.uuid_id, {"artist": "Art"}, b.revision, WriteMode.db_and_master)
    monkeypatch.undo()

    assert outcome["a"] in ("refused", 0)  # the row waits for startup
    assert db.get_track_file_path(b.uuid_id) == str(audio)
    assert metadata_mod.get_track_metadata(audio).title == "B"

    reconcile_journal(db, library)  # restart

    assert metadata_mod.get_track_metadata(audio).title == "B"
    assert db.list_journal_entries() == []
