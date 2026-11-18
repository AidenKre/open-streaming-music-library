"""7A.3b S9 (spec §4 DELETE: "Cancel unpublished item; repeated cancellation
succeeds. Commit already accepted returns 409/current receipt, never deletes a
published track."): a ``duplicate_conflict`` item becomes cancellable (source
released, journal untouched); ``committing``, ``imported`` and ``duplicate``
answer 409 ``upload_item_not_cancellable`` and change nothing."""

import pytest

from tests.identity_worker_fixtures import add_track, sql
from tests.upload_commit_fixtures import accept, ready_item, reservations

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

    def accepted(self, journal_state="committing", item_state=None, **item_columns):
        """A ready item with an accepted commit, its journal and item put in the given states."""
        staged = ready_item(self.db, self.root, owner_id=self.admin)
        commit = accept(self.db, staged)
        sql(self.db, "UPDATE upload_commit_journal SET state = ? WHERE operation_uuid = ?",
            (journal_state, commit["op"]))
        if item_state:
            names = ["state", *item_columns]
            sql(self.db, "UPDATE upload_items SET " + ", ".join(f"{n} = ?" for n in names)
                         + " WHERE item_uuid = ?", (item_state, *item_columns.values(), commit["item_uuid"]))
        return commit

    def delete(self, commit):
        return self.client.delete(f"/tracks/uploads/items/{commit['item_uuid']}")

    def snapshot(self, commit):
        return {
            "item": sql(self.db, "SELECT * FROM upload_items WHERE item_uuid = ?", (commit["item_uuid"],)),
            "journal": sql(self.db, "SELECT * FROM upload_commit_journal WHERE operation_uuid = ?",
                           (commit["op"],)),
            "reservations": reservations(self.db, self.admin),
            "tracks": sql(self.db, "SELECT * FROM tracks ORDER BY id"),
        }

    def upload_source_rows(self, commit):
        return [r for r in reservations(self.db, self.admin)
                if r["purpose"] == "upload_source" and r["subject_ref"] == commit["item_uuid"]]


@pytest.fixture
def env(client):
    return Env(client)


def _error(response):
    return response.json()["detail"]["error"]


def test_a_duplicate_conflict_item_can_be_cancelled_and_gives_back_its_source(env):
    commit = env.accepted("duplicate_conflict", "duplicate_conflict")
    journal_before = env.snapshot(commit)["journal"]
    assert commit["source"].exists() and len(env.upload_source_rows(commit)) == 1

    r = env.delete(commit)

    assert r.status_code == 200, r.text
    assert r.json()["state"] == "cancelled"
    assert not commit["source"].exists()
    assert env.upload_source_rows(commit) == []
    assert env.snapshot(commit)["journal"] == journal_before


def test_repeating_the_cancel_of_a_cancelled_conflict_succeeds(env):
    commit = env.accepted("duplicate_conflict", "duplicate_conflict")
    assert env.delete(commit).status_code == 200

    r = env.delete(commit)

    assert r.status_code == 200, r.text
    assert r.json()["state"] == "cancelled"


@pytest.mark.parametrize("journal_state", ["committing", "prepared", "moved"])
def test_an_item_with_an_active_commit_is_never_cancelled(env, journal_state):
    commit = env.accepted(journal_state)
    before = env.snapshot(commit)

    r = env.delete(commit)

    assert (r.status_code, _error(r)) == (409, "upload_item_not_cancellable"), r.text
    assert r.json()["detail"]["state"] == "committing"
    assert env.snapshot(commit) == before
    assert commit["source"].exists()


def test_an_imported_item_is_not_cancelled_and_its_track_survives(env):
    master = env.root.parent / "master.flac"
    master.write_bytes(b"the published master")
    track = add_track(env.db, master, owner_id=env.admin)
    commit = env.accepted("imported", "imported", result_track_uuid=track, result_revision=3)
    before = env.snapshot(commit)

    r = env.delete(commit)

    assert (r.status_code, _error(r)) == (409, "upload_item_not_cancellable"), r.text
    assert r.json()["detail"]["state"] == "imported"
    assert env.snapshot(commit) == before
    assert master.read_bytes() == b"the published master"


def test_a_duplicate_item_is_not_cancelled(env):
    track = add_track(env.db, env.root.parent / "other.flac", owner_id=env.admin)
    commit = env.accepted("failed", "duplicate", result_track_uuid=track, duplicate_kind="exact")
    before = env.snapshot(commit)

    r = env.delete(commit)

    assert (r.status_code, _error(r)) == (409, "upload_item_not_cancellable"), r.text
    assert r.json()["detail"]["state"] == "duplicate"
    assert env.snapshot(commit) == before
