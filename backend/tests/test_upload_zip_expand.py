"""7A.2d S3 (spec §5 "ZIP": "Create a durable ordered child manifest with
stable item UUIDs once ... Extract to opaque per-child files, not
archive-provided paths. Stage all members before marking children
review_ready. No watcher sees partial archive members."; §3 `expanded`: ZIP
parent terminal transfer state, children have independent review/import
statuses; "Expanding work reserves worst-case bounded output before
starting"): the validation worker's zip handler expands a received ZIP."""

import hashlib
import uuid
import zipfile
from pathlib import Path

import pytest

from tests.identity_worker_fixtures import make_db, sql
from tests.owned_database import add_test_user
from tests.upload_validation_fixtures import FakeProbe, item_row, source_rows
from tests.upload_zip_fixtures import (
    Entry, LedgerSpy, children_of, files_under, make_expander, make_ledger, stage_zip, zip_worker,
)

B, A = b"B" * 30, bytes(range(40))
NAMES = ("disc1/02.flac", "disc2/01.flac")
PARTS = {"disc1", "disc2", "01.flac", "02.flac", "cover.jpg", "notes.txt"}


@pytest.fixture
def db(tmp_path):
    return make_db(tmp_path)


@pytest.fixture
def root(tmp_path):
    path = tmp_path / "music" / ".uploads"
    path.mkdir(parents=True)
    return path


def album(a=A, b=B):
    return [Entry("disc2/01.flac", b), Entry("disc1/02.flac", a), Entry("cover.jpg", b"jpg"),
            Entry("notes.txt", b"txt"), Entry("disc1", is_dir=True)]


@pytest.fixture
def expanded(db, root, tmp_path):
    staged = stage_zip(db, root, tmp_path, album())
    spy = LedgerSpy(make_ledger(db, tmp_path))
    probe = FakeProbe()
    worker = zip_worker(db, root, tmp_path, expander=make_expander(db, root, tmp_path, ledger=spy), probe=probe)
    result = worker.process_one()
    return staged, worker, spy, probe, result


def test_parent_is_expanded_and_archive_gone(db, expanded):
    staged, _, _, _, result = expanded
    assert result == "expanded"
    row = item_row(db, staged)
    assert (row["state"], row["kind"], row["skipped_members"]) == ("expanded", "zip", 2)
    assert row["lease_boot_id"] is None and row["error_code"] is None and row["source_path"] is None
    assert not staged["source"].exists()
    assert sql(db, "SELECT * FROM storage_reservations WHERE subject_ref = ?", (staged["item_uuid"],)) == []
    assert sql(db, "SELECT * FROM storage_reservations WHERE purpose = 'upload_expand'") == []


def test_children_manifest(db, expanded):
    staged, *_ = expanded
    parent = item_row(db, staged)
    kids = children_of(db, staged)
    assert [k["member_order_key"] for k in kids] == list(NAMES)
    assert [k["filename"] for k in kids] == list(NAMES)
    sizes = {"disc1/02.flac": A, "disc2/01.flac": B}
    for k in kids:
        data = sizes[k["member_order_key"]]
        assert k["parent_item_uuid"] == staged["item_uuid"] and k["batch_uuid"] == staged["batch_uuid"]
        assert k["selection_index"] == parent["selection_index"]
        assert k["expected_bytes"] == k["received_bytes"] == len(data)
        assert k["expected_sha256"] is None
        assert k["received_sha256"] == hashlib.sha256(data).hexdigest()
        assert k["state"] == "validating" and k["lease_boot_id"] is None and k["kind"] is None
        assert str(uuid.UUID(k["item_uuid"])) == k["item_uuid"] and k["item_uuid"] != staged["item_uuid"]


def test_child_sources_and_reservations(db, root, expanded):
    staged, *_ = expanded
    data = {"disc1/02.flac": A, "disc2/01.flac": B}
    for k in children_of(db, staged):
        expect = root / str(staged["owner_id"]) / staged["batch_uuid"] / k["item_uuid"] / "source"
        assert k["source_path"] == str(expect)
        assert expect.read_bytes() == data[k["member_order_key"]]
        [r] = source_rows(db, {"owner_id": staged["owner_id"], "item_uuid": k["item_uuid"]})
        assert (r["purpose"], r["bytes"]) == ("upload_source", len(data[k["member_order_key"]]))
        rows = sql(db, "SELECT lease_boot_id FROM storage_reservations WHERE subject_ref = ?", (k["item_uuid"],))
        assert rows == [{"lease_boot_id": None}]


def test_tree_has_only_child_sources_and_opaque_names(db, root, expanded):
    staged, *_ = expanded
    sources = {Path(k["source_path"]) for k in children_of(db, staged)}
    assert files_under(root) == sources
    for p in root.rglob("*"):
        assert not (set(p.relative_to(root).parts) & PARTS)


def test_worst_case_reserved_first(expanded):
    staged, _, spy, _, _ = expanded
    [r] = [r for r in spy.reserves if r["purpose"] == "upload_expand"]
    assert r["nbytes"] == 70 and r["owner_id"] == staged["owner_id"]


def test_children_then_validate_one_by_one(db, expanded):
    staged, worker, _, probe, _ = expanded
    kids = children_of(db, staged)
    for _ in kids:
        worker.process_one()
    after = children_of(db, staged)
    assert all(k["state"] == "review_ready" and k["kind"] == "audio" for k in after)
    assert item_row(db, staged)["state"] == "expanded"
    assert {c["path"] for c in probe.calls} == {Path(k["source_path"]) for k in kids}
    assert staged["source"] not in {c["path"] for c in probe.calls}


def test_two_users_same_ids(db, root, tmp_path):
    sam = add_test_user(db, "sam")
    batch, item = str(uuid.uuid4()), str(uuid.uuid4())
    mine = stage_zip(db, root, tmp_path, album(b"a" * 40, b"b" * 30), batch_uuid=batch, item_uuid=item, progress_at=1)
    theirs = stage_zip(db, root, tmp_path, album(b"s" * 40, b"t" * 30), owner_id=sam,
                       batch_uuid=batch, item_uuid=item, progress_at=2)
    worker = zip_worker(db, root, tmp_path)
    assert worker.process_one() == "expanded"
    assert worker.process_one() == "expanded"
    for staged, first in ((mine, b"a"), (theirs, b"s")):
        kids = children_of(db, staged)
        assert len(kids) == 2
        mine_root = root / str(staged["owner_id"])
        for k in kids:
            assert Path(k["source_path"]).is_relative_to(mine_root)
        assert Path(kids[0]["source_path"]).read_bytes() == first * 40
    assert len(files_under(root)) == 4


def test_archive_without_audio(db, root, tmp_path):
    staged = stage_zip(db, root, tmp_path, [Entry("notes.txt", b"n")])
    assert zip_worker(db, root, tmp_path).process_one() == "expanded"
    row = item_row(db, staged)
    assert (row["state"], row["skipped_members"]) == ("expanded", 1)
    assert children_of(db, staged) == [] and not staged["source"].exists()
    assert files_under(root) == set()
