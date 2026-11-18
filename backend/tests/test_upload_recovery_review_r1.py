"""7A.3c review r1 (7A.3c-review.md): regressions for the confirmed findings.

- R1 (major): a restart that resumes a ``prepared`` journal whose final name is
  already this operation's own link (crash after the link) and then meets an
  exact duplicate must remove that placed file, never leave it untracked in the
  library.
- R2: the expiry compare-and-swap also requires the progress the janitor read,
  so a user action between the janitor's list and its write wins.
- R3: an item reaching ``review_ready`` from validation has made progress.
- R4: a janitor thread whose start failed stops cleanly.
- R5: a received file that still exists stays counted at restart whatever the
  item's ended state, until the janitor removes it.
- R6: an unremovable part path does not block the source removal."""

import os
import threading

import pytest

from app.services import upload_janitor
from app.services.upload_janitor import UploadJanitor, UploadJanitorThread
from app.services.upload_receipt import reconcile_upload_receipts
from tests.identity_worker_fixtures import make_db, sql
from tests.upload_commit_fixtures import journal, reservations
from tests.upload_publish_fixtures import library_track, track_row
from tests.upload_recovery_fixtures import World
from tests.upload_validation_fixtures import FakeProbe, detected, item_row, make_worker, stage_item

DAY = 86_400
NOW = 2_000_000_000


@pytest.fixture
def db(tmp_path):
    return make_db(tmp_path)


@pytest.fixture
def music(tmp_path):
    path = tmp_path / "music"
    (path / ".uploads").mkdir(parents=True)
    return path


@pytest.fixture
def world(db, music):
    return World(db, music)


# ── R1 ─────────────────────────────────────────────────────────────────────

def test_a_conflict_met_after_a_crash_after_the_link_removes_the_placed_file(world):
    commit = world.crash_at("after_link")
    final = journal(world.db, commit)["final_path"]
    assert os.path.samefile(commit["work"], final)
    library_track(world.db, world.music, b"audio-A")  # an exact duplicate went live meanwhile

    world.restart()
    world.restart()

    assert item_row(world.db, commit)["state"] == "duplicate_conflict"
    assert not os.path.lexists(final)  # never left untracked in the library
    assert not commit["work"].exists()
    assert track_row(world.db, commit["track"]) is None
    assert commit["source"].read_bytes() == commit["content"]
    assert sql(world.db, "SELECT count(*) AS n FROM upload_commit_journal")[0]["n"] == 0


def test_an_unrelated_file_at_the_final_path_of_a_prepared_journal_is_never_taken_over(world):
    commit = world.crash_at("before_link")
    final = journal(world.db, commit)["final_path"]
    os.makedirs(os.path.dirname(final), exist_ok=True)
    with open(final, "wb") as f:
        f.write(b"someone else's file")
    library_track(world.db, world.music, b"audio-A")

    world.restart()

    assert item_row(world.db, commit)["state"] == "duplicate_conflict"
    with open(final, "rb") as f:
        assert f.read() == b"someone else's file"


# ── R2 ─────────────────────────────────────────────────────────────────────

def test_progress_made_after_the_janitor_listed_an_item_wins(db, music, monkeypatch):
    staged = stage_item(db, music / ".uploads", state="review_ready", progress_at=0)
    real = db.list_expirable_upload_items

    def stale_list(**kwargs):
        rows = real(**kwargs)
        # The user commits and the commit fails back to review_ready meanwhile.
        sql(db, "UPDATE upload_items SET progress_at = ? WHERE item_uuid = ?", (NOW, staged["item_uuid"]))
        return rows

    monkeypatch.setattr(db, "list_expirable_upload_items", stale_list)
    UploadJanitor(db, uploads_root=music / ".uploads", music_library_dir=music, cover_art=None,
                  clock=lambda: NOW).run_once()

    assert item_row(db, staged)["state"] == "review_ready"
    assert staged["source"].exists()


# ── R3 ─────────────────────────────────────────────────────────────────────

def test_validation_reaching_review_ready_renews_progress(db, music):
    staged = stage_item(db, music / ".uploads", progress_at=0)
    worker = make_worker(db, music / ".uploads", probe=FakeProbe(detected()), clock=lambda: NOW)

    assert worker.process_one() == "review_ready"

    assert item_row(db, staged)["progress_at"] == NOW


# ── R4 ─────────────────────────────────────────────────────────────────────

def test_a_thread_whose_start_failed_stops_cleanly(monkeypatch):
    class Janitor:
        def run_once(self):
            pass

    thread = UploadJanitorThread(Janitor(), interval_s=1)

    def failing_start(self):
        raise RuntimeError("cannot start")

    monkeypatch.setattr(threading.Thread, "start", failing_start)
    with pytest.raises(RuntimeError):
        thread.start()
    monkeypatch.undo()

    assert thread.stop(timeout=1)
    assert thread.done.done()
    assert not thread.is_alive()


# ── R5 ─────────────────────────────────────────────────────────────────────

@pytest.mark.parametrize("state", ["imported", "duplicate", "expired"])
def test_a_received_file_that_still_exists_stays_counted_at_restart(db, music, state):
    staged = stage_item(db, music / ".uploads", state="review_ready", progress_at=NOW)
    extra = {"imported": ", result_track_uuid = 't', result_revision = 1",
             "duplicate": ", result_track_uuid = 't', duplicate_kind = 'exact'"}.get(state, "")
    sql(db, f"UPDATE upload_items SET state = ?{extra} WHERE item_uuid = ?", (state, staged["item_uuid"]))

    reconcile_upload_receipts(db, music / ".uploads", boot_id="boot-next")

    assert [r["purpose"] for r in reservations(db, staged["owner_id"])] == ["upload_source"]

    staged["source"].unlink()
    reconcile_upload_receipts(db, music / ".uploads", boot_id="boot-next")

    assert reservations(db, staged["owner_id"]) == []


# ── R6 ─────────────────────────────────────────────────────────────────────

def test_a_part_path_outside_the_stage_does_not_block_the_source_removal(db, music):
    staged = stage_item(db, music / ".uploads", state="review_ready", progress_at=NOW)
    outside = music / "elsewhere.part"
    outside.write_bytes(b"keep")
    sql(db, "UPDATE upload_items SET state = 'cancelled', part_path = ? WHERE item_uuid = ?",
        (str(outside), staged["item_uuid"]))

    upload_janitor.UploadJanitor(db, uploads_root=music / ".uploads", music_library_dir=music,
                                 cover_art=None, clock=lambda: NOW).run_once()

    assert not staged["source"].exists()
    assert item_row(db, staged)["source_path"] is None
    assert outside.read_bytes() == b"keep"


# ── round 2 #1: validation's failed exit is progress too ──────────────────

class _ProbeBroke(OSError):
    pass


def test_validation_ending_failed_and_retryable_renews_progress(db, music):
    staged = stage_item(db, music / ".uploads", progress_at=NOW - 8 * DAY)
    worker = make_worker(db, music / ".uploads", probe=FakeProbe(_ProbeBroke("probe broke")),
                         clock=lambda: NOW)

    worker.process_one()

    row = item_row(db, staged)
    assert (row["state"], row["error_retryable"]) == ("failed", 1)
    assert row["progress_at"] == NOW
    UploadJanitor(db, uploads_root=music / ".uploads", music_library_dir=music, cover_art=None,
                  clock=lambda: NOW + 60).run_once()
    assert item_row(db, staged)["state"] == "failed"  # the user still gets to retry
