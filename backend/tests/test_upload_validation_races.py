"""7A.2c S7 (spec §3: `validating` → `cancelled`, `review_ready` → `cancelled`;
§4 DELETE "Cancel unpublished item; repeated cancellation succeeds"; §4 "Per-item
lock plus DB compare-and-swap state/version protects races across request and
worker paths"; SC-16d "cancellation is a durable flag plus an in-memory
token"; 7A.2b rule: whoever removes a source releases its quota row in the
same transaction): a cancel or a newer state always wins over a validation
result that is still in flight, and a stale result never overwrites it."""

import os

import pytest

from app.services.storage_ledger import UPLOAD_SOURCE
from tests.identity_worker_fixtures import sql
from tests.upload_validation_fixtures import (
    BOOT,
    DEAD_BOOT,
    FakeCompute,
    FakeProbe,
    FakeRegistry,
    identity_row,
    item_row,
    make_worker,
    source_rows,
    stage_item,
)

NOW = 1_700_000_000


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
        return make_worker(self.db, self.root, tokens=self.tokens, registry=self.registry, **kwargs)

    def delete(self, staged):
        return self.client.delete(f"/tracks/uploads/items/{staged['item_uuid']}")


@pytest.fixture
def env(client):
    return Env(client)


def _nothing_written(env, staged):
    row = item_row(env.db, staged)
    assert (row["detected_metadata"], row["duplicate_report"], row["kind"]) == (None, None, None)
    assert identity_row(env.db, staged) is None


def _source_given_back(env, staged):
    assert not staged["source"].exists()
    assert item_row(env.db, staged)["source_path"] is None
    assert source_rows(env.db, staged) == []


# ── cancel ────────────────────────────────────────────────────────────────

def test_a_review_ready_item_can_be_cancelled_and_its_bytes_are_given_back(env):
    staged = env.stage()
    env.worker().process_one()
    assert item_row(env.db, staged)["state"] == "review_ready"

    response = env.delete(staged)

    assert (response.status_code, response.json()["state"]) == (200, "cancelled")
    _source_given_back(env, staged)
    assert env.delete(staged).status_code == 200  # repeated cancel succeeds


def test_a_queued_validating_item_can_be_cancelled_and_is_then_never_validated(env):
    staged = env.stage()
    probe = FakeProbe()

    response = env.delete(staged)

    assert (response.status_code, response.json()["state"]) == (200, "cancelled")
    assert item_row(env.db, staged)["cancel_requested"] == 1
    _source_given_back(env, staged)
    assert env.worker(probe=probe).process_one() == "idle"
    assert probe.calls == []


def test_a_cancel_during_the_probe_kills_it_and_nothing_is_written(env):
    staged = env.stage()
    probe = FakeProbe()
    answers = []
    probe.mid = lambda: answers.append(env.delete(staged))

    env.worker(probe=probe).process_one()

    [answer] = answers
    assert (answer.status_code, answer.json()["state"]) == (200, "cancelled")
    [call] = probe.calls
    assert env.registry.killed == [call["job_id"]]  # the token killed the item's process
    assert item_row(env.db, staged)["state"] == "cancelled"
    _nothing_written(env, staged)
    _source_given_back(env, staged)


def test_a_cancel_during_the_identity_computation_writes_nothing(env):
    staged = env.stage()
    compute = FakeCompute()
    compute.mid = lambda: env.delete(staged)

    env.worker(compute=compute).process_one()

    [call] = compute.calls
    assert env.registry.killed == [call["job_id"]]
    assert item_row(env.db, staged)["state"] == "cancelled"
    _nothing_written(env, staged)


def test_a_finished_item_holds_no_cancel_token(env):
    staged = env.stage()

    env.worker().process_one()

    assert env.tokens.cancel((env.admin, staged["item_uuid"])) is False


def test_a_source_that_cannot_be_removed_on_cancel_stays_recorded_and_counted(env, monkeypatch):
    staged = env.stage(content=b"abc")
    env.worker().process_one()

    def refuse(path):
        raise PermissionError("no")

    monkeypatch.setattr(os, "unlink", refuse)
    response = env.delete(staged)

    assert (response.status_code, response.json()["state"]) == (200, "cancelled")
    assert staged["source"].exists()
    assert item_row(env.db, staged)["source_path"] == str(staged["source"])
    assert source_rows(env.db, staged) == [{"purpose": UPLOAD_SOURCE, "bytes": 3}]


def test_cancel_never_removes_a_recorded_path_outside_the_uploads_tree(env, tmp_path):
    staged = env.stage()
    env.worker().process_one()
    outside = tmp_path / "elsewhere.flac"
    outside.write_bytes(b"not ours")
    sql(env.db, "UPDATE upload_items SET source_path = ? WHERE item_uuid = ?", (str(outside), staged["item_uuid"]))

    assert env.delete(staged).status_code == 200

    assert outside.read_bytes() == b"not ours"


# ── stale results ─────────────────────────────────────────────────────────

def test_a_result_for_an_older_review_version_is_dropped_and_the_item_revalidated(env):
    staged = env.stage()
    probe = FakeProbe()
    probe.mid = lambda: sql(env.db, "UPDATE upload_items SET review_version = 1 WHERE item_uuid = ?",
                            (staged["item_uuid"],))
    worker = env.worker(probe=probe)

    worker.process_one()

    row = item_row(env.db, staged)
    assert (row["state"], row["review_version"], row["lease_boot_id"]) == ("validating", 1, None)
    _nothing_written(env, staged)
    worker.process_one()
    assert (item_row(env.db, staged)["state"], item_row(env.db, staged)["review_version"]) == ("review_ready", 1)


def test_a_result_whose_lease_was_taken_away_is_dropped(env):
    staged = env.stage()
    probe = FakeProbe()
    probe.mid = lambda: sql(env.db, "UPDATE upload_items SET lease_boot_id = ? WHERE item_uuid = ?",
                            (DEAD_BOOT, staged["item_uuid"]))

    env.worker(probe=probe).process_one()

    row = item_row(env.db, staged)
    assert (row["state"], row["lease_boot_id"]) == ("validating", DEAD_BOOT)
    _nothing_written(env, staged)


def test_a_cancel_racing_the_finish_either_wins_whole_or_loses_whole(env):
    # The cancel lands after the worker's last process step: the finish CAS
    # sees `cancelled` and writes nothing.
    staged = env.stage()

    class Late(FakeCompute):
        def __call__(self, path, codec_hint, **kwargs):
            result = super().__call__(path, codec_hint, **kwargs)
            env.delete(staged)
            return result

    env.worker(compute=Late()).process_one()

    assert item_row(env.db, staged)["state"] == "cancelled"
    _nothing_written(env, staged)
    _source_given_back(env, staged)


@pytest.mark.parametrize("error", [("probe_failed", 0), ("upload_commit_failed", 1)])
def test_a_failed_item_can_be_cancelled_and_its_bytes_are_given_back(env, error):
    """Review r1 7-R1-16 (coordinator decision): ``failed`` is cancellable, so
    its staged bytes and quota row are not held until the 7-day expiry."""
    staged = env.stage()
    code, retryable = error
    sql(env.db, "UPDATE upload_items SET state = 'failed', error_code = ?, error_message = 'x',"
                " error_retryable = ? WHERE item_uuid = ?", (code, retryable, staged["item_uuid"]))
    assert source_rows(env.db, staged) != []

    response = env.delete(staged)

    assert response.status_code == 200, response.text
    assert response.json()["state"] == "cancelled"
    _source_given_back(env, staged)
    assert env.delete(staged).status_code == 200  # repeated cancel succeeds


# 7A.2d: an expanded ZIP parent answers 200 (test_upload_zip_cancel).
@pytest.mark.parametrize("state", ["committing", "imported", "duplicate", "expired"])
def test_other_states_still_refuse_a_cancel(env, state):
    staged = env.stage()
    extra = {"imported": ", result_track_uuid = 'x', result_revision = 1",
             "duplicate": ", result_track_uuid = 'x', duplicate_kind = 'exact'",
             "expanded": ", kind = 'zip'"}.get(state, "")
    sql(env.db, f"UPDATE upload_items SET state = ?{extra} WHERE item_uuid = ?", (state, staged["item_uuid"]))

    response = env.delete(staged)

    assert (response.status_code, response.json()["detail"]["error"]) == (409, "upload_item_not_cancellable")
    assert staged["source"].exists()


def test_validation_claims_carry_this_boot(env):
    staged = env.stage()
    seen = []
    probe = FakeProbe()
    probe.mid = lambda: seen.append(item_row(env.db, staged)["lease_boot_id"])

    env.worker(probe=probe).process_one()

    assert seen == [BOOT]
