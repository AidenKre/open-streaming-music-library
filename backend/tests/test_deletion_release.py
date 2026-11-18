"""Phase 8 review r1 8-R1-01 (widens audit U13-BE-DEL-B-01): one release rule
for a claimed deletion item.

Any ``Exception`` after the claim (not a crash: ``SimulatedCrash`` is a
``BaseException`` and is the crash matrix's business) must not leave the item
``running`` for the rest of the boot. Within the **same boot**, without a
restart, the item ends where startup recovery would put it for the same
persisted state:

- no journal row → ``pending`` again (the next run retries it);
- an uncommitted journal the startup verdict keeps → ``failed:recovery_required``
  with the journal kept;
- a database that is still failing when the release is tried → the release is
  retried by a later worker step of the same boot.

Failures are injected at each site with a one-shot ``sqlite3.OperationalError``
("database is locked"), the transient fault the review names.
"""

import sqlite3

import pytest

from app.services import file_ops
from app.services.deletion_worker import DeletionWorker
from tests.deletion_world import (
    BOOT,
    accept_job,
    add_master,
    build_world,
    drain,
    files_under,
    item,
    journal,
    live,
    make_executor,
    path_of,
    revision,
    sql,
    tombstone,
)


@pytest.fixture
def world(tmp_path):
    return build_world(tmp_path)


def _fail_once(monkeypatch, target, name, *, when=lambda *a, **k: True):
    """Make ``target.name`` raise "database is locked" once (the first call
    ``when`` accepts), then behave normally again."""
    real = getattr(target, name)
    state = {"failed": False}

    def wrapper(*args, **kwargs):
        if not state["failed"] and when(*args, **kwargs):
            state["failed"] = True
            raise sqlite3.OperationalError("database is locked")
        return real(*args, **kwargs)

    monkeypatch.setattr(target, name, wrapper)
    return state


def _status(world, op, uuid_id):
    it = item(world, op, uuid_id)
    return it["status"], it["error"]


def _job(world, rel="A/Album/a.flac", delta=0):
    uuid_id = add_master(world, rel)
    op = accept_job(world, (uuid_id, revision(world, uuid_id) + delta))
    return uuid_id, op


def _released(world, op, uuid_id):
    it = item(world, op, uuid_id)
    assert (it["status"], it["lease"]) == ("pending", None)
    assert journal(world, uuid_id) is None


# ── no journal row: back to pending, then the retry finishes it ────────────


def test_a_failing_busy_outcome_after_the_lock_timeout_is_released(world, monkeypatch):
    uuid_id, op = _job(world)
    _fail_once(monkeypatch, world.db, "finish_deletion_item")
    lock = world.locks.lock_for(uuid_id)
    assert lock.acquire()
    try:
        assert make_executor(world, lock_timeout_s=0).run_one()
        _released(world, op, uuid_id)
    finally:
        lock.release()
    assert live(world, uuid_id)


def test_a_failing_target_read_is_released_and_retried(world, monkeypatch):
    uuid_id, op = _job(world)
    _fail_once(monkeypatch, world.db, "read_deletion_target")
    executor = make_executor(world)

    assert executor.run_one()
    _released(world, op, uuid_id)

    drain(executor)
    assert _status(world, op, uuid_id) == ("deleted", None)


def test_a_failing_user_read_is_released(world, monkeypatch):
    uuid_id, op = _job(world)
    _fail_once(monkeypatch, world.db, "get_user")
    before = files_under(world.music)

    assert make_executor(world).run_one()

    _released(world, op, uuid_id)
    assert files_under(world.music) == before and live(world, uuid_id)


def test_a_failing_journal_write_is_released_with_nothing_moved(world, monkeypatch):
    uuid_id, op = _job(world)
    _fail_once(monkeypatch, world.db, "begin_track_deletion")
    before = files_under(world.music)

    assert make_executor(world).run_one()

    _released(world, op, uuid_id)
    assert files_under(world.music) == before and live(world, uuid_id)


@pytest.mark.parametrize("delta", [7], ids=["conflict"])
def test_a_failing_outcome_write_of_a_conflict_is_released_then_finished(
    world, monkeypatch, delta
):
    uuid_id, op = _job(world, delta=delta)
    _fail_once(monkeypatch, world.db, "finish_deletion_item")
    executor = make_executor(world)

    assert executor.run_one()
    _released(world, op, uuid_id)

    drain(executor)
    assert _status(world, op, uuid_id) == ("conflict", "conflict")


def test_a_failing_outcome_after_a_cleared_rename_journal_is_released(world, monkeypatch):
    uuid_id, op = _job(world)
    master = path_of(world, uuid_id)
    monkeypatch.setattr(file_ops, "move_file", lambda *a, **k: False)
    _fail_once(
        monkeypatch, world.db, "finish_deletion_item",
        when=lambda **k: k.get("status") == "failed",
    )
    executor = make_executor(world)

    assert executor.run_one()
    _released(world, op, uuid_id)
    assert master.read_bytes() == b"master A/Album/a.flac" and live(world, uuid_id)

    drain(executor)
    assert _status(world, op, uuid_id) == ("failed", "rename")


def test_a_failing_outcome_after_a_restored_commit_failure_is_released(world, monkeypatch):
    uuid_id, op = _job(world)
    master = path_of(world, uuid_id)
    _fail_once(monkeypatch, world.db, "_delete_track_in")
    _fail_once(
        monkeypatch, world.db, "finish_deletion_item",
        when=lambda **k: k.get("status") == "busy",
    )
    executor = make_executor(world)

    assert executor.run_one()
    _released(world, op, uuid_id)
    assert master.read_bytes() == b"master A/Album/a.flac" and live(world, uuid_id)

    drain(executor)
    assert _status(world, op, uuid_id) == ("deleted", None)
    assert tombstone(world, uuid_id) is not None and not master.exists()


# ── a kept journal: failed:recovery_required now, not after a restart ──────


def test_a_failing_recovery_required_outcome_still_ends_the_item(world, monkeypatch):
    uuid_id, op = _job(world)
    master = path_of(world, uuid_id)

    def seam(name):
        if name == "after_moved":  # a new import takes the path: no restore possible
            master.write_bytes(b"a new import took the path")
            sql(world, "UPDATE tracks SET revision = revision + 1000 WHERE uuid_id = ?",
                (uuid_id,))

    _fail_once(
        monkeypatch, world.db, "finish_deletion_item",
        when=lambda **k: k.get("error_code") == "recovery_required",
    )

    assert make_executor(world, seam=seam).run_one()

    assert _status(world, op, uuid_id) == ("failed", "recovery_required")
    assert journal(world, uuid_id) is not None
    assert master.read_bytes() == b"a new import took the path"


# ── the database is still down when the release is tried ───────────────────


def test_a_release_that_fails_is_retried_by_a_later_worker_step(world, monkeypatch):
    uuid_id, op = _job(world)
    real = world.db._connection
    down = {"on": False}

    def connection(*args, **kwargs):
        if down["on"]:
            raise sqlite3.OperationalError("unable to open database file")
        return real(*args, **kwargs)

    monkeypatch.setattr(world.db, "_connection", connection)

    seen = []

    def seam(name):
        if name == "after_claim" and not seen:
            seen.append(name)
            down["on"] = True  # the database goes away right after the claim

    executor = make_executor(world, seam=seam)
    worker = DeletionWorker(executor, idle_poll_s=0)
    assert worker.process_one() == "error"
    assert item(world, op, uuid_id)["status"] == "running"  # nothing could be written

    down["on"] = False
    worker.process_one()

    assert item(world, op, uuid_id)["status"] != "running"
    drain(executor)
    assert _status(world, op, uuid_id) == ("deleted", None)


# ── review r2 8-R2-05(a): ordinary exceptions inside the lock ──────────────
#
# Not database faults: a programming or OS error at a site after the claim.
# The release runs with the track lock released (or, at a keep site, held),
# and the verdict proves identity before it touches anything.


def _assert_path_never_logged(caplog, capsys):
    """The raised message is a file path: it must reach neither the logs nor the
    process output (the worker logs the exception class only)."""
    out = capsys.readouterr()
    assert "RuntimeError" in caplog.text  # the failure was logged, by class name only
    for text in (caplog.text, out.out, out.err):
        assert "/music/secret" not in text and "secret/path" not in text
    assert all("/music/secret" not in r.getMessage() for r in caplog.records)


def _raise_once(monkeypatch, target, name, *, on_call=1):
    real = getattr(target, name)
    calls = {"n": 0}

    def wrapper(*args, **kwargs):
        calls["n"] += 1
        if calls["n"] == on_call:
            raise RuntimeError("/music/secret/path.flac")
        return real(*args, **kwargs)

    monkeypatch.setattr(target, name, wrapper)
    return calls


def test_an_exception_right_after_the_journal_write_is_released(world, caplog, capsys):
    uuid_id, op = _job(world)
    master = path_of(world, uuid_id)
    raised = []

    def seam(name):
        if name == "after_journal" and not raised:
            raised.append(name)
            assert journal(world, uuid_id) is not None  # the journal is written
            raise RuntimeError("/music/secret/path.flac")

    executor = make_executor(world, seam=seam)

    assert executor.run_one()
    _released(world, op, uuid_id)
    assert master.read_bytes() == b"master A/Album/a.flac" and live(world, uuid_id)
    assert world.locks.lock_for(uuid_id).acquire(timeout=0)  # not left held
    world.locks.lock_for(uuid_id).release()

    drain(executor)
    assert _status(world, op, uuid_id) == ("deleted", None)
    _assert_path_never_logged(caplog, capsys)
    assert tombstone(world, uuid_id) is not None and not master.exists()


def test_an_exception_from_the_directory_sync_after_the_move_is_released(world, monkeypatch, caplog, capsys):
    from app.services import deletion_worker

    uuid_id, op = _job(world)
    master = path_of(world, uuid_id)
    _raise_once(monkeypatch, deletion_worker, "fsync_dir")
    executor = make_executor(world)

    assert executor.run_one()
    _released(world, op, uuid_id)
    assert master.read_bytes() == b"master A/Album/a.flac" and live(world, uuid_id)
    assert files_under(world.music / ".deleting") == {}

    drain(executor)
    assert _status(world, op, uuid_id) == ("deleted", None)
    _assert_path_never_logged(caplog, capsys)


def test_an_exception_in_the_target_read_under_the_lock_is_released(world, monkeypatch, caplog, capsys):
    uuid_id, op = _job(world)
    _raise_once(monkeypatch, world.db, "read_deletion_target", on_call=2)  # 1 = the lock-free read
    before = files_under(world.music)
    executor = make_executor(world)

    assert executor.run_one()
    _released(world, op, uuid_id)
    assert files_under(world.music) == before and live(world, uuid_id)

    drain(executor)
    assert _status(world, op, uuid_id) == ("deleted", None)
    _assert_path_never_logged(caplog, capsys)


def test_an_exception_in_the_master_path_check_is_released(world, monkeypatch, caplog, capsys):
    from app.services import deletion_worker

    uuid_id, op = _job(world)
    _raise_once(monkeypatch, deletion_worker, "check_master_path")
    before = files_under(world.music)
    executor = make_executor(world)

    assert executor.run_one()
    _released(world, op, uuid_id)
    assert files_under(world.music) == before and live(world, uuid_id)

    drain(executor)
    assert _status(world, op, uuid_id) == ("deleted", None)
    _assert_path_never_logged(caplog, capsys)


# ── review r2 8-R2-06: a released item waits a poll before its next claim ──


def test_a_step_that_released_its_item_answers_error_so_the_worker_waits(world, monkeypatch):
    # "error" makes the shared base wait idle_poll_s (or until wake()) before
    # the next claim, so a fault confined to one item cannot burn its three
    # releases in milliseconds.
    uuid_id, op = _job(world)
    _fail_once(monkeypatch, world.db, "read_deletion_target")
    events = []

    class Recording(DeletionWorker):
        """Writes down each step's outcome and each wait the loop asks for;
        nothing really waits, and the second wait stops the loop."""

        def process_one(self):
            outcome = super().process_one()
            if outcome == "error":
                _released(world, op, uuid_id)
            events.append(outcome)
            return outcome

        def _wait(self, timeout):
            events.append(("wait", timeout))
            if events.count(("wait", timeout)) == 2:
                self.request_stop()

    Recording(make_executor(world), idle_poll_s=5)._run_loop()

    # The released item waits one poll; the finished target is followed at once.
    assert events == ["error", ("wait", 5), "done", "idle", ("wait", 5)]
    assert _status(world, op, uuid_id) == ("deleted", None)


def test_a_keep_site_release_also_answers_error(world, monkeypatch):
    # In-piece review #1: a designed keep site (here the directory sync after
    # the move) releases through `_release_held`, not an escaping
    # exception; that requeue must wait a poll too.
    from app.services import deletion_worker

    uuid_id, op = _job(world)
    _raise_once(monkeypatch, deletion_worker, "fsync_dir")
    worker = DeletionWorker(make_executor(world), idle_poll_s=5)

    assert worker.process_one() == "error"
    _released(world, op, uuid_id)

    assert worker.process_one() == "done"
    assert _status(world, op, uuid_id) == ("deleted", None)


def test_a_step_that_ended_its_item_as_recovery_required_is_done(world, monkeypatch):
    # A terminal outcome is not a requeue: nothing is re-claimed, no wait needed.
    uuid_id, op = _job(world)
    master = path_of(world, uuid_id)

    def seam(name):
        if name == "after_moved":
            master.write_bytes(b"a new import took the path")
            sql(world, "UPDATE tracks SET revision = revision + 1000 WHERE uuid_id = ?",
                (uuid_id,))

    _fail_once(
        monkeypatch, world.db, "finish_deletion_item",
        when=lambda **k: k.get("error_code") == "recovery_required",
    )
    worker = DeletionWorker(make_executor(world, seam=seam), idle_poll_s=5)

    assert worker.process_one() == "done"
    assert _status(world, op, uuid_id) == ("failed", "recovery_required")


# ── a fault that never clears: bounded, never a hot loop ───────────────────


def test_a_permanent_database_fault_ends_the_item_failed_after_a_few_releases(world, monkeypatch):
    uuid_id, op = _job(world)

    def broken(*args, **kwargs):
        raise sqlite3.OperationalError("database disk image is malformed")

    monkeypatch.setattr(world.db, "read_deletion_target", broken)
    executor = make_executor(world)

    runs = drain(executor)

    assert 1 <= runs <= 5
    # Sign-off DEV-8-17 items 4 and 17: after the retries, busy only for a
    # busy database; a database that stays broken ends the target failed.
    assert _status(world, op, uuid_id) == ("failed", "internal_error")
    assert item(world, op, uuid_id)["lease"] == BOOT
    assert live(world, uuid_id) and journal(world, uuid_id) is None


@pytest.mark.parametrize("error, expected", [
    (sqlite3.OperationalError("database is locked"), ("busy", "busy")),
    (sqlite3.OperationalError("database is busy"), ("busy", "busy")),
    (sqlite3.OperationalError("disk I/O error"), ("failed", "internal_error")),
    (OSError(5, "I/O error"), ("failed", "internal_error")),
], ids=["locked", "busy", "io", "oserror"])
def test_a_fault_that_never_clears_ends_busy_only_when_the_database_was_busy(
    world, monkeypatch, error, expected
):
    uuid_id, op = _job(world)
    master = path_of(world, uuid_id)

    def broken(*args, **kwargs):
        raise error

    monkeypatch.setattr(world.db, "read_deletion_target", broken)

    runs = drain(make_executor(world))

    assert 1 <= runs <= 5
    assert _status(world, op, uuid_id) == expected
    assert live(world, uuid_id) and journal(world, uuid_id) is None
    assert master.read_bytes() == b"master A/Album/a.flac"


def test_the_last_fault_decides_after_mixed_faults(world, monkeypatch):
    """Busy twice, then a broken database: the retries end on the last error."""
    uuid_id, op = _job(world)
    errors = [sqlite3.OperationalError("database is locked")] * 2

    def flaky(*args, **kwargs):
        if errors:
            raise errors.pop(0)
        raise sqlite3.OperationalError("disk I/O error")

    monkeypatch.setattr(world.db, "read_deletion_target", flaky)

    drain(make_executor(world))

    assert _status(world, op, uuid_id) == ("failed", "internal_error")


def test_a_busy_fault_stays_busy_when_the_final_outcome_write_was_retried(world, monkeypatch):
    """The retry cap's own outcome write fails once (the database is still
    busy), so a later step releases the item again: the busy cause is kept and
    the target still ends busy, never failed:internal_error."""
    uuid_id, op = _job(world)

    def locked(*args, **kwargs):
        raise sqlite3.OperationalError("database is locked")

    monkeypatch.setattr(world.db, "read_deletion_target", locked)
    _fail_once(
        monkeypatch, world.db, "finish_deletion_item",
        when=lambda **k: k.get("status") == "busy",
    )
    executor = make_executor(world)
    worker = DeletionWorker(executor, idle_poll_s=0)

    for _ in range(10):
        worker.process_one()
        if item(world, op, uuid_id)["status"] not in ("pending", "running"):
            break

    assert _status(world, op, uuid_id) == ("busy", "busy")


def test_a_busy_commit_whose_journal_clear_is_also_busy_ends_busy_at_the_cap(world, monkeypatch):
    """Review r1 minor 1: the commit answers "database is locked", the file is
    put back, and clearing the journal is locked too, every time: the keep site
    carries the busy cause, so the cap ends busy, not failed:internal_error."""
    uuid_id, op = _job(world)
    master = path_of(world, uuid_id)

    def locked(*args, **kwargs):
        raise sqlite3.OperationalError("database is locked")

    monkeypatch.setattr(world.db, "commit_track_deletion", locked)
    executor = make_executor(world)
    # The worker's own journal clear after the put-back meets the lock (it
    # swallows the error); the release's startup verdict then clears it.
    monkeypatch.setattr(executor, "_clear_journal", lambda key: False)

    for _ in range(10):
        executor.run_one()
        if item(world, op, uuid_id)["status"] not in ("pending", "running"):
            break

    assert _status(world, op, uuid_id) == ("busy", "busy")
    assert master.read_bytes() == b"master A/Album/a.flac"
