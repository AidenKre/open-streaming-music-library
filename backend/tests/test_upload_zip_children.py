"""7A.2d S6 (spec §5 "no nested ZIP ... reject nested archives explicitly";
children are ordinary audio items once expanded but cannot be re-sent):
a ZIP-shaped child fails as nested, a child never receives content, and a
child without its source is not retryable."""

import uuid
from pathlib import Path

import pytest

from tests.identity_worker_fixtures import make_db, sql
from tests.upload_validation_fixtures import FakeProbe, item_row, new_uuid, source_rows, stage_item
from tests.upload_stream import put
from tests.upload_zip_fixtures import Entry, build_zip, children_of, files_under, stage_zip, zip_worker

NOW = 1_700_000_000


def test_a_zip_shaped_child_fails_as_nested_and_its_sibling_is_unaffected(tmp_path):
    db = make_db(tmp_path)
    root = tmp_path / "music" / ".uploads"
    root.mkdir(parents=True)
    inner = build_zip(tmp_path / "inner.zip", [Entry("x.flac", b"x" * 10)]).read_bytes()
    staged = stage_zip(db, root, tmp_path, [Entry("inner.flac", inner), Entry("ok.flac", bytes(range(50)))])
    worker = zip_worker(db, root, tmp_path, probe=FakeProbe())
    assert worker.process_one() == "expanded"
    kids = {c["member_order_key"]: c for c in children_of(db, staged)}
    assert set(kids) == {"inner.flac", "ok.flac"}
    worker.process_one()
    worker.process_one()
    bad = item_row(db, {"owner_id": staged["owner_id"], "item_uuid": kids["inner.flac"]["item_uuid"]})
    good = item_row(db, {"owner_id": staged["owner_id"], "item_uuid": kids["ok.flac"]["item_uuid"]})
    assert (bad["state"], bad["error_code"], bad["error_retryable"]) == ("failed", "upload_archive_nested", 0)
    assert bad["source_path"] is None and not Path(kids["inner.flac"]["source_path"]).exists()
    assert source_rows(db, {"owner_id": staged["owner_id"], "item_uuid": bad["item_uuid"]}) == []
    assert (good["state"], good["kind"]) == ("review_ready", "audio")
    assert item_row(db, staged)["state"] == "expanded"
    child_ids = tuple(c["item_uuid"] for c in kids.values())
    marks = ",".join("?" * len(child_ids))
    assert sql(db, f"SELECT * FROM upload_items WHERE parent_item_uuid IN ({marks})", child_ids) == []
    assert files_under(root) == {Path(kids["ok.flac"]["source_path"])}


# ── API: a child never receives content and is retryable only with its source ──

@pytest.fixture
def client(app_client):
    from app.routers.uploads import upload_clock

    app_client.app.dependency_overrides[upload_clock] = lambda: NOW
    app_client.app.state.upload_receipt.uploads_root.mkdir(parents=True, exist_ok=True)
    return app_client


class Wakes:
    def wake(self):
        pass


class Env:
    def __init__(self, client):
        self.client = client
        self.db = client.app.state.database
        self.owner = client.app.state.admin_user_id
        self.root = client.app.state.upload_receipt.uploads_root
        client.app.state.upload_validation_worker = Wakes()
        self.parent = stage_item(self.db, self.root, owner_id=self.owner)
        sql(self.db, "UPDATE upload_items SET state='expanded', kind='zip', source_path=NULL WHERE item_uuid=?",
            (self.parent["item_uuid"],))

    def child(self, state, *, source=False, error=None, retryable=None):
        uid = new_uuid()
        path = None
        if source:
            folder = self.root / str(self.owner) / self.parent["batch_uuid"] / uid
            folder.mkdir(parents=True)
            (folder / "source").write_bytes(b"child-bytes")
            path = str(folder / "source")
        sql(self.db, "INSERT INTO upload_items (owner_id, item_uuid, batch_uuid, parent_item_uuid, filename, "
                     "selection_index, member_order_key, expected_bytes, state, error_code, error_retryable, "
                     "source_path, created_at, updated_at, progress_at) "
                     "VALUES (?, ?, ?, ?, 'm.flac', 0, 'm.flac', 11, ?, ?, ?, ?, 100, 100, 100)",
            (self.owner, uid, self.parent["batch_uuid"], self.parent["item_uuid"], state, error, retryable, path))
        if source:
            sql(self.db, "INSERT INTO storage_reservations (owner_id, purpose, subject_ref, bytes, lease_boot_id, "
                         "created_at) VALUES (?, 'upload_source', ?, 11, NULL, 0)", (self.owner, uid))
        return uid

    def row(self, uid):
        return item_row(self.db, {"owner_id": self.owner, "item_uuid": uid})


@pytest.fixture
def env(client):
    yield Env(client)
    client.app.state.upload_validation_worker = None


@pytest.mark.parametrize("state", ["validating", "review_ready", "allocated"])
def test_a_child_is_never_receivable(env, state):
    uid = env.child(state)
    before = env.row(uid)
    sent = put(env.client, uid, [b"x" * 11])
    assert sent.status == 409, sent.body
    assert sent.json()["detail"]["error"] == "upload_item_not_receivable"
    assert env.row(uid) == before
    assert sql(env.db, "SELECT * FROM storage_reservations WHERE purpose = 'upload_receive'") == []


def test_a_failed_child_without_its_source_is_not_retryable(env):
    uid = env.child("failed", error="upload_source_missing", retryable=1)
    before = env.row(uid)
    response = env.client.post(f"/tracks/uploads/items/{uid}/retry", json={"expected_review_version": 0})
    assert response.status_code == 409, response.text
    assert response.json()["detail"]["error"] == "upload_item_not_retryable"
    assert env.row(uid) == before and before["state"] == "failed" and before["review_version"] == 0


def test_a_failed_child_with_its_source_is_retryable(env):
    uid = env.child("failed", source=True, error="upload_validation_failed", retryable=1)
    response = env.client.post(f"/tracks/uploads/items/{uid}/retry", json={"expected_review_version": 0})
    assert response.status_code == 200, response.text
    assert env.row(uid)["state"] == "validating"
