"""7A.2d × 7A.3a (spec §3 `expanded`: "children have independent review/import
statuses"; §4 commit row): a ZIP child that reached review_ready is committed
through the same route and the same commit worker as a single-file item, from
its own staged source inside its owner's folder."""

import uuid

import pytest

from tests.identity_worker_fixtures import sql
from tests.upload_commit_fixtures import make_commit_worker
from tests.upload_validation_fixtures import FakeProbe, item_row
from tests.upload_zip_fixtures import Entry, children_of, make_expander, stage_zip, zip_worker

NOW = 1_700_000_000
A, B = bytes(range(40)), bytes(range(100, 130))


@pytest.fixture
def client(app_client):
    from app.routers.uploads import upload_clock

    app_client.app.dependency_overrides[upload_clock] = lambda: NOW
    return app_client


class Wakes:
    def wake(self):
        pass


@pytest.fixture
def env(client, tmp_path):
    db = client.app.state.database
    root = client.app.state.upload_receipt.uploads_root
    root.mkdir(parents=True, exist_ok=True)
    client.app.state.upload_commit_worker = Wakes()
    staged = stage_zip(db, root, tmp_path, [Entry("d/01.flac", A), Entry("d/02.flac", B)],
                       owner_id=client.app.state.admin_user_id)
    worker = zip_worker(db, root, tmp_path, expander=make_expander(db, root, tmp_path), probe=FakeProbe())
    assert worker.process_one() == "expanded"
    while worker.process_one() != "idle":
        pass
    yield client, db, root, staged
    client.app.state.upload_commit_worker = None


def _commit(client, item_uuid):
    return client.post(f"/tracks/uploads/items/{item_uuid}/commit", json={
        "operation_uuid": str(uuid.uuid4()), "base_review_version": 0, "edits": {},
        "write_tags": False, "acknowledged_duplicates": {"library_tracks": [], "staged_items": []},
    })


def test_a_review_ready_child_is_committed_like_a_single_file(env):
    client, db, root, staged = env
    kids = children_of(db, staged)
    assert [k["state"] for k in kids] == ["review_ready", "review_ready"]
    child = kids[0]

    response = _commit(client, child["item_uuid"])

    assert response.status_code == 202, response.text
    assert response.json()["state"] == "committing"
    [journal] = sql(db, "SELECT * FROM upload_commit_journal WHERE item_uuid = ?", (child["item_uuid"],))
    assert journal["source_path"] == child["source_path"]
    assert journal["source_path"].startswith(str(root / str(staged["owner_id"]) / staged["batch_uuid"]))

    assert make_commit_worker(db, root.parent).process_one() == "prepared"
    [journal] = sql(db, "SELECT * FROM upload_commit_journal WHERE item_uuid = ?", (child["item_uuid"],))
    assert journal["state"] == "prepared"
    work = journal["work_path"]
    assert work.startswith(str(root / str(staged["owner_id"]) / staged["batch_uuid"] / child["item_uuid"]))
    with open(work, "rb") as handle:
        assert handle.read() == A
    # The sibling and the parent are untouched.
    assert item_row(db, {"owner_id": staged["owner_id"], "item_uuid": kids[1]["item_uuid"]})["state"] == "review_ready"
    assert item_row(db, staged)["state"] == "expanded"


def test_an_expanded_parent_itself_is_not_committable(env):
    client, _, _, staged = env

    response = _commit(client, staged["item_uuid"])

    assert response.status_code == 409, response.text
    assert response.json()["detail"]["error"] == "upload_item_not_committable"
