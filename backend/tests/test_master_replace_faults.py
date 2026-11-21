"""Faults of "replace a track's file" (refactor piece BE-REPLACE, stage 1).

``tests/test_master_replace_matrix.py`` stops each writer before each of its
steps. This file makes a step *fail* the way it can in a running server (the
move refused, the commit refused by a busy database, a durable point that
answers no, the final replace refused and its undo refused or interrupted, the
identity write refused), and plants the states that earlier defects made real: the staged copy
lost, another track's file at the path, a symbolic link where a file is
expected, a database that lost what was not yet flushed, the track deleted in
between, a rename that differs only in case.

Each failing step is followed by every recovery path: the next start alone, and
the same track's next edit, its next conversion request and the idle pass, each
followed by the next start. Expected values are written here from the rules of
the work order (7.3) and of the fixes that made them (the progress files of
``signoff-8-recovery-settle``, ``-journal-flush``, ``-second-wait`` and of bug
U06-B-06), not read off the code. The rig (``tests/replace_matrix_rig.py``) says
what is real and what is faked.
"""

import logging
import os
import sqlite3
import sys
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Optional

import pytest

from app.services.conversion import PendingRecovery
from app.services.path_sanitize import PathEscapesRoot
from app.services.track_editor import MasterSwapPending, MasterWriteError
from tests.crash import Crash
from tests.replace_matrix_rig import (
    ANY_TEXT,
    AUDIO,
    DB_ONLY,
    NEW,
    OLD,
    RUNTIME_PATHS,
    WRITERS,
    Expect,
    Writer,
    bystander_files,
    build_world,
    check_evidence,
    check_final,
    check_others_untouched,
    check_safe,
    check_settled,
    each_killed_start,
    master,
    meet_at_runtime,
)
from tests.track_paths import allow_two_tracks_on_one_path, set_track_path
from tests.track_removal import delete_track

# The sentences a client reads on a same-file conversion's job (pinned copies).
SWAP_REFUSED = (
    "The converted file could not replace the original, so the original was kept. "
    "Convert it again."
)
SWAP_PENDING = (
    "The conversion could not be finished. The server checks this track at its next start."
)
SWAP_LOST = "The converted file was lost, so the original was kept. Convert it again."
SWAP_UNPROVEN = "could not place the converted master"
TRACK_CHANGED = "track changed since the conversion was requested"

E_OLD = Expect(OLD, 0, "kept")
E_NEW = Expect(NEW, 1, "stale")
E_DB_ONLY = Expect(DB_ONLY, 1, "kept")
C_OLD = Expect(OLD, 0, "kept", job=("failed", ANY_TEXT))
C_NEW = Expect(NEW, 1, "stale", job=("done", None))
C_DONE = Expect(NEW, 1, "written", job=("done", None))
C_SWAPPED = Expect(NEW, 2, "stale", job=("done", None))
# The original was kept and the catalog describes it again (it was bumped for
# the conversion's commit and for the way back).
C_LOST = Expect(OLD, 2, "stale", job=("failed", SWAP_LOST), detour=True)
# A refused same-file swap that was taken back: the same, said by the job itself.
# The identity stays marked: the unchanged file is hashed again.
C_UNDONE = Expect(OLD, 2, "stale", job=("failed", SWAP_REFUSED), detour=True)


# A file's flush is one call, or two where the full flush is tried first and
# refused (macOS): both must fail for the flush to fail.
FLUSH_CALLS = 2 if sys.platform == "darwin" else 1


def busy():
    return sqlite3.OperationalError("database is locked")


def refused():
    return OSError(13, "Permission denied")


def warnings_of(world) -> int:
    return sum(level == "WARNING" for level, _ in world.recorder.operator_lines)


# --- a step fails in a running server -----------------------------------------------------------------


@dataclass(frozen=True)
class Case:
    """``faults`` are placed on the writer's steps: (step, kind, keywords of
    ``Recorder.place``). ``answer``: the error an edit raises (None: it
    succeeds), or the status of a conversion's job. ``rows``: journal rows the
    server is left with. ``held``: they wait for the next start. ``end``: after
    the next start. ``survived``: after the running server finished the rows and
    the next start, where that differs. ``lines``: operator warnings written."""

    writer: str
    id: str
    faults: tuple
    answer: object
    end: Expect
    rows: int = 0
    held: bool = False
    survived: Optional[Expect] = None
    lines: int = 0
    steps: tuple = ()  # steps the writer must have taken, in this order
    staged: int = 0  # staged copies left that no row names (the next start removes them)


CASES = [
    # --- W1, a moving edit ---
    # G3: on a failed move the row is deleted first, then the staged copy.
    Case("W1", "the move is refused", (("fs.replace T -> N", "raise", {"error": refused()}),),
         MasterWriteError, E_OLD, steps=("db.delete_journal_entry", "fs.unlink T")),
    # G5: the commit raises: the file goes back to staging, the row and the copy go.
    Case("W1", "the commit is refused",
         (("db.apply_track_metadata_edit", "raise", {"error": busy()}),),
         sqlite3.OperationalError, E_OLD,
         steps=("fs.replace N -> T", "db.delete_journal_entry", "fs.unlink T")),
    Case("W1", "the commit is refused and the move back too",
         (("db.apply_track_metadata_edit", "raise", {"error": busy()}),
          ("fs.replace N -> T", "raise", {"error": refused()})),
         sqlite3.OperationalError, E_OLD, steps=("fs.unlink N", "db.delete_journal_entry")),
    # The staged copy stays while the row does: it shows the move was undone.
    Case("W1", "the commit is refused and then the row's deletion",
         (("db.apply_track_metadata_edit", "raise", {"error": busy()}),
          ("db.delete_journal_entry", "raise", {"error": busy()})),
         sqlite3.OperationalError, E_OLD, rows=1),
    Case("W1", "the move is refused and then the row's deletion",
         (("fs.replace T -> N", "raise", {"error": refused()}),
          ("db.delete_journal_entry", "raise", {"error": busy()})),
         sqlite3.OperationalError, E_OLD, rows=1),
    Case("W1", "the journal row cannot be written",
         (("db.insert_journal_entry", "raise", {"error": busy()}),),
         sqlite3.OperationalError, E_OLD),
    # The staged copy could not be flushed: nothing is journaled, the copy goes.
    Case("W1", "the staged copy cannot be flushed",
         (("fs.flush T", "raise", {"error": refused(), "times": FLUSH_CALLS}),),
         MasterWriteError, E_OLD),
    # Decision D10: the move goes ahead after a failed flush, with one line; the
    # second point is then asked once without waiting.
    Case("W1", "the flush before the move answers no",
         (("db.make_durable", "answer", {"answer": False}),),
         None, E_NEW, lines=1, steps=("db.make_durable(no wait)", "fs.unlink O")),
    Case("W1", "the flush before the move raises",
         (("db.make_durable", "raise", {"error": RuntimeError("disk")}),),
         None, E_NEW, lines=1, steps=("db.make_durable(no wait)", "fs.unlink O")),
    # G6: without a durable point the old file and the row stay, the file is
    # remembered, and the edit still succeeds. The running server may remove
    # that remembered file after a later durable point.
    Case("W1", "the flush before the old file goes answers no",
         (("db.make_durable", "answer", {"answer": False, "nth": 2}),),
         None, E_NEW, rows=1, lines=1),
    Case("W1", "the flush before the old file goes raises",
         (("db.make_durable", "raise", {"error": RuntimeError("disk"), "nth": 2}),),
         None, E_NEW, rows=1, lines=1),
    Case("W1", "both flushes answer no",
         (("db.make_durable", "answer", {"answer": False}),
          ("db.make_durable(no wait)", "answer", {"answer": False})),
         None, E_NEW, rows=1, lines=2),
    Case("W1", "the row's deletion is refused after the old file went",
         (("db.delete_journal_entry", "raise", {"error": busy()}),),
         sqlite3.OperationalError, E_NEW, rows=1),
    # --- W2, a conversion to another extension ---
    Case("W2", "the move is refused", (("fs.replace T -> N", "raise", {"error": refused()}),),
         "failed", C_OLD, steps=("db.delete_journal_entry", "fs.unlink T")),
    Case("W2", "the commit is refused",
         (("db.complete_conversion_job", "raise", {"error": busy()}),),
         "failed", C_OLD, steps=("fs.replace N -> T", "db.delete_journal_entry", "fs.unlink T")),
    Case("W2", "the commit is refused and the move back too",
         (("db.complete_conversion_job", "raise", {"error": busy()}),
          ("fs.replace N -> T", "raise", {"error": refused()})),
         "failed", C_OLD, steps=("fs.unlink N", "db.delete_journal_entry")),
    Case("W2", "the move is refused and then the row's deletion",
         (("fs.replace T -> N", "raise", {"error": refused()}),
          ("db.delete_journal_entry", "raise", {"error": busy()})),
         "failed", C_OLD, rows=1),
    Case("W2", "the commit is refused and then the row's deletion",
         (("db.complete_conversion_job", "raise", {"error": busy()}),
          ("db.delete_journal_entry", "raise", {"error": busy()})),
         "failed", C_OLD, rows=1),
    Case("W2", "the staged copy cannot be flushed",
         (("fs.flush T", "raise", {"error": refused(), "times": FLUSH_CALLS}),),
         "failed", C_OLD),
    Case("W2", "the journal row cannot be written",
         (("db.insert_journal_entry", "raise", {"error": busy()}),),
         "failed", C_OLD),
    Case("W2", "the flush before the move answers no",
         (("db.make_durable", "answer", {"answer": False}),),
         "done", C_DONE, lines=1, steps=("db.make_durable(no wait)", "fs.unlink O")),
    Case("W2", "the flush before the old file goes answers no",
         (("db.make_durable", "answer", {"answer": False, "nth": 2}),),
         "done", C_NEW, rows=1, lines=1),
    Case("W2", "both flushes answer no",
         (("db.make_durable", "answer", {"answer": False}),
          ("db.make_durable(no wait)", "answer", {"answer": False})),
         "done", C_NEW, rows=1, lines=2),
    Case("W2", "the row's deletion is refused after the old file went",
         (("db.delete_journal_entry", "raise", {"error": busy()}),),
         "done", C_NEW, rows=1),
    # --- W3, an edit in place ---
    Case("W3", "the staged copy cannot be flushed",
         (("fs.flush T", "raise", {"error": refused(), "times": FLUSH_CALLS}),),
         MasterWriteError, E_OLD),
    Case("W3", "the commit is refused",
         (("db.apply_track_metadata_edit", "raise", {"error": busy()}),),
         sqlite3.OperationalError, E_OLD),
    # The catalog advanced, no row: the catalog has the new tags, the file the old.
    Case("W3", "the journal row cannot be written",
         (("db.insert_journal_entry", "raise", {"error": busy()}),),
         sqlite3.OperationalError, E_DB_ONLY),
    # G7: from the row on no error path deletes the staged copy.
    Case("W3", "the replace is refused", (("fs.replace T -> O", "raise", {"error": refused()}),),
         MasterSwapPending, E_NEW, rows=1),
    # G7: a failed identity mark keeps the row and the edit still succeeds.
    Case("W3", "the identity mark is refused",
         (("db.mark_audio_identity_stale", "raise", {"error": busy()}),),
         None, E_NEW, rows=1),
    Case("W3", "the row's deletion is refused",
         (("db.delete_journal_entry", "raise", {"error": busy()}),),
         sqlite3.OperationalError, E_NEW, rows=1),
    # --- W4, a conversion in place ---
    Case("W4", "the commit is refused",
         (("db.complete_conversion_job", "raise", {"error": busy()}),),
         "failed", C_OLD),
    Case("W4", "the staged copy cannot be flushed",
         (("fs.flush T", "raise", {"error": refused(), "times": FLUSH_CALLS}),),
         "failed", C_OLD),
    Case("W4", "the flush before the replace answers no",
         (("db.make_durable", "answer", {"answer": False}),),
         "done", C_DONE, lines=1),
    Case("W4", "the flush before the replace raises",
         (("db.make_durable", "raise", {"error": RuntimeError("disk")}),),
         "done", C_DONE, lines=1),
    # One attempt (the owner's decision of 2026-11-18). A refused replace is
    # taken back in one transaction: the catalog describes the original again
    # at a new revision, the row goes, the job says so; the worker is woken for
    # the marked identity; then, after a durable point, the staged copy goes.
    Case("W4", "the replace is refused",
         (("fs.replace T -> O", "raise", {"error": refused()}),),
         "failed", C_UNDONE,
         steps=("db.undo_inplace_conversion", "signal.notify", "db.make_durable", "fs.unlink T")),
    # The undo itself is refused: what a crash at that instant leaves. The job
    # fails truthfully, the row and the staged copy stay, and only the next
    # start places the converted bytes.
    Case("W4", "the replace is refused and the undo too",
         (("fs.replace T -> O", "raise", {"error": refused()}),
          ("db.undo_inplace_conversion", "raise", {"error": busy()})),
         "failed", C_SWAPPED, rows=1, held=True),
    # ... and the job cannot even be marked: exactly the crash state (job done).
    Case("W4", "the replace is refused, the undo too, and the job cannot say so",
         (("fs.replace T -> O", "raise", {"error": refused()}),
          ("db.undo_inplace_conversion", "raise", {"error": busy()}),
          ("db.mark_conversion_job_failed", "raise", {"error": busy()})),
         "done", C_SWAPPED, rows=1, held=True),
    # The rename happened and an error was reported all the same: the staged
    # copy is gone, so nothing is taken back; the next start reads the file.
    Case("W4", "the replace reports an error after it happened",
         (("fs.replace T -> O", "raise_after", {"error": refused()}),),
         "failed", C_SWAPPED, rows=1, held=True),
    # The undo is not known to be on disk: the staged copy stays (a power cut
    # could bring its row back) until the next start, which removes it.
    Case("W4", "the replace is refused and the flush after the undo answers no",
         (("fs.replace T -> O", "raise", {"error": refused()}),
          ("db.make_durable", "answer", {"answer": False, "nth": 2})),
         "failed", C_UNDONE, staged=1),
    Case("W4", "the replace is refused and the flush after the undo raises",
         (("fs.replace T -> O", "raise", {"error": refused()}),
          ("db.make_durable", "raise", {"error": RuntimeError("disk"), "nth": 2})),
         "failed", C_UNDONE, staged=1),
    Case("W4", "the replace is refused and the staged copy cannot be removed",
         (("fs.replace T -> O", "raise", {"error": refused()}),
          ("fs.unlink T", "raise", {"error": refused()})),
         "failed", C_UNDONE, staged=1),
    Case("W4", "the identity write is refused",
         (("db.write_conversion_identity", "raise", {"error": busy()}),),
         "done", C_SWAPPED, rows=1, survived=C_NEW),
    Case("W4", "the row's deletion is refused",
         (("db.delete_journal_entry", "raise", {"error": busy()}),),
         "done", C_SWAPPED, rows=1, survived=C_NEW),
]


def _flush_faults(case: Case) -> list:
    return [(step, keywords.get("nth", 1)) for step, _kind, keywords in case.faults
            if step.startswith("db.make_durable")]


def run_case(world, case: Case) -> None:
    """The writer with the case's faults; every fault must have fired."""
    placed = [world.recorder.place(step, kind, **keywords) for step, kind, keywords in case.faults]
    if world.writer.kind == "convert":
        world.run_writer()
        assert world.job()[0] == case.answer, world.job()
    elif case.answer is None:
        world.run_writer()
    else:
        with pytest.raises(case.answer):
            world.run_writer()
    assert all(fault.hits == fault.times for fault in placed), (
        [(f.step, f.hits) for f in placed], world.recorder.steps)
    taken = iter(world.recorder.steps)
    assert all(step in taken for step in case.steps), (case.steps, world.recorder.steps)
    assert len(world.journal()) == case.rows
    assert warnings_of(world) == case.lines
    if world.writer.moving and case.lines:
        # The two lines of the shared helpers, word for word (work order G9), with
        # the journal row's id and the track's id and nothing else.
        wanted = []
        if any(step.startswith("db.make_durable") and nth == 1 for step, nth in _flush_faults(case)):
            wanted.append(
                f"journal entry 1 for track {world.uuid}: the file is about to move although it "
                "could not be confirmed just now that database.db holds every saved change (the "
                "entry itself is already on disk)"
            )
        if case.rows:
            wanted.append(f"journal entry 1 for track {world.uuid}: the old file waits for a database flush")
        assert [text for level, text in world.recorder.operator_lines if level == "WARNING"] == wanted
    assert world.reservations() == 0  # G11: given back whatever happened
    assert world.recorder.steps.count("ledger.release") == (world.writer.kind == "convert")
    check_safe(world)
    check_evidence(world)


@pytest.mark.parametrize("case_id", [
    "W2-the row's deletion is refused after the old file went",
    "W4-the identity write is refused",
    "W4-the row's deletion is refused",
])
def test_a_failure_after_the_commit_never_fails_the_job(tmp_path, monkeypatch, case_id):
    """A job that fails for a reason the server has no sentence for says "The
    conversion failed. The original was kept." That is true only before the
    commit. Here a step fails after it: the converted file is the track's file,
    so the job stays done with no text, also when the writer's own handler
    tries to mark it failed with that sentence (the first and the last case:
    the error leaves the writer)."""
    case = CASES_BY_ID[case_id]
    world = build_world(tmp_path, monkeypatch, WRITERS[case.writer])

    run_case(world, case)

    assert world.job() == ("done", None)
    assert world.track()["codec"] == AUDIO[world.writer.new_audio][0]
    if "deletion is refused" in case_id:
        assert "db.mark_conversion_job_failed" in world.recorder.steps, world.recorder.steps


@pytest.mark.parametrize("path", ["start", *RUNTIME_PATHS])
@pytest.mark.parametrize("case", [pytest.param(c, id=f"{c.writer}-{c.id}") for c in CASES])
def test_a_failing_step_and_every_recovery_path(tmp_path, monkeypatch, case, path):
    world = build_world(tmp_path, monkeypatch, WRITERS[case.writer])
    run_case(world, case)
    if case.rows == 0:
        assert len(world.staged()) == case.staged, "nothing else may be left staged without a row"

    expect = case.end
    if path != "start":
        finished, edited = meet_at_runtime(world, path, case.held)
        if finished and case.survived is not None:
            expect = case.survived
        if edited:
            expect = replace(expect, bumps=expect.bumps + 1, identity="stale", title="Next")
    world.recorder.begin("start")
    world.start_up()

    # The second start is run where the next start is the case's own subject.
    (check_settled if path == "start" else check_final)(world, expect)


def test_a_refused_same_file_swap_is_taken_back_at_once(tmp_path, monkeypatch):
    """One attempt, then the undo, step by step under the track's lock: the
    job says what happened, the catalog row reads as before the conversion (two
    bumps later), nothing is staged, the worker was woken for a marked
    identity, the caches were evicted once and the reservation given back once."""
    world = build_world(tmp_path, monkeypatch, WRITERS["W4"])
    before = world.track()
    run_case(world, CASES_BY_ID["W4-the replace is refused"])

    steps = world.recorder.steps
    commit = steps.index("db.complete_conversion_job")
    assert steps[commit:] == [
        "db.complete_conversion_job",
        "db.make_durable",
        "fs.replace T -> O raises PermissionError",  # once: no retry
        "db.undo_inplace_conversion",  # the catalog, the row and the job in one commit
        "signal.notify",
        "db.make_durable",  # the staged copy goes only once the undo is on disk
        "fs.unlink T",
        "cache.evict",
        "default_cache.evict",
        "ledger.release",
    ]
    assert all(world.recorder.locked[commit:steps.index("fs.unlink T") + 1]), "the track's lock is held"
    assert world.job() == ("failed", SWAP_REFUSED)
    assert world.track() == {**before, "revision": world.track()["revision"]}
    assert world.bumps() == 2
    assert world.staged() == [] and world.journal() == []
    assert world.wakeup.saw_pending == [True]
    assert world.cache.evicted == world.default_cache.evicted == [world.uuid]
    assert world.recorder.operator_lines == []


def test_a_refused_same_file_swap_that_is_not_taken_back_says_so_until_the_next_start(
    tmp_path, monkeypatch
):
    """The undo was refused. Between the failure and the next start the job
    reads failed with the sentence that says who finishes it; the catalog
    already has the new format, the file the old bytes, and the row with its
    staged copy is the promise."""
    world = build_world(tmp_path, monkeypatch, WRITERS["W4"])
    run_case(world, CASES_BY_ID["W4-the replace is refused and the undo too"])

    assert world.job() == ("failed", SWAP_PENDING)
    assert world.old.read_bytes() == world.writer.old_bytes
    assert world.staged_copy().read_bytes() == world.writer.new_bytes
    assert world.bumps() == 1
    assert world.cache.evicted == [world.uuid]


CASES_BY_ID = {f"{c.writer}-{c.id}": c for c in CASES}


def _failed(case_id: str):
    def prepare(world):
        run_case(world, CASES_BY_ID[case_id])
    return prepare


@pytest.mark.parametrize("case_id, expect", [
    ("W1-the flush before the old file goes answers no", E_NEW),
    ("W2-the flush before the old file goes answers no", C_NEW),
    ("W3-the replace is refused", E_NEW),
    ("W4-the replace is refused and the undo too", C_SWAPPED),
    ("W4-the replace reports an error after it happened", C_SWAPPED),
    ("W4-the identity write is refused", C_SWAPPED),
])
def test_the_next_start_killed_at_any_step_over_a_kept_row(tmp_path, monkeypatch, case_id, expect):
    killed = each_killed_start(
        tmp_path, monkeypatch, case_id[:2], _failed(case_id),
        lambda world: check_final(world, replace(expect, extra_bumps=True)))

    assert killed >= 3


# --- a kill inside a failure branch -------------------------------------------------------------------


@pytest.mark.parametrize("name, commit, expect", [
    ("W1", "db.apply_track_metadata_edit", E_OLD), ("W2", "db.complete_conversion_job", C_OLD),
])
@pytest.mark.parametrize("step", ["fs.replace N -> T", "db.delete_journal_entry", "fs.unlink T"])
def test_a_kill_inside_the_undo_of_a_refused_commit(tmp_path, monkeypatch, name, commit, expect, step):
    """G5 step by step: the copy goes back to staging, the row goes, the staged
    copy goes. Killed before any of the three, the next start ends with the old
    file and nothing else."""
    world = build_world(tmp_path, monkeypatch, WRITERS[name])
    try:
        world.recorder.place(commit, "raise", error=busy())
        world.recorder.place(step)
        world.recorder.run_killed(world.run_writer)
        check_safe(world)
        check_evidence(world)

        world.recorder.begin("start")
        world.start_up()

        check_settled(world, expect)
    finally:
        world.recorder.thaw()


# Where a refused same-file swap can be stopped: (the step, its occurrence,
# whether the undo's transaction is refused first, what the next start leaves).
# Before the undo committed, the state is the one a kill before the replace
# leaves; after it, the original is the track's file whatever else is left over.
AFTER_A_REFUSED_SWAP = [
    pytest.param("db.undo_inplace_conversion", 1, False, C_SWAPPED, id="before the undo"),
    pytest.param("signal.notify", 1, False, C_UNDONE, id="before the wake-up"),
    pytest.param("db.make_durable", 2, False, C_UNDONE, id="before the flush"),
    pytest.param("fs.unlink T", 1, False, C_UNDONE, id="before the staged copy goes"),
    pytest.param("ledger.release", 1, False, C_UNDONE, id="before the reservation is given back"),
    pytest.param("db.mark_conversion_job_failed", 1, True, C_SWAPPED,
                 id="undo refused, before the job says so"),
    pytest.param("ledger.release", 1, True, C_SWAPPED,
                 id="undo refused, before the reservation is given back"),
]


def _refuse_the_swap(world, undo_refused: bool) -> None:
    world.recorder.place("fs.replace T -> O", "raise", error=refused())
    if undo_refused:
        world.recorder.place("db.undo_inplace_conversion", "raise", error=busy())


@pytest.mark.parametrize("step, nth, undo_refused, expect", AFTER_A_REFUSED_SWAP)
def test_a_kill_after_a_refused_same_file_swap(
    tmp_path, monkeypatch, step, nth, undo_refused, expect
):
    """The process dies before a step of the undo (or of what follows a refused
    undo); the next start ends in one of the two true states, and a second
    start changes nothing."""
    world = build_world(tmp_path, monkeypatch, WRITERS["W4"])
    try:
        _refuse_the_swap(world, undo_refused)
        world.recorder.place(step, nth=nth)
        world.recorder.run_killed(world.run_writer)
        check_safe(world)
        check_evidence(world)

        world.recorder.begin("start")
        world.start_up()

        check_settled(world, expect)
    finally:
        world.recorder.thaw()


@pytest.mark.parametrize("path", RUNTIME_PATHS)
@pytest.mark.parametrize("step, nth, undo_refused, expect", AFTER_A_REFUSED_SWAP)
def test_an_interruption_after_a_refused_same_file_swap_that_the_server_survives(
    tmp_path, monkeypatch, step, nth, undo_refused, expect, path
):
    """The same stops with the server living on (the writer's own handlers
    run): while the row is kept the track's next file operations wait for the
    next start; once the undo committed nothing is in their way."""
    world = build_world(tmp_path, monkeypatch, WRITERS["W4"])
    _refuse_the_swap(world, undo_refused)
    world.recorder.place(step, nth=nth)
    with pytest.raises(Crash):
        world.run_writer()
    check_safe(world)
    check_evidence(world)
    if step != "ledger.release":  # given back by the writer's own handler
        assert world.reservations() == 0

    held = expect is C_SWAPPED
    assert len(world.journal()) == held
    _finished, edited = meet_at_runtime(world, path, held)

    if edited:
        expect = replace(expect, bumps=expect.bumps + 1, identity="stale", title="Next")
    world.recorder.begin("start")
    world.start_up()
    check_final(world, expect)


def test_the_next_start_killed_at_any_step_over_a_staged_copy_nobody_owns(tmp_path, monkeypatch):
    """The undo committed and the staged copy stayed (it could not be
    removed): however the next start is stopped, the one after ends undone."""
    killed = each_killed_start(
        tmp_path, monkeypatch, "W4",
        _failed("W4-the replace is refused and the staged copy cannot be removed"),
        lambda world: check_final(world, C_UNDONE))

    assert killed >= 2


@pytest.mark.parametrize("name", list(WRITERS))
def test_a_master_outside_the_owners_root_is_refused_before_the_disk_is_touched(
    tmp_path, monkeypatch, name
):
    """The catalog row names a file inside another user's folder (that user's
    own track, with the same relative name). Nothing is staged, journaled, moved
    or replaced, and the other user's file and row are as they were."""
    world = build_world(tmp_path, monkeypatch, WRITERS[name])
    foreign = world.music / "other" / "Art" / "song.m4a"
    # Two rows naming one file: the state the unique index now refuses.
    allow_two_tracks_on_one_path(world.database_path)
    set_track_path(world.database_path, world.uuid, foreign)

    if world.writer.kind == "edit":
        with pytest.raises(PathEscapesRoot):
            world.run_writer()
    else:
        world.run_writer()
        status, text = world.job()
        assert status == "failed" and text and str(tmp_path) not in text

    steps = [s for s in world.recorder.steps if s.startswith(("fs.", "db.insert", "db.apply",
                                                               "db.complete", "ledger."))]
    assert steps == [], steps
    assert world.journal() == [] and world.staged() == []
    assert world.track()["revision"] == world.revision0
    check_others_untouched(world)


# --- the remembered old file (G6) ---------------------------------------------------------------------


def _old_file_kept(world):
    run_case(world, CASES_BY_ID[f"{world.writer.name}-the flush before the old file goes answers no"])
    assert world.old.read_bytes() == world.writer.old_bytes
    assert world.new.read_bytes() == world.writer.new_bytes


@pytest.mark.parametrize("name", ["W1", "W2"])
def test_while_the_flush_keeps_failing_the_old_file_stays_and_the_next_edit_waits(
    tmp_path, monkeypatch, name
):
    world = build_world(tmp_path, monkeypatch, WRITERS[name])
    _old_file_kept(world)
    world.recorder.begin("runtime")
    world.recorder.place("db.make_durable", "answer", answer=False, times=9)

    assert isinstance(world.next_edit(), MasterWriteError)
    assert world.idle_pass() == 0

    assert world.old.read_bytes() == world.writer.old_bytes
    assert len(world.journal()) == 1
    check_safe(world)
    world.recorder.begin("start")
    world.start_up()
    check_settled(world, E_NEW if name == "W1" else C_NEW)


@pytest.mark.parametrize("name", ["W1", "W2"])
def test_a_failed_read_while_remembering_the_old_file_still_answers_success(
    tmp_path, monkeypatch, name, caplog
):
    """Pre-merge D2-04: the commit landed, the flush before the old file goes
    answered no, and the read that remembers the old file fails (a busy
    database). The operation still answers success (the edit returns, the job
    is done); the row and the old file wait for the next start."""
    world = build_world(tmp_path, monkeypatch, WRITERS[name])
    world.recorder.place("db.make_durable", "answer", answer=False, nth=2)
    real_list = world.db._real.list_journal_entries
    failed = []

    def busy_once(*args, **kwargs):
        """Fails the first read made by settle_old_master (other callers read
        the journal too, before the commit)."""
        frame, callers = sys._getframe(1), set()
        while frame is not None:
            callers.add(frame.f_code.co_name)
            frame = frame.f_back
        if not failed and "settle_old_master" in callers:
            failed.append(True)
            raise sqlite3.OperationalError("database is locked")
        return real_list(*args, **kwargs)

    monkeypatch.setattr(world.db._real, "list_journal_entries", busy_once)

    with caplog.at_level(logging.WARNING, logger="app.services.track_editor"):
        world.run_writer()

    assert failed == [True]
    if name == "W2":
        assert world.job() == ("done", None)
    lines = [r.getMessage() for r in caplog.records
             if r.name == "app.services.track_editor" and "could not remember the old file" in r.getMessage()]
    assert lines == [f"could not remember the old file of {world.uuid}: OperationalError"]
    assert str(tmp_path) not in caplog.text
    assert len(world.journal()) == 1
    assert world.old.read_bytes() == world.writer.old_bytes
    assert world.new.read_bytes() == world.writer.new_bytes
    check_safe(world)
    world.recorder.begin("start")
    world.start_up()
    check_settled(world, E_NEW if name == "W1" else C_NEW)


@pytest.mark.parametrize("path", ["start", *RUNTIME_PATHS])
@pytest.mark.parametrize("name", ["W1", "W2"])
def test_another_tracks_file_that_landed_at_the_old_path_is_never_removed(
    tmp_path, monkeypatch, name, path
):
    """The old file was kept for a flush; before anything settled the row, the
    old file went away and another track's file is at that path now."""
    world = build_world(tmp_path, monkeypatch, WRITERS[name])
    _old_file_kept(world)
    other = world.plant_track(world.old)
    planted = master("Z", "Planted", "Else")
    inode = os.lstat(world.old).st_ino

    if path != "start":
        meet_at_runtime(world, path, held=False)
        assert world.old.read_bytes() == planted
    world.recorder.begin("start")
    world.start_up()

    assert world.old.read_bytes() == planted and os.lstat(world.old).st_ino == inode
    assert world.track_naming(world.old) == [other]
    assert world.journal() == [] and world.staged() == []
    assert Path(world.track()["file_path"]) == world.new
    edited = master(world.writer.new_audio, "Next", world.writer.new_tags[1])
    assert world.new.read_bytes() == (edited if path == "edit" else world.writer.new_bytes)
    check_others_untouched(world)


@pytest.mark.parametrize("name", ["W1", "W2"])
def test_a_file_put_at_the_old_path_by_someone_else_is_left_to_the_next_start(
    tmp_path, monkeypatch, name
):
    """The remembered old file was replaced by a file no track names: the
    running server no longer knows it and removes nothing; the row waits."""
    world = build_world(tmp_path, monkeypatch, WRITERS[name])
    _old_file_kept(world)
    with world.outside():
        world.old.unlink()
        world.old.write_bytes(master("Z", "Someone", "Else"))

    world.recorder.begin("runtime")
    assert isinstance(world.next_edit(), MasterWriteError)
    assert world.idle_pass() == 0

    assert world.old.read_bytes() == master("Z", "Someone", "Else")
    assert len(world.journal()) == 1
    check_others_untouched(world)


@pytest.mark.parametrize("name", ["W1", "W2"])
def test_a_file_put_at_the_old_path_while_the_database_is_flushed_is_not_removed(
    tmp_path, monkeypatch, name
):
    """The running server flushes before it removes the remembered old file;
    the file is replaced by someone else during that flush. It looks again
    after the flush and removes nothing."""
    world = build_world(tmp_path, monkeypatch, WRITERS[name])
    _old_file_kept(world)

    def someone_replaces_the_old_file():
        with world.outside():
            world.old.unlink()
            world.old.write_bytes(master("Z", "Someone", "Else"))

    world.recorder.begin("runtime")
    flush = world.recorder.place("db.make_durable", "observe", then=someone_replaces_the_old_file)

    assert world.idle_pass() == 0

    assert flush.hits == 1
    assert world.old.read_bytes() == master("Z", "Someone", "Else")
    assert len(world.journal()) == 1


@pytest.mark.parametrize("name", ["W1", "W2"])
def test_the_old_file_is_kept_when_the_new_file_is_not_at_its_place(tmp_path, monkeypatch, name):
    """The old file waits for a flush; then the new file disappears. The old
    file is the only copy now: the running server must not remove it on the
    word of the catalog alone, and the next start makes it the track's file
    again."""
    world = build_world(tmp_path, monkeypatch, WRITERS[name])
    _old_file_kept(world)
    with world.outside():
        world.new.unlink()

    world.recorder.begin("runtime")
    assert world.idle_pass() == 0
    assert world.old.read_bytes() == world.writer.old_bytes
    assert len(world.journal()) == 1

    world.recorder.begin("start")
    world.start_up()

    files = bystander_files()
    files[world.writer.old_rel] = world.writer.old_bytes
    assert world.files() == files
    track = world.track()
    assert track["file_path"] == str(world.old)
    assert (track["codec"], track["bitrate_kbps"], track["sample_rate_hz"]) == AUDIO[world.writer.old_audio]
    assert world.journal() == []
    check_others_untouched(world)


# --- the staged copy is lost --------------------------------------------------------------------------


@pytest.mark.parametrize("path", ["start", *RUNTIME_PATHS])
def test_a_same_file_conversion_whose_staged_copy_was_lost_ends_lost(tmp_path, monkeypatch, path):
    """Refused and not taken back, then the staged file disappears. Nothing may say "done":
    the original is still there. The running server leaves the row alone; the
    next start reads the file, sees the old audio, describes it again in the
    catalog and fails the job with the sentence that says so."""
    world = build_world(tmp_path, monkeypatch, WRITERS["W4"])
    run_case(world, CASES_BY_ID["W4-the replace is refused and the undo too"])
    with world.outside():
        world.staged_copy().unlink()

    if path != "start":
        meet_at_runtime(world, path, held=True, evidence=False)
        assert world.job() == ("failed", SWAP_PENDING)
    world.recorder.begin("start")
    world.start_up()

    check_settled(world, C_LOST)


def test_a_same_file_conversion_lost_then_a_start_killed_at_any_step_still_ends_lost(
    tmp_path, monkeypatch
):
    def lost(world):
        run_case(world, CASES_BY_ID["W4-the replace is refused and the undo too"])
        with world.outside():
            world.staged_copy().unlink()

    killed = each_killed_start(
        tmp_path, monkeypatch, "W4", lost,
        lambda world: check_final(world, replace(C_LOST, extra_bumps=True)))

    assert killed >= 3


@pytest.mark.parametrize("path", ["start", "edit", "idle"])
def test_an_edit_whose_staged_copy_was_lost_keeps_the_file_it_has(tmp_path, monkeypatch, path):
    """The replace was refused, then the staged copy disappears: the file keeps
    its old tags, the catalog has the new ones (the same audio), the row goes
    and the identity is marked for a new look at the file."""
    world = build_world(tmp_path, monkeypatch, WRITERS["W3"])
    run_case(world, CASES_BY_ID["W3-the replace is refused"])
    with world.outside():
        world.staged_copy().unlink()

    expect = Expect(DB_ONLY, 1, "stale")
    if path != "start":
        _finished, edited = meet_at_runtime(world, path, held=False)
        if edited:
            expect = Expect(DB_ONLY, 2, "stale", title="Next")
    world.recorder.begin("start")
    world.start_up()

    check_settled(world, expect)


@pytest.mark.parametrize("name, step", [
    ("W1", "fs.replace T -> N"), ("W2", "fs.replace T -> N"),
])
def test_a_moving_writer_killed_before_its_move_whose_staged_copy_was_lost(
    tmp_path, monkeypatch, name, step
):
    world = build_world(tmp_path, monkeypatch, WRITERS[name])
    try:
        world.recorder.place(step)
        world.recorder.run_killed(world.run_writer)
        with world.outside():
            world.staged_copy().unlink()

        world.recorder.begin("start")
        world.start_up()

        check_settled(world, E_OLD if name == "W1" else C_OLD)
    finally:
        world.recorder.thaw()


# --- another track's file at the path -----------------------------------------------------------------


@pytest.mark.parametrize("path", ["start", "idle", "edit"])
def test_a_same_file_conversion_never_replaces_another_tracks_file_at_its_path(
    tmp_path, monkeypatch, path
):
    """The data loss bug U06-B-06 closed. The swap was refused and not taken back; then the
    track's master went away and another track's file landed at the path. The
    converted copy is never written over it: the job fails, the row and the
    staged copy are kept, and a second start does the same."""
    world = build_world(tmp_path, monkeypatch, WRITERS["W4"])
    run_case(world, CASES_BY_ID["W4-the replace is refused and the undo too"])
    staged = world.staged_copy()
    other = world.plant_track(world.old)
    planted = master("Z", "Planted", "Else")
    inode = os.lstat(world.old).st_ino

    world.recorder.begin("runtime")
    if path == "edit":
        assert isinstance(world.next_edit(), MasterWriteError)
    elif path == "idle":
        assert world.idle_pass() == 0
    for _ in range(2):
        world.recorder.begin("start")
        world.start_up()

        assert world.old.read_bytes() == planted and os.lstat(world.old).st_ino == inode
        assert other in world.track_naming(world.old)
        assert staged.read_bytes() == world.writer.new_bytes  # the converted audio is not lost
        assert len(world.journal()) == 1
        assert world.job() == ("failed", SWAP_UNPROVEN)
        check_others_untouched(world)


@pytest.mark.parametrize("name", ["W1", "W2"])
def test_a_file_another_track_owns_at_the_new_path_survives_the_undo(tmp_path, monkeypatch, name):
    """Killed before the move; then another track's file is at the new path.
    The staged copy still exists, so the move never happened and the file there
    is not the operation's: it stays, and the row is undone around it."""
    world = build_world(tmp_path, monkeypatch, WRITERS[name])
    try:
        world.recorder.place("fs.replace T -> N")
        world.recorder.run_killed(world.run_writer)
        other = world.plant_track(world.new)

        world.recorder.begin("start")
        world.start_up()

        expect = replace(E_OLD if name == "W1" else C_OLD,
                         extra_files=((world.writer.new_rel, master("Z", "Planted", "Else")),))
        check_settled(world, expect)
        assert world.track_naming(world.new) == [other]
    finally:
        world.recorder.thaw()


@pytest.mark.parametrize("name", ["W1", "W2"])
def test_a_strangers_file_at_the_new_path_is_never_deleted_as_the_operations_own(
    tmp_path, monkeypatch, name
):
    """Killed before the move; then a file no track names appears at the new
    path, with other audio. It is not the operation's output (the staged copy
    is still there): it is kept and becomes a track of the owner."""
    world = build_world(tmp_path, monkeypatch, WRITERS[name])
    try:
        world.recorder.place("fs.replace T -> N")
        world.recorder.run_killed(world.run_writer)
        with world.outside():
            world.new.parent.mkdir(exist_ok=True)
            world.new.write_bytes(master("Z", "Stranger", "Else"))

        world.recorder.begin("start")
        world.start_up()

        assert world.new.read_bytes() == master("Z", "Stranger", "Else")
        [adopted] = world.track_naming(world.new)
        assert adopted != world.uuid
        assert world.track(adopted)["owner_id"] == world.owner
        assert world.old.read_bytes() == world.writer.old_bytes
        assert Path(world.track()["file_path"]) == world.old
        assert world.journal() == [] and world.staged() == []
        check_others_untouched(world)
    finally:
        world.recorder.thaw()


@pytest.mark.parametrize("name", ["W1", "W2"])
@pytest.mark.parametrize("step", ["db.make_durable", "fs.replace T -> N"])
def test_a_strangers_file_at_the_new_path_survives_an_interrupted_writer_too(
    tmp_path, monkeypatch, name, step
):
    """G3 at work: the writer was interrupted between its journal row and its
    move and the server lived on; the row still has the staged copy, so the
    next start knows the file that meanwhile appeared at the new path is not
    the operation's."""
    world = build_world(tmp_path, monkeypatch, WRITERS[name])
    world.recorder.place(step)
    with pytest.raises(Crash):
        world.run_writer()
    check_evidence(world)
    with world.outside():
        world.new.parent.mkdir(exist_ok=True)
        world.new.write_bytes(master("Z", "Stranger", "Else"))

    world.recorder.begin("start")
    world.start_up()

    assert world.new.read_bytes() == master("Z", "Stranger", "Else")
    [adopted] = world.track_naming(world.new)
    assert adopted != world.uuid
    assert world.old.read_bytes() == world.writer.old_bytes
    assert world.journal() == [] and world.staged() == []
    check_others_untouched(world)


@pytest.mark.parametrize("path", ["start", "edit", "conversion", "idle"])
def test_an_edits_kept_row_never_replaces_another_tracks_file_at_its_path(
    tmp_path, monkeypatch, path
):
    """The same rule as for a conversion's row (the test above), for an edit's
    row. An edit's replace was refused; then the track's master went away and
    another track's file landed at the path. The staged copy is never written
    over that file: not by the next start, not by the track's own next edit or
    conversion request, not by the idle pass. The row and the staged copy are
    kept, and a second start does the same."""
    world = build_world(tmp_path, monkeypatch, WRITERS["W3"])
    run_case(world, CASES_BY_ID["W3-the replace is refused"])
    staged = world.staged_copy()
    other = world.plant_track(world.old)
    planted = master("Z", "Planted", "Else")
    inode = os.lstat(world.old).st_ino

    world.recorder.begin("runtime")
    if path == "edit":
        assert isinstance(world.next_edit(), MasterWriteError)
    elif path == "conversion":
        assert isinstance(world.next_conversion(), PendingRecovery)
    elif path == "idle":
        assert world.idle_pass() == 0
    for _ in range(2):
        world.recorder.begin("start")
        world.start_up()

        assert world.old.read_bytes() == planted and os.lstat(world.old).st_ino == inode
        assert other in world.track_naming(world.old)
        assert staged.read_bytes() == world.writer.new_bytes  # the edit's file is not lost
        assert len(world.journal()) == 1
        check_others_untouched(world)
    # Told once per start, without a path.
    kept = [text for level, text in world.recorder.operator_lines if "kept" in text]
    assert kept == [
        f"journal entry 1 for track {world.uuid} kept: another track's file is at the path"] * 2


def test_an_edits_kept_row_is_finished_once_the_other_track_left_the_path(tmp_path, monkeypatch):
    """What clears such a row: the other track no longer names the path (here
    it is deleted with its file). The next start then puts the staged copy in
    place, and the track has its file again."""
    world = build_world(tmp_path, monkeypatch, WRITERS["W3"])
    run_case(world, CASES_BY_ID["W3-the replace is refused"])
    other = world.plant_track(world.old)
    world.recorder.begin("start")
    world.start_up()
    assert len(world.journal()) == 1
    assert delete_track(world.db._real, other, owner_id=world.owner)
    with world.outside():
        world.old.unlink()

    world.recorder.begin("start")
    world.start_up()

    check_settled(world, E_NEW)


# --- a symbolic link where a file is expected ---------------------------------------------------------


def _outside(world, audio="Z") -> Path:
    target = world.tmp / "outside" / "song.m4a"
    target.parent.mkdir(exist_ok=True)
    target.write_bytes(master(audio, "Outside", "Else"))
    return target


def _swap_for_link(world, path: Path, target: Path) -> None:
    with world.outside():
        path.unlink()
        path.symlink_to(target)


@pytest.mark.parametrize("name, step, expect", [
    ("W1", "fs.replace T -> N", E_OLD),
    ("W2", "fs.replace T -> N", C_OLD),
])
def test_a_staged_copy_that_is_a_link_is_never_moved_into_the_library(
    tmp_path, monkeypatch, name, step, expect
):
    world = build_world(tmp_path, monkeypatch, WRITERS[name])
    try:
        world.recorder.place(step)
        world.recorder.run_killed(world.run_writer)
        target = _outside(world)
        _swap_for_link(world, world.staged_copy(), target)

        world.recorder.begin("start")
        world.start_up()

        check_settled(world, expect)  # the link's name is gone from staging, nothing was placed
        assert target.read_bytes() == master("Z", "Outside", "Else")
    finally:
        world.recorder.thaw()


@pytest.mark.parametrize("path", ["start", "edit"])
def test_an_edits_staged_copy_that_is_a_link_is_never_put_in_place(tmp_path, monkeypatch, path):
    """The replace was refused; then the staged copy is a link to a file
    elsewhere. Nothing is written over the master: the running server refuses
    the track's next edit, the next start removes the link's name and the row."""
    world = build_world(tmp_path, monkeypatch, WRITERS["W3"])
    run_case(world, CASES_BY_ID["W3-the replace is refused"])
    target = _outside(world, audio="A")
    _swap_for_link(world, world.staged_copy(), target)

    if path == "edit":
        meet_at_runtime(world, "edit", held=True, evidence=False)
    world.recorder.begin("start")
    world.start_up()

    check_settled(world, Expect(DB_ONLY, 1, "stale"))
    assert target.read_bytes() == master("A", "Outside", "Else")


def test_a_conversions_staged_copy_that_is_a_link_ends_the_job_lost(tmp_path, monkeypatch):
    world = build_world(tmp_path, monkeypatch, WRITERS["W4"])
    run_case(world, CASES_BY_ID["W4-the replace is refused and the undo too"])
    target = _outside(world, audio="M1")
    _swap_for_link(world, world.staged_copy(), target)

    world.recorder.begin("start")
    world.start_up()

    check_settled(world, C_LOST)
    assert target.read_bytes() == master("M1", "Outside", "Else")


@pytest.mark.parametrize("name", ["W1", "W2"])
def test_a_link_at_the_new_path_proves_nothing_about_the_old_file(tmp_path, monkeypatch, name):
    """Killed after the commit, with the old file still there; then the new
    path is a link to a file outside the library with the same audio. The old
    file is the only copy inside the library: it is never deleted on the
    strength of a link. It is kept as a track of its own."""
    world = build_world(tmp_path, monkeypatch, WRITERS[name])
    try:
        world.recorder.place("fs.unlink O")
        world.recorder.run_killed(world.run_writer)
        target = world.tmp / "outside" / world.new.name
        target.parent.mkdir()
        target.write_bytes(world.new.read_bytes())
        _swap_for_link(world, world.new, target)

        world.recorder.begin("start")
        world.start_up()

        assert world.old.read_bytes() == world.writer.old_bytes
        [keeper] = world.track_naming(world.old)
        assert keeper != world.uuid
        assert world.new.is_symlink() and target.read_bytes() == world.writer.new_bytes
        assert world.journal() == []
        check_others_untouched(world)
    finally:
        world.recorder.thaw()


def test_a_link_at_the_masters_path_is_never_written_through(tmp_path, monkeypatch):
    """An edit's replace was refused; then the master's path is a link to a
    file elsewhere. The staged copy is not written over the link or through
    it: it is placed under the row's own "(recovered <id>)" name and becomes the
    track's file; the link and its target stay as they are."""
    world = build_world(tmp_path, monkeypatch, WRITERS["W3"])
    run_case(world, CASES_BY_ID["W3-the replace is refused"])
    [row] = world.journal()
    target = _outside(world)
    _swap_for_link(world, world.old, target)

    world.recorder.begin("start")
    world.start_up()

    assert world.old.is_symlink() and os.readlink(world.old) == str(target)
    assert target.read_bytes() == master("Z", "Outside", "Else")
    recovered = world.old.with_name(f"song (recovered {row['id']}).m4a")
    assert recovered.read_bytes() == world.writer.new_bytes
    assert world.track()["file_path"] == str(recovered)
    assert world.journal() == [] and world.staged() == []
    check_others_untouched(world)


# --- the database lost what was not yet flushed (a power cut) -----------------------------------------


def _killed_then_power_cut(world, step, nth=1):
    world.expect_power_cut()
    world.recorder.place(step, nth=nth)
    world.recorder.run_killed(world.run_writer)
    world.power_cut()
    world.recorder.begin("start")
    world.start_up()


@pytest.mark.parametrize("name, expect", [("W1", E_OLD), ("W2", C_OLD)])
def test_a_power_cut_after_the_move_finds_the_journal_row_and_undoes_it(
    tmp_path, monkeypatch, name, expect
):
    """G2: the row was flushed before the file appeared at the new path, so the
    database a power cut leaves still has it and the copy is removed."""
    world = build_world(tmp_path, monkeypatch, WRITERS[name])
    try:
        commit = "db.apply_track_metadata_edit" if name == "W1" else "db.complete_conversion_job"
        _killed_then_power_cut(world, commit)

        check_settled(world, expect)
    finally:
        world.recorder.thaw()


@pytest.mark.parametrize("name", ["W1", "W2"])
def test_a_power_cut_after_a_move_whose_flush_failed_leaves_one_unnamed_copy_and_said_so(
    tmp_path, monkeypatch, name
):
    """Decision D10, the documented exception: the flush before the move
    failed, the move went ahead with one operator line, and the power cut lost
    the row. The copy at the new path is named by nobody; the track is whole."""
    world = build_world(tmp_path, monkeypatch, WRITERS[name])
    try:
        world.recorder.place("db.make_durable", "answer", answer=False)
        commit = "db.apply_track_metadata_edit" if name == "W1" else "db.complete_conversion_job"
        _killed_then_power_cut(world, commit)

        assert warnings_of(world) == 1
        # The job's own "running" mark is lost too: it is queued again.
        expect = E_OLD if name == "W1" else replace(C_OLD, job=("queued", None))
        check_settled(world, replace(
            expect, extra_files=((world.writer.new_rel, world.writer.new_bytes),)))
    finally:
        world.recorder.thaw()


@pytest.mark.parametrize("name, expect", [("W1", E_NEW), ("W2", C_NEW)])
def test_a_power_cut_after_the_old_file_went_finds_the_commit(tmp_path, monkeypatch, name, expect):
    """G6: the old file is removed only after a durable point, so the database
    a power cut leaves already names the new file."""
    world = build_world(tmp_path, monkeypatch, WRITERS[name])
    try:
        _killed_then_power_cut(world, "db.delete_journal_entry")

        check_settled(world, expect)
    finally:
        world.recorder.thaw()


@pytest.mark.parametrize("name, expect", [("W1", E_OLD), ("W2", C_OLD)])
def test_a_power_cut_after_a_commit_that_was_never_flushed_goes_back_to_the_old_file(
    tmp_path, monkeypatch, name, expect
):
    """G6, the other half: the flush after the commit failed, so the old file
    was kept. The power cut loses the commit; the old file is still the track's
    and the new copy goes as the operation's own unfinished output."""
    world = build_world(tmp_path, monkeypatch, WRITERS[name])
    world.expect_power_cut()
    world.recorder.place("db.make_durable", "answer", answer=False, nth=2)
    world.run_writer()
    assert world.old.exists() and world.new.exists()

    world.power_cut()
    world.recorder.begin("start")
    world.start_up()

    check_settled(world, expect)


def test_a_power_cut_after_a_same_file_replace_finds_the_commit(tmp_path, monkeypatch):
    world = build_world(tmp_path, monkeypatch, WRITERS["W4"])
    try:
        _killed_then_power_cut(world, "fs.flush dir(O)")

        check_settled(world, Expect(NEW, 2, "stale", job=("done", None)))
    finally:
        world.recorder.thaw()


def test_a_power_cut_after_the_undo_of_a_refused_swap_finds_the_undo(tmp_path, monkeypatch):
    """The staged copy goes only after a durable point: the database a power
    cut leaves then already has the undo (no row is left that would need the
    copy)."""
    world = build_world(tmp_path, monkeypatch, WRITERS["W4"])
    try:
        world.recorder.place("fs.replace T -> O", "raise", error=refused())
        _killed_then_power_cut(world, "ledger.release")

        check_settled(world, C_UNDONE)
    finally:
        world.recorder.thaw()


def test_a_power_cut_before_the_undo_was_flushed_finishes_the_swap(tmp_path, monkeypatch):
    """The power cut loses the undo and brings the committed conversion and its
    row back; the staged copy is still there, so the next start puts it in
    place, as after a crash before the replace."""
    world = build_world(tmp_path, monkeypatch, WRITERS["W4"])
    try:
        world.recorder.place("fs.replace T -> O", "raise", error=refused())
        _killed_then_power_cut(world, "db.make_durable", nth=2)

        check_settled(world, C_SWAPPED)
    finally:
        world.recorder.thaw()


def test_a_power_cut_after_an_undo_whose_flush_failed_still_finds_the_staged_copy(
    tmp_path, monkeypatch
):
    """Why the staged copy stays when the flush after the undo fails: the row
    the power cut brings back names it."""
    world = build_world(tmp_path, monkeypatch, WRITERS["W4"])
    world.expect_power_cut()
    run_case(world, CASES_BY_ID["W4-the replace is refused and the flush after the undo answers no"])
    assert world.job() == ("failed", SWAP_REFUSED) and len(world.staged()) == 1

    world.power_cut()
    world.recorder.begin("start")
    world.start_up()

    check_settled(world, C_SWAPPED)


def test_a_power_cut_after_the_next_start_removed_the_staged_copy_of_an_unflushed_undo_ends_lost(
    tmp_path, monkeypatch
):
    """Three faults in a row, pinned so that the ending stays known: the swap
    is refused, the flush after its undo fails (the staged copy stays), the
    next start removes that copy (no row names it; the sweep takes no durable
    point), and then a power cut loses the undo. The row is back and its staged
    copy is gone: the start after that reads the file, sees the original,
    describes it again and says that the converted file was lost."""
    world = build_world(tmp_path, monkeypatch, WRITERS["W4"])
    world.expect_power_cut()
    run_case(world, CASES_BY_ID["W4-the replace is refused and the flush after the undo answers no"])
    world.recorder.begin("start")
    world.start_up()
    assert world.staged() == [] and world.job() == ("failed", SWAP_REFUSED)

    world.power_cut()
    world.recorder.begin("start after the power cut")
    world.start_up()

    check_settled(world, C_LOST)


def test_a_power_cut_after_a_same_file_replace_whose_flush_failed_is_the_known_gap(
    tmp_path, monkeypatch
):
    """Decision D10, the documented exception, pinned so that it stays known:
    the flush before the replace failed, the replace went ahead with one
    operator line, the power cut lost the commit. The file holds the converted
    audio while the catalog still describes the original; no row is left."""
    world = build_world(tmp_path, monkeypatch, WRITERS["W4"])
    try:
        world.recorder.place("db.make_durable", "answer", answer=False)
        _killed_then_power_cut(world, "fs.flush dir(O)")

        assert warnings_of(world) == 1
        assert world.old.read_bytes() == world.writer.new_bytes
        track = world.track()
        assert (track["codec"], track["bitrate_kbps"], track["sample_rate_hz"]) == AUDIO["M3"]
        assert track["revision"] == world.revision0
        assert world.journal() == [] and world.staged() == []
        assert world.job() == ("queued", None)
        check_others_untouched(world)
    finally:
        world.recorder.thaw()


def test_a_power_cut_after_an_edit_in_place_leaves_the_same_audio_with_newer_tags(
    tmp_path, monkeypatch
):
    """An edit in place asks for no durable point (the same audio either way):
    a power cut can lose its commit and row and keep the new file. The file has
    the new tags, the catalog the old ones; nothing else differs."""
    world = build_world(tmp_path, monkeypatch, WRITERS["W3"])
    try:
        _killed_then_power_cut(world, "db.delete_journal_entry")

        files = bystander_files()
        files[world.writer.old_rel] = world.writer.new_bytes
        assert world.files() == files
        track = world.track()
        assert (track["title"], track["revision"]) == ("Song", world.revision0)
        assert world.identity() == world.identity0
        assert world.journal() == []
        check_others_untouched(world)
    finally:
        world.recorder.thaw()


# --- the track is gone, a rename that differs only in case --------------------------------------------


@pytest.mark.parametrize("name, step", [
    ("W1", "db.apply_track_metadata_edit"), ("W2", "db.complete_conversion_job"),
    ("W1", "fs.unlink O"), ("W3", "fs.replace T -> O"), ("W4", "fs.replace T -> O"),
])
def test_when_the_track_is_gone_no_file_of_the_row_is_lost(tmp_path, monkeypatch, name, step):
    """A row whose track no longer exists (a deletion refuses a track with a
    row, so only an outside change makes this): every file the row names stays
    or becomes a track of the row's owner; only the server's own staged copy
    goes, and only while another copy is there."""
    world = build_world(tmp_path, monkeypatch, WRITERS[name])
    try:
        world.recorder.place(step)
        world.recorder.run_killed(world.run_writer)
        before = {rel: data for rel, data in world.files().items() if not rel.startswith(".staging")}
        assert delete_track(world.db._real, world.uuid, owner_id=world.owner)

        world.recorder.begin("start")
        world.start_up()

        after = world.files()
        assert {rel: data for rel, data in after.items() if rel in before} == before
        for rel in before:
            if rel not in bystander_files():
                [named] = world.track_naming(world.music / rel)
                assert world.track(named)["owner_id"] == world.owner
        assert world.journal() == [] and world.staged() == []
        check_others_untouched(world)
    finally:
        world.recorder.thaw()


CASE_ONLY = Writer("W1", "edit", False, "owner/Old/song.m4a", "owner/Old/song.m4a", "A", "A",
                   ("Song", "Old"), ("Song", "OLD"), fields={"artist": "OLD"})


def _case_insensitive(folder: Path) -> bool:
    probe = folder / "CaseProbe"
    probe.write_bytes(b"x")
    try:
        return (folder / "caseprobe").exists()
    finally:
        probe.unlink()


@pytest.mark.parametrize("step", [None, "fs.replace T -> O", "db.mark_audio_identity_stale"])
def test_a_rename_that_differs_only_in_case_is_an_edit_in_place(tmp_path, monkeypatch, step):
    """On a disk that ignores case, "Old" to "OLD" names the same folder: the
    file is replaced where it is (never moved onto itself, never deleted as
    "the old file"), with the spelling it had."""
    if not _case_insensitive(tmp_path):
        pytest.skip("this disk tells Old from OLD")
    world = build_world(tmp_path, monkeypatch, CASE_ONLY)
    try:
        if step is None:
            world.run_writer()
        else:
            world.recorder.place(step)
            world.recorder.run_killed(world.run_writer)
            world.recorder.begin("start")
            world.start_up()

        assert "fs.unlink O" not in sum(world.recorder.phases.values(), [])
        check_settled(world, E_NEW)
    finally:
        world.recorder.thaw()
