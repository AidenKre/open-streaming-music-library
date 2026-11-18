"""7A.3c S6 (spec §3 retention: "Retain unconfirmed staged items for seven
days since meaningful user/transfer progress, then mark expired and remove only
owned stages ... Background janitor never deletes receiving/committing items
with a live lease"; 7-U07): the expiry janitor, driven by an injected clock.

- An unconfirmed item (``allocated``, ``review_ready``, ``duplicate_conflict``,
  ``failed``) whose ``progress_at`` is at least 7 days old becomes ``expired``;
  its staged source is removed and, once verifiably gone, its quota row is
  released in the transaction that clears the path.
- ``receiving``, ``validating`` and ``committing`` items are never expired
  (a worker or a transfer owns them), nor are ended items.
- An ended item that still records a source (a removal failed earlier, or a
  crash hit between the state change and the removal) gets it removed.
- Empty folders of ended items go (``rmdir`` only); a folder holding anything
  else stays.
- Finished commit journals are cleaned once they are older than a grace period
  (the publisher may still be finishing a fresh one)."""

import os

import pytest

from app.services.upload_janitor import UploadJanitor
from app.services.upload_receipt import ReceiptFiles
from tests.identity_worker_fixtures import make_db, sql
from tests.owned_database import add_test_user
from tests.upload_commit_fixtures import reservations
from tests.upload_recovery_fixtures import World
from tests.upload_validation_fixtures import BOOT, item_row, stage_item

DAY = 86_400
NOW = 2_000_000_000  # after the wall clock: a janitor reading time.time() fails these tests
EXPIRY = 7 * DAY
OLD = NOW - EXPIRY  # exactly seven days: expired
YOUNG = NOW - EXPIRY + 1


@pytest.fixture
def db(tmp_path):
    return make_db(tmp_path)


@pytest.fixture
def music(tmp_path):
    path = tmp_path / "music"
    (path / ".uploads").mkdir(parents=True)
    return path


_REQUIRED = {"failed": ", error_code = 'x', error_retryable = 1",
             "imported": ", result_track_uuid = 't', result_revision = 1",
             "duplicate": ", result_track_uuid = 't', duplicate_kind = 'exact'",
             "expanded": ", kind = 'zip'"}


def staged_in(db, music, state, **kwargs):
    """A staged item put into ``state`` with the columns that state requires."""
    staged = stage_item(db, music / ".uploads", state="review_ready", **kwargs)
    sql(db, f"UPDATE upload_items SET state = ?{_REQUIRED.get(state, '')} WHERE owner_id = ? AND item_uuid = ?",
        (state, staged["owner_id"], staged["item_uuid"]))
    return staged


def janitor(db, music, now=NOW, **kwargs):
    world = kwargs.pop("world", None)
    cover_art = world.cover_art if world is not None else None
    return UploadJanitor(db, uploads_root=music / ".uploads", music_library_dir=music,
                         cover_art=cover_art, clock=lambda: now, **kwargs)


def sources(db, staged) -> list[str]:
    return [r["purpose"] for r in reservations(db, staged["owner_id"])
            if r["subject_ref"] == staged["item_uuid"]]


def assert_expired_and_gone(db, staged):
    row = item_row(db, staged)
    assert row["state"] == "expired"
    assert row["source_path"] is None
    assert not staged["source"].exists()
    assert sources(db, staged) == []
    assert not staged["source"].parent.exists()  # the empty item folder goes too


@pytest.mark.parametrize("state", ["review_ready", "duplicate_conflict", "failed"])
def test_an_unconfirmed_item_expires_after_seven_days_without_progress(db, music, state):
    staged = staged_in(db, music, state, progress_at=OLD)

    janitor(db, music).run_once()

    assert_expired_and_gone(db, staged)
    assert not staged["source"].parent.parent.exists()  # its batch held nothing else


def test_an_allocated_item_without_bytes_expires(db, music):
    staged = stage_item(db, music / ".uploads", state="allocated", progress_at=OLD)
    staged["source"].unlink()
    sql(db, "UPDATE upload_items SET source_path = NULL WHERE item_uuid = ?", (staged["item_uuid"],))
    sql(db, "DELETE FROM storage_reservations WHERE subject_ref = ?", (staged["item_uuid"],))

    janitor(db, music).run_once()

    assert item_row(db, staged)["state"] == "expired"


@pytest.mark.parametrize("state", ["review_ready", "duplicate_conflict", "failed", "allocated"])
def test_an_item_with_recent_progress_is_kept(db, music, state):
    staged = staged_in(db, music, state, progress_at=YOUNG)

    janitor(db, music).run_once()

    assert item_row(db, staged)["state"] == state
    assert staged["source"].exists()
    assert sources(db, staged) == ["upload_source"]


@pytest.mark.parametrize("state,lease", [
    ("receiving", BOOT), ("receiving", None), ("validating", BOOT), ("validating", None),
    ("committing", BOOT), ("committing", None)])
def test_an_item_a_worker_or_transfer_may_hold_is_never_expired(db, music, state, lease):
    staged = stage_item(db, music / ".uploads", state=state, lease=lease, progress_at=0)

    janitor(db, music).run_once()

    assert item_row(db, staged)["state"] == state
    assert staged["source"].read_bytes() == b"audio-A"
    assert sources(db, staged) == ["upload_source"]


@pytest.mark.parametrize("state", ["imported", "duplicate", "expanded", "cancelled", "expired"])
def test_an_ended_item_is_not_expired_again(db, music, state):
    staged = staged_in(db, music, state, progress_at=0)

    janitor(db, music).run_once()

    assert item_row(db, staged)["state"] == state


@pytest.mark.parametrize("state", ["cancelled", "expired", "imported", "duplicate"])
def test_an_ended_item_still_recording_its_source_gives_it_back(db, music, state):
    """7A.2c RC4 (a cancel whose removal failed), 7A.3b F8 (a crash after
    resolve-duplicate before the give-back), a crash after expiry."""
    staged = staged_in(db, music, state, progress_at=NOW)

    janitor(db, music).run_once()

    row = item_row(db, staged)
    assert row["state"] == state
    assert row["source_path"] is None
    assert not staged["source"].exists()
    assert sources(db, staged) == []


def test_a_source_that_cannot_be_removed_stays_recorded_and_counted(db, music, monkeypatch):
    staged = stage_item(db, music / ".uploads", state="review_ready", progress_at=OLD)
    monkeypatch.setattr(ReceiptFiles, "remove", lambda self, path: (_ for _ in ()).throw(OSError("busy")))

    janitor(db, music).run_once()

    row = item_row(db, staged)
    assert row["state"] == "expired"
    assert row["source_path"] == str(staged["source"])
    assert sources(db, staged) == ["upload_source"]

    monkeypatch.undo()
    janitor(db, music).run_once()

    assert_expired_and_gone(db, staged)


def test_a_recorded_path_outside_the_owners_stage_is_never_removed(db, music):
    other = add_test_user(db, "other")
    theirs = stage_item(db, music / ".uploads", owner_id=other, state="review_ready", progress_at=NOW,
                        content=b"theirs")
    mine = stage_item(db, music / ".uploads", state="review_ready", progress_at=OLD)
    sql(db, "UPDATE upload_items SET source_path = ? WHERE owner_id = ? AND item_uuid = ?",
        (str(theirs["source"]), mine["owner_id"], mine["item_uuid"]))

    janitor(db, music).run_once()

    assert theirs["source"].read_bytes() == b"theirs"
    assert item_row(db, theirs)["state"] == "review_ready"
    assert item_row(db, mine)["state"] == "expired"


def test_another_users_young_items_are_untouched(db, music):
    other = add_test_user(db, "other")
    theirs = stage_item(db, music / ".uploads", owner_id=other, state="review_ready", progress_at=YOUNG)
    mine = stage_item(db, music / ".uploads", state="review_ready", progress_at=OLD)

    janitor(db, music).run_once()

    assert item_row(db, theirs)["state"] == "review_ready"
    assert theirs["source"].exists()
    assert_expired_and_gone(db, mine)


def test_a_folder_holding_an_unknown_file_stays(db, music):
    staged = stage_item(db, music / ".uploads", state="review_ready", progress_at=OLD)
    stray = staged["source"].parent / "stray.bin"
    stray.write_bytes(b"?")

    janitor(db, music).run_once()

    assert item_row(db, staged)["state"] == "expired"
    assert stray.read_bytes() == b"?"


def test_a_live_items_empty_folder_and_its_batch_stay(db, music):
    ended = stage_item(db, music / ".uploads", state="review_ready", progress_at=OLD)
    live = stage_item(db, music / ".uploads", state="allocated", progress_at=YOUNG,
                      batch_uuid=ended["batch_uuid"])
    live["source"].unlink()  # a transfer about to start: empty folder
    sql(db, "UPDATE upload_items SET source_path = NULL WHERE item_uuid = ?", (live["item_uuid"],))

    janitor(db, music).run_once()

    assert not ended["source"].parent.exists()
    assert live["source"].parent.is_dir()
    assert live["source"].parent.parent.is_dir()


def test_running_twice_changes_nothing_more(db, music):
    staged = stage_item(db, music / ".uploads", state="review_ready", progress_at=OLD)
    janitor(db, music).run_once()
    before = item_row(db, staged)

    janitor(db, music).run_once()

    assert item_row(db, staged) == before


# ── finished commit journals in a running server ──────────────────────────

def test_a_finished_journal_is_cleaned_only_after_the_grace_period(db, music):
    world = World(db, music)
    commit = world.commit()
    assert world.worker().process_one() == "imported"
    os.link(sql(db, "SELECT file_path FROM tracks WHERE uuid_id = ?", (commit["track"],))[0]["file_path"],
            commit["work"])  # a leftover the publisher could not remove
    [row] = sql(db, "SELECT updated_at FROM upload_commit_journal WHERE operation_uuid = ?", (commit["op"],))

    janitor(db, music, now=row["updated_at"] + 59, journal_grace_s=60, world=world).run_once()
    assert commit["work"].exists()
    assert sql(db, "SELECT state FROM upload_commit_journal WHERE operation_uuid = ?",
               (commit["op"],)) == [{"state": "imported"}]

    janitor(db, music, now=row["updated_at"] + 60, journal_grace_s=60, world=world).run_once()
    assert not commit["work"].exists()
    assert sql(db, "SELECT state FROM upload_commit_journal WHERE operation_uuid = ?", (commit["op"],)) == []


def test_an_unfinished_journal_is_never_touched(db, music):
    world = World(db, music)
    commit = world.crash_at("before_insert_commit")
    final = sql(db, "SELECT final_path FROM upload_commit_journal WHERE operation_uuid = ?",
                (commit["op"],))[0]["final_path"]

    janitor(db, music, now=NOW, world=world).run_once()

    assert sql(db, "SELECT state FROM upload_commit_journal WHERE operation_uuid = ?",
               (commit["op"],)) == [{"state": "moved"}]
    assert os.path.isfile(final)
    assert item_row(db, commit)["state"] == "committing"
