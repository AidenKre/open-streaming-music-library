"""Finishing a committed move deletes nothing without proof that the move landed.

Sign-off OPEN-A-03 (refactor audit SP-PE-BE-01). A relocate row, or a convert row
whose path changes, is *finished* when the track's database row already points at
its ``new_path``: the old master and the staged copy are then redundant. If no file
is at ``new_path`` (a rename lost to a power cut after the commit reached the disk,
or the new file removed while the server was down), they are not redundant: they
are the track's last copies.

Updated 2026-11-16 (sign-off OPEN-6.5-05, the user's decision): startup no longer
keeps such a row. It settles it: a surviving staged copy is put in place, else the
file at the other location is adopted, and a file the ownership proofs do not
cover goes to the content rule. The proof itself stays: the old master is deleted
by proof only when a regular file is at ``new_path`` (lstat) and the staged copy
was consumed (or this recovery placed it there). Runtime recovery is unchanged:
it still keeps an unproven row for startup. The audio is faked as in
``test_journal_settle.py`` (``b"A|..."`` reads as audio A); the full state table
lives there.
"""

import logging

import pytest

from app.services.journal_recovery import reconcile_one
from app.services.track_editor import finish_kept_journal_rows
from app.services.track_editor import reconcile_journal as _reconcile_journal
from app.services.track_locks import TrackLocks
from tests.test_journal_settle import fake_read
from tests.track_editor_fixtures import _add_track, _db

INTENTS = ["relocate", "convert"]
OPERATOR = "uvicorn.error"
COMBOS = [(o, n, t) for o in (1, 0) for n in (1, 0) for t in (1, 0)]

OLD, MOVED, STAGED = b"A|old master", b"A|moved master", b"A|staged copy"


def reconcile_journal(db, music_dir):
    return _reconcile_journal(db, music_dir, read_audio=fake_read)


def _combo_id(combo):
    o, n, t = combo
    return f"old{o}-new{n}-temp{t}"


def _world(tmp_path, *, db_at, old, new, temp):
    """A track whose move from ``Old/song.flac`` to ``New/song.m4a`` was journaled;
    the database points at ``db_at`` ("old" or "new"); each file exists or not."""
    db = _db(tmp_path)
    root = tmp_path / "owner"
    root.mkdir()
    staging = tmp_path / ".staging"
    staging.mkdir()
    old_p = root / "Old" / "song.flac"
    old_p.parent.mkdir()
    if old:
        old_p.write_bytes(OLD)
    new_p = root / "New" / "song.m4a"
    if new:
        new_p.parent.mkdir()
        new_p.write_bytes(MOVED)
    track = _add_track(db, new_p if db_at == "new" else old_p, "T", "Art")
    temp_p = staging / f"{track.uuid_id}.0a1b2c.edit.m4a"
    if temp:
        temp_p.write_bytes(STAGED)
    return db, old_p, new_p, temp_p, track


def _journal(db, intent, track, old, new, temp):
    db.insert_journal_entry(intent, track.uuid_id, str(old), str(new), str(temp))


def _operator_lines(caplog):
    return [r.getMessage() for r in caplog.records if r.name == OPERATOR]


# --- the reproduction -----------------------------------------------------------------------------


@pytest.mark.parametrize("intent", INTENTS)
def test_a_lost_rename_after_the_commit_puts_the_staged_copy_in_place(tmp_path, intent, caplog):
    """The database committed the move, the rename did not reach the disk: the
    staged copy is put where the database points, then the old master goes by
    proof (the move is now complete). Never both copies lost; no path in the log."""
    db, old, new, temp, track = _world(tmp_path, db_at="new", old=1, new=0, temp=1)
    _journal(db, intent, track, old, new, temp)

    with caplog.at_level(logging.INFO, logger=OPERATOR):
        reconcile_journal(db, tmp_path)

    assert new.read_bytes() == STAGED
    assert not old.exists() and not temp.exists()
    assert db.get_track_file_path(track.uuid_id) == str(new)
    assert db.list_journal_entries() == []
    lines = _operator_lines(caplog)
    assert any(track.uuid_id in line for line in lines)
    for line in lines:
        assert str(tmp_path) not in line and "song" not in line and "Old" not in line


# --- the finish branch, every file state ----------------------------------------------------------

# combo -> (where the track points, files that remain with their bytes)
FINISH = {
    (1, 1, 1): ("new", {"new": MOVED}),  # old and staged copy: the same audio (rule b)
    (1, 1, 0): ("new", {"new": MOVED}),  # old by proof (rule a)
    (1, 0, 1): ("new", {"new": STAGED}),  # staged copy put in place, old by proof
    (1, 0, 0): ("old", {"old": OLD}),  # the old master adopted
    (0, 1, 1): ("new", {"new": MOVED}),  # staged copy: the same audio (rule b)
    (0, 1, 0): ("new", {"new": MOVED}),
    (0, 0, 1): ("new", {"new": STAGED}),  # staged copy put in place
    (0, 0, 0): ("new", {}),  # nothing left: an ordinary "file missing" track
}


@pytest.mark.parametrize("combo", COMBOS, ids=_combo_id)
@pytest.mark.parametrize("intent", INTENTS)
@pytest.mark.parametrize("recovery", ["startup", "finisher-then-startup"])
def test_finishing_a_committed_row_deletes_only_with_proof_and_settles_the_rest(
    tmp_path, combo, intent, recovery
):
    o, n, t = combo
    db, old, new, temp, track = _world(tmp_path, db_at="new", old=o, new=n, temp=t)
    _journal(db, intent, track, old, new, temp)

    if recovery == "finisher-then-startup":
        finish_kept_journal_rows(db, tmp_path, TrackLocks(), reported=set())
    reconcile_journal(db, tmp_path)

    points_at, remaining = FINISH[combo]
    paths = {"old": old, "new": new}
    assert db.get_track_file_path(track.uuid_id) == str(paths[points_at])
    for label, path in paths.items():
        if label in remaining:
            assert path.read_bytes() == remaining[label]
        else:
            assert not path.exists(), label
    assert not temp.exists()
    if o and points_at == "new":
        assert not old.parent.exists()  # the old master's empty folder is pruned
    if not o and n and not t and recovery == "startup":
        assert not old.parent.exists()  # today's finish prunes it too
    assert db.list_journal_entries() == []


@pytest.mark.parametrize("intent", INTENTS)
def test_a_new_path_that_is_not_a_regular_file_is_no_proof(tmp_path, intent):
    """A folder (or anything that is not a regular file) at ``new_path`` is not the
    moved master: nothing is deleted, the old master is adopted, the folder stays."""
    db, old, new, temp, track = _world(tmp_path, db_at="new", old=1, new=0, temp=0)
    new.mkdir(parents=True)
    _journal(db, intent, track, old, new, temp)

    reconcile_journal(db, tmp_path)

    assert old.read_bytes() == OLD
    assert db.get_track_file_path(track.uuid_id) == str(old)
    assert new.is_dir()
    assert db.list_journal_entries() == []


@pytest.mark.parametrize("intent", INTENTS)
def test_runtime_recovery_never_deletes_the_staged_copy_of_a_move_that_did_not_land(tmp_path, intent):
    """The audit's runtime case: old master gone, new file missing, staged copy left.
    Recovery inside a running server must not delete that last copy either."""
    db, old, new, temp, track = _world(tmp_path, db_at="new", old=0, new=0, temp=1)
    _journal(db, intent, track, old, new, temp)
    [entry] = db.list_journal_entries()

    try:
        reconcile_one(db, entry, tmp_path)
    except Exception:  # noqa: BLE001 - a kept row may be signalled by raising
        pass

    assert temp.read_bytes() == STAGED
    assert [e["intent"] for e in db.list_journal_entries()] == [intent]


@pytest.mark.parametrize("intent", INTENTS)
def test_the_idle_finisher_keeps_an_unproven_row_and_logs_it_once(tmp_path, intent, caplog):
    db, old, new, temp, track = _world(tmp_path, db_at="new", old=1, new=0, temp=0)
    _journal(db, intent, track, old, new, temp)
    caplog.set_level("WARNING", logger="app.services.track_editor")
    reported = set()

    finished = [finish_kept_journal_rows(db, tmp_path, TrackLocks(), reported=reported)
                for _ in range(3)]

    assert finished == [0, 0, 0]
    assert old.read_bytes() == OLD
    assert [e["intent"] for e in db.list_journal_entries()] == [intent]
    assert len([r for r in caplog.records if "journal finish failed" in r.getMessage()]) == 1


@pytest.mark.parametrize("intent", INTENTS)
def test_a_settled_lost_rename_stays_settled_at_the_next_start(tmp_path, intent):
    """Before 2026-11-16 such a row was kept until an operator put the staged copy
    at ``new_path``; now the first start does that, and a second start changes
    nothing."""
    db, old, new, temp, track = _world(tmp_path, db_at="new", old=1, new=0, temp=1)
    _journal(db, intent, track, old, new, temp)
    reconcile_journal(db, tmp_path)
    reconcile_journal(db, tmp_path)

    assert new.read_bytes() == STAGED
    assert not old.exists()
    assert db.list_journal_entries() == []


# --- the undo branch (the database never moved) ---------------------------------------------------


@pytest.mark.parametrize("n,t", [(1, 1), (1, 0), (0, 1), (0, 0)])
@pytest.mark.parametrize("intent", INTENTS)
def test_the_undo_of_an_uncommitted_move_leaves_only_the_old_master(tmp_path, intent, n, t):
    """With the old master in place, the undo removes the row's own copy at
    ``new_path`` (the staged copy was consumed: rule a); a file there while the
    staged copy is present goes to the content rule (here the same audio: rule b);
    the staged copy and the row go."""
    db, old, new, temp, track = _world(tmp_path, db_at="old", old=1, new=n, temp=t)
    _journal(db, intent, track, old, new, temp)

    reconcile_journal(db, tmp_path)

    assert old.read_bytes() == OLD
    assert not new.exists()
    assert not temp.exists()
    assert db.list_journal_entries() == []


# --- the undo branch: the master the database points at is missing --------------------------------
#
# The coordinator's rule of 2026-11-14 (delete nothing unless the track's own file
# is in place) still holds; since 2026-11-16 a copy is adopted instead of the row
# being kept.

UNDO_ROWS = [(1, 1), (1, 0), (0, 1)]  # state-table rows 5, 6, 7


@pytest.mark.parametrize("n,t", UNDO_ROWS, ids=["row5-new1-temp1", "row6-new1-temp0", "row7-new0-temp1"])
@pytest.mark.parametrize("intent", INTENTS)
@pytest.mark.parametrize("recovery", ["startup", "finisher-then-startup"])
def test_undoing_a_move_whose_old_master_is_missing_adopts_a_copy(
    tmp_path, intent, n, t, recovery, caplog
):
    db, old, new, temp, track = _world(tmp_path, db_at="old", old=0, new=n, temp=t)
    _journal(db, intent, track, old, new, temp)
    recovered = new.with_name("song (recovered 1).m4a")

    if recovery == "finisher-then-startup":
        finish_kept_journal_rows(db, tmp_path, TrackLocks(), reported=set())
    with caplog.at_level(logging.INFO, logger=OPERATOR):
        reconcile_journal(db, tmp_path)

    assert not old.exists() and not temp.exists()
    current = db.get_track_file_path(track.uuid_id)
    if (n, t) == (1, 1):  # the staged copy's place (new_path) is taken: the recovered name
        assert current == str(recovered) and recovered.read_bytes() == STAGED
        assert not new.exists()  # the same audio as the adopted copy (rule b)
    elif (n, t) == (1, 0):  # the row's own output at new_path is adopted
        assert current == str(new) and new.read_bytes() == MOVED
    else:
        assert current == str(new) and new.read_bytes() == STAGED
    assert db.list_journal_entries() == []
    for line in _operator_lines(caplog):
        assert str(tmp_path) not in line and "song" not in line and "Old" not in line


@pytest.mark.parametrize("intent", INTENTS)
def test_undoing_a_row_with_nothing_left_to_delete_still_drops_it(tmp_path, intent):
    """Guard, state-table row 8: no file anywhere, nothing to delete; unchanged."""
    db, old, new, temp, track = _world(tmp_path, db_at="old", old=0, new=0, temp=0)
    _journal(db, intent, track, old, new, temp)

    reconcile_journal(db, tmp_path)

    assert db.list_journal_entries() == []


@pytest.mark.parametrize("intent", INTENTS)
def test_a_row_whose_track_moved_on_to_a_missing_master_adopts_the_staged_copy(tmp_path, intent):
    """State-table M6: the database points elsewhere (a later move) and no file is
    there; the staged copy is put there, the copy at ``new_path`` has the same audio."""
    db = _db(tmp_path)
    root = tmp_path / "owner"
    (root / "New").mkdir(parents=True)
    staging = tmp_path / ".staging"
    staging.mkdir()
    old = root / "Old" / "song.flac"  # never created
    new = root / "New" / "song.m4a"
    new.write_bytes(MOVED)
    later = root / "Later" / "song.m4a"  # never created
    track = _add_track(db, later, "T", "Art")
    temp = staging / f"{track.uuid_id}.0a1b2c.edit.m4a"
    temp.write_bytes(STAGED)
    _journal(db, intent, track, old, new, temp)

    reconcile_journal(db, tmp_path)

    assert later.read_bytes() == STAGED
    assert db.get_track_file_path(track.uuid_id) == str(later)
    assert not new.exists() and not temp.exists()
    assert db.list_journal_entries() == []


@pytest.mark.parametrize("intent", ["inplace", "convert"])
def test_an_in_place_row_of_a_track_whose_master_is_missing_adopts_its_staged_copy(tmp_path, intent):
    """State-table I5 with the track's current master missing: the staged copy may
    be the track's last audio, so it is put where the track points."""
    db = _db(tmp_path)
    root = tmp_path / "owner"
    (root / "Other").mkdir(parents=True)
    staging = tmp_path / ".staging"
    staging.mkdir()
    current = root / "Other" / "song.m4a"  # never created
    track = _add_track(db, current, "T", "Other")
    temp = staging / f"{track.uuid_id}.0a1b.edit.m4a"
    temp.write_bytes(STAGED)
    db.insert_journal_entry(intent, track.uuid_id, str(root / "song.m4a"), None, str(temp))

    reconcile_journal(db, tmp_path)

    assert current.read_bytes() == STAGED
    assert not temp.exists()
    assert db.list_journal_entries() == []


@pytest.mark.parametrize("intent", INTENTS)
def test_a_symlink_at_new_path_is_no_proof_even_to_a_real_file(tmp_path, intent):
    """Review F3: the proof reads the name itself (lstat), never a link's target.
    The old master is then compared with the linked file: other audio, so it is
    kept as a track of its own."""
    db, old, new, temp, track = _world(tmp_path, db_at="new", old=1, new=0, temp=0)
    target = tmp_path / "owner" / "elsewhere.m4a"
    target.write_bytes(b"B|some file")
    new.parent.mkdir()
    new.symlink_to(target)
    _journal(db, intent, track, old, new, temp)

    reconcile_journal(db, tmp_path)

    assert old.read_bytes() == OLD
    assert db.track_path_in_use(str(old), owner_id=db.owner_id, exclude_uuid=track.uuid_id)
    assert new.is_symlink() and target.read_bytes() == b"B|some file"
    assert db.list_journal_entries() == []


@pytest.mark.parametrize("intent", INTENTS)
def test_undoing_when_the_database_points_at_a_folder_deletes_nothing_it_cannot_prove(tmp_path, intent):
    """Review F3: a folder where the old master should be is not the track's audio.
    The staged copy is adopted under the recovered name (new_path is taken); the
    copy at new_path has the same audio; the folder stays."""
    db, old, new, temp, track = _world(tmp_path, db_at="old", old=0, new=1, temp=1)
    old.mkdir()
    _journal(db, intent, track, old, new, temp)

    reconcile_journal(db, tmp_path)

    recovered = new.with_name("song (recovered 1).m4a")
    assert recovered.read_bytes() == STAGED
    assert db.get_track_file_path(track.uuid_id) == str(recovered)
    assert old.is_dir()
    assert db.list_journal_entries() == []
