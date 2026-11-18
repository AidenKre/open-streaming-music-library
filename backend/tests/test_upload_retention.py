"""7A.3c S8 (spec §3: "Imported/cancelled/duplicate receipts remain 30 days for
UI; idempotency receipts for commit must be retained separately"; SC-16c:
receipts are not pruned): a batch whose items have all ended, that nothing on
disk or in the ledger still depends on, and that has not changed for 30 days
is pruned with its items (identity and acknowledgement rows cascade).
Operation receipts are never pruned. Replaying the allocation of a pruned
batch answers 410 ``upload_batch_expired`` and never re-creates it."""

import pytest

from app.services.upload_janitor import UploadJanitor
from tests.identity_worker_fixtures import sql
from tests.owned_database import add_test_user
from tests.upload_validation_fixtures import stage_item

DAY = 86_400
NOW = 2_000_000_000
OLD = NOW - 30 * DAY
YOUNG = OLD + 1
ENDED = {"imported": ", result_track_uuid = 't', result_revision = 1",
         "duplicate": ", result_track_uuid = 't', duplicate_kind = 'exact'",
         "expanded": ", kind = 'zip'", "cancelled": "", "expired": ""}


@pytest.fixture
def music(tmp_path):
    path = tmp_path / "music"
    (path / ".uploads").mkdir(parents=True)
    return path


def janitor(db, music, now=NOW):
    return UploadJanitor(db, uploads_root=music / ".uploads", music_library_dir=music, cover_art=None,
                         clock=lambda: now)


def ended_item(db, music, state="imported", *, updated_at=OLD, owner_id=None, batch_uuid=None):
    """An ended item whose files and quota row are already gone."""
    staged = stage_item(db, music / ".uploads", state="review_ready", owner_id=owner_id,
                        batch_uuid=batch_uuid, progress_at=0)
    owner, item = staged["owner_id"], staged["item_uuid"]
    staged["source"].unlink()
    staged["source"].parent.rmdir()
    sql(db, f"UPDATE upload_items SET state = ?{ENDED[state]}, source_path = NULL, updated_at = ?"
            " WHERE owner_id = ? AND item_uuid = ?", (state, updated_at, owner, item))
    sql(db, "UPDATE upload_batches SET updated_at = ? WHERE owner_id = ? AND batch_uuid = ?",
        (updated_at, owner, staged["batch_uuid"]))
    sql(db, "DELETE FROM storage_reservations WHERE owner_id = ? AND subject_ref = ?", (owner, item))
    return staged


def batch_rows(db, staged) -> list:
    return sql(db, "SELECT batch_uuid FROM upload_batches WHERE owner_id = ? AND batch_uuid = ?",
               (staged["owner_id"], staged["batch_uuid"]))


def item_rows(db, staged) -> list:
    return sql(db, "SELECT item_uuid FROM upload_items WHERE owner_id = ? AND batch_uuid = ?",
               (staged["owner_id"], staged["batch_uuid"]))


def add_receipt(db, staged, op):
    sql(db, "INSERT INTO operation_receipts (owner_id, operation_uuid, kind, request_hash, created_at,"
            " result_ref) VALUES (?, ?, 'upload_commit', ?, 0, ?)",
        (staged["owner_id"], op, "a" * 64, staged["item_uuid"]))


@pytest.mark.parametrize("state", sorted(ENDED))
def test_an_ended_batch_older_than_thirty_days_is_pruned_with_its_items(db, music, state):
    staged = ended_item(db, music, state)
    op = "11111111-0000-4000-8000-000000000001"
    add_receipt(db, staged, op)
    sql(db, "INSERT INTO upload_item_acknowledgements (owner_id, item_uuid, subject_kind, subject_ref)"
            " VALUES (?, ?, 'library_track', 't')", (staged["owner_id"], staged["item_uuid"]))

    janitor(db, music).run_once()

    assert batch_rows(db, staged) == []
    assert item_rows(db, staged) == []
    assert sql(db, "SELECT count(*) AS n FROM upload_item_acknowledgements")[0]["n"] == 0
    assert sql(db, "SELECT kind FROM operation_receipts WHERE operation_uuid = ?", (op,)) == [
        {"kind": "upload_commit"}]  # receipts are never pruned
    assert not (music / ".uploads" / str(staged["owner_id"]) / staged["batch_uuid"]).exists()


def test_a_batch_changed_within_thirty_days_is_kept(db, music):
    staged = ended_item(db, music, updated_at=YOUNG)

    janitor(db, music).run_once()

    assert batch_rows(db, staged) != []


def test_a_batch_with_one_recent_item_is_kept(db, music):
    old = ended_item(db, music)
    ended_item(db, music, batch_uuid=old["batch_uuid"], updated_at=YOUNG)
    sql(db, "UPDATE upload_batches SET updated_at = ? WHERE batch_uuid = ?", (OLD, old["batch_uuid"]))

    janitor(db, music).run_once()

    assert len(item_rows(db, old)) == 2


@pytest.mark.parametrize("state", ["allocated", "review_ready", "failed", "duplicate_conflict",
                                   "receiving", "validating", "committing"])
def test_a_batch_with_an_item_that_has_not_ended_is_kept(db, music, state):
    done = ended_item(db, music)
    live = stage_item(db, music / ".uploads", state="review_ready", batch_uuid=done["batch_uuid"],
                      progress_at=NOW)
    extra = ", error_code = 'x'" if state == "failed" else ""
    sql(db, f"UPDATE upload_items SET state = ?{extra}, updated_at = ? WHERE item_uuid = ?",
        (state, OLD, live["item_uuid"]))

    janitor(db, music).run_once()

    assert len(item_rows(db, done)) == 2


def test_a_batch_whose_item_still_records_a_file_is_kept(db, music, monkeypatch):
    staged = ended_item(db, music, "cancelled")
    sql(db, "UPDATE upload_items SET part_path = ? WHERE item_uuid = ?",
        (str(music / "elsewhere.part"), staged["item_uuid"]))  # outside the stage: never removed

    janitor(db, music).run_once()

    assert batch_rows(db, staged) != []


def test_a_batch_with_a_reservation_left_is_kept(db, music):
    staged = ended_item(db, music, "cancelled")
    sql(db, "INSERT INTO storage_reservations (owner_id, purpose, subject_ref, bytes, lease_boot_id,"
            " created_at) VALUES (?, 'upload_source', ?, 5, NULL, 0)", (staged["owner_id"], staged["item_uuid"]))

    janitor(db, music).run_once()

    assert batch_rows(db, staged) != []


def test_a_batch_with_a_journal_row_left_is_kept(db, music):
    staged = ended_item(db, music, "imported")
    op = "22222222-0000-4000-8000-000000000002"
    add_receipt(db, staged, op)
    work = music / ".uploads" / "elsewhere"  # not in the owner's stage: the clean-up keeps the row
    sql(db, "INSERT INTO upload_commit_journal (owner_id, operation_uuid, item_uuid, state,"
            " base_review_version, reserved_track_uuid, edits, write_tags, acknowledged_duplicates,"
            " source_path, work_path, created_at, updated_at) VALUES (?, ?, ?, 'imported', 0, 't', '{}', 0,"
            " '{}', ?, ?, 0, 0)",
        (staged["owner_id"], op, staged["item_uuid"], str(staged["source"]), str(work)))
    work.write_bytes(b"?")
    sql(db, "INSERT INTO storage_reservations (owner_id, purpose, subject_ref, bytes, lease_boot_id,"
            " created_at) VALUES (?, 'upload_work', ?, 1, NULL, 0)", (staged["owner_id"], op))

    janitor(db, music).run_once()

    assert batch_rows(db, staged) != []


def test_a_batch_folder_holding_an_unknown_file_is_kept(db, music):
    staged = ended_item(db, music)
    stray = music / ".uploads" / str(staged["owner_id"]) / staged["batch_uuid"] / "stray.bin"
    stray.write_bytes(b"?")

    janitor(db, music).run_once()

    assert stray.read_bytes() == b"?"
    assert batch_rows(db, staged) != []


def test_only_the_old_batches_of_every_user_go(db, music):
    other = add_test_user(db, "other")
    mine_old = ended_item(db, music)
    theirs_old = ended_item(db, music, owner_id=other)
    theirs_young = ended_item(db, music, owner_id=other, updated_at=YOUNG)

    janitor(db, music).run_once()

    assert batch_rows(db, mine_old) == []
    assert batch_rows(db, theirs_old) == []
    assert batch_rows(db, theirs_young) != []


def test_an_expired_item_goes_thirty_days_after_it_expired(db, music):
    staged = stage_item(db, music / ".uploads", state="review_ready", progress_at=NOW - 7 * DAY)
    janitor(db, music).run_once()  # expires now
    assert batch_rows(db, staged) != []

    janitor(db, music, now=NOW + 30 * DAY - 1).run_once()
    assert batch_rows(db, staged) != []

    janitor(db, music, now=NOW + 30 * DAY).run_once()
    assert batch_rows(db, staged) == []


# ── allocation replay after pruning (API) ────────────────────────────────

def test_replaying_the_allocation_of_a_pruned_batch_answers_410(app_client):
    from app.routers.uploads import upload_clock

    app_client.app.dependency_overrides[upload_clock] = lambda: NOW
    body = {"batch_uuid": "33333333-0000-4000-8000-000000000003",
            "items": [{"item_uuid": "44444444-0000-4000-8000-000000000004", "filename": "a.flac",
                       "byte_length": 3, "sha256": "b" * 64}]}
    assert app_client.post("/tracks/uploads", json=body).status_code == 201
    assert app_client.delete(f"/tracks/uploads/items/{body['items'][0]['item_uuid']}").status_code == 200
    db = app_client.app.state.database
    root = app_client.app.state.upload_receipt.uploads_root
    UploadJanitor(db, uploads_root=root, music_library_dir=root.parent, cover_art=None,
                  clock=lambda: NOW + 30 * DAY).run_once()
    assert app_client.get(f"/tracks/uploads/{body['batch_uuid']}").status_code == 404

    response = app_client.post("/tracks/uploads", json=body)

    assert response.status_code == 410, response.text
    detail = response.json()["detail"]
    assert (detail["error"], detail["retryable"]) == ("upload_batch_expired", False)
    assert app_client.get(f"/tracks/uploads/{body['batch_uuid']}").status_code == 404
    changed = {**body, "label": "other"}
    assert app_client.post("/tracks/uploads", json=changed).status_code == 409
