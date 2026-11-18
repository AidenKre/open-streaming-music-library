"""7A.2c review r1 R1 (blocker, SC-28) and R8: two users may hold the same
batch and item uuids (decision O2: ids are per owner), so nothing on disk or in
the database may be shared by them. The staged file lives under the owner's
own folder, ``.uploads/<owner_id>/<batch>/<item>/``, and every worker and
request path touches only its own owner's row."""

import hashlib
from pathlib import Path

import pytest

from app.services.storage_ledger import UPLOAD_SOURCE
from app.services.upload_errors import probe_timeout, upload_invalid_audio
from app.services.upload_validation import ValidationFailed
from tests.identity_worker_fixtures import sql
from tests.test_uploads_api import _second_user_client, allocate, batch, uid
from tests.upload_validation_fixtures import (
    FakeProbe,
    identity_row,
    item_row,
    make_worker,
    report_of,
    source_rows,
    stage_item,
)

NOW = 1_700_000_000
BATCH, ITEM = "b2000000-0000-4000-8000-000000000001", "b2000000-0000-4000-8000-000000000002"


@pytest.fixture
def client(app_client):
    from app.routers.uploads import upload_clock

    app_client.app.dependency_overrides[upload_clock] = lambda: NOW
    app_client.app.state.upload_receipt.uploads_root.mkdir(parents=True, exist_ok=True)
    return app_client


def _alloc_and_put(client, content, headers=None):
    body = batch([{"item_uuid": uid(1), "filename": "a.flac", "byte_length": len(content),
                   "sha256": hashlib.sha256(content).hexdigest()}])
    kw = {"headers": headers} if headers else {}
    assert allocate(client, body, **kw).status_code == 201
    response = client.put(f"/tracks/uploads/items/{uid(1)}/content", content=content, **kw)
    assert response.status_code == 200, response.text


def test_the_same_ids_of_two_users_stage_two_files(client):
    db = client.app.state.database
    root = client.app.state.upload_receipt.uploads_root
    alice = client.app.state.admin_user_id
    _alloc_and_put(client, b"ALICE-AUDIO")
    make_worker(db, root).process_one()
    sam, sam_headers = _second_user_client(client)

    _alloc_and_put(client, b"SAM-BYTES!!", headers=sam_headers)

    paths = {owner: Path(item_row(db, {"owner_id": owner, "item_uuid": uid(1)})["source_path"])
             for owner in (alice, sam)}
    assert paths[alice] != paths[sam]
    assert {owner: p.relative_to(root).parts[0] for owner, p in paths.items()} == {
        alice: str(alice), sam: str(sam)}
    assert client.get(f"/tracks/uploads/items/{uid(1)}/preview").content == b"ALICE-AUDIO"


def test_one_users_cancel_never_touches_the_others_staged_file(client):
    db = client.app.state.database
    root = client.app.state.upload_receipt.uploads_root
    _alloc_and_put(client, b"ALICE-AUDIO")
    sam, sam_headers = _second_user_client(client)
    _alloc_and_put(client, b"SAM-BYTES!!", headers=sam_headers)
    worker = make_worker(db, root)
    worker.process_one()
    worker.process_one()

    assert client.delete(f"/tracks/uploads/items/{uid(1)}", headers=sam_headers).status_code == 200

    response = client.get(f"/tracks/uploads/items/{uid(1)}/preview")
    assert (response.status_code, response.content) == (200, b"ALICE-AUDIO")


# ── R8: every worker and request path is owner-scoped (same ids, two users) ──

@pytest.fixture
def pair(client):
    db = client.app.state.database
    root = client.app.state.upload_receipt.uploads_root
    alice = client.app.state.admin_user_id
    sam, sam_headers = _second_user_client(client)
    mine = stage_item(db, root, owner_id=alice, batch_uuid=BATCH, item_uuid=ITEM, content=b"alice", progress_at=1)
    theirs = stage_item(db, root, owner_id=sam, batch_uuid=BATCH, item_uuid=ITEM, content=b"sam", progress_at=2)
    return db, root, mine, theirs, sam_headers


@pytest.fixture
def pair_db(tmp_path):
    """``pair`` without the app: the cases that call no HTTP route need only the
    database (a plain ``Database``, as the app uses, two real users, the same
    staged rows) and the worker."""
    from app.database.database import Database, DatabaseContext
    from tests.identity_worker_fixtures import INIT_SQL
    from tests.owned_database import add_test_user

    db = Database(DatabaseContext(database_path=tmp_path / "db.sqlite", init_sql_path=INIT_SQL))
    assert db.initialize()
    root = tmp_path / "music" / ".uploads"
    root.mkdir(parents=True)
    alice, sam = add_test_user(db, "alice"), add_test_user(db, "sam")
    mine = stage_item(db, root, owner_id=alice, batch_uuid=BATCH, item_uuid=ITEM, content=b"alice", progress_at=1)
    theirs = stage_item(db, root, owner_id=sam, batch_uuid=BATCH, item_uuid=ITEM, content=b"sam", progress_at=2)
    return db, root, mine, theirs, None


def _probe_failing_for(path, error):
    class PathProbe(FakeProbe):
        def __call__(self, p, **kwargs):
            if Path(p) == path:
                raise ValidationFailed(error)
            return super().__call__(p, **kwargs)

    return PathProbe()


def test_both_users_items_are_validated_each_as_their_own(pair_db):
    db, root, mine, theirs, _ = pair_db
    worker = make_worker(db, root)

    worker.process_one()
    worker.process_one()

    for staged in (mine, theirs):
        assert item_row(db, staged)["state"] == "review_ready"
        assert identity_row(db, staged)["owner_id"] == staged["owner_id"]
        assert report_of(db, staged)["matches"] == []  # never each other
    assert identity_row(db, mine)["exact_digest"] != identity_row(db, theirs)["exact_digest"]


def test_one_users_failure_never_touches_the_others_item(pair_db):
    db, root, mine, theirs, _ = pair_db
    worker = make_worker(db, root, probe=_probe_failing_for(theirs["source"], upload_invalid_audio()))

    worker.process_one()
    worker.process_one()

    assert item_row(db, theirs)["state"] == "failed"
    assert item_row(db, mine)["state"] == "review_ready"
    assert mine["source"].read_bytes() == b"alice"
    assert source_rows(db, mine) == [{"purpose": UPLOAD_SOURCE, "bytes": 5}]


def test_one_users_retry_never_touches_the_others_item(client, pair):
    db, root, mine, theirs, sam_headers = pair
    make_worker(db, root, probe=_probe_failing_for(theirs["source"], probe_timeout())).process_one()
    make_worker(db, root, probe=_probe_failing_for(theirs["source"], probe_timeout())).process_one()
    before = item_row(db, mine)

    response = client.post(f"/tracks/uploads/items/{ITEM}/retry", json={"expected_review_version": 0},
                           headers=sam_headers)

    assert (response.status_code, response.json()["state"]) == (200, "validating")
    assert item_row(db, mine) == before


def test_a_stale_step_of_one_user_never_releases_the_others_lease(pair_db):
    db, root, mine, theirs, _ = pair_db
    sql(db, "UPDATE upload_items SET lease_boot_id = 'boot-current' WHERE owner_id = ? AND item_uuid = ?",
        (mine["owner_id"], ITEM))
    probe = FakeProbe()
    probe.mid = lambda: sql(db, "UPDATE upload_items SET review_version = 7 WHERE owner_id = ? AND item_uuid = ?",
                            (theirs["owner_id"], ITEM))

    make_worker(db, root, probe=probe).process_one()  # takes sam's item (alice's is held)

    assert item_row(db, mine)["lease_boot_id"] == "boot-current"
    assert item_row(db, mine)["state"] == "validating"


# R8 (continued): both users' rows in the same state at the same time, so a
# write that lost its owner predicate would reach the other user's row.

def _rows(db, staged):
    item = item_row(db, staged)
    return item, identity_row(db, staged), source_rows(db, staged)


@pytest.mark.parametrize("start", ["duplicate_conflict", "failed-with-source", "failed-without-source"])
def test_a_retry_touches_only_the_callers_row_while_the_other_is_in_the_same_state(client, pair, start):
    db, root, mine, theirs, sam_headers = pair
    worker = make_worker(db, root)
    worker.process_one()
    worker.process_one()
    for staged in (mine, theirs):
        if start == "duplicate_conflict":
            sql(db, "UPDATE upload_items SET state = 'duplicate_conflict' WHERE owner_id = ? AND item_uuid = ?",
                (staged["owner_id"], ITEM))
        else:
            sql(db, "UPDATE upload_items SET state = 'failed', error_code = 'probe_timeout', error_retryable = 1 "
                    "WHERE owner_id = ? AND item_uuid = ?", (staged["owner_id"], ITEM))
    if start == "failed-without-source":
        theirs["source"].unlink()
    before = _rows(db, mine)

    response = client.post(f"/tracks/uploads/items/{ITEM}/retry", json={"expected_review_version": 0},
                           headers=sam_headers)

    assert response.status_code == 200, response.text
    # The caller's own source decides (alice's file is still there).
    assert response.json()["state"] == ("allocated" if start == "failed-without-source" else "validating")
    assert _rows(db, mine) == before


def test_a_failure_touches_only_its_owners_row_while_the_other_is_held(pair_db):
    db, root, mine, theirs, _ = pair_db
    # Alice's item is held by this very process (a step of hers in flight).
    sql(db, "UPDATE upload_items SET lease_boot_id = 'boot-current' WHERE owner_id = ? AND item_uuid = ?",
        (mine["owner_id"], ITEM))
    before = item_row(db, mine)

    make_worker(db, root, probe=_probe_failing_for(theirs["source"], probe_timeout())).process_one()

    assert item_row(db, theirs)["state"] == "failed"
    assert item_row(db, mine) == before


def test_a_stale_result_is_never_written_because_the_other_users_row_still_matches(pair_db):
    db, root, mine, theirs, _ = pair_db
    sql(db, "UPDATE upload_items SET lease_boot_id = 'boot-current' WHERE owner_id = ? AND item_uuid = ?",
        (mine["owner_id"], ITEM))
    probe = FakeProbe()
    probe.mid = lambda: sql(db, "UPDATE upload_items SET review_version = 4 WHERE owner_id = ? AND item_uuid = ?",
                            (theirs["owner_id"], ITEM))

    make_worker(db, root, probe=probe).process_one()

    row = item_row(db, theirs)
    assert (row["state"], row["duplicate_report"]) == ("validating", None)
    assert identity_row(db, theirs) is None


def test_the_check_reads_back_the_callers_own_identity(pair_db):
    from tests.identity_worker_fixtures import add_track
    from tests.upload_validation_fixtures import exact_for

    db, root, mine, theirs, _ = pair_db
    make_worker(db, root).process_one()  # alice's item first: her identity row exists
    track = add_track(db, "/m/sams.flac", owner_id=theirs["owner_id"], identity={
        "exact_state": "current", "exact_kind": "pcm_sha256", "exact_digest": exact_for(b"sam").digest,
        "sample_rate_hz": 44100, "channels": 2, "bits_per_sample": 16, "match_state": "current"})

    make_worker(db, root).process_one()

    assert [m["id"] for m in report_of(db, theirs)["matches"]] == [track]
