"""Journal recovery never deletes a file at ``new_path`` that is not its own.

A relocate or convert row is reverted when the database never moved to its
``new_path``. The revert used to unlink whatever sat at ``new_path``. But a row
can be kept (its delete failed) after its move was refused because another file
already sat at the destination, or after the in-process revert already removed
its copy; the file found there later is then someone else's, possibly another
track's master. Recovery (at startup, and the idle identity worker's finisher)
now deletes ``new_path`` only when the row shows the file is its own output:
the staged temp it recorded was consumed by the move, and no track's master is
that path. A temp still present means the move never happened (or was undone):
the destination is left alone. When ownership cannot be shown, the file stays,
the row stays and the failure is logged (once by the finisher).
"""

import subprocess
from pathlib import Path

import pytest

from app.database import ANY_OWNER

import tests.conversion_fixtures as conv
from app.services.track_editor import finish_kept_journal_rows, reconcile_journal
from app.services.track_locks import TrackLocks
from tests.identity_conversion_fixtures import _lossless_world, fixtures  # noqa: F401  (fixture)
from tests.track_editor_fixtures import _add_track, _db

INTENTS = ["relocate", "convert"]


def _other_audio(path: Path) -> bytes:
    """A real audio file at ``path`` whose audio is not the track's (an 880 Hz sine;
    aac for .m4a). Since 2026-11-16 (sign-off OPEN-6.5-05) startup settles every row:
    a file at the destination that is audio of its own becomes a track; a file
    ffprobe refuses is removed when the track's file hashed (decision D1)."""
    path.parent.mkdir(parents=True, exist_ok=True)
    codec = "aac" if path.suffix == ".m4a" else "flac"
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
                    "sine=frequency=880:duration=0.3", "-c:a", codec, str(path)], check=True)
    return path.read_bytes()


def _world(tmp_path):
    db = _db(tmp_path)
    root = tmp_path / "owner"
    root.mkdir()
    staging = tmp_path / ".staging"
    staging.mkdir()
    old = root / "old.flac"
    old.write_bytes(b"old master")
    track = _add_track(db, old, "T", "Art")  # the database never moved to new_path
    return db, root, staging, old, track


def _finisher_passes(db, tmp_path, caplog, passes=3):
    caplog.set_level("WARNING", logger="app.services.track_editor")
    reported = set()
    finished = [finish_kept_journal_rows(db, tmp_path, TrackLocks(), reported=reported)
                for _ in range(passes)]
    warnings = [r for r in caplog.records if "journal finish failed" in r.getMessage()]
    return finished, warnings


# --- another track's master at new_path --------------------------------------------------------


@pytest.mark.parametrize("intent", INTENTS)
def test_startup_keeps_another_tracks_master_at_new_path(tmp_path, intent):
    db, root, staging, old, track = _world(tmp_path)
    new = root / "song.m4a"
    new.write_bytes(b"another track's master")
    _add_track(db, new, "Other", "Art")
    db.insert_journal_entry(intent, track.uuid_id, str(old), str(new), str(staging / "gone.m4a"))

    reconcile_journal(db, tmp_path)

    assert new.read_bytes() == b"another track's master"
    assert old.read_bytes() == b"old master"
    # Since 2026-11-16 (M1): another track's master is never touched and the row goes.
    assert db.list_journal_entries() == []


@pytest.mark.parametrize("intent", INTENTS)
def test_the_idle_finisher_keeps_another_tracks_master_and_logs_once(tmp_path, intent, caplog):
    db, root, staging, old, track = _world(tmp_path)
    new = root / "song.m4a"
    new.write_bytes(b"another track's master")
    _add_track(db, new, "Other", "Art")
    db.insert_journal_entry(intent, track.uuid_id, str(old), str(new), str(staging / "gone.m4a"))

    finished, warnings = _finisher_passes(db, tmp_path, caplog)

    assert finished == [0, 0, 0]
    assert new.read_bytes() == b"another track's master"
    assert old.read_bytes() == b"old master"
    assert [e["intent"] for e in db.list_journal_entries()] == [intent]
    assert len(warnings) == 1


# --- the staged temp is still there: the move never happened -----------------------------------


@pytest.mark.parametrize("intent", INTENTS)
def test_a_present_temp_means_the_move_never_happened_so_new_path_is_left(tmp_path, intent):
    db, root, staging, old, track = _world(tmp_path)
    new = root / "song.m4a"
    new.write_bytes(b"a file that is not a track")
    temp = staging / f"{track.uuid_id}.7.tagged.m4a"
    temp.write_bytes(b"staged copy")
    db.insert_journal_entry(intent, track.uuid_id, str(old), str(new), str(temp))

    reconcile_journal(db, tmp_path)

    assert new.read_bytes() == b"a file that is not a track"
    assert old.read_bytes() == b"old master"
    assert not temp.exists()
    assert db.list_journal_entries() == []


# --- nothing recorded to show ownership ----------------------------------------------------------


@pytest.mark.parametrize("intent", INTENTS)
def test_a_row_without_a_recorded_temp_leaves_a_file_nothing_can_read_and_the_row_goes(
    tmp_path, intent, caplog
):
    """M4 (since 2026-11-16): with no recorded temp the file at new_path goes to the
    content rule; here neither it nor the track's own file is audio, so nothing
    proves anything (decision D2): the file stays, the row goes."""
    db, root, staging, old, track = _world(tmp_path)
    new = root / "song.m4a"
    new.write_bytes(b"a file that is not a track")
    db.insert_journal_entry(intent, track.uuid_id, str(old), str(new), None)

    reconcile_journal(db, tmp_path)
    finished, warnings = _finisher_passes(db, tmp_path, caplog)

    assert finished == [0, 0, 0] and warnings == []
    assert new.read_bytes() == b"a file that is not a track"
    assert old.read_bytes() == b"old master"
    assert db.list_journal_entries() == []


# --- the row's own copy is still removed -------------------------------------------------------


@pytest.mark.parametrize("intent", INTENTS)
def test_the_rows_own_copy_is_removed_when_its_temp_was_consumed(tmp_path, intent):
    """Crash between the move and the commit: the temp became new_path, nothing else
    names that path, so the uncommitted copy is the row's own and is removed."""
    db, root, staging, old, track = _world(tmp_path)
    new = root / "Sub" / "song.m4a"
    new.parent.mkdir()
    new.write_bytes(b"the row's own converted copy")
    db.insert_journal_entry(intent, track.uuid_id, str(old), str(new), str(staging / "moved.m4a"))

    reconcile_journal(db, tmp_path)

    assert not new.exists() and not new.parent.exists()
    assert old.read_bytes() == b"old master"
    assert db.list_journal_entries() == []


# --- the writers: a kept row keeps the evidence that its move did not happen ------------------
#
# Two faults at once: a file appears at the conversion's destination while it
# transcodes (an import, another track's move), so the move is refused; and the
# journal row's delete then hits a locked database, so the row is kept. Neither
# the idle finisher nor startup recovery may delete that file.


def _locked_once(monkeypatch, db):
    import sqlite3

    real = db.delete_journal_entry
    calls = []

    def flaky(*args, **kwargs):
        calls.append(args)
        if len(calls) == 1:
            raise sqlite3.OperationalError("database is locked")
        return real(*args, **kwargs)

    monkeypatch.setattr(db, "delete_journal_entry", flaky)


def _recover_both_ways(db, tmp_path, caplog):
    """The idle worker's finisher (a few passes), then a restart's recovery."""
    finished, _ = _finisher_passes(db, tmp_path, caplog)
    reconcile_journal(db, tmp_path)
    return finished


@pytest.mark.requires_ffmpeg
def test_a_conversion_whose_move_was_refused_never_costs_the_file_at_its_destination(
    tmp_path, fixtures, monkeypatch, caplog
):
    db, orch, coordinator, track, source, before, spy, wakeup, job_id = _lossless_world(
        tmp_path, fixtures["flac24.flac"], "alac")
    dest = source.with_suffix(".m4a")
    real = spy.__call__

    def foreign_file_appears(path, codec_hint, **kwargs):
        if ".tagged." in Path(path).name and not dest.exists():
            _other_audio(dest)
        return real(path, codec_hint, **kwargs)

    orch.compute_identity = foreign_file_appears
    _locked_once(monkeypatch, db)
    original = source.read_bytes()

    conv._run_submitted(coordinator)
    monkeypatch.undo()

    assert db.get_conversion_job(job_id)["status"] == "failed"
    assert [e["intent"] for e in db.list_journal_entries()] == ["convert"]  # the kept row
    foreign = dest.read_bytes()
    _recover_both_ways(db, tmp_path, caplog)

    assert dest.read_bytes() == foreign  # other audio: kept, now a track of its own
    assert db.track_path_in_use(str(dest), owner_id=ANY_OWNER, exclude_uuid=track.uuid_id)
    assert source.read_bytes() == original
    assert db.list_journal_entries() == []
    assert conv._staging_files(tmp_path) == []


@pytest.mark.requires_ffmpeg
def test_a_conversion_whose_commit_failed_never_costs_a_file_that_appears_later(
    tmp_path, fixtures, monkeypatch, caplog
):
    """The commit fails, the in-process revert takes its copy back, the row's delete
    fails: a file that later lands at the destination is not the row's."""
    import sqlite3

    db, orch, coordinator, track, source, before, spy, wakeup, job_id = _lossless_world(
        tmp_path, fixtures["flac24.flac"], "alac")
    dest = source.with_suffix(".m4a")

    def commit_fails(*args, **kwargs):
        raise sqlite3.OperationalError("database is locked")

    monkeypatch.setattr(db, "complete_conversion_job", commit_fails)
    _locked_once(monkeypatch, db)
    original = source.read_bytes()

    conv._run_submitted(coordinator)
    monkeypatch.undo()

    assert db.get_conversion_job(job_id)["status"] == "failed"
    assert [e["intent"] for e in db.list_journal_entries()] == ["convert"]
    assert not dest.exists()
    foreign = _other_audio(dest)
    _recover_both_ways(db, tmp_path, caplog)

    assert dest.read_bytes() == foreign  # other audio: kept, now a track of its own
    assert db.track_path_in_use(str(dest), owner_id=ANY_OWNER, exclude_uuid=track.uuid_id)
    assert source.read_bytes() == original
    assert db.list_journal_entries() == []
    assert conv._staging_files(tmp_path) == []


@pytest.mark.requires_ffmpeg
def test_a_master_edit_whose_commit_failed_never_costs_a_file_that_appears_later(
    tmp_path, monkeypatch, caplog
):
    """The same for a tag edit that relocates the master."""
    import sqlite3

    from app.services.track_edit import WriteMode
    from tests.identity_editor_fixtures import _editor, _world
    from tests.track_editor_fixtures import _lib

    library, audio, db, track, before = _world(tmp_path)
    dest = library / "owner" / "New" / audio.name

    def commit_fails(*args, **kwargs):
        raise sqlite3.OperationalError("database is locked")

    monkeypatch.setattr(db, "apply_track_metadata_edit", commit_fails)
    _locked_once(monkeypatch, db)
    original = audio.read_bytes()

    with pytest.raises(sqlite3.OperationalError):
        _editor(library).apply_edit(
            _lib(db), track.uuid_id, {"artist": "New"}, track.revision, WriteMode.db_and_master)
    monkeypatch.undo()

    assert [e["intent"] for e in db.list_journal_entries()] == ["relocate"]
    assert not dest.exists()
    foreign = _other_audio(dest)
    _recover_both_ways(db, library, caplog)

    assert dest.read_bytes() == foreign  # other audio: kept, now a track of its own
    assert db.track_path_in_use(str(dest), owner_id=ANY_OWNER, exclude_uuid=track.uuid_id)
    assert audio.read_bytes() == original
    assert db.list_journal_entries() == []
    assert not any((library / ".staging").iterdir())


@pytest.mark.requires_ffmpeg
@pytest.mark.parametrize("recovery", ["finisher", "startup"])
def test_a_later_edit_of_the_same_track_never_consumes_a_kept_rows_temp(
    tmp_path, monkeypatch, caplog, recovery
):
    """Edit 1's move is refused (a file that is not a track sits at its destination)
    and its row is kept; the user retries with other metadata and it succeeds. The
    retry first finishes edit 1's row (its temp shows the move never happened, so
    the file at the destination is left alone), then stages its own temp."""
    import sqlite3

    from app.services.track_edit import WriteMode
    from tests.identity_editor_fixtures import _editor, _world
    from tests.track_editor_fixtures import _lib

    library, audio, db, track, before = _world(tmp_path)
    blocked = library / "owner" / "New" / audio.name
    blocked.parent.mkdir(parents=True)
    blocked.write_bytes(b"a file that is not a track")
    _locked_once(monkeypatch, db)

    with pytest.raises(sqlite3.OperationalError):
        _editor(library).apply_edit(
            _lib(db), track.uuid_id, {"artist": "New"}, track.revision, WriteMode.db_and_master)
    monkeypatch.undo()
    assert [e["intent"] for e in db.list_journal_entries()] == ["relocate"]

    _editor(library).apply_edit(
        _lib(db), track.uuid_id, {"artist": "Other"}, track.revision, WriteMode.db_and_master)
    moved = library / "owner" / "Other" / audio.name
    assert db.get_track_file_path(track.uuid_id) == str(moved)

    if recovery == "finisher":
        _finisher_passes(db, library, caplog)
    reconcile_journal(db, library)

    assert blocked.read_bytes() == b"a file that is not a track"
    assert moved.exists()
    assert db.list_journal_entries() == []


def test_the_startup_sweep_removes_an_edit_temp_no_journal_row_owns(tmp_path):
    """Edit temps are named per operation, so one left by a crash before its
    journal row existed is swept at startup like a conversion temp; one a kept
    row owns stays."""
    from app.services.conversion import reconcile_conversion_jobs

    db, root, staging, old, track = _world(tmp_path)
    leaked = staging / f"{track.uuid_id}.0a1b2c.edit.m4a"  # the editor's per-operation name
    owned = staging / f"{track.uuid_id}.3d4e5f.edit.m4a"
    leaked.write_bytes(b"leaked")
    owned.write_bytes(b"owned")
    db.insert_journal_entry("relocate", track.uuid_id, str(old), str(root / "x.m4a"), str(owned))

    reconcile_conversion_jobs(db, staging)

    assert not leaked.exists()
    assert owned.read_bytes() == b"owned"


# --- a master named with another letter case is still a track's master ---------------------------


@pytest.mark.parametrize("intent", INTENTS)
def test_a_new_path_that_differs_from_a_tracks_master_only_in_case_is_never_touched(tmp_path, intent):
    """On a case-insensitive filesystem (macOS) ``art/song.m4a`` is the same file as
    ``Art/song.m4a``. Recovery treats a case-only difference as the same path."""
    db, root, staging, old, track = _world(tmp_path)
    master = root / "Art" / "song.m4a"
    master.parent.mkdir()
    master.write_bytes(b"another track's master")
    _add_track(db, master, "Other", "Art")
    variant = root / "art" / "song.m4a"
    if not variant.exists():  # case-sensitive filesystem: a separate file of the same name
        variant.parent.mkdir()
        variant.write_bytes(b"another track's master")
    db.insert_journal_entry(intent, track.uuid_id, str(old), str(variant), str(staging / "gone.m4a"))

    reconcile_journal(db, tmp_path)

    assert master.read_bytes() == b"another track's master"
    assert variant.read_bytes() == b"another track's master"
    # Since 2026-11-16 (M1): a claimed path is never touched; the row goes.
    assert db.list_journal_entries() == []


# --- the finish branch: a file at old_path that is another track's master ------------------------


@pytest.mark.parametrize("intent", INTENTS)
@pytest.mark.parametrize("recovery", ["finisher", "startup"])
def test_finishing_a_committed_row_keeps_another_tracks_master_at_old_path(tmp_path, intent, recovery, caplog):
    """The move committed and the old master was removed, but the row's delete failed.
    Another track has since landed at the old path; finishing the row must not delete it."""
    db = _db(tmp_path)
    root = tmp_path / "owner"
    root.mkdir()
    (tmp_path / ".staging").mkdir()
    old = root / "song.flac"
    new = root / "song.m4a"
    new.write_bytes(b"the moved master")
    track = _add_track(db, new, "T", "Art")  # the database moved to new_path
    old.write_bytes(b"a later track's master")
    _add_track(db, old, "Later", "Art")
    db.insert_journal_entry(intent, track.uuid_id, str(old), str(new), str(tmp_path / ".staging" / "moved.m4a"))

    if recovery == "finisher":
        _finisher_passes(db, tmp_path, caplog)
    reconcile_journal(db, tmp_path)

    assert old.read_bytes() == b"a later track's master"
    assert new.read_bytes() == b"the moved master"
    assert db.list_journal_entries() == []


# --- a case-only move of the track itself ----------------------------------------------------------


def _case_world(tmp_path, *, db_at):
    """A track moved between ``Art/song.m4a`` and ``art/song.m4a`` (a case-only
    rename). On a case-insensitive filesystem both names are one file."""
    db = _db(tmp_path)
    root = tmp_path / "owner"
    (tmp_path / ".staging").mkdir()
    upper, lower = root / "Art" / "song.m4a", root / "art" / "song.m4a"
    upper.parent.mkdir(parents=True)
    upper.write_bytes(b"the master")
    if not lower.exists():  # case-sensitive: the other spelling is a separate copy
        lower.parent.mkdir()
        lower.write_bytes(b"the master")
    track = _add_track(db, upper if db_at == "upper" else lower, "T", "Art")
    return db, upper, lower, track


@pytest.mark.parametrize("intent", INTENTS)
def test_reverting_a_case_only_move_of_the_track_itself_keeps_its_master(tmp_path, intent):
    db, upper, lower, track = _case_world(tmp_path, db_at="upper")
    db.insert_journal_entry(intent, track.uuid_id, str(upper), str(lower), str(tmp_path / ".staging" / "moved.m4a"))

    reconcile_journal(db, tmp_path)

    assert upper.read_bytes() == b"the master"
    assert not lower.exists() or lower.samefile(upper)  # the copy goes; the master never
    assert db.list_journal_entries() == []


@pytest.mark.parametrize("intent", INTENTS)
def test_finishing_a_case_only_move_of_the_track_itself_keeps_its_master(tmp_path, intent):
    db, upper, lower, track = _case_world(tmp_path, db_at="lower")
    db.insert_journal_entry(intent, track.uuid_id, str(upper), str(lower), str(tmp_path / ".staging" / "moved.m4a"))

    reconcile_journal(db, tmp_path)

    assert lower.read_bytes() == b"the master"
    assert not upper.exists() or upper.samefile(lower)  # the old name goes; the master never
    assert db.list_journal_entries() == []


# --- an in-place row replays only while the track is still at its path (6-5-R3-01 belt) ---------


@pytest.mark.parametrize("intent", ["inplace", "convert"])
@pytest.mark.parametrize("at_old_path", ["another track", "nothing"])
def test_an_in_place_row_never_replays_after_the_track_moved(tmp_path, caplog, intent, at_old_path):
    """A kept in-place row (edit or same-path conversion) whose temp is still staged
    is replayed onto ``old_path`` only while the track's master is still that path.
    Once the track has moved, whatever is at ``old_path`` is not the row's to
    overwrite: nothing is written, the row's own temp and the row are cleared, and
    a warning is logged."""
    caplog.set_level("WARNING", logger="app.services.track_editor")
    db = _db(tmp_path)
    root = tmp_path / "owner"
    (root / "Other").mkdir(parents=True)
    staging = tmp_path / ".staging"
    staging.mkdir()
    moved = root / "Other" / "song.m4a"
    moved.write_bytes(b"the track's current master")
    track = _add_track(db, moved, "T", "Other")
    old = root / "song.m4a"
    if at_old_path == "another track":
        old.write_bytes(b"track B master")
        _add_track(db, old, "B", "Art")
    temp = staging / f"{track.uuid_id}.0a1b.edit.m4a"
    temp.write_bytes(b"stale bytes of an earlier operation")
    db.insert_journal_entry(intent, track.uuid_id, str(old), None, str(temp))

    reconcile_journal(db, tmp_path)

    if at_old_path == "another track":
        assert old.read_bytes() == b"track B master"
    else:
        assert not old.exists()
    assert moved.read_bytes() == b"the track's current master"
    assert not temp.exists()
    assert db.list_journal_entries() == []
    assert any(r.levelname == "WARNING" for r in caplog.records)


# --- another track's master at a Unicode variant of the row's path (6-5-R3-02) ------------------

UNICODE_VARIANTS = [
    ("Élan", "élan"),       # non-ASCII case: SQLite's NOCASE folds ASCII only
    ("Café", "Café"),      # NFC vs NFD: APFS ignores the difference
]


def _variant_master(db, root, spelling):
    b = root / spelling / "song.m4a"
    b.parent.mkdir(parents=True, exist_ok=True)
    b.write_bytes(b"track B master")
    _add_track(db, b, "B", spelling)
    return b


@pytest.mark.parametrize("row_spelling,other_spelling", UNICODE_VARIANTS)
@pytest.mark.parametrize("intent", INTENTS)
@pytest.mark.parametrize("recovery", ["finisher", "startup"])
def test_finishing_a_row_keeps_a_master_at_a_unicode_variant_of_old_path(
    tmp_path, caplog, row_spelling, other_spelling, intent, recovery
):
    db = _db(tmp_path)
    root = tmp_path / "owner"
    (root / "Other").mkdir(parents=True)
    (tmp_path / ".staging").mkdir()
    new = root / "Other" / "song.m4a"
    new.write_bytes(b"the moved master")
    track = _add_track(db, new, "T", "Other")  # the move committed
    b = _variant_master(db, root, other_spelling)
    old = root / row_spelling / "song.m4a"
    db.insert_journal_entry(intent, track.uuid_id, str(old), str(new), str(tmp_path / ".staging" / "moved.m4a"))

    if recovery == "finisher":
        _finisher_passes(db, tmp_path, caplog)
    reconcile_journal(db, tmp_path)

    assert b.read_bytes() == b"track B master"
    assert new.read_bytes() == b"the moved master"


@pytest.mark.parametrize("row_spelling,other_spelling", UNICODE_VARIANTS)
@pytest.mark.parametrize("intent", INTENTS)
@pytest.mark.parametrize("recovery", ["finisher", "startup"])
def test_reverting_a_row_keeps_a_master_at_a_unicode_variant_of_new_path(
    tmp_path, caplog, row_spelling, other_spelling, intent, recovery
):
    db, root, staging, old, track = _world(tmp_path)  # the database never moved
    b = _variant_master(db, root, other_spelling)
    new = root / row_spelling / "song.m4a"
    db.insert_journal_entry(intent, track.uuid_id, str(old), str(new), str(staging / "gone.m4a"))

    if recovery == "finisher":
        _finisher_passes(db, tmp_path, caplog)
    reconcile_journal(db, tmp_path)

    assert b.read_bytes() == b"track B master"
    assert old.read_bytes() == b"old master"
    # Since 2026-11-16 (M1): startup leaves the claimed path alone and drops the row.
    assert db.list_journal_entries() == []


@pytest.mark.requires_ffmpeg
@pytest.mark.parametrize("first_artist,other_spelling", UNICODE_VARIANTS)
def test_a_kept_committed_edit_row_never_deletes_a_master_at_a_unicode_variant(
    tmp_path, monkeypatch, caplog, first_artist, other_spelling
):
    """Review r3 probe: A is edited to ``first_artist``, then edited again; that
    second move commits but its row's delete hits a locked database. Track B lands
    at another spelling of A's first folder; the finisher finishes the row."""
    import sqlite3

    from app.services.track_edit import WriteMode
    from tests.identity_editor_fixtures import _editor, _world as _editor_world
    from tests.track_editor_fixtures import _lib

    library, audio, db, track, before = _editor_world(tmp_path)
    _editor(library).apply_edit(
        _lib(db), track.uuid_id, {"artist": first_artist}, track.revision, WriteMode.db_and_master)
    first = Path(db.get_track_file_path(track.uuid_id))
    rev = db.get_track_by_uuid(track.uuid_id).revision
    _locked_once(monkeypatch, db)
    with pytest.raises(sqlite3.OperationalError):
        _editor(library).apply_edit(
            _lib(db), track.uuid_id, {"artist": "Other"}, rev, WriteMode.db_and_master)
    monkeypatch.undo()
    assert [e["old_path"] for e in db.list_journal_entries()] == [str(first)]
    assert not first.exists()
    b = _variant_master(db, library / "owner", other_spelling)

    _recover_both_ways(db, library, caplog)

    assert b.read_bytes() == b"track B master"
    assert db.list_journal_entries() == []
