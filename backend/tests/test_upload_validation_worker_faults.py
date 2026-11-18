"""7A.2c in-piece review r1 regressions (7A.2c-review.md R2–R7, R9–R13, R16).
Each test failed before its fix for the reason its finding names."""

import json
import os
import sqlite3
import threading

import pytest

from app.services.audio_identity import AudioIdentity, ExactUnavailable
from app.services.ffmpeg_runner import run_capture
from app.services.storage_ledger import UPLOAD_SOURCE
from app.services.upload_errors import probe_timeout, upload_unsupported_audio
from app.services.upload_receipt import reconcile_upload_receipts
from app.services.upload_validation import ValidationFailed, ValidationInterrupted, probe_upload
from tests.identity_worker_fixtures import sql
from tests.tool_call_capture import tool_call
from tests.upload_validation_fixtures import (
    FakeProbe,
    FakeRegistry,
    item_row,
    make_worker,
    source_rows,
    stage_item,
)

NOW = 1_700_000_000
WAIT_S = 10


@pytest.fixture
def client(app_client):
    from app.routers.uploads import upload_clock

    app_client.app.dependency_overrides[upload_clock] = lambda: NOW
    return app_client


class Env:
    def __init__(self, client):
        self.client = client
        self.db = client.app.state.database
        self.admin = client.app.state.admin_user_id
        self.root = client.app.state.upload_receipt.uploads_root
        self.root.mkdir(parents=True, exist_ok=True)
        self.tokens = client.app.state.upload_cancel_tokens
        self.registry = FakeRegistry()

    def stage(self, **kwargs):
        kwargs.setdefault("owner_id", self.admin)
        return stage_item(self.db, self.root, **kwargs)

    def worker(self, **kwargs):
        kwargs.setdefault("tokens", self.tokens)
        kwargs.setdefault("registry", self.registry)
        return make_worker(self.db, self.root, **kwargs)

    def delete(self, staged):
        return self.client.delete(f"/tracks/uploads/items/{staged['item_uuid']}")


@pytest.fixture
def env(client):
    return Env(client)


# R2: one database error must not end the worker.
def test_a_claim_that_raises_is_survived_and_the_item_validated_next(env):
    staged = env.stage()
    worker = env.worker()
    real = env.db.claim_upload_validation
    calls = []

    def flaky(**kwargs):
        calls.append(1)
        if len(calls) == 1:
            raise sqlite3.OperationalError("database is locked")
        return real(**kwargs)

    env.db.claim_upload_validation = flaky

    assert worker.process_one() == "error"
    worker.process_one()
    assert item_row(env.db, staged)["state"] == "review_ready"


def test_the_thread_lives_through_a_database_error(env):
    staged = env.stage()
    finished = threading.Event()
    real_claim, real_finish = env.db.claim_upload_validation, env.db.finish_upload_validation
    calls = []

    def flaky(**kwargs):
        calls.append(1)
        if len(calls) == 1:
            raise sqlite3.OperationalError("database is locked")
        return real_claim(**kwargs)

    def finish(**kwargs):
        try:
            return real_finish(**kwargs)
        finally:
            finished.set()

    env.db.claim_upload_validation, env.db.finish_upload_validation = flaky, finish
    worker = env.worker(idle_poll_s=0.01)
    worker.start()
    try:
        assert finished.wait(WAIT_S)
        assert worker.is_alive()
    finally:
        assert worker.stop(timeout=WAIT_S)
    assert item_row(env.db, staged)["state"] == "review_ready"


# R3: a cancel that kills the real probe leaves no lease on the cancelled item.
def test_a_cancel_that_kills_the_probe_leaves_no_lease(env):
    staged = env.stage()
    probe = FakeProbe(ValidationInterrupted())  # what probe_upload raises on SIGKILL
    probe.mid = lambda: env.delete(staged)

    outcome = env.worker(probe=probe).process_one()

    row = item_row(env.db, staged)
    assert (outcome, row["state"], row["lease_boot_id"]) == ("cancelled", "cancelled", None)


# R4: a kill that is neither a stop nor a cancel fails the item retryably.
def test_a_process_killed_from_outside_fails_the_item_retryably(env):
    staged = env.stage()

    env.worker(probe=FakeProbe(ValidationInterrupted())).process_one()

    row = item_row(env.db, staged)
    assert (row["state"], row["error_code"], row["error_retryable"], row["lease_boot_id"]) == (
        "failed", "upload_validation_failed", 1, None)
    assert staged["source"].exists()


# R5: a stop that lands between the probe and the identity step writes nothing.
def test_a_stop_between_the_process_steps_writes_nothing(env):
    staged = env.stage()
    worker = env.worker()
    real_step = worker._process_step
    steps = []

    def step(fn, *args, **kwargs):
        steps.append(fn)
        if len(steps) == 2:
            worker.request_stop()  # lands while no job is published
            return AudioIdentity(exact=ExactUnavailable("failed", "killed"), tool_versions=None,
                                 computed_at=1, fingerprint=None)
        return real_step(fn, *args, **kwargs)

    worker._process_step = step

    assert worker.process_one() == "interrupted"
    row = item_row(env.db, staged)
    assert (row["state"], row["duplicate_report"], row["detected_metadata"]) == ("validating", None, None)


# R7: a receipt token still registered never hides a cancel from the worker.
def test_a_cancel_reaches_the_worker_even_while_the_receipts_token_is_registered(env):
    staged = env.stage()
    key = (staged["owner_id"], staged["item_uuid"])
    env.tokens.register(key)  # the receipt's token, not yet discarded by its finish()
    probe = FakeProbe()

    def mid():
        env.tokens.discard(key)  # the receipt's finish() runs now
        env.delete(staged)

    probe.mid = mid
    env.worker(probe=probe).process_one()

    assert env.registry.killed == [probe.calls[0]["job_id"]]


# R9: the failure write is guarded by lease and review_version too.
@pytest.mark.parametrize("change", [
    "UPDATE upload_items SET review_version = 3 WHERE item_uuid = ?",
    "UPDATE upload_items SET lease_boot_id = 'boot-other' WHERE item_uuid = ?",
], ids=["review-version", "lease"])
def test_a_stale_failure_is_never_written(env, change):
    staged = env.stage()
    probe = FakeProbe(ValidationFailed(probe_timeout()))
    probe.mid = lambda: sql(env.db, change, (staged["item_uuid"],))

    env.worker(probe=probe).process_one()

    row = item_row(env.db, staged)
    assert (row["state"], row["error_code"]) == ("validating", None)


# R11: an internal runner error is not the file's fault.
def test_an_internal_runner_error_is_retryable_not_invalid_audio(tmp_path):
    source = tmp_path / "source"
    source.write_bytes(b"x")

    def run(*args, **kwargs):
        tool_call(run_capture, *args, **kwargs)
        raise RuntimeError("selector broke")

    with pytest.raises(ValidationFailed) as caught:
        probe_upload(source, run=run)

    assert (caught.value.error.code, caught.value.error.retryable) == ("upload_validation_failed", True)


# R12: a stale step never touches the filesystem.
def test_a_stale_non_retryable_failure_keeps_the_source(env):
    staged = env.stage()
    probe = FakeProbe(ValidationFailed(upload_unsupported_audio()))
    probe.mid = lambda: sql(env.db, "UPDATE upload_items SET review_version = 3 WHERE item_uuid = ?",
                            (staged["item_uuid"],))

    env.worker(probe=probe).process_one()

    assert staged["source"].exists()
    assert item_row(env.db, staged)["source_path"] == str(staged["source"])
    assert source_rows(env.db, staged) == [{"purpose": UPLOAD_SOURCE, "bytes": 7}]


# R16: a retried item is claimable again even if it ever carried the cancel flag.
def test_a_retry_to_validating_clears_the_cancel_flag(env):
    staged = env.stage()
    env.worker(probe=FakeProbe(ValidationFailed(probe_timeout()))).process_one()
    sql(env.db, "UPDATE upload_items SET cancel_requested = 1 WHERE item_uuid = ?", (staged["item_uuid"],))

    response = env.client.post(f"/tracks/uploads/items/{staged['item_uuid']}/retry",
                               json={"expected_review_version": 0})

    assert response.json()["state"] == "validating"
    env.worker().process_one()
    assert item_row(env.db, staged)["state"] == "review_ready"


# R13: retry gives a source up only when it is verifiably gone.
def test_a_source_that_cannot_be_inspected_is_not_treated_as_gone(env, monkeypatch):
    staged = env.stage()
    env.worker(probe=FakeProbe(ValidationFailed(probe_timeout()))).process_one()
    real_stat, real_lstat = os.stat, os.lstat
    target = str(staged["source"])

    def denied(real):
        def stat(path, *args, **kwargs):
            if os.fspath(path) == target:
                raise PermissionError(13, "denied")
            return real(path, *args, **kwargs)
        return stat

    monkeypatch.setattr(os, "stat", denied(real_stat))
    monkeypatch.setattr(os, "lstat", denied(real_lstat))
    response = env.client.post(f"/tracks/uploads/items/{staged['item_uuid']}/retry",
                               json={"expected_review_version": 0})
    monkeypatch.undo()

    assert response.json()["state"] == "validating"
    assert source_rows(env.db, staged) == [{"purpose": UPLOAD_SOURCE, "bytes": 7}]


# R10: a restart never releases the quota of a cancelled item whose file is still there.
def test_a_restart_keeps_the_quota_of_a_cancelled_items_remaining_file(env):
    staged = env.stage()
    env.worker().process_one()
    sql(env.db, "UPDATE upload_items SET state = 'cancelled' WHERE item_uuid = ?", (staged["item_uuid"],))

    reconcile_upload_receipts(env.db, env.root, boot_id="boot-next")

    assert staged["source"].exists()
    assert source_rows(env.db, staged) == [{"purpose": UPLOAD_SOURCE, "bytes": 7}]


# R6: a stored report in an unexpected shape reads as a failed check, never a 500.
GOOD_LAYER = {"subject_state": "current", "library_pending": 0, "library_failed": 0, "library_not_comparable": 0}


@pytest.mark.parametrize("report", [
    {"v": 1, "status": "complete", "exact": GOOD_LAYER, "fingerprint": GOOD_LAYER,
     "matches": [{"ref": "library_track", "id": "x"}]},
    {"v": 1, "status": "complete", "exact": {**GOOD_LAYER, "library_pending": "a"}, "fingerprint": GOOD_LAYER,
     "matches": []},
    {"v": 1, "status": "complete", "exact": GOOD_LAYER, "fingerprint": GOOD_LAYER,
     "matches": [{"ref": "library_track", "id": {"a": 1}, "kind": "exact", "band": "exact", "score": None}]},
    {"v": 1, "status": "complete", "exact": GOOD_LAYER, "fingerprint": GOOD_LAYER,
     "matches": [{"ref": "staged_item", "id": "not-a-uuid", "kind": "exact", "band": "exact", "score": None}]},
], ids=["match-missing-keys", "bad-count", "id-not-string", "id-not-uuid"])
def test_a_corrupted_report_reads_as_a_failed_check(env, report):
    staged = env.stage()
    env.worker().process_one()
    sql(env.db, "UPDATE upload_items SET duplicate_report = ? WHERE item_uuid = ?",
        (json.dumps(report), staged["item_uuid"]))

    item = env.client.get(f"/tracks/uploads/items/{staged['item_uuid']}")
    page = env.client.get(f"/tracks/uploads/{staged['batch_uuid']}/items")

    assert (item.status_code, page.status_code) == (200, 200)
    assert item.json()["duplicate_check"]["status"] == "failed"
    assert item.json()["duplicate_check"]["no_duplicates_found"] is False
