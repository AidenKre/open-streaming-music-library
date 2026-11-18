"""7A.2d S7 (spec §4 DELETE: "Cancel unpublished item; repeated cancellation
succeeds. ... Cancelling ZIP parent cancels only uncommitted children; report
imported children retained."; review 7-L07: only unpublished owned data
removed, imported track retained, exact parent/child terminal outcomes,
repeat cancellation safe; §5 "cancel safely ... Clean temporary work")."""

import uuid
from pathlib import Path

import pytest

from app.library import Library
from app.services.job_runtime import CancelTokens
from app.services.uploads import cancel
from tests.identity_worker_fixtures import make_db, sql
from tests.test_uploads_api import _second_user_client
from tests.upload_zip_fixtures import (
    CallbackFiles, Entry, children_of, files_under, make_expander, make_ledger, stage_zip, zip_worker,
)
from tests.upload_validation_fixtures import item_row

NOW = 1_700_000_000
NAMES = ["a.flac", "b.flac", "c.flac", "d.flac"]


def entries(n=4):
    return [Entry(NAMES[i], bytes([i + 1]) * (20 + i)) for i in range(n)]


def all_rows(db, owner):
    return sql(db, "SELECT * FROM upload_items WHERE owner_id = ? ORDER BY item_uuid", (owner,))


def rows_of(db, uuids):
    marks = ",".join("?" * len(uuids))
    return sql(db, f"SELECT * FROM storage_reservations WHERE subject_ref IN ({marks})", tuple(uuids))


# ── worker level ────────────────────────────────────────────────────────────

@pytest.fixture
def plain(tmp_path):
    db = make_db(tmp_path)
    root = tmp_path / "music" / ".uploads"
    root.mkdir(parents=True)
    return db, root


def test_cancel_during_expansion(plain, tmp_path):
    db, root = plain
    staged = stage_zip(db, root, tmp_path, entries(3))
    tokens, seam = CancelTokens(), CallbackFiles()
    worker = zip_worker(db, root, tmp_path, tokens=tokens,
                        expander=make_expander(db, root, tmp_path, files=seam))
    seam.callback = lambda: cancel(Library(db, staged["owner_id"]), staged["item_uuid"], now=NOW,
                                   tokens=tokens, uploads_root=root)
    assert worker.process_one() == "cancelled"
    assert item_row(db, staged)["state"] == "cancelled"
    kids = children_of(db, staged)
    assert kids and all(k["state"] == "cancelled" and k["source_path"] is None for k in kids)
    assert files_under(root) == set()
    ids = [staged["item_uuid"]] + [k["item_uuid"] for k in kids]
    assert rows_of(db, ids) == []
    assert sql(db, "SELECT * FROM storage_reservations WHERE purpose = 'upload_expand'") == []


def test_cancel_after_a_stop_before_any_restart(plain, tmp_path):
    db, root = plain
    staged = stage_zip(db, root, tmp_path, entries(3))
    seam = CallbackFiles()
    worker = zip_worker(db, root, tmp_path, expander=make_expander(db, root, tmp_path, files=seam))
    seam.callback = worker.request_stop
    assert worker.process_one() == "interrupted"
    assert len(files_under(root)) >= 2  # the archive and the first staged member
    out = cancel(Library(db, staged["owner_id"]), staged["item_uuid"], now=NOW, uploads_root=root)
    assert out.state == "cancelled"
    assert item_row(db, staged)["state"] == "cancelled"
    assert all(k["state"] == "cancelled" for k in children_of(db, staged))
    assert children_of(db, staged)
    assert files_under(root) == set()


# ── API level, real expansion ───────────────────────────────────────────────

@pytest.fixture
def client(app_client):
    from app.routers.uploads import upload_clock

    app_client.app.dependency_overrides[upload_clock] = lambda: NOW
    app_client.app.state.upload_receipt.uploads_root.mkdir(parents=True, exist_ok=True)
    return app_client


class Env:
    def __init__(self, client, tmp_path):
        self.client, self.tmp = client, tmp_path
        self.db = client.app.state.database
        self.owner = client.app.state.admin_user_id
        self.root = client.app.state.upload_receipt.uploads_root
        self.staged = stage_zip(self.db, self.root, tmp_path, entries(4), owner_id=self.owner)
        zip_worker(self.db, self.root, tmp_path).process_one()
        self.kids = {k["member_order_key"]: k for k in children_of(self.db, self.staged)}
        assert len(self.kids) == 4
        self.parent = self.staged["item_uuid"]

    def delete(self, uid, headers=None):
        return self.client.delete(f"/tracks/uploads/items/{uid}", headers=headers)

    def set_state(self, name, state, **cols):
        sets = ", ".join(f"{k} = ?" for k in {"state": 0, **cols})
        sql(self.db, f"UPDATE upload_items SET {sets} WHERE item_uuid = ?",
            (state, *cols.values(), self.kids[name]["item_uuid"]))

    def source(self, name):
        return Path(self.kids[name]["source_path"])

    def row(self, name):
        return item_row(self.db, {"owner_id": self.owner, "item_uuid": self.kids[name]["item_uuid"]})


@pytest.fixture
def env(client, tmp_path):
    yield Env(client, tmp_path)


def mixed(env):
    env.set_state("a.flac", "review_ready", kind="audio")
    # b.flac stays validating (published, with its source)
    env.set_state("c.flac", "imported", kind="audio", result_track_uuid=str(uuid.uuid4()), result_revision=1)
    env.set_state("d.flac", "committing", kind="audio")


def test_cancelling_an_expanded_parent_cancels_only_uncommitted_children(env):
    mixed(env)
    before = {n: env.row(n) for n in env.kids}
    response = env.delete(env.parent)
    assert response.status_code == 200, response.text
    assert (response.json()["item_uuid"], response.json()["state"]) == (env.parent, "expanded")
    for name in ("a.flac", "b.flac"):
        row = env.row(name)
        assert row["state"] == "cancelled" and row["source_path"] is None
        assert not env.source(name).exists()
        assert rows_of(env.db, [row["item_uuid"]]) == []
    for name in ("c.flac", "d.flac"):
        assert env.row(name) == before[name]
        assert env.source(name).exists()
    assert env.row("b.flac")["cancel_requested"] == 1
    after = all_rows(env.db, env.owner)
    files = files_under(env.root)
    again = env.delete(env.parent)
    assert again.status_code == 200 and again.json()["state"] == "expanded"
    assert all_rows(env.db, env.owner) == after and files_under(env.root) == files


def test_cancelling_one_child_leaves_parent_and_siblings(env):
    parent_before = item_row(env.db, env.staged)
    siblings = {n: env.row(n) for n in env.kids if n != "a.flac"}
    response = env.delete(env.kids["a.flac"]["item_uuid"])
    assert response.status_code == 200, response.text
    assert env.row("a.flac")["state"] == "cancelled"
    assert item_row(env.db, env.staged) == parent_before
    for name, row in siblings.items():
        assert env.row(name) == row and env.source(name).exists()


def test_another_users_delete_of_my_parent_is_not_found(env):
    mixed(env)
    _, headers = _second_user_client(env.client)
    before, files = all_rows(env.db, env.owner), files_under(env.root)
    response = env.delete(env.parent, headers=headers)
    assert response.status_code == 404
    assert response.json()["detail"]["error"] == "upload_item_not_found"
    assert all_rows(env.db, env.owner) == before and files_under(env.root) == files
