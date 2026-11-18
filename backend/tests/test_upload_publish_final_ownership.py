"""Phase 7 review round 1, publisher findings (7-R1-13, 7-R1-08, 7-R1-10).

Spec §6: "Never blindly unlink a path without proving journal ownership and
absence of another track reference"; step 5 "Cleanup only this operation's
moved unreferenced file"."""
import errno
import os
import sqlite3
from pathlib import Path

import pytest

from app.services import file_ops, organizer, upload_recovery
from app.services.upload_publish import SimulatedCrash
from tests.identity_worker_fixtures import sql
from tests.upload_commit_fixtures import (
    FakeCoverArt, accept, journal, library_root, make_commit_worker, ready_item,
)
from tests.upload_publish_fixtures import RecordingSeam, library_track, make_publisher, prepared_commit
from tests.upload_validation_fixtures import item_row
from tests.track_paths import set_track_path


@pytest.fixture
def music(tmp_path):
    path = tmp_path / "music"
    (path / ".uploads").mkdir(parents=True)
    return path


def _linked_prepared(db, music):
    """A ``prepared`` journal whose final name is already the work file's own
    link: a crash after the link whose startup ``moved`` mark did not happen."""
    commit = prepared_commit(db, music)
    work = Path(commit["work"])
    work.write_bytes(b"audio-A")
    final = _in_own_library(db, music, commit)
    final.parent.mkdir(parents=True, exist_ok=True)
    os.link(work, final)
    return commit, work, final


def _in_own_library(db, music, commit) -> Path:
    """Journal a final path inside the owner's library root (the fixture's is not)."""
    final = library_root(db, music, commit["owner_id"]) / "Artist" / f"{commit['track']}.flac"
    sql(db, "UPDATE upload_commit_journal SET final_path = ? WHERE owner_id = ? AND operation_uuid = ?",
        (str(final), commit["owner_id"], commit["op"]))
    return final


# ── 7-R1-13: a preflight conflict on a row whose final is already its own link ──

def test_a_preflight_conflict_removes_the_final_name_that_is_provably_its_own(db, music):
    commit, work, final = _linked_prepared(db, music)
    library_track(db, music, b"audio-A")  # a watch-folder copy landed meanwhile

    assert make_publisher(db, music)(journal(db, commit)) == "duplicate_conflict"

    assert not final.exists()
    assert not work.exists()
    assert journal(db, commit)["state"] == "duplicate_conflict"
    assert item_row(db, commit)["state"] == "duplicate_conflict"


def test_a_crash_after_that_conflict_is_recorded_leaves_the_final_for_the_clean_up(db, music):
    commit, work, final = _linked_prepared(db, music)
    library_track(db, music, b"audio-A")
    publisher = make_publisher(db, music, seam=RecordingSeam(crash_at="after_conflict_journal"))

    with pytest.raises(SimulatedCrash):
        publisher(journal(db, commit))

    row = journal(db, commit)
    assert row["state"] == "duplicate_conflict"
    assert row["final_path"] == str(final)  # still recorded: the clean-up can prove it
    assert upload_recovery.clean_finished_journal(
        db, row, uploads_root=music / ".uploads", music_library_dir=music,
        cover_art=FakeCoverArt())
    assert not final.exists() and not work.exists()


def test_a_preflight_conflict_never_removes_a_final_name_that_is_not_its_own_link(db, music):
    commit = prepared_commit(db, music)
    work = Path(commit["work"])
    work.write_bytes(b"audio-A")
    final = _in_own_library(db, music, commit)
    final.parent.mkdir(parents=True, exist_ok=True)
    final.write_bytes(b"audio-A")  # same bytes, another file: not ours
    library_track(db, music, b"audio-A")

    assert make_publisher(db, music)(journal(db, commit)) == "duplicate_conflict"

    assert final.read_bytes() == b"audio-A"
    assert journal(db, commit)["final_path"] is None
    assert not work.exists()


def test_a_preflight_conflict_keeps_its_own_final_when_a_track_names_it(db, music):
    commit, work, final = _linked_prepared(db, music)
    library_track(db, music, b"audio-A")
    [track] = sql(db, "SELECT uuid_id FROM tracks")
    set_track_path(db, track["uuid_id"], final)

    assert make_publisher(db, music)(journal(db, commit)) == "duplicate_conflict"

    assert final.exists()
    assert not work.exists()


# ── 7-R1-08: an outcome the publisher could not record is retried in-process ──

class _FailsFirst:
    """Wrap a database method so its first ``times`` calls raise a busy error."""

    def __init__(self, real, times=1):
        self.real = real
        self.times = times
        self.calls = 0

    def __call__(self, **kwargs):
        self.calls += 1
        if self.calls <= self.times:
            raise sqlite3.OperationalError("database is locked")
        return self.real(**kwargs)


def _accepted(db, music, content=b"audio-A"):
    staged = ready_item(db, music / ".uploads", content=content)
    return accept(db, staged)


def test_an_unrecorded_outcome_is_retried_without_a_restart(db, music, monkeypatch):
    commit = _accepted(db, music)
    monkeypatch.setattr(db, "mark_upload_commit_moved", _FailsFirst(db.mark_upload_commit_moved))
    monkeypatch.setattr(db, "fail_upload_publish", _FailsFirst(db.fail_upload_publish))
    worker = make_commit_worker(db, music, after_prepared=make_publisher(db, music))

    assert worker.process_one() == "error"  # two busy errors in a row: nothing recorded
    assert (journal(db, commit)["state"], item_row(db, commit)["state"]) == ("prepared", "committing")

    assert worker.process_one() == "imported"  # the same process tries again
    assert item_row(db, commit)["state"] == "imported"
    assert worker.process_one() == "idle"


def test_a_failure_that_cannot_be_recorded_is_retried_a_bounded_number_of_times(db, music, monkeypatch):
    commit = _accepted(db, music)
    publisher = make_publisher(db, music)
    calls = []

    def counting(prepared):
        calls.append(prepared["operation_uuid"])
        return publisher(prepared)

    moved = _FailsFirst(db.mark_upload_commit_moved, 10**6)
    monkeypatch.setattr(db, "mark_upload_commit_moved", moved)
    monkeypatch.setattr(db, "fail_upload_publish", _FailsFirst(db.fail_upload_publish, 10**6))
    worker = make_commit_worker(db, music, after_prepared=counting)

    outcomes = [worker.process_one() for _ in range(8)]

    assert outcomes[:4] == ["error"] * 4  # the first run and three retries
    assert outcomes[4:] == ["idle"] * 4  # then left for the next start
    # Review r2 7-R2-09: each retry first records the operation's own link as
    # moved; while that cannot be recorded it is not handed over again.
    assert len(calls) == 1
    assert moved.calls == 4
    assert (journal(db, commit)["state"], item_row(db, commit)["state"]) == ("prepared", "committing")


def test_a_hand_over_that_cannot_be_recorded_is_retried_a_bounded_number_of_times(db, music, monkeypatch):
    """Review r3 7-R3-03: no link is ever made (the preflight is busy every
    time), so each retry reaches the publisher, and its failure cannot be
    recorded either: the first run and three retries, then left for the next
    start."""
    commit = _accepted(db, music)
    publisher = make_publisher(db, music)
    calls = []

    def counting(prepared):
        calls.append(prepared["operation_uuid"])
        return publisher(prepared)

    def busy(**kwargs):
        raise sqlite3.OperationalError("database is locked")

    monkeypatch.setattr(db, "upload_commit_preflight", busy)
    monkeypatch.setattr(db, "fail_upload_publish", _FailsFirst(db.fail_upload_publish, 10**6))
    worker = make_commit_worker(db, music, after_prepared=counting)

    outcomes = [worker.process_one() for _ in range(8)]

    assert outcomes[:4] == ["error"] * 4
    assert outcomes[4:] == ["idle"] * 4
    assert calls == [commit["op"]] * 4  # four hand-overs, never a fifth
    assert not os.path.lexists(journal(db, commit)["final_path"])  # nothing was placed
    assert (journal(db, commit)["state"], item_row(db, commit)["state"]) == ("prepared", "committing")


def test_the_retry_first_records_a_link_that_is_already_its_own(db, music, monkeypatch):
    """Review r2 7-R2-09: the runtime retry takes startup's first step
    (``_advance_if_linked``) before any preflight, so a failure on the retry
    can never be recorded as "nothing placed" while the final name is the
    work file's own link (which would orphan that file in the library)."""
    commit = _accepted(db, music)
    monkeypatch.setattr(db, "mark_upload_commit_moved", _FailsFirst(db.mark_upload_commit_moved))
    monkeypatch.setattr(db, "fail_upload_publish", _FailsFirst(db.fail_upload_publish))
    real_preflight = db.upload_commit_preflight
    preflights = []

    def preflight(**kwargs):  # passes on the first run, busy on any later one
        preflights.append(kwargs)
        if len(preflights) > 1:
            raise sqlite3.OperationalError("database is locked")
        return real_preflight(**kwargs)

    monkeypatch.setattr(db, "upload_commit_preflight", preflight)
    worker = make_commit_worker(db, music, after_prepared=make_publisher(db, music))

    assert worker.process_one() == "error"  # linked, then two busy errors: nothing recorded
    final = Path(journal(db, commit)["final_path"])
    assert organizer.is_own_hard_link(commit["work"], final)

    assert worker.process_one() == "imported"
    assert len(preflights) == 1  # the retry resumed the moved journal: no second preflight
    [track] = sql(db, "SELECT file_path FROM tracks")
    assert Path(track["file_path"]) == final and final.is_file()
    assert item_row(db, commit)["state"] == "imported"


@pytest.mark.parametrize("err", [errno.EACCES, errno.EIO])
def test_a_retry_that_cannot_examine_its_own_link_hands_nothing_over(db, music, monkeypatch, err):
    """Review r3 7-R3-01: a final name that cannot be examined proves nothing;
    the retry neither records it as moved nor hands over (which would record
    "nothing placed" and leave the placed file in the library)."""
    commit = _accepted(db, music)
    monkeypatch.setattr(db, "mark_upload_commit_moved", _FailsFirst(db.mark_upload_commit_moved))
    monkeypatch.setattr(db, "fail_upload_publish", _FailsFirst(db.fail_upload_publish))
    worker = make_commit_worker(db, music, after_prepared=make_publisher(db, music))

    assert worker.process_one() == "error"  # linked, then two busy errors: nothing recorded
    final = Path(journal(db, commit)["final_path"])
    assert organizer.is_own_hard_link(commit["work"], final)
    real_lstat = os.lstat

    def lstat(path, *args, **kwargs):
        if Path(path) == final:
            raise OSError(err, os.strerror(err))
        return real_lstat(path, *args, **kwargs)

    monkeypatch.setattr(os, "lstat", lstat)
    assert worker.process_one() == "error"
    monkeypatch.setattr(os, "lstat", real_lstat)

    row = journal(db, commit)
    assert (row["state"], row["final_path"]) == ("prepared", str(final))
    assert final.is_file() and item_row(db, commit)["state"] == "committing"

    assert worker.process_one() == "imported"  # it can be examined again
    [track] = sql(db, "SELECT file_path FROM tracks")
    assert Path(track["file_path"]) == final


def test_a_journal_another_worker_left_is_not_taken_at_runtime(db, music):
    """Only this process's own unrecorded outcomes are retried; a dead boot's
    prepared journal waits for startup recovery (which validates it first)."""
    prepared_commit(db, music)
    worker = make_commit_worker(db, music, after_prepared=make_publisher(db, music))

    assert worker.process_one() == "idle"


# ── 7-R1-10: a library where hard links cannot be made ──────────────────────

def _no_links(monkeypatch, err):
    def refuse(src, dst, *args, **kwargs):
        raise OSError(err, os.strerror(err))

    monkeypatch.setattr(organizer.os, "link", refuse)


def _tree(root: Path) -> set:
    return {p.relative_to(root) for p in root.rglob("*")} if root.exists() else set()


@pytest.mark.parametrize("err", [errno.EXDEV, errno.EPERM, errno.ENOTSUP, errno.EMLINK])
def test_links_not_supported_falls_back_and_imports(db, music, monkeypatch, err, caplog):
    """Sign-off DEV-7-25 (link fallback): was "a non-retryable
    upload_library_links_unsupported"; the owner chose a move/copy fallback."""
    commit = _accepted(db, music)
    _no_links(monkeypatch, err)
    worker = make_commit_worker(db, music, after_prepared=make_publisher(db, music))

    with caplog.at_level("WARNING", logger="uvicorn.error"):
        assert worker.process_one() == "imported"

    item = item_row(db, commit)
    assert (item["state"], item["error_code"]) == ("imported", None)
    assert journal(db, commit)["state"] == "imported"
    [track] = sql(db, "SELECT file_path FROM tracks WHERE uuid_id = ?", (commit["track"],))
    assert Path(track["file_path"]).read_bytes() == commit["content"]
    assert not commit["work"].exists()
    operator = [r.getMessage() for r in caplog.records if r.name == "uvicorn.error"]
    assert len(operator) == 1
    assert "hard links" in operator[0] and "/" not in operator[0]


def test_the_operator_line_is_written_once_and_existing_folders_stay(db, music, monkeypatch, caplog):
    first = _accepted(db, music)
    library = library_root(db, music, first["owner_id"])
    publisher = make_publisher(db, music)
    worker = make_commit_worker(db, music, after_prepared=publisher)
    # The first commit's folders exist before the second one tries.
    assert worker.process_one() == "imported"
    kept = {p for p in _tree(library) if (library / p).is_dir()}
    second = _accepted(db, music, b"audio-B")  # other audio: not a duplicate of the first
    _no_links(monkeypatch, errno.EXDEV)

    with caplog.at_level("WARNING", logger="uvicorn.error"):
        assert worker.process_one() == "imported"
        third = _accepted(db, music, b"audio-C")
        assert worker.process_one() == "imported"

    assert item_row(db, third)["state"] == "imported"
    assert kept <= {p for p in _tree(library) if (library / p).is_dir()}
    assert len([r for r in caplog.records if r.name == "uvicorn.error"]) == 1
    assert item_row(db, second)["state"] == "imported"


def test_another_link_error_stays_retryable(db, music, monkeypatch):
    commit = _accepted(db, music)
    _no_links(monkeypatch, errno.EIO)
    worker = make_commit_worker(db, music, after_prepared=make_publisher(db, music))

    assert worker.process_one() == "failed"

    item = item_row(db, commit)
    assert (item["error_code"], item["error_retryable"]) == ("upload_commit_failed", 1)


# ── 7-R1-34: the own-final removal is contained in the owner's library ──────

def test_a_conflict_never_removes_a_final_outside_the_owners_library(db, music):
    """Defence in depth: even a journal naming a file outside the owner's
    library root (a corrupt row) never has it removed."""
    commit = prepared_commit(db, music)
    work = Path(commit["work"])
    work.write_bytes(b"audio-A")
    outside = music.parent / "elsewhere" / "x.flac"
    outside.parent.mkdir(parents=True)
    os.link(work, outside)  # even an own link outside the root is never removed
    sql(db, "UPDATE upload_commit_journal SET state = 'moved', final_path = ?"
            " WHERE owner_id = ? AND operation_uuid = ?",
        (str(outside), commit["owner_id"], commit["op"]))
    library_track(db, music, b"audio-A")

    make_publisher(db, music)._remove_own_final(outside, commit["owner_id"])

    assert outside.exists()


# ── in-piece review (7-R1-10 / 7-R1-12 follow-ups) ──────────────────────────

def test_only_a_link_error_means_links_are_unsupported(db, music, monkeypatch, caplog):
    """A folder that cannot be made (EPERM on mkdir) is not "no hard links":
    it stays the retryable failure and writes no operator line."""
    commit = _accepted(db, music)
    real_mkdir = Path.mkdir

    def mkdir(self, *args, **kwargs):
        if self.is_relative_to(library_root(db, music, commit["owner_id"])):
            raise OSError(errno.EPERM, os.strerror(errno.EPERM))
        return real_mkdir(self, *args, **kwargs)

    monkeypatch.setattr(Path, "mkdir", mkdir)
    worker = make_commit_worker(db, music, after_prepared=make_publisher(db, music))

    with caplog.at_level("WARNING", logger="uvicorn.error"):
        assert worker.process_one() == "failed"

    item = item_row(db, commit)
    assert (item["error_code"], item["error_retryable"]) == ("upload_commit_failed", 1)
    assert [r for r in caplog.records if r.name == "uvicorn.error"] == []


@pytest.mark.parametrize("err", [errno.EIO, errno.ENOTSUP])
def test_each_folder_removed_after_a_failed_link_is_removed_under_its_own_lock(db, music, monkeypatch,
                                                                             err):
    """The folders a failed link made are removed one at a time, each under its
    own directory lock (as prune_empty_dirs does), so a concurrent organizer
    move into one of them is never cut off. Link fallback: EXDEV no longer
    fails; EIO is a failed link, ENOTSUP a fallback whose move then fails."""
    commit = _accepted(db, music)
    library = library_root(db, music, commit["owner_id"])
    library.mkdir(parents=True, exist_ok=True)
    _no_links(monkeypatch, err)
    if err == errno.ENOTSUP:
        def refuse_rename(src, dst, *args, **kwargs):
            raise PermissionError(errno.EACCES, os.strerror(errno.EACCES))

        monkeypatch.setattr(organizer.os, "rename", refuse_rename)
    held = []
    real_lock = file_ops._directory_locks.lock
    real_rmdir = Path.rmdir

    def lock(key):
        held.append(Path(key))
        cm = real_lock(key)

        class Tracking:
            def __enter__(self):
                cm.__enter__()

            def __exit__(self, *exc):
                held.remove(Path(key))
                return cm.__exit__(*exc)

        return Tracking()

    removed_unlocked = []

    def rmdir(self):
        # The lock key is the folded resolved folder (review r1 of U05-B-01).
        if file_ops.directory_lock_key(self) not in held:
            removed_unlocked.append(self)
        return real_rmdir(self)

    monkeypatch.setattr(file_ops._directory_locks, "lock", lock)
    monkeypatch.setattr(Path, "rmdir", rmdir)
    worker = make_commit_worker(db, music, after_prepared=make_publisher(db, music))

    assert worker.process_one() == "failed"

    assert removed_unlocked == []
    assert [p for p in library.rglob("*") if p.is_dir()] == []


def test_every_folder_made_for_the_final_name_is_durable_before_moved(db, music, monkeypatch):
    """7-R1-12 follow-up: the new Artist/Album folders are synced into their
    parents too, up to the library root, before the journal says moved."""
    from app.services.upload_receipt import ReceiptFiles

    commit = _accepted(db, music)
    library = library_root(db, music, commit["owner_id"])
    events = []
    real_sync = ReceiptFiles.sync_dir
    real_moved = db.mark_upload_commit_moved

    def sync_dir(self, path):
        events.append(("sync", Path(path).resolve()))
        return real_sync(self, path)

    def moved(**kwargs):
        events.append(("moved",))
        return real_moved(**kwargs)

    monkeypatch.setattr(ReceiptFiles, "sync_dir", sync_dir)
    monkeypatch.setattr(db, "mark_upload_commit_moved", moved)
    worker = make_commit_worker(db, music, after_prepared=make_publisher(db, music))

    assert worker.process_one() == "imported"

    final = Path(journal(db, commit)["final_path"]).resolve()
    before_moved = {e[1] for e in events[:events.index(("moved",))] if e[0] == "sync"}
    chain = []
    folder = final.parent
    while folder != library.resolve().parent:
        chain.append(folder)
        folder = folder.parent
    assert set(chain) <= before_moved, (chain, before_moved)


# ── Refactor audit U12-B-01 (= 7-R3-01 at the publisher's own sites): "is the
# final name this operation's own link" has one answer everywhere, and a name
# that cannot be examined is unknown: nothing is recorded, nothing removed. ──

def _unexaminable(monkeypatch, path: Path, err=errno.EACCES):
    real_lstat = os.lstat

    def lstat(p, *args, **kwargs):
        if Path(p) == path:
            raise OSError(err, os.strerror(err))
        return real_lstat(p, *args, **kwargs)

    monkeypatch.setattr(os, "lstat", lstat)


def _untouched(db, commit, work, final):
    row = journal(db, commit)
    assert (row["state"], row["final_path"]) == ("prepared", str(final))
    assert final.is_file() and work.is_file()
    assert item_row(db, commit)["state"] == "committing"


def test_a_preflight_conflict_on_a_final_that_cannot_be_examined_records_nothing(db, music, monkeypatch):
    commit, work, final = _linked_prepared(db, music)
    library_track(db, music, b"audio-A")  # a conflict the preflight will find
    _unexaminable(monkeypatch, final)

    assert make_publisher(db, music)(journal(db, commit)) == "error"
    monkeypatch.undo()

    _untouched(db, commit, work, final)
    assert make_publisher(db, music)(journal(db, commit)) == "duplicate_conflict"  # examinable again
    assert not final.exists()  # proven its own: removed as such


def test_a_recovered_failure_on_a_final_that_cannot_be_examined_records_nothing(db, music, monkeypatch):
    commit, work, final = _linked_prepared(db, music)
    _unexaminable(monkeypatch, final)

    assert make_publisher(db, music).fail_recovered(journal(db, commit)) == "error"
    monkeypatch.undo()

    _untouched(db, commit, work, final)
    assert make_publisher(db, music).fail_recovered(journal(db, commit)) == "failed"
    assert not final.exists()


def test_a_final_name_too_long_to_exist_is_not_our_link(db, music, tmp_path):
    """In-piece review F1: a name the filesystem cannot even hold (ENAMETOOLONG)
    can never be our link: "not linked", not unknown (a too-long final name must
    not hold the item in ``committing`` for ever)."""
    commit = prepared_commit(db, music)
    work = Path(commit["work"])
    work.write_bytes(b"audio-A")
    too_long = tmp_path / ("a" * 300) / "final.flac"
    with pytest.raises(OSError) as e:  # the real filesystem refuses the name itself
        os.lstat(too_long)
    assert e.value.errno == errno.ENAMETOOLONG

    assert organizer.is_own_hard_link(work, too_long, strict=True) is False
    assert organizer.final_is_own_link({"work_path": str(work), "final_path": str(too_long)}) is False
