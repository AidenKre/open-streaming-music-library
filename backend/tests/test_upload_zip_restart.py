"""7A.2d S5 (spec §5 "Create a durable ordered child manifest with stable
item UUIDs once; restart/re-extraction reuses those IDs. Stage all members
before marking children review_ready."; exit proof "restart mid-expansion
reuses child UUIDs"): a stop during staging leaves the manifest, releases
the parent and its reservation; the next boot re-runs the expansion with the
same child ids."""

from pathlib import Path

import pytest

from app.services.upload_validation import reconcile_upload_validation
from tests.identity_worker_fixtures import make_db, sql
from tests.upload_validation_fixtures import FakeProbe, item_row
from tests.upload_zip_fixtures import (
    CallbackFiles, Entry, children_of, files_under, make_expander, make_ledger, stage_zip, zip_worker,
)

ONE, TWO = "disc1/one.flac", "disc1/two.flac"
DATA = {ONE: bytes(range(60)), TWO: bytes(range(60))[::-1]}
BOOT2 = "boot-2"


@pytest.fixture
def db(tmp_path):
    return make_db(tmp_path)


@pytest.fixture
def root(tmp_path):
    path = tmp_path / "music" / ".uploads"
    path.mkdir(parents=True)
    return path


@pytest.fixture
def stopped(db, root, tmp_path):
    """(staged, children-by-name before restart) after a stop during the 2nd member's first write."""
    staged = stage_zip(db, root, tmp_path, [Entry(n, d) for n, d in DATA.items()])
    seam = CallbackFiles()
    worker = zip_worker(db, root, tmp_path, expander=make_expander(db, root, tmp_path, files=seam))
    seam.callback = worker.request_stop
    assert worker.process_one() == "interrupted"
    return staged, {c["member_order_key"]: c for c in children_of(db, staged)}


def second_worker(db, root, tmp_path, probe=None):
    expander = make_expander(db, root, tmp_path, ledger=make_ledger(db, tmp_path, boot_id=BOOT2), boot_id=BOOT2)
    return zip_worker(db, root, tmp_path, expander=expander, boot_id=BOOT2, probe=probe)


def test_stop_mid_expansion_leaves_manifest_and_releases_parent(db, root, stopped):
    staged, kids = stopped
    row = item_row(db, staged)
    assert (row["state"], row["kind"], row["lease_boot_id"]) == ("validating", "zip", None)
    assert set(kids) == {ONE, TWO}
    assert all(c["source_path"] is None and c["state"] == "validating" for c in kids.values())
    assert sql(db, "SELECT * FROM storage_reservations WHERE purpose = 'upload_expand'") == []
    assert staged["source"].exists()


def test_restart_reuses_child_uuids(db, root, tmp_path, stopped):
    staged, kids = stopped
    assert second_worker(db, root, tmp_path).process_one() == "expanded"
    after = children_of(db, staged)
    assert {c["member_order_key"]: c["item_uuid"] for c in after} == {k: v["item_uuid"] for k, v in kids.items()}
    assert item_row(db, staged)["state"] == "expanded"
    sources = {Path(c["source_path"]) for c in after}
    assert files_under(root) == sources
    for c in after:
        assert Path(c["source_path"]).read_bytes() == DATA[c["member_order_key"]]


def test_leftover_parts_and_stale_source_are_overwritten(db, root, tmp_path, stopped):
    staged, kids = stopped
    folders = {n: root / str(staged["owner_id"]) / staged["batch_uuid"] / c["item_uuid"] for n, c in kids.items()}
    for folder in folders.values():
        folder.mkdir(parents=True, exist_ok=True)
        (folder / "source.part").write_bytes(b"junk")
    (folders[ONE] / "source").write_bytes(b"stale junk")
    assert second_worker(db, root, tmp_path).process_one() == "expanded"
    assert not [p for p in root.rglob("*") if p.name.endswith(".part")]
    for c in children_of(db, staged):
        assert Path(c["source_path"]).read_bytes() == DATA[c["member_order_key"]]
    assert len(files_under(root)) == 2


def test_children_are_never_claimed_before_the_parent_expands(db, root, tmp_path, stopped):
    staged, kids = stopped
    sql(db, "UPDATE upload_items SET progress_at = 0 WHERE parent_item_uuid = ?", (staged["item_uuid"],))
    probe = FakeProbe()
    worker = second_worker(db, root, tmp_path, probe=probe)
    assert worker.process_one() == "expanded"
    assert probe.calls == []
    assert item_row(db, staged)["state"] == "expanded"


def test_dead_lease_is_reconciled_then_expanded_with_same_ids(db, root, tmp_path, stopped):
    staged, kids = stopped
    sql(db, "UPDATE upload_items SET lease_boot_id = 'boot-dead' WHERE item_uuid = ?", (staged["item_uuid"],))
    reconcile_upload_validation(db, boot_id=BOOT2)
    assert item_row(db, staged)["lease_boot_id"] is None
    assert second_worker(db, root, tmp_path).process_one() == "expanded"
    after = {c["member_order_key"]: c["item_uuid"] for c in children_of(db, staged)}
    assert after == {k: v["item_uuid"] for k, v in kids.items()}
