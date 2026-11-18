"""7A.3a S9 (spec §3 `committing`: "→ `review_ready`/`failed` after safe
recovery; durable journal protects filesystem/DB boundary"; §6: "One operation
is immutable after acceptance. ... changed body requires a new review
version/operation after a safe failed attempt"; "Original staged source
remains recoverable until commit completes"; "Never blindly unlink a path
without proving journal ownership"; §3 "handle ENOSPC at every write"; SC-16d:
a lease of another boot is dead; SC-28 rule 5 containment).

A failure before ``prepared`` removes only this operation's own work file,
gives its reservation back, keeps the staged source, ends the journal
``failed`` and returns the item to ``review_ready`` with a new review version
and a retryable error (or to ``failed upload_source_missing`` when the staged
source itself is gone). A crash leaves a ``committing`` journal that the next
boot claims again and re-runs from the start."""

import errno

import pytest

from app.services.metadata import TagWriteError, write_metadata_tags
from tests.tool_call_capture import bound_to
from app.services import upload_errors
from app.services.upload_errors import probe_timeout, upload_invalid_audio
from app.services.upload_validation import ValidationFailed
from tests.identity_worker_fixtures import sql
from tests.upload_commit_fixtures import (
    FakeArt,
    FakeCoverArt,
    FakeExact,
    FakeProbe,
    FakeTagWriter,
    accept,
    journal,
    make_commit_worker,
    make_ledger,
    ready_item,
    reservations,
    sha,
)
from tests.upload_validation_fixtures import BOOT, DEAD_BOOT, detected, item_row


@pytest.fixture
def music(tmp_path):
    path = tmp_path / "music"
    (path / ".uploads").mkdir(parents=True)
    return path


def _ready(db, music, **kwargs):
    return ready_item(db, music / ".uploads", **kwargs)


def _assert_back_to_review(db, commit, code):
    item = item_row(db, commit)
    assert (item["state"], item["review_version"]) == ("review_ready", 1)
    assert (item["error_code"], item["error_retryable"]) == (code, 1)
    assert item["error_message"] and "/" not in item["error_message"]
    assert item["lease_boot_id"] is None
    row = journal(db, commit)
    assert (row["state"], row["error_code"], row["lease_boot_id"]) == ("failed", code, None)
    assert not commit["work"].exists()
    assert commit["source"].read_bytes() == commit["content"]
    assert [r["purpose"] for r in reservations(db, commit["owner_id"])] == ["upload_source"]


def test_no_room_for_the_work_copy_returns_the_item_to_review(db, music):
    commit = accept(db, _ready(db, music))

    outcome = make_commit_worker(db, music, ledger=make_ledger(db, music, free=0)).process_one()

    assert outcome == "failed"
    _assert_back_to_review(db, commit, "insufficient_storage")


def test_a_failed_tag_write_returns_the_item_to_review(db, music):
    commit = accept(db, _ready(db, music), write_tags=True, edits={"title": "T"})
    writer = FakeTagWriter()
    writer.raises = TagWriteError("ffmpeg exited 1 for /secret/path")

    assert make_commit_worker(db, music, tag_writer=writer).process_one() == "failed"

    _assert_back_to_review(db, commit, "tag_write_failed")


def test_a_full_disk_while_copying_returns_the_item_to_review(db, music):
    commit = accept(db, _ready(db, music), write_tags=True, edits={"title": "T"})
    writer = FakeTagWriter()
    writer.raises = OSError(errno.ENOSPC, "No space left on device")

    assert make_commit_worker(db, music, tag_writer=writer).process_one() == "failed"

    _assert_back_to_review(db, commit, "insufficient_storage")


def test_a_failed_reprobe_returns_the_item_to_review(db, music):
    commit = accept(db, _ready(db, music))

    outcome = make_commit_worker(db, music, probe=FakeProbe(ValidationFailed(probe_timeout()))).process_one()

    assert outcome == "failed"
    _assert_back_to_review(db, commit, "probe_timeout")


PREPARED_UNREADABLE = "The server couldn't read the file after preparing it."


def test_a_prepared_copy_that_cannot_be_read_returns_the_item_to_review_with_its_own_error(db, music):
    # Sign-off 2026-11-17 (OPEN-7-05, U12-B-03, alternative 1): the upload already
    # passed its check, so the checker's "not a readable audio file" is not passed
    # through; the import step has its own retryable code and message.
    commit = accept(db, _ready(db, music), write_tags=True, edits={"title": "T"})

    outcome = make_commit_worker(
        db, music, probe=FakeProbe(ValidationFailed(upload_invalid_audio()))).process_one()

    assert outcome == "failed"
    _assert_back_to_review(db, commit, "upload_prepared_unreadable")
    assert item_row(db, commit)["error_message"] == PREPARED_UNREADABLE
    assert journal(db, commit)["error_code"] == "upload_prepared_unreadable"


def test_the_prepared_copy_error_is_retryable_with_the_owners_wording():
    error = upload_errors.upload_prepared_unreadable()
    assert (error.code, error.message, error.retryable) \
        == ("upload_prepared_unreadable", PREPARED_UNREADABLE, True)


def test_output_larger_than_its_reservation_is_refused(db, music):
    commit = accept(db, _ready(db, music, content=b"x" * 100), write_tags=True, edits={"title": "T"})

    outcome = make_commit_worker(db, music, tag_writer=FakeTagWriter(extra=b"y" * (4 * 1024 * 1024))
                                 ).process_one()

    assert outcome == "failed"
    _assert_back_to_review(db, commit, "upload_commit_failed")


def test_an_unexpected_error_returns_the_item_to_review(db, music):
    commit = accept(db, _ready(db, music))
    exact = FakeExact()
    exact.result = RuntimeError("boom")

    assert make_commit_worker(db, music, exact=exact).process_one() == "failed"

    _assert_back_to_review(db, commit, "upload_commit_failed")


def test_a_missing_staged_source_fails_the_item_for_a_new_transfer(db, music):
    commit = accept(db, _ready(db, music))
    commit["source"].unlink()

    assert make_commit_worker(db, music).process_one() == "failed"

    item = item_row(db, commit)
    assert (item["state"], item["error_code"], item["error_retryable"]) == ("failed", "upload_source_missing", 1)
    assert (journal(db, commit)["state"], journal(db, commit)["error_code"]) == ("failed", "upload_source_missing")
    assert not commit["work"].exists()


def test_a_work_path_outside_the_owners_stage_is_never_written(db, music):
    commit = accept(db, _ready(db, music))
    outside = music / "victim.flac"
    outside.write_bytes(b"not ours")
    sql(db, "UPDATE upload_commit_journal SET work_path = ?", (str(outside),))

    assert make_commit_worker(db, music).process_one() == "failed"

    assert outside.read_bytes() == b"not ours"
    assert journal(db, commit)["state"] == "failed"


def test_a_staged_source_outside_the_owners_stage_is_never_read(db, music, tmp_path):
    commit = accept(db, _ready(db, music))
    foreign = tmp_path / "elsewhere.flac"
    foreign.write_bytes(b"someone else's")
    sql(db, "UPDATE upload_commit_journal SET source_path = ?", (str(foreign),))

    assert make_commit_worker(db, music).process_one() == "failed"

    assert not commit["work"].exists()
    assert journal(db, commit)["state"] == "failed"
    assert foreign.read_bytes() == b"someone else's"


def test_a_failure_before_prepared_never_removes_the_staged_source(db, music):
    commit = accept(db, _ready(db, music, content=b"keep me"), write_tags=True, edits={"title": "T"})
    before = sha(commit["source"])
    writer = FakeTagWriter()
    writer.raises = TagWriteError("x")

    make_commit_worker(db, music, tag_writer=writer).process_one()

    assert sha(commit["source"]) == before


def _art_meta():
    meta = detected()
    meta["has_album_art"] = True
    return meta


def test_a_failure_releases_artwork_this_operation_created(db, music):
    """SC-16h: newly created art is removed only through release_if_unreferenced."""
    commit = accept(db, _ready(db, music))
    covers, exact = FakeCoverArt(first_id=500), FakeExact()
    exact.result = RuntimeError("boom")

    outcome = make_commit_worker(db, music, probe=FakeProbe(_art_meta()), art=FakeArt(b"img"),
                                 cover_art=covers, exact=exact).process_one()

    assert outcome == "failed"
    assert covers.released == [500]
    _assert_back_to_review(db, commit, "upload_commit_failed")


def test_a_failure_never_releases_shared_artwork(db, music):
    commit = accept(db, _ready(db, music))
    covers, exact = FakeCoverArt(first_id=500), FakeExact()
    covers.add_album_art_with_status(b"img")  # another track's cover
    exact.result = RuntimeError("boom")

    make_commit_worker(db, music, probe=FakeProbe(_art_meta()), art=FakeArt(b"img"),
                       cover_art=covers, exact=exact).process_one()

    assert covers.released == []
    assert journal(db, commit)["state"] == "failed"


# ── crash and re-claim ──────────────────────────────────────────────────────

def test_a_commit_leased_by_a_dead_boot_is_claimed_and_rerun(db, music):
    commit = accept(db, _ready(db, music, content=b"audio-A"), lease=DEAD_BOOT)
    sql(db, "UPDATE upload_commit_journal SET lease_boot_id = ?", (DEAD_BOOT,))
    commit["work"].write_bytes(b"half-written by the dead run")

    assert make_commit_worker(db, music).process_one() == "prepared"

    assert commit["work"].read_bytes() == b"audio-A"
    assert journal(db, commit)["state"] == "prepared"


def test_a_commit_this_boot_is_working_on_is_not_claimed_twice(db, music):
    accept(db, _ready(db, music), lease=BOOT)
    sql(db, "UPDATE upload_commit_journal SET lease_boot_id = ?", (BOOT,))

    assert make_commit_worker(db, music).process_one() == "idle"


def test_a_stop_mid_step_writes_nothing_further(db, music):
    commit = accept(db, _ready(db, music))
    worker = None
    probe = FakeProbe()
    probe.mid = lambda: worker.request_stop()
    worker = make_commit_worker(db, music, probe=probe)

    assert worker.process_one() == "interrupted"

    row = journal(db, commit)
    assert (row["state"], row["final_metadata"]) == ("committing", None)
    assert item_row(db, commit)["state"] == "committing"


def test_the_next_boot_finishes_what_a_stop_interrupted(db, music):
    commit = accept(db, _ready(db, music, content=b"audio-A"))
    worker = None
    probe = FakeProbe()
    probe.mid = lambda: worker.request_stop()
    worker = make_commit_worker(db, music, probe=probe)
    worker.process_one()

    assert make_commit_worker(db, music, boot_id="boot-next").process_one() == "prepared"

    assert commit["work"].read_bytes() == b"audio-A"
    assert journal(db, commit)["state"] == "prepared"


# ── review r1 ───────────────────────────────────────────────────────────────

def test_a_new_attempt_clears_the_previous_attempts_error(db, music):
    """Review r1 #1: after a failed attempt the next accepted commit must not
    keep showing the old error."""
    from app.library import Library
    from app.models.uploads import CommitRequest
    from app.services.upload_commit import accept as accept_commit

    commit = accept(db, _ready(db, music))
    make_commit_worker(db, music, ledger=make_ledger(db, music, free=0)).process_one()
    assert item_row(db, commit)["error_code"] == "insufficient_storage"

    request = CommitRequest.model_validate({
        "operation_uuid": "44444444-4444-4444-8444-444444444444", "base_review_version": 1,
        "edits": {}, "write_tags": False,
        "acknowledged_duplicates": {"library_tracks": [], "staged_items": []}})
    status, row = accept_commit(Library(db, commit["owner_id"]), request, commit["item_uuid"],
                                uploads_root=music / ".uploads", now=2_000_000_000)

    assert (status, row["state"]) == (202, "committing")
    item = item_row(db, commit)
    assert (item["error_code"], item["error_message"], item["error_retryable"]) == (None, None, None)


def test_a_work_copy_that_cannot_be_removed_keeps_its_quota(db, music, monkeypatch):
    """Review r1 #4: a leftover work file must stay counted until it is gone."""
    from app.services import upload_commit

    commit = accept(db, _ready(db, music, content=b"x" * 100))
    monkeypatch.setattr(upload_commit, "remove_verified", lambda files, path: False)
    exact = FakeExact()
    exact.result = RuntimeError("boom")

    assert make_commit_worker(db, music, exact=exact).process_one() == "failed"

    assert commit["work"].exists()
    assert journal(db, commit)["state"] == "failed"
    rows = reservations(db, commit["owner_id"])
    assert {"purpose": "upload_work", "subject_ref": commit["op"], "bytes": 100, "lease_boot_id": None} in rows


def test_a_full_server_wide_quota_neither_refuses_a_commit_nor_reveals_other_users_totals(db, music):
    """Review r1 7-R1-04 (DEV-7-10): another user's staged bytes never reach this
    user's item. Since TR-UPLOAD-01 (coordinator decision 2026-11-13) a commit
    is admitted against the free-disk floor only, so a full server-wide quota no
    longer refuses it at all: no refusal, no figure. (The commit's remaining
    refusal, the disk floor, keeps its fixed text: test_upload_commit_quota.py.)"""
    from tests.owned_database import add_test_user
    from tests.upload_commit_fixtures import QUOTA

    other = add_test_user(db, "sam")
    commit = accept(db, _ready(db, music, content=b"x" * 100))
    used = sum(r["bytes"] for r in reservations(db, commit["owner_id"]))
    others_bytes = QUOTA.total_bytes - used - 50  # leaves 50 bytes: too few for the work copy
    sql(db, "INSERT INTO storage_reservations (owner_id, purpose, subject_ref, bytes, created_at)"
            " VALUES (?, 'upload_source', 'theirs', ?, 1)", (other, others_bytes))

    assert make_commit_worker(db, music).process_one() == "prepared"

    item = item_row(db, commit)
    assert (item["state"], item["error_code"], item["error_message"]) == ("committing", None, None)


def test_a_step_killed_by_a_shutdown_says_so_and_not_that_it_failed(db, music, caplog):
    """Live gate O-4: a shutdown kills the tag write under way; the step's log
    line says it was stopped by the shutdown, not that the commit failed."""
    commit = accept(db, _ready(db, music), edits={"title": "New"}, write_tags=True)
    worker = None

    @bound_to(write_metadata_tags)
    def killed_tag_write(source, dest, tags, **kwargs):
        worker.request_stop()  # shutdown: stop first, then the registry kills the process
        raise TagWriteError("tag write failed")

    worker = make_commit_worker(db, music, tag_writer=killed_tag_write)

    with caplog.at_level("INFO"), caplog.at_level("INFO", logger="uvicorn.error"):
        worker.process_one()

    lines = [r.getMessage() for r in caplog.records if r.name == "app.services.upload_commit"]
    assert not [line for line in lines if "failed" in line]
    # Review r3 7-R3-07: the operator sees it at the default level (the operator log).
    operator = [r.getMessage() for r in caplog.records if r.name == "uvicorn.error"]
    assert any("stopped" in line and "shutdown" in line for line in operator)
    assert all("/" not in line for line in operator)
    assert item_row(db, commit)["state"] == "committing"
