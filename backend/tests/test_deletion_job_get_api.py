"""Piece 8A.2b S6 (spec §4 GET row, §5 "Aggregate job status is derived from
target outcomes", SC-22, SC-28 rule 4, plan O12; review 8-U01, 8-U03):
``GET /tracks/deletions/{operation_uuid}``.

The job answers each target's outcome in request order (status, stable error
code, tombstone revision, bounded detail codes; never a path) and an aggregate
derived from the items: ``pending`` (all pending), ``running`` (some item not
finished), ``succeeded`` (all deleted or already deleted), ``failed`` (none
deleted) or ``partial``. It stays readable with the switch off. Another
user's job answers exactly like an unknown UUID: 404 ``deletion_job_not_found``.
"""

import sqlite3

import pytest

from app.library import Library
from app.models.deletions import DeletionJobRequest
from tests.owned_database import add_test_user

OP = "11111111-1111-4111-8111-111111111111"
UNKNOWN_OP = "00000000-0000-4000-8000-0000000000ff"
TARGETS = [f"{i}aaaaaaa-0000-4000-8000-00000000000{i}" for i in range(1, 4)]


@pytest.fixture
def client(open_app_client):
    with open_app_client(env={"LIBRARY_DELETE_ENABLED": "true"}) as client:
        yield client


@pytest.fixture
def switched_off(open_app_client):
    with open_app_client() as client:
        yield client


def _me(client):
    return Library(client.app.state.database, client.app.state.admin_user_id)


def _create(library, targets=TARGETS, op=OP, now=700):
    request = DeletionJobRequest.model_validate({
        "operation_uuid": op,
        "targets": [{"uuid_id": u, "base_revision": i + 1} for i, u in enumerate(targets)],
        "confirmed_count": len(targets),
    })
    assert library.create_deletion_job(request, now=now)


def _set(client, uuid_id, status, *, error_code=None, tombstone_revision=None, detail_json=None):
    conn = sqlite3.connect(client.app.state.database.context.database_path)
    try:
        conn.execute(
            "UPDATE deletion_job_items SET status = ?, error_code = ?, tombstone_revision = ?,"
            " detail_json = ? WHERE uuid_id = ?",
            (status, error_code, tombstone_revision, detail_json, uuid_id),
        )
        conn.commit()
    finally:
        conn.close()


def test_a_new_job_answers_its_pending_items(client):
    _create(_me(client))

    response = client.get(f"/tracks/deletions/{OP}")

    assert response.status_code == 200, response.text
    assert response.json() == {
        "operation_uuid": OP,
        "created_at": 700,
        "status": "pending",
        "item_count": 3,
        "items": [
            {"uuid_id": u, "base_revision": i + 1, "status": "pending", "error": None,
             "tombstone_revision": None, "details": []}
            for i, u in enumerate(TARGETS)
        ],
    }


def test_each_target_outcome_is_answered(client):
    _create(_me(client))
    one, two, three = TARGETS
    _set(client, one, "deleted", tombstone_revision=41,
         detail_json='["master_missing", "storage_cleanup_pending"]')
    _set(client, two, "already_deleted", tombstone_revision=7)
    _set(client, three, "failed", error_code="not_found")

    items = client.get(f"/tracks/deletions/{OP}").json()["items"]

    assert [(i["status"], i["error"], i["tombstone_revision"], i["details"]) for i in items] == [
        ("deleted", None, 41, ["master_missing", "storage_cleanup_pending"]),
        ("already_deleted", None, 7, []),
        ("failed", "not_found", None, []),
    ]


@pytest.mark.parametrize("outcomes,aggregate", [
    (["pending", "pending", "pending"], "pending"),
    (["running", "pending", "pending"], "running"),
    (["deleted", "pending", "pending"], "running"),
    (["deleted", "already_deleted", "deleted"], "succeeded"),
    (["failed", "conflict", "busy"], "failed"),
    (["deleted", "conflict", "failed"], "partial"),
    (["already_deleted", "busy", "busy"], "partial"),
])
def test_the_aggregate_is_derived_from_the_items(client, outcomes, aggregate):
    _create(_me(client))
    for uuid_id, status in zip(TARGETS, outcomes):
        _set(
            client, uuid_id, status,
            error_code={"failed": "path_rejected", "conflict": "conflict", "busy": "busy"}.get(status),
            tombstone_revision=9 if status in ("deleted", "already_deleted") else None,
        )

    job = client.get(f"/tracks/deletions/{OP}").json()

    assert job["status"] == aggregate
    assert [i["status"] for i in job["items"]] == outcomes


def test_a_stored_value_outside_the_closed_codes_never_reaches_the_response(client):
    # Plan O12: only the closed per-target codes are answered; a stray path never is.
    _create(_me(client))
    one, two, _ = TARGETS
    _set(client, one, "failed", error_code="/music/alex/secret.flac")
    _set(client, two, "deleted", tombstone_revision=3,
         detail_json='["/music/alex/secret.flac", "master_missing"]')

    response = client.get(f"/tracks/deletions/{OP}")

    assert response.status_code == 200
    assert "/music" not in response.text and "secret" not in response.text
    items = response.json()["items"]
    assert items[0]["error"] is None
    assert items[1]["details"] == ["master_missing"]


def test_any_uuid_spelling_reaches_the_job(client):
    _create(_me(client))

    assert client.get(f"/tracks/deletions/{OP.upper()}").json()["operation_uuid"] == OP


def test_the_job_is_readable_with_the_switch_off(switched_off):
    _create(_me(switched_off))

    response = switched_off.get(f"/tracks/deletions/{OP}")

    assert response.status_code == 200, response.text
    assert response.json()["operation_uuid"] == OP


def test_an_unknown_job_is_404(client):
    response = client.get(f"/tracks/deletions/{UNKNOWN_OP}")

    assert response.status_code == 404
    detail = response.json()["detail"]
    assert (detail["error"], detail["retryable"]) == ("deletion_job_not_found", False)


def test_another_users_job_answers_exactly_like_an_unknown_one(client):
    db = client.app.state.database
    sam = Library(db, add_test_user(db, "sam"))
    _create(sam)

    foreign = client.get(f"/tracks/deletions/{OP}")
    unknown = client.get(f"/tracks/deletions/{UNKNOWN_OP}")

    assert (foreign.status_code, foreign.content) == (unknown.status_code, unknown.content)
    assert foreign.status_code == 404


def test_a_non_uuid_segment_is_404(client):
    assert client.get("/tracks/deletions/not-a-uuid").status_code == 404


def test_a_deletion_that_failed_for_an_internal_error_answers_that_code(client):
    # Sign-off DEV-8-17 item 4: a database error that is not "busy" ends the
    # target failed with its own code, answered like the other closed codes.
    _create(_me(client))
    _set(client, TARGETS[0], "failed", error_code="internal_error")

    [first, *_] = client.get(f"/tracks/deletions/{OP}").json()["items"]

    assert (first["status"], first["error"]) == ("failed", "internal_error")
