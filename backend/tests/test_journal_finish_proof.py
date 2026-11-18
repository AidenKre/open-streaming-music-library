"""Finishing a committed move deletes nothing without proof that the move landed.

Sign-off OPEN-A-03 (refactor audit SP-PE-BE-01). A relocate row, or a convert row
whose path changes, is *finished* when the track's database row already points at
its ``new_path``: the old master and the staged copy are then redundant. If no file
is at ``new_path`` (a rename lost to a power cut after the commit reached the disk,
or the new file removed while the server was down), they are not redundant: they
are the track's last copies. Recovery now removes them only when a regular file is
at ``new_path`` and the row's staged copy was consumed by the move (the same
evidence the undo branch reads). Otherwise it deletes nothing, keeps the row and
logs one operator line naming the track, never a path.
"""

import logging

import pytest

from app.services.track_editor import (
    _reconcile_one,
    finish_kept_journal_rows,
    reconcile_journal,
)
from app.services.track_locks import TrackLocks
from tests.test_track_editor import _add_track, _db

INTENTS = ["relocate", "convert"]
OPERATOR = "uvicorn.error"
COMBOS = [(o, n, t) for o in (1, 0) for n in (1, 0) for t in (1, 0)]


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
        old_p.write_bytes(b"old master")
    new_p = root / "New" / "song.m4a"
    if new:
        new_p.parent.mkdir()
        new_p.write_bytes(b"moved master")
    track = _add_track(db, new_p if db_at == "new" else old_p, "T", "Art")
    temp_p = staging / f"{track.uuid_id}.0a1b2c.edit.m4a"
    if temp:
        temp_p.write_bytes(b"staged copy")
    return db, old_p, new_p, temp_p, track


def _journal(db, intent, track, old, new, temp):
    db.insert_journal_entry(intent, track.uuid_id, str(old), str(new), str(temp))


def _operator_lines(caplog):
    return [r.getMessage() for r in caplog.records if r.name == OPERATOR]


# --- the reproduction -----------------------------------------------------------------------------


@pytest.mark.parametrize("intent", INTENTS)
def test_a_lost_rename_after_the_commit_keeps_both_copies_and_the_row(tmp_path, intent, caplog):
    """The database committed the move, the rename did not reach the disk: the old
    master and the staged copy are the only copies of the track's audio."""
    db, old, new, temp, track = _world(tmp_path, db_at="new", old=1, new=0, temp=1)
    _journal(db, intent, track, old, new, temp)

    with caplog.at_level(logging.WARNING, logger=OPERATOR):
        reconcile_journal(db, tmp_path)

    assert old.read_bytes() == b"old master"
    assert temp.read_bytes() == b"staged copy"
    assert not new.exists()
    assert [e["intent"] for e in db.list_journal_entries()] == [intent]
    [line] = _operator_lines(caplog)
    assert track.uuid_id in line
    assert str(tmp_path) not in line and "song" not in line and "Old" not in line


# --- the finish branch, every file state ----------------------------------------------------------


@pytest.mark.parametrize("combo", COMBOS, ids=_combo_id)
@pytest.mark.parametrize("intent", INTENTS)
@pytest.mark.parametrize("recovery", ["startup", "finisher-then-startup"])
def test_finishing_a_committed_row_deletes_only_with_proof_that_the_move_landed(
    tmp_path, combo, intent, recovery
):
    o, n, t = combo
    db, old, new, temp, track = _world(tmp_path, db_at="new", old=o, new=n, temp=t)
    _journal(db, intent, track, old, new, temp)

    if recovery == "finisher-then-startup":
        finish_kept_journal_rows(db, tmp_path, TrackLocks(), reported=set())
    reconcile_journal(db, tmp_path)

    if n and not t:  # proof: the moved master is there and the move consumed its staged copy
        assert new.read_bytes() == b"moved master"
        assert not old.exists()  # the normal finish still cleans up
        if recovery == "startup" or o:  # runtime recovery never prunes; startup does
            assert not old.parent.exists()
        assert db.list_journal_entries() == []
    else:  # no proof: every file stays as it was and the row is kept
        assert old.exists() == bool(o)
        if o:
            assert old.read_bytes() == b"old master"
        assert new.exists() == bool(n)
        if n:
            assert new.read_bytes() == b"moved master"
        assert temp.exists() == bool(t)
        if t:
            assert temp.read_bytes() == b"staged copy"
        assert [e["intent"] for e in db.list_journal_entries()] == [intent]


@pytest.mark.parametrize("intent", INTENTS)
def test_a_new_path_that_is_not_a_regular_file_is_no_proof(tmp_path, intent):
    """A folder (or anything that is not a regular file) at ``new_path`` is not the
    moved master."""
    db, old, new, temp, track = _world(tmp_path, db_at="new", old=1, new=0, temp=0)
    new.mkdir(parents=True)
    _journal(db, intent, track, old, new, temp)

    reconcile_journal(db, tmp_path)

    assert old.read_bytes() == b"old master"
    assert new.is_dir()
    assert [e["intent"] for e in db.list_journal_entries()] == [intent]


@pytest.mark.parametrize("intent", INTENTS)
def test_runtime_recovery_never_deletes_the_staged_copy_of_a_move_that_did_not_land(tmp_path, intent):
    """The audit's runtime case: old master gone, new file missing, staged copy left.
    Recovery inside a running server must not delete that last copy either."""
    db, old, new, temp, track = _world(tmp_path, db_at="new", old=0, new=0, temp=1)
    _journal(db, intent, track, old, new, temp)
    [entry] = db.list_journal_entries()

    try:
        _reconcile_one(db, entry, tmp_path, runtime=True)
    except Exception:  # noqa: BLE001 - a kept row may be signalled by raising
        pass

    assert temp.read_bytes() == b"staged copy"
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
    assert old.read_bytes() == b"old master"
    assert [e["intent"] for e in db.list_journal_entries()] == [intent]
    assert len([r for r in caplog.records if "journal finish failed" in r.getMessage()]) == 1


@pytest.mark.parametrize("intent", INTENTS)
def test_a_kept_row_is_finished_at_the_next_start_once_the_moved_master_is_in_place(tmp_path, intent):
    """What resolves a kept row: an operator puts the staged copy at ``new_path``;
    the next start then finds the proof and finishes the move normally."""
    db, old, new, temp, track = _world(tmp_path, db_at="new", old=1, new=0, temp=1)
    _journal(db, intent, track, old, new, temp)
    reconcile_journal(db, tmp_path)
    assert len(db.list_journal_entries()) == 1

    new.parent.mkdir()
    temp.rename(new)
    reconcile_journal(db, tmp_path)

    assert new.read_bytes() == b"staged copy"
    assert not old.exists()
    assert db.list_journal_entries() == []


# --- the undo branch is unchanged (the database never moved) --------------------------------------


@pytest.mark.parametrize("n,t", [(1, 1), (1, 0), (0, 1), (0, 0)])
@pytest.mark.parametrize("intent", INTENTS)
def test_the_undo_of_an_uncommitted_move_is_unchanged(tmp_path, intent, n, t):
    """Guard: with the old master in place, the undo removes the row's own copy at
    ``new_path`` (the staged copy was consumed), leaves a file there otherwise,
    drops the staged copy and the row."""
    db, old, new, temp, track = _world(tmp_path, db_at="old", old=1, new=n, temp=t)
    _journal(db, intent, track, old, new, temp)

    reconcile_journal(db, tmp_path)

    assert old.read_bytes() == b"old master"
    assert new.exists() == bool(n and t)
    assert not temp.exists()
    assert db.list_journal_entries() == []


# --- the undo branch: the master the database points at is missing --------------------------------
#
# Coordinator 2026-11-14 (OPEN-A-03 scope): recovery never deletes a file unless a
# regular file of the track's audio is proven to exist where the database points
# after the step. In the undo branch the database points at ``old_path``; when the
# old master is gone (removed while the server was down), the staged copy or the
# moved copy at ``new_path`` is the track's last copy.

UNDO_ROWS = [(1, 1), (1, 0), (0, 1)]  # state-table rows 5, 6, 7


@pytest.mark.parametrize("n,t", UNDO_ROWS, ids=["row5-new1-temp1", "row6-new1-temp0", "row7-new0-temp1"])
@pytest.mark.parametrize("intent", INTENTS)
@pytest.mark.parametrize("recovery", ["startup", "finisher-then-startup"])
def test_undoing_a_move_whose_old_master_is_missing_deletes_nothing(
    tmp_path, intent, n, t, recovery, caplog
):
    db, old, new, temp, track = _world(tmp_path, db_at="old", old=0, new=n, temp=t)
    _journal(db, intent, track, old, new, temp)

    if recovery == "finisher-then-startup":
        finish_kept_journal_rows(db, tmp_path, TrackLocks(), reported=set())
    with caplog.at_level(logging.WARNING, logger=OPERATOR):
        reconcile_journal(db, tmp_path)

    assert not old.exists()
    assert new.exists() == bool(n)
    if n:
        assert new.read_bytes() == b"moved master"
    assert temp.exists() == bool(t)
    if t:
        assert temp.read_bytes() == b"staged copy"
    assert [e["intent"] for e in db.list_journal_entries()] == [intent]
    [line] = _operator_lines(caplog)
    assert track.uuid_id in line
    assert str(tmp_path) not in line and "song" not in line and "Old" not in line


@pytest.mark.parametrize("intent", INTENTS)
def test_undoing_a_row_with_nothing_left_to_delete_still_drops_it(tmp_path, intent):
    """Guard, state-table row 8: no file anywhere, nothing to delete; unchanged."""
    db, old, new, temp, track = _world(tmp_path, db_at="old", old=0, new=0, temp=0)
    _journal(db, intent, track, old, new, temp)

    reconcile_journal(db, tmp_path)

    assert db.list_journal_entries() == []


@pytest.mark.parametrize("intent", INTENTS)
def test_undoing_a_row_whose_track_moved_on_to_a_missing_master_deletes_nothing(tmp_path, intent):
    """State-table row 17: the database points elsewhere (a later move) and no file
    is there; the copies the row knows about are kept."""
    db = _db(tmp_path)
    root = tmp_path / "owner"
    (root / "New").mkdir(parents=True)
    staging = tmp_path / ".staging"
    staging.mkdir()
    old = root / "Old" / "song.flac"  # never created
    new = root / "New" / "song.m4a"
    new.write_bytes(b"moved master")
    track = _add_track(db, root / "Later" / "song.m4a", "T", "Art")  # never created
    temp = staging / f"{track.uuid_id}.0a1b2c.edit.m4a"
    temp.write_bytes(b"staged copy")
    _journal(db, intent, track, old, new, temp)

    reconcile_journal(db, tmp_path)

    assert new.read_bytes() == b"moved master"
    assert temp.read_bytes() == b"staged copy"
    assert [e["intent"] for e in db.list_journal_entries()] == [intent]


@pytest.mark.parametrize("intent", ["inplace", "convert"])
def test_an_in_place_row_of_a_track_whose_master_is_missing_keeps_its_staged_copy(tmp_path, intent):
    """State-table row I5 with the track's current master missing: the staged copy
    may be the track's last audio, so it is not discarded."""
    db = _db(tmp_path)
    root = tmp_path / "owner"
    (root / "Other").mkdir(parents=True)
    staging = tmp_path / ".staging"
    staging.mkdir()
    track = _add_track(db, root / "Other" / "song.m4a", "T", "Other")  # never created
    temp = staging / f"{track.uuid_id}.0a1b.edit.m4a"
    temp.write_bytes(b"staged copy")
    db.insert_journal_entry(intent, track.uuid_id, str(root / "song.m4a"), None, str(temp))

    reconcile_journal(db, tmp_path)

    assert temp.read_bytes() == b"staged copy"
    assert [e["intent"] for e in db.list_journal_entries()] == [intent]


@pytest.mark.parametrize("intent", INTENTS)
def test_a_symlink_at_new_path_is_no_proof_even_to_a_real_file(tmp_path, intent):
    """Review F3: the proof reads the name itself (lstat), never a link's target."""
    db, old, new, temp, track = _world(tmp_path, db_at="new", old=1, new=0, temp=0)
    target = tmp_path / "owner" / "elsewhere.m4a"
    target.write_bytes(b"some file")
    new.parent.mkdir()
    new.symlink_to(target)
    _journal(db, intent, track, old, new, temp)

    reconcile_journal(db, tmp_path)

    assert old.read_bytes() == b"old master"
    assert new.is_symlink() and target.read_bytes() == b"some file"
    assert [e["intent"] for e in db.list_journal_entries()] == [intent]


@pytest.mark.parametrize("intent", INTENTS)
def test_undoing_when_the_database_points_at_a_folder_deletes_nothing(tmp_path, intent):
    """Review F3: a folder where the old master should be is not the track's audio."""
    db, old, new, temp, track = _world(tmp_path, db_at="old", old=0, new=1, temp=1)
    old.mkdir()
    _journal(db, intent, track, old, new, temp)

    reconcile_journal(db, tmp_path)

    assert new.read_bytes() == b"moved master"
    assert temp.read_bytes() == b"staged copy"
    assert [e["intent"] for e in db.list_journal_entries()] == [intent]
