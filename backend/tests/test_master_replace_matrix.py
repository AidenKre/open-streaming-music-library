"""The crash matrix of "replace a track's file" (refactor piece BE-REPLACE, stage 1).

Four writers swap a track's audio file (``tests/replace_matrix_rig.py`` says how
they are run and what is faked):

- W1: a tag edit that moves the file (``TrackEditor``, artist changed);
- W2: a conversion to another extension (flac to aac);
- W3: a tag edit that keeps the path;
- W4: a conversion that keeps the path (mp3 to mp3 at a lower bitrate).

For every writer and every step of its sequence this file stops the writer
before that step, in two ways, and then lets the real recovery run:

- **a kill**: the process dies there (nothing of the writer unwinds), and the
  next start recovers; a second start changes nothing;
- **the same kill of the next start itself**, before every one of its steps,
  followed by a third start;
- **an interruption the server survives**: the ``Crash`` propagates through the
  writer's own handlers, then the same track's next edit, its next conversion
  request, or the idle pass meets what is left, and then the next start.

The expected outcome of each cell is written in the tables below, from the
guarantees of the work order (section 7.3, G1 to G11), not read off the code:

- the catalog's commit decides (G2 to G6): a moving writer stopped before its
  commit ends with the old file at the old path and the catalog unchanged;
  stopped after it, with the new file at the new path and the old file gone;
- an in-place row exists only if the catalog advanced (G7): stopped after the
  row, the staged copy is put in place by the next start;
- a running server never deletes a library file and never places converted
  bytes (G10): where finishing a row needs that, the track's next file
  operations are refused until the next start ("held");
- after a same-file conversion's bytes changed under a revision clients may
  have seen, the next start bumps the revision again.

Every cell also checks, whatever its row says: exactly the expected files
under the music folder (staging included), the catalog row, no journal row, the
identity, the job, the reservations, and that no file or row of another track
(the same owner's and another user's, one of them with the target's own
relative name) changed. ``World.judge`` checks at every real file operation
that nothing is destroyed or placed ahead of the database a power cut would
leave.

Not repeated here, because existing files cover it (the media tools are faked
in this matrix; these run real ffmpeg where marked):

- the same crash windows with real media: ``test_conversion.py``
  (``TestPathChangeCrashWindows``, ``TestSamePathJournaling``,
  ``TestSameFileSwapRefused``, ``TestSameFileSwapStartupRecheck``),
  ``test_crash_recovery.py`` (a real app restart, two users),
  ``test_journal_edit_fence.py``;
- the durable points: ``test_edit_durable_point.py``,
  ``test_journal_flush_before_move.py``, ``test_durable_point_second_wait.py``;
- start-up's state table, the content rule, files nothing can read, the
  operator lines of a settled or kept row: ``test_journal_settle.py``,
  ``test_recovery_audio.py``;
- runtime recovery's proofs and containment of a row's paths:
  ``test_journal_finish_proof.py``, ``test_journal_recovery_ownership.py``,
  ``test_identity_journal_finisher.py`` (the idle pass: a held lock, a track
  pending deletion);
- the conversion's re-checks under the lock, a cancel between the journal and
  the commit, a conversion that keeps the audio (``audio_unchanged``):
  ``test_conversion.py``, ``test_identity_conversion.py``,
  ``test_pending_deletion_conversion.py``;
- the flushes of the move and of the staged copy: ``test_edit_move_flush.py``,
  ``test_staged_file_flush.py``; a rename that differs only in case, also on a
  disk that tells the spellings apart: ``test_track_editor_case_rename.py``
  (the cells of this matrix for it need a disk that ignores case);
- a real app restart over a kept row: ``test_crash_recovery.py``.
  ``World.start_up`` cannot call ``main._startup_recovery_steps`` (that
  function reads the app's settings and takes no fake reader); it runs its
  three steps in the order of ``tests/recovery_steps.py``, which
  ``tests/test_startup_recovery_order.py`` compares with main.py's.
"""

from dataclasses import dataclass, replace
from typing import Optional

import pytest

from app.database.database import Database
from tests.crash import Crash
from tests.replace_matrix_rig import (
    ANY_TEXT,
    DB_ONLY,
    DB_READS,
    DB_WRITES,
    NEW,
    OLD,
    RUNTIME_PATHS,
    WRITERS,
    Expect,
    build_world,
    check_evidence,
    check_final,
    check_safe,
    check_settled,
    each_killed_start,
    master,
    meet_at_runtime,
)

# --- the steps of an undisturbed run ------------------------------------------------------------------

# The order of journal, disk, flush and database steps (work order 7.1). A step
# added, dropped or moved by a later change shows here first.
CLEAN_STEPS = {
    "W1": [
        "fs.mkdir staging",
        "fs.flush T",  # the staged copy is flushed before anything names it
        "db.insert_journal_entry",
        "db.make_durable",  # G2: one flush is tried before a file appears at the new path
        "fs.mkdir dir(N)",
        "fs.replace T -> N",
        "fs.flush dir(N)",  # G4: the move is flushed before the commit
        "fs.flush root",
        "fs.flush staging",
        "db.apply_track_metadata_edit",
        "db.make_durable",  # G6: the old file goes only after a durable point
        "fs.unlink O",
        "fs.rmdir dir(O)",
        "db.delete_journal_entry",
        "signal.notify",  # G8
    ],
    "W2": [
        "db.mark_conversion_job_running",
        "ledger.reserve",
        "fs.unlink C",
        "fs.flush T",
        "db.insert_journal_entry",
        "db.make_durable",
        "fs.replace T -> N",
        "fs.flush dir(O)",
        "fs.flush root",
        "fs.flush staging",
        "db.complete_conversion_job",
        "cache.evict",  # G11: eviction comes before the row's deletion
        "default_cache.evict",
        "db.make_durable",
        "fs.unlink O",
        "db.delete_journal_entry",
        "signal.notify",
        "cache.evict",
        "default_cache.evict",
        "ledger.release",  # G11: once
    ],
    "W3": [
        "fs.mkdir staging",
        "fs.flush T",
        "db.apply_track_metadata_edit",  # G7: the row exists only if the catalog advanced
        "db.insert_journal_entry",
        "fs.replace T -> O",
        "fs.flush dir(O)",
        "fs.flush staging",
        "db.mark_audio_identity_stale",
        "db.delete_journal_entry",
        "signal.notify",
    ],
    "W4": [
        "db.mark_conversion_job_running",
        "ledger.reserve",
        "fs.unlink C",
        "fs.flush T",
        "db.complete_conversion_job",  # the job, the catalog and the journal row in one commit
        "db.make_durable",  # best effort, before the destructive replace
        "fs.replace T -> O",
        "fs.flush dir(O)",
        "fs.flush staging",
        "cache.evict",
        "default_cache.evict",
        "db.write_conversion_identity",
        "db.delete_journal_entry",
        "signal.notify",
        "cache.evict",
        "default_cache.evict",
        "ledger.release",
    ],
}
# From this step to the row's deletion the track's lock is held (G1).
FIRST_JOURNALED_STEP = {
    "W1": "db.insert_journal_entry", "W2": "db.insert_journal_entry",
    "W3": "db.insert_journal_entry", "W4": "db.complete_conversion_job",
}
CLEAN_END = {
    "W1": Expect(NEW, 1, "stale"),
    "W2": Expect(NEW, 1, "written", job=("done", None)),
    "W3": Expect(NEW, 1, "stale"),
    "W4": Expect(NEW, 1, "written", job=("done", None)),
}


@pytest.mark.parametrize("name", list(WRITERS))
def test_an_undisturbed_run_takes_its_steps_in_this_order(tmp_path, monkeypatch, name):
    world = build_world(tmp_path, monkeypatch, WRITERS[name])

    world.run_writer()

    steps = world.recorder.steps
    assert steps == CLEAN_STEPS[name]
    first = steps.index(FIRST_JOURNALED_STEP[name])
    last = steps.index("db.delete_journal_entry")
    assert all(world.recorder.locked[first:last + 1]), "G1: the track's lock is held"
    assert world.wakeup.saw_pending == [True], "G8: woken only after the mark committed"
    assert world.cache.evicted == world.default_cache.evicted
    assert world.cache.evicted == ([world.uuid] * 2 if WRITERS[name].kind == "convert" else [])
    assert world.recorder.operator_lines == []
    assert world.staged() == []
    check_settled(world, CLEAN_END[name])


def _shape(world) -> dict:
    """A world as its writer finds it, with the music folder's own path taken out."""
    music = str(world.music)
    return {
        "folders": sorted(str(p.relative_to(world.music)) for p in world.music.rglob("*") if p.is_dir()),
        "state": repr(world.snapshot()["files"]) + repr(
            [{k: str(v).replace(music, "<music>") for k, v in row.items()}
             for row in world.snapshot()["tracks"]]) + repr(
            {k: world.snapshot()[k] for k in ("identity", "journal", "jobs", "reservations")}),
    }


@pytest.mark.parametrize("name", list(WRITERS))
def test_a_world_does_not_depend_on_the_worlds_built_before_it(tmp_path, monkeypatch, name):
    """The rig builds each writer's seeded database once per test process. A
    world built later in the process must be the same world: the same folders
    and files, the same rows, and its undisturbed run takes the same steps
    (a full run once failed here: the first conversion world of a process had
    its staging folder, later ones did not)."""
    shapes = []
    for number in (1, 2, 3):
        folder = tmp_path / f"world-{number}"
        folder.mkdir()
        with monkeypatch.context() as patch:
            world = build_world(folder, patch, WRITERS[name])
            shapes.append(_shape(world))
            world.run_writer()
            assert world.recorder.steps == CLEAN_STEPS[name], number
    assert shapes[0] == shapes[1] == shapes[2]


def test_two_writers_that_differ_only_in_their_old_audio_get_their_own_seed(tmp_path, monkeypatch):
    """Pre-merge D2-01: the seed cache is keyed on the whole writer, so a variant
    with another old file (same name and paths) never gets the seed of a writer
    built before it in the same process."""
    variant = replace(WRITERS["W1"], old_audio="Z")
    worlds = []
    for number, writer in enumerate((WRITERS["W1"], variant)):
        folder = tmp_path / f"world-{number}"
        folder.mkdir()
        with monkeypatch.context() as patch:
            world = build_world(folder, patch, writer)
            worlds.append((world.old.read_bytes(), world.identity()["exact_digest"]))
    assert worlds[0][0] == master("A", *WRITERS["W1"].old_tags)
    assert worlds[1][0] == master("Z", *variant.old_tags)
    assert worlds[0][1] != worlds[1][1]


# --- the cells ----------------------------------------------------------------------------------------


@dataclass(frozen=True)
class Cell:
    """The writer is stopped before ``step`` (its ``nth`` occurrence).

    ``kill``: what the next start leaves after a kill there.
    ``held``: after an interruption the server survives, whether the track's
    next file operations must be refused until the next start.
    ``survived``: what is left after such an interruption, a runtime recovery
    and the next start, where that differs from ``kill``."""

    step: str
    kill: Expect
    held: bool = False
    nth: int = 1
    survived: Optional[Expect] = None
    # The step is a later flush of the same move or replace: a stop before it
    # leaves exactly what a stop before the first flush leaves (a flush changes
    # nothing a process can read, and no handler sits between two flushes). It
    # has its kill cell; the costlier rows are run for the first flush only.
    same_as_previous: bool = False

    @property
    def id(self) -> str:
        name = self.step.replace(" -> ", ">").replace(" ", "_")
        return name if self.nth == 1 else f"{name}#{self.nth}"


E_OLD = Expect(OLD, 0, "kept")
E_NEW = Expect(NEW, 1, "stale")
C_QUEUED = Expect(OLD, 0, "kept", job=("queued", None))  # never started: still to run
C_OLD = Expect(OLD, 0, "kept", job=("failed", ANY_TEXT))  # the job says it did not happen
C_NEW = Expect(NEW, 1, "stale", job=("done", None))
C_DONE = Expect(NEW, 1, "written", job=("done", None))
# A same-file conversion whose bytes the next start put in place, or found in
# place: the revision is bumped again, so a client that saw the committed
# revision with the old bytes sees a change. (That a running server which
# finishes the same row does not bump is today's behaviour, pinned by
# ``survived=C_NEW`` below; the guarantees say nothing about it.)
C_SWAPPED = Expect(NEW, 2, "stale", job=("done", None))

CELLS = {
    # W1, a moving edit. Before the commit: the old file, the catalog unchanged
    # (the copy at the new path is the operation's own unfinished output and goes).
    # After it: the new file; the old one goes after a durable point.
    "W1": [
        Cell("fs.flush T", E_OLD),
        Cell("db.insert_journal_entry", E_OLD),
        Cell("db.make_durable", E_OLD),
        Cell("fs.mkdir dir(N)", E_OLD),
        Cell("fs.replace T -> N", E_OLD),
        # The file is at the new path and the catalog does not name it: undoing
        # that deletes a library file, which a running server never does.
        Cell("fs.flush dir(N)", E_OLD, held=True),
        Cell("fs.flush root", E_OLD, held=True, same_as_previous=True),
        Cell("fs.flush staging", E_OLD, held=True, same_as_previous=True),
        Cell("db.apply_track_metadata_edit", E_OLD),
        # Committed. The old file is still there and no flush is known: removing
        # it is the next start's job.
        Cell("db.make_durable", E_NEW, held=True, nth=2),
        Cell("fs.unlink O", E_NEW, held=True),
        Cell("fs.rmdir dir(O)", E_NEW),
        Cell("db.delete_journal_entry", E_NEW),
        Cell("signal.notify", E_NEW),
    ],
    "W2": [
        Cell("db.mark_conversion_job_running", C_QUEUED),
        Cell("ledger.reserve", C_OLD),
        Cell("fs.unlink C", C_OLD),
        Cell("fs.flush T", C_OLD),
        Cell("db.insert_journal_entry", C_OLD),
        Cell("db.make_durable", C_OLD),
        Cell("fs.replace T -> N", C_OLD),
        Cell("fs.flush dir(O)", C_OLD, held=True),
        Cell("fs.flush root", C_OLD, held=True, same_as_previous=True),
        Cell("fs.flush staging", C_OLD, held=True, same_as_previous=True),
        Cell("db.complete_conversion_job", C_OLD),
        Cell("db.make_durable", C_NEW, held=True, nth=2),
        Cell("fs.unlink O", C_NEW, held=True),
        Cell("db.delete_journal_entry", C_NEW),
        # No row is left for the next start to evict the caches by: the eviction
        # must already have happened (G11).
        Cell("signal.notify", C_DONE),
        Cell("ledger.release", C_DONE),
    ],
    # W3, an edit in place. The row is written after the commit: stopped between
    # the two, the catalog has the new tags and the file keeps the old ones (the
    # same audio; the state an edit of the catalog alone leaves).
    "W3": [
        Cell("fs.flush T", E_OLD),
        Cell("db.apply_track_metadata_edit", E_OLD),
        Cell("db.insert_journal_entry", Expect(DB_ONLY, 1, "kept")),
        # The same audio with other tags: a running server may put it in place.
        Cell("fs.replace T -> O", E_NEW),
        Cell("fs.flush dir(O)", E_NEW),
        Cell("fs.flush staging", E_NEW, same_as_previous=True),
        Cell("db.mark_audio_identity_stale", E_NEW),
        Cell("db.delete_journal_entry", E_NEW),
        Cell("signal.notify", E_NEW),
    ],
    "W4": [
        Cell("db.mark_conversion_job_running", C_QUEUED),
        Cell("ledger.reserve", C_OLD),
        Cell("fs.unlink C", C_OLD),
        Cell("fs.flush T", C_OLD),
        Cell("db.complete_conversion_job", C_OLD),
        # Committed with its row; the converted bytes are still staged. Only the
        # next start places converted bytes.
        Cell("db.make_durable", C_SWAPPED, held=True),
        Cell("fs.replace T -> O", C_SWAPPED, held=True),
        # The bytes are in place. The next start proves it and bumps; a running
        # server only finishes the row.
        Cell("fs.flush dir(O)", C_SWAPPED, survived=C_NEW),
        Cell("fs.flush staging", C_SWAPPED, survived=C_NEW, same_as_previous=True),
        Cell("db.write_conversion_identity", C_SWAPPED, survived=C_NEW),
        Cell("db.delete_journal_entry", C_SWAPPED, survived=C_NEW),
        Cell("signal.notify", C_DONE),  # as for W2: evicted before the row went
        Cell("ledger.release", C_DONE),
    ],
}
ALL_CELLS = [
    pytest.param(name, cell, id=f"{name}-{cell.id}") for name, cells in CELLS.items() for cell in cells
]
DISTINCT_CELLS = [param for param in ALL_CELLS if not param.values[1].same_as_previous]


def test_every_step_of_every_writer_has_a_cell():
    """A step that changes the disk or the database and has no kill before it
    would be a hole in the matrix (evictions, and the first folder made, change
    nothing a new process reads)."""
    for name, steps in CLEAN_STEPS.items():
        expected, seen = [], {}
        for step in steps:
            seen[step] = seen.get(step, 0) + 1
            if step.endswith(".evict") or step == "fs.mkdir staging":
                continue
            expected.append((step, seen[step]))
        assert [(c.step, c.nth) for c in CELLS[name]] == expected, name


def test_the_rig_classifies_real_database_methods_only():
    """The rig refuses a database call it has not classified as a read or a
    write; a name in its lists that the class no longer has would hide that."""
    for name in sorted(DB_READS | DB_WRITES):
        assert callable(getattr(Database, name, None)), name
    assert not DB_READS & DB_WRITES


# --- a kill, then the next start ----------------------------------------------------------------------


@pytest.mark.parametrize("name, cell", ALL_CELLS)
def test_a_kill_before_the_step_then_the_next_start(tmp_path, monkeypatch, name, cell):
    world = build_world(tmp_path, monkeypatch, WRITERS[name])
    try:
        world.recorder.place(cell.step, nth=cell.nth)
        world.recorder.run_killed(world.run_writer)
        check_safe(world)
        check_evidence(world)

        world.recorder.begin("start")
        world.start_up()

        check_settled(world, cell.kill)
    finally:
        world.recorder.thaw()


@pytest.mark.parametrize("name, cell", DISTINCT_CELLS)
def test_a_second_kill_at_any_step_of_the_next_start(tmp_path, monkeypatch, name, cell):
    """The next start is itself killed before its first step, its second, ...
    (each time on a fresh copy of the same killed writer); the start after that
    ends where an undisturbed one does. A start killed after it bumped a
    revision may have bumped it once more."""
    def killed_writer(world):
        world.recorder.place(cell.step, nth=cell.nth)
        world.recorder.run_killed(world.run_writer)

    killed = each_killed_start(
        tmp_path, monkeypatch, name, killed_writer,
        lambda world: check_final(world, replace(cell.kill, extra_bumps=True)))

    assert killed > 0, "the next start took no step at all"


# --- an interruption the server survives, then runtime recovery, then the next start ------------------


@pytest.mark.parametrize("path", RUNTIME_PATHS)
@pytest.mark.parametrize("name, cell", DISTINCT_CELLS)
def test_an_interruption_the_server_survives(tmp_path, monkeypatch, name, cell, path):
    world = build_world(tmp_path, monkeypatch, WRITERS[name])
    world.recorder.place(cell.step, nth=cell.nth)
    with pytest.raises(Crash):
        world.run_writer()
    check_safe(world)
    check_evidence(world)

    finished, edited = meet_at_runtime(world, path, cell.held)

    expect = cell.survived if finished and cell.survived is not None else cell.kill
    if edited:
        expect = replace(expect, bumps=expect.bumps + 1, identity="stale", title="Next")
    world.recorder.begin("start")
    world.start_up()
    check_final(world, expect)
