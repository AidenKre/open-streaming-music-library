"""Phase 7A.1d (spec §4 upload API rows: allocation, batch list, batch, batch
items, item status, cancel; 7-U02; SC-16b/16c/22/24/28)."""

import base64
import hashlib
import json
import sqlite3
import uuid

import pytest

from tests.test_upload_limits import EFFECTIVE_DEFAULTS

NOW = 1_700_000_000


def uid(n: int, space: int = 1) -> str:
    """A deterministic, well-formed v4 UUID with hex letters in it."""
    return str(uuid.UUID(int=(0xABCDEF << 96) + (space << 64) + n, version=4))


def item(n: int, size: int = 10, **overrides) -> dict:
    body = {
        "item_uuid": uid(n),
        "filename": f"Track {n}.flac",
        "byte_length": size,
        "sha256": hashlib.sha256(str(n).encode()).hexdigest(),
    }
    body.update(overrides)
    return body


def batch(items, batch_uuid=None, **extra) -> dict:
    return {"batch_uuid": batch_uuid or uid(0, space=2), "items": items, **extra}


def rows(client, sql, params=()):
    conn = sqlite3.connect(client.app.state.database.context.database_path)
    try:
        return conn.execute(sql, params).fetchall()
    finally:
        conn.close()


@pytest.fixture
def client(app_client):
    from app.routers.uploads import upload_clock

    app_client.app.dependency_overrides[upload_clock] = lambda: NOW
    return app_client


def allocate(client, body, **kwargs):
    return client.post("/tracks/uploads", json=body, **kwargs)


# ── S4: allocation ─────────────────────────────────────────────────────────

def test_an_allocation_answers_201_with_the_batch_items_and_limits(client):
    body = batch([item(1, 11), item(2, 22)], label="Holiday")

    response = allocate(client, body)

    assert response.status_code == 201, response.text
    data = response.json()
    assert data["limits"] == EFFECTIVE_DEFAULTS
    assert data["batch"] == {
        "batch_uuid": body["batch_uuid"],
        "label": "Holiday",
        "created_at": NOW,
        "updated_at": NOW,
        "item_count": 2,
        "state_counts": {"allocated": 2},
        "items_path": f"/tracks/uploads/{body['batch_uuid']}/items",
    }
    assert data["items"] == [
        {
            "item_uuid": spec["item_uuid"],
            "batch_uuid": body["batch_uuid"],
            "parent_item_uuid": None,
            "filename": spec["filename"],
            "selection_index": index,
            "member_order_key": "",
            "state": "allocated",
            "expected_bytes": spec["byte_length"],
            "expected_sha256": spec["sha256"],
            "received_bytes": 0,
            "review_version": 0,
            "error": None,
            "detected_metadata": None,
            "tag_write_supported": None,
            "duplicate_check": None,
            "kind": None,
            "skipped_members": None,
            "result_track_uuid": None,
            "result_revision": None,
            "duplicate_kind": None,
            "conflict_matches": None,
            "created_at": NOW,
            "updated_at": NOW,
        }
        for index, spec in enumerate(body["items"])
    ]


def test_an_allocation_persists_the_caller_s_rows_and_a_receipt(client):
    body = batch([item(1, 11), item(2, 22)])

    assert allocate(client, body).status_code == 201

    admin = client.app.state.admin_user_id
    assert rows(client, "SELECT owner_id, batch_uuid, label, created_at, updated_at FROM upload_batches") == [
        (admin, body["batch_uuid"], None, NOW, NOW)
    ]
    assert rows(
        client,
        "SELECT owner_id, item_uuid, batch_uuid, parent_item_uuid, kind, filename, selection_index, "
        "member_order_key, expected_bytes, expected_sha256, received_bytes, state, review_version, "
        "cancel_requested, created_at, updated_at, progress_at FROM upload_items ORDER BY selection_index",
    ) == [
        (admin, s["item_uuid"], body["batch_uuid"], None, None, s["filename"], i, "", s["byte_length"],
         s["sha256"], 0, "allocated", 0, 0, NOW, NOW, NOW)
        for i, s in enumerate(body["items"])
    ]
    assert rows(client, "SELECT owner_id, operation_uuid, kind, created_at, result_ref FROM operation_receipts") == [
        (admin, body["batch_uuid"], "upload_allocation", NOW, body["batch_uuid"])
    ]


def test_every_uuid_and_digest_spelling_is_stored_canonically(client):
    spec = item(1)
    body = batch(
        [{**spec, "item_uuid": spec["item_uuid"].upper(), "sha256": spec["sha256"].upper()}],
        batch_uuid=uuid.UUID(uid(0, space=2)).hex.upper(),
    )

    response = allocate(client, body)

    assert response.status_code == 201, response.text
    assert response.json()["batch"]["batch_uuid"] == uid(0, space=2)
    assert response.json()["items"][0]["item_uuid"] == spec["item_uuid"]
    assert rows(client, "SELECT batch_uuid, item_uuid, expected_sha256 FROM upload_items") == [
        (uid(0, space=2), spec["item_uuid"], spec["sha256"])
    ]


@pytest.mark.parametrize(
    "body",
    [
        pytest.param(batch([]), id="no-items"),
        pytest.param(batch([item(1), item(1)]), id="duplicate-item-uuid"),
        pytest.param(batch([item(1), {**item(2), "item_uuid": uid(1).upper()}]), id="duplicate-item-uuid-spelling"),
        pytest.param(batch([item(1, sha256="0" * 63)]), id="short-digest"),
        pytest.param(batch([item(1, sha256="g" * 64)]), id="non-hex-digest"),
        pytest.param(batch([item(1, size=0)]), id="zero-bytes"),
        pytest.param(batch([item(1, size=-1)]), id="negative-bytes"),
        pytest.param(batch([item(1, filename="")]), id="empty-filename"),
        pytest.param(batch([item(1, filename="x" * 256)]), id="long-filename"),
        pytest.param(batch([item(1, item_uuid="nope")]), id="bad-item-uuid"),
        pytest.param(batch([item(1)], batch_uuid="nope"), id="bad-batch-uuid"),
        pytest.param(batch([item(1)], label="x" * 201), id="long-label"),
        pytest.param(batch([item(1)], surprise=1), id="unknown-field"),
        pytest.param(batch([{**item(1), "surprise": 1}]), id="unknown-item-field"),
        pytest.param({"items": [item(1)]}, id="no-batch-uuid"),
    ],
)
def test_an_invalid_body_is_a_422_and_allocates_nothing(client, body):
    response = allocate(client, body)

    assert response.status_code == 422, response.text
    detail = response.json()["detail"]
    assert isinstance(detail, list) and detail
    assert all("input" not in entry for entry in detail)
    assert rows(client, "SELECT count(*) FROM upload_batches") == [(0,)]
    assert rows(client, "SELECT count(*) FROM operation_receipts") == [(0,)]


def test_a_malformed_json_body_is_a_422(client):
    response = client.post(
        "/tracks/uploads", content=b"{not json", headers={"Content-Type": "application/json"}
    )

    assert response.status_code == 422


def test_a_body_over_256_kib_is_refused_before_validation(client):
    response = allocate(client, batch([item(1)], label="x" * (256 * 1024)))

    assert response.status_code == 413
    assert response.json()["detail"]["error"] == "request_too_large"
    assert rows(client, "SELECT count(*) FROM upload_batches") == [(0,)]


# ── S5: limits are checked before anything is allocated ────────────────────

@pytest.fixture
def small(open_app_client):
    """A client whose byte limits are tiny (file 100, batch 250)."""
    from app.routers.uploads import upload_clock

    env = {"UPLOAD_MAX_FILE_BYTES": "100", "UPLOAD_MAX_BATCH_BYTES": "250"}
    with open_app_client(env=env) as c:
        c.app.dependency_overrides[upload_clock] = lambda: NOW
        yield c


def assert_refused(client, response, limit, value):
    assert response.status_code == 413, response.text
    detail = response.json()["detail"]
    assert detail["error"] == "upload_limit_exceeded"
    assert detail["retryable"] is False
    assert (detail["limit"], detail["limit_value"]) == (limit, value)
    assert str(value) in detail["message"]
    root = str(client.app.state.settings.music_library_dir.parent)
    assert root not in response.text
    assert rows(client, "SELECT count(*) FROM upload_batches") == [(0,)]
    assert rows(client, "SELECT count(*) FROM upload_items") == [(0,)]
    assert rows(client, "SELECT count(*) FROM operation_receipts") == [(0,)]


@pytest.mark.parametrize("count", [1, 100])
def test_one_to_100_files_are_allocated(client, count):
    response = allocate(client, batch([item(n, 1) for n in range(count)]))

    assert response.status_code == 201, response.text
    assert len(response.json()["items"]) == count
    assert rows(client, "SELECT count(*) FROM upload_items") == [(count,)]


def test_101_files_are_refused_with_the_limit(client):
    response = allocate(client, batch([item(n, 1) for n in range(101)]))

    assert_refused(client, response, "max_files_per_batch", 100)


@pytest.mark.parametrize("size", [99, 100])
def test_a_file_at_or_below_the_file_limit_is_allocated(small, size):
    assert allocate(small, batch([item(1, size)])).status_code == 201


def test_a_file_above_the_file_limit_is_refused(small):
    response = allocate(small, batch([item(1, 50), item(2, 101)]))

    assert_refused(small, response, "max_file_bytes", 100)
    assert response.json()["detail"]["item_uuid"] == uid(2)


@pytest.mark.parametrize("sizes", [[100, 100, 49], [100, 100, 50]], ids=["below", "at"])
def test_a_batch_at_or_below_the_batch_limit_is_allocated(small, sizes):
    response = allocate(small, batch([item(n, s) for n, s in enumerate(sizes)]))

    assert response.status_code == 201, response.text


def test_a_batch_above_the_batch_limit_is_refused(small):
    response = allocate(small, batch([item(n, s) for n, s in enumerate([100, 100, 51])]))

    assert_refused(small, response, "max_batch_bytes", 250)


def test_the_refusal_names_the_effective_limit_not_the_raw_setting(open_app_client):
    env = {"UPLOAD_MAX_FILE_BYTES": "500", "UPLOAD_MAX_BATCH_BYTES": "200"}
    with open_app_client(env=env) as c:
        response = allocate(c, batch([item(1, 201)]))

        assert_refused(c, response, "max_file_bytes", 200)


def test_a_refused_batch_id_can_still_be_allocated(small):
    body = batch([item(1, 101)])
    assert allocate(small, body).status_code == 413

    response = allocate(small, {**body, "items": [item(1, 100)]})

    assert response.status_code == 201, response.text


# ── S6: allocation idempotency (SC-16c receipt) and owner-scoped ids (O2) ──

def snapshot(client):
    return (
        rows(client, "SELECT * FROM upload_batches ORDER BY owner_id, batch_uuid"),
        rows(client, "SELECT * FROM upload_items ORDER BY owner_id, item_uuid"),
        rows(client, "SELECT * FROM operation_receipts ORDER BY owner_id, operation_uuid"),
    )


def test_an_exact_retry_returns_the_same_allocation_with_200(client):
    body = batch([item(1, 11), item(2, 22)], label="Holiday")
    first = allocate(client, body)
    stored = snapshot(client)
    from app.routers.uploads import upload_clock

    client.app.dependency_overrides[upload_clock] = lambda: NOW + 60

    again = allocate(client, body)

    assert (first.status_code, again.status_code) == (201, 200)
    assert again.json() == first.json()
    assert snapshot(client) == stored


def test_a_retry_in_another_spelling_is_the_same_request(client):
    body = batch([item(1)])
    assert allocate(client, body).status_code == 201
    spec = body["items"][0]
    respelled = {
        "batch_uuid": uuid.UUID(body["batch_uuid"]).hex.upper(),
        "items": [{**spec, "item_uuid": spec["item_uuid"].upper(), "sha256": spec["sha256"].upper()}],
    }

    assert allocate(client, respelled).status_code == 200


def test_an_exact_retry_after_a_restart_returns_the_same_allocation(open_app_client):
    body = batch([item(1), item(2)])
    with open_app_client() as c:
        first = allocate(c, body)
    with open_app_client() as c:
        again = allocate(c, body)

    assert (first.status_code, again.status_code) == (201, 200)
    assert again.json() == first.json()


@pytest.mark.parametrize(
    "change",
    [
        pytest.param(lambda b: {**b, "label": "Other"}, id="label"),
        pytest.param(lambda b: {**b, "items": [b["items"][0], {**b["items"][1], "filename": "x.mp3"}]}, id="filename"),
        pytest.param(lambda b: {**b, "items": [b["items"][0], {**b["items"][1], "byte_length": 23}]}, id="bytes"),
        pytest.param(lambda b: {**b, "items": [b["items"][0], {**b["items"][1], "sha256": "a" * 64}]}, id="digest"),
        pytest.param(lambda b: {**b, "items": b["items"][::-1]}, id="order"),
        pytest.param(lambda b: {**b, "items": b["items"][:1]}, id="fewer"),
        pytest.param(lambda b: {**b, "items": [*b["items"], item(3)]}, id="more"),
        pytest.param(lambda b: {**b, "items": [b["items"][0], {**b["items"][1], "item_uuid": uid(9)}]}, id="item-uuid"),
    ],
)
def test_a_different_body_for_the_same_batch_is_a_409(client, change):
    body = batch([item(1, 11), item(2, 22)])
    assert allocate(client, body).status_code == 201
    stored = snapshot(client)

    response = allocate(client, change(body))

    assert response.status_code == 409, response.text
    detail = response.json()["detail"]
    assert (detail["error"], detail["retryable"]) == ("operation_conflict", False)
    assert snapshot(client) == stored


def test_an_item_id_already_in_another_of_my_batches_is_a_409(client):
    assert allocate(client, batch([item(1), item(2)], batch_uuid=uid(1, space=2))).status_code == 201
    stored = snapshot(client)

    response = allocate(client, batch([item(3), item(2)], batch_uuid=uid(2, space=2)))

    assert response.status_code == 409, response.text
    detail = response.json()["detail"]
    assert detail["error"] == "upload_item_conflict"
    assert detail["conflicting_item_uuids"] == [uid(2)]
    assert snapshot(client) == stored


def test_a_batch_id_used_by_another_kind_of_operation_is_a_409(client):
    admin = client.app.state.admin_user_id
    conn = sqlite3.connect(client.app.state.database.context.database_path)
    try:
        conn.execute(
            "INSERT INTO operation_receipts (owner_id, operation_uuid, kind, request_hash, created_at) "
            "VALUES (?, ?, 'upload_commit', ?, 1)",
            (admin, uid(0, space=2), "0" * 64),
        )
        conn.commit()
    finally:
        conn.close()

    response = allocate(client, batch([item(1)]))

    assert response.status_code == 409
    assert response.json()["detail"]["error"] == "operation_conflict"
    assert rows(client, "SELECT count(*) FROM upload_batches") == [(0,)]


def _second_user_client(client):
    from tests.auth_helpers import create_session
    from tests.conftest import bearer
    from tests.owned_database import add_test_user

    db = client.app.state.database
    sam = add_test_user(db, "sam")
    return sam, bearer(create_session(db, sam).token)


def test_another_users_batch_item_and_operation_ids_allocate_fresh_for_me(client):
    sam, sam_headers = _second_user_client(client)
    body = batch([item(1), item(2)], label="Sam's")
    assert allocate(client, body, headers=sam_headers).status_code == 201
    # Another operation of sam's under a uuid alex will use as a batch id.
    conn = sqlite3.connect(client.app.state.database.context.database_path)
    try:
        conn.execute(
            "INSERT INTO operation_receipts (owner_id, operation_uuid, kind, request_hash, created_at) "
            "VALUES (?, ?, 'upload_commit', ?, 1)",
            (sam, uid(9, space=2), "0" * 64),
        )
        conn.commit()
    finally:
        conn.close()
    sams = [
        rows(client, f"SELECT * FROM {table} WHERE owner_id = ? ORDER BY 2", (sam,))
        for table in ("upload_batches", "upload_items", "operation_receipts")
    ]

    # The admin reuses sam's batch and item ids with a different body: a fresh allocation.
    mine = allocate(client, {**body, "label": "Mine", "items": [item(2, 5), item(1, 6)]})
    other = allocate(client, batch([item(3)], batch_uuid=uid(9, space=2)))

    assert (mine.status_code, other.status_code) == (201, 201), (mine.text, other.text)
    assert mine.json()["batch"]["label"] == "Mine"
    assert [i["expected_bytes"] for i in mine.json()["items"]] == [5, 6]
    assert sams == [
        rows(client, f"SELECT * FROM {table} WHERE owner_id = ? ORDER BY 2", (sam,))
        for table in ("upload_batches", "upload_items", "operation_receipts")
    ]
    admin = client.app.state.admin_user_id
    assert rows(client, "SELECT count(*) FROM upload_items WHERE owner_id = ?", (admin,)) == [(3,)]


# ── S7: one batch and one item by id; foreign ids look absent ─────────────

def test_a_batch_summary_counts_its_items_by_state(client):
    body = batch([item(1), item(2), item(3)], label="Mix")
    allocated = allocate(client, body).json()

    response = client.get(f"/tracks/uploads/{body['batch_uuid']}")

    assert response.status_code == 200, response.text
    assert response.json() == allocated["batch"]


def test_an_item_reads_as_in_the_allocation(client):
    body = batch([item(1), item(2)])
    allocated = allocate(client, body).json()

    for expected in allocated["items"]:
        response = client.get(f"/tracks/uploads/items/{expected['item_uuid']}")
        assert response.status_code == 200, response.text
        assert response.json() == expected


@pytest.mark.parametrize("spell", [str.upper, lambda u: uuid.UUID(u).hex, lambda u: uuid.UUID(u).hex.upper()])
def test_any_uuid_spelling_reaches_the_same_batch_and_item(client, spell):
    body = batch([item(1)])
    allocate(client, body)

    got_batch = client.get(f"/tracks/uploads/{spell(body['batch_uuid'])}")
    got_item = client.get(f"/tracks/uploads/items/{spell(uid(1))}")

    assert got_batch.json()["batch_uuid"] == body["batch_uuid"]
    assert got_item.json()["item_uuid"] == uid(1)


def test_the_item_error_is_reported_without_internal_fields(client):
    allocate(client, batch([item(1)]))
    conn = sqlite3.connect(client.app.state.database.context.database_path)
    try:
        conn.execute(
            "UPDATE upload_items SET state = 'failed', error_code = 'probe_failed', "
            "error_message = 'Not an audio file.', error_retryable = 0, "
            "part_path = '/secret/x.part', source_path = '/secret/x' WHERE item_uuid = ?",
            (uid(1),),
        )
        conn.commit()
    finally:
        conn.close()

    response = client.get(f"/tracks/uploads/items/{uid(1)}")

    assert response.json()["state"] == "failed"
    assert response.json()["error"] == {
        "code": "probe_failed", "message": "Not an audio file.", "retryable": False,
    }
    assert "/secret" not in response.text


def _not_found(response, code):
    assert response.status_code == 404, response.text
    detail = response.json()["detail"]
    assert (detail["error"], detail["retryable"]) == (code, False)
    return response.json()


def test_an_unknown_and_a_foreign_batch_answer_the_same_404(client):
    sam, sam_headers = _second_user_client(client)
    body = batch([item(1)])
    assert allocate(client, body, headers=sam_headers).status_code == 201

    foreign = client.get(f"/tracks/uploads/{body['batch_uuid']}")
    unknown = client.get(f"/tracks/uploads/{uid(77, space=2)}")

    assert _not_found(foreign, "upload_batch_not_found") == _not_found(unknown, "upload_batch_not_found")


def test_an_unknown_and_a_foreign_item_answer_the_same_404(client):
    sam, sam_headers = _second_user_client(client)
    assert allocate(client, batch([item(1)]), headers=sam_headers).status_code == 201

    foreign = client.get(f"/tracks/uploads/items/{uid(1)}")
    unknown = client.get(f"/tracks/uploads/items/{uid(77)}")

    assert _not_found(foreign, "upload_item_not_found") == _not_found(unknown, "upload_item_not_found")


@pytest.mark.parametrize("segment", ["nope", "123", uid(1) + "x"])
def test_a_non_uuid_id_answers_404(client, segment):
    assert client.get(f"/tracks/uploads/{segment}").status_code == 404
    assert client.get(f"/tracks/uploads/items/{segment}").status_code == 404


# ── S8: the batch list, keyset pages ordered (created_at, batch_uuid) ──────

def cursor(*key) -> str:
    """The wire cursor: base64url (no padding) of the compact JSON key."""
    raw = json.dumps(list(key), separators=(",", ":")).encode()
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def set_clock(client, value):
    from app.routers.uploads import upload_clock

    client.app.dependency_overrides[upload_clock] = lambda: value


def make_batches(client, keys):
    """Allocate one single-item batch per (created_at, batch_number), in the
    given order; returns the batch uuids by key."""
    made = {}
    for n, (at, b) in enumerate(keys):
        set_clock(client, at)
        bu = uid(b, space=3)
        assert allocate(client, batch([item(1000 + n)], batch_uuid=bu)).status_code == 201
        made[(at, b)] = bu
    return made


def walk(client, path, key, limit=None):
    pages, after = [], None
    while True:
        # A keyset that repeats rows must fail, never loop forever.
        assert len(pages) < 200, "paging did not terminate"
        params = {k: v for k, v in (("after", after), ("limit", limit)) if v is not None}
        response = client.get(path, params=params)
        assert response.status_code == 200, response.text
        data = response.json()
        pages.append(data[key])
        after = data["next_after"]
        if after is None:
            return pages


def test_an_empty_list(client):
    assert client.get("/tracks/uploads").json() == {"batches": [], "next_after": None}


# Created out of order, with ties on created_at broken by batch uuid.
TIED = [(NOW + 2, 5), (NOW, 9), (NOW + 1, 3), (NOW, 2), (NOW + 2, 1), (NOW, 7), (NOW + 1, 8)]


@pytest.mark.parametrize("limit", [1, 2, 3, 7, 100])
def test_every_page_size_walks_the_same_complete_order(client, limit):
    made = make_batches(client, TIED)
    expected = [made[key] for key in sorted(TIED, key=lambda k: (k[0], uid(k[1], space=3)))]

    pages = walk(client, "/tracks/uploads", "batches", limit)

    assert [b["batch_uuid"] for page in pages for b in page] == expected
    assert all(len(page) == limit for page in pages[:-1])
    assert 0 < len(pages[-1]) <= limit


def seed_batches(client, n):
    """``n`` empty batches of the caller, written directly (review r1
    7-R1-31: allocating each over HTTP made the default-page test slow)."""
    conn = sqlite3.connect(client.app.state.database.context.database_path)
    try:
        owner = client.app.state.admin_user_id
        conn.executemany(
            "INSERT INTO upload_batches (owner_id, batch_uuid, created_at, updated_at) VALUES (?, ?, ?, ?)",
            [(owner, uid(b, space=3), NOW, NOW) for b in range(n)])
        conn.commit()
    finally:
        conn.close()


def test_the_default_page_is_25(client):
    seed_batches(client, 26)

    first = client.get("/tracks/uploads").json()
    second = client.get("/tracks/uploads", params={"after": first["next_after"]}).json()

    assert (len(first["batches"]), len(second["batches"])) == (25, 1)
    assert second["next_after"] is None


def test_a_full_last_page_has_no_next_cursor(client):
    make_batches(client, [(NOW, n) for n in range(4)])

    first = client.get("/tracks/uploads", params={"limit": 2}).json()
    second = client.get("/tracks/uploads", params={"limit": 2, "after": first["next_after"]}).json()

    assert first["next_after"] is not None
    assert (len(second["batches"]), second["next_after"]) == (2, None)


def test_a_listed_batch_is_its_summary(client):
    body = batch([item(1), item(2)], label="Mix")
    summary = allocate(client, body).json()["batch"]

    assert client.get("/tracks/uploads").json()["batches"] == [summary]


def test_the_cursor_is_the_last_rows_key(client):
    made = make_batches(client, [(NOW, 4), (NOW, 6), (NOW + 1, 2)])

    page = client.get("/tracks/uploads", params={"limit": 1}).json()
    after_six = client.get("/tracks/uploads", params={"after": cursor(NOW, uid(6, space=3))}).json()

    assert page["next_after"] == cursor(NOW, made[(NOW, 4)])
    assert [b["batch_uuid"] for b in after_six["batches"]] == [made[(NOW + 1, 2)]]


@pytest.mark.parametrize("limit", [0, 101, -1])
def test_a_limit_outside_1_to_100_is_a_422(client, limit):
    assert client.get("/tracks/uploads", params={"limit": limit}).status_code == 422


@pytest.mark.parametrize(
    "after",
    ["garbage!", cursor(NOW), cursor("x", uid(1)), cursor(NOW, "not-a-uuid"), cursor(NOW, uid(1), 3),
     base64.urlsafe_b64encode(b"not json").decode(), cursor(2**63, uid(1)), cursor(-(2**63) - 1, uid(1)),
     cursor(True, uid(1)),
     # review r1 F2: deep nesting and an oversized cursor.
     base64.urlsafe_b64encode(b"[" * 10000).decode(), cursor(NOW, uid(1)) + "A" * 600],
    ids=lambda v: v[:20],
)
def test_a_malformed_cursor_is_a_422(client, after):
    response = client.get("/tracks/uploads", params={"after": after})

    assert response.status_code == 422, response.text
    assert response.json()["detail"]["error"] == "invalid_cursor"


def test_another_users_batches_are_never_listed(client):
    sam, sam_headers = _second_user_client(client)
    assert allocate(client, batch([item(1)], batch_uuid=uid(1, space=2)), headers=sam_headers).status_code == 201
    assert allocate(client, batch([item(2)], batch_uuid=uid(2, space=2))).status_code == 201

    mine = client.get("/tracks/uploads").json()["batches"]
    theirs = client.get("/tracks/uploads", headers=sam_headers).json()["batches"]

    assert [b["batch_uuid"] for b in mine] == [uid(2, space=2)]
    assert [b["batch_uuid"] for b in theirs] == [uid(1, space=2)]


# ── S9: a batch's items, keyset pages ordered (selection_index, member_order_key, item_uuid)

@pytest.fixture
def roomy(open_app_client):
    """A client that accepts 150 files per batch."""
    from app.routers.uploads import upload_clock

    with open_app_client(env={"UPLOAD_MAX_FILES_PER_BATCH": "150"}) as c:
        c.app.dependency_overrides[upload_clock] = lambda: NOW
        yield c


def add_zip_children(client, parent_uuid, children):
    """Insert ZIP children (member key, uuid) under ``parent_uuid`` as 7A.2d will."""
    conn = sqlite3.connect(client.app.state.database.context.database_path)
    try:
        owner, batch_uuid, index = conn.execute(
            "SELECT owner_id, batch_uuid, selection_index FROM upload_items WHERE item_uuid = ?",
            (parent_uuid,),
        ).fetchone()
        conn.execute("UPDATE upload_items SET kind = 'zip' WHERE item_uuid = ?", (parent_uuid,))
        conn.executemany(
            "INSERT INTO upload_items (owner_id, item_uuid, batch_uuid, parent_item_uuid, filename, "
            "selection_index, member_order_key, state, created_at, updated_at, progress_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, 'allocated', ?, ?, ?)",
            [(owner, child, batch_uuid, parent_uuid, key.rsplit("/", 1)[-1], index, key, NOW, NOW, NOW)
             for key, child in children],
        )
        conn.commit()
    finally:
        conn.close()


def items_path(batch_uuid):
    return f"/tracks/uploads/{batch_uuid}/items"


def test_more_than_100_items_walk_deterministically_with_ties(roomy):
    bu = uid(0, space=2)
    # 120 direct files, given in an order whose uuids do not follow the selection order.
    files = [item(n, 1) for n in reversed(range(120))]
    assert allocate(roomy, batch(files, batch_uuid=bu)).status_code == 201
    parent = files[5]["item_uuid"]  # selection index 5
    # Children tie on the parent's selection index; two also tie on the member key.
    children = [("b/z.flac", uid(500)), ("a/x.flac", uid(503)), ("a/x.flac", uid(501)), ("a/y.flac", uid(502))]
    add_zip_children(roomy, parent, children)
    # Another batch's items never appear.
    assert allocate(roomy, batch([item(900)], batch_uuid=uid(1, space=2))).status_code == 201

    expected = [f["item_uuid"] for f in files[:5]] + [parent] + [
        uid(501), uid(503), uid(502), uid(500)
    ] + [f["item_uuid"] for f in files[6:]]
    assert len(expected) == 124

    # Review r1 7-R1-31: a page of 1 over this walk was 124 requests; page sizes
    # 1, 2 and 3 are walked by the smaller tests (ties included).
    for limit in (7, 25, 100, None):
        pages = walk(roomy, items_path(bu), "items", limit)
        assert [i["item_uuid"] for page in pages for i in page] == expected, limit
        if limit is None:
            assert [len(p) for p in pages] == [25, 25, 25, 25, 24]


# Review r1 7-R1-03: the longest member names a ZIP can carry (the name field is
# 16 bits: 65535 UTF-8 bytes), in the scripts that grow most under JSON escaping.
_ZIP_NAME_BYTES = 65535
_LONG_KEYS = [
    "曲" * (_ZIP_NAME_BYTES // 3),                       # 3-byte CJK
    "曲" * (_ZIP_NAME_BYTES // 3 - 1) + "a",             # sorts after the line above
    "🎵" * (_ZIP_NAME_BYTES // 4),                      # 4-byte: a surrogate pair in JSON
    'é"\\' * (_ZIP_NAME_BYTES // 4),                  # escapes: quote and backslash
    "a" * 1000,                                          # long ASCII
    "a" * 1000,                                          # the same key twice: the uuid breaks the tie
]


def test_long_non_ascii_member_names_page_to_the_end(client):
    from app.services.uploads import MAX_CURSOR_CHARS

    files = [item(1), item(2), item(3)]
    body = batch(files)
    assert allocate(client, body).status_code == 201
    parent = files[1]["item_uuid"]
    children = [(key, uid(600 + n)) for n, key in enumerate(_LONG_KEYS)]
    assert all(len(k.encode()) <= _ZIP_NAME_BYTES for k, _ in children)
    add_zip_children(client, parent, children)
    in_order = [u for _, u in sorted(children, key=lambda c: (c[0], c[1]))]
    expected = [files[0]["item_uuid"], parent, *in_order, files[2]["item_uuid"]]

    for limit in (1, 2, 3):
        pages, after = [], None
        while True:
            assert len(pages) < 50
            params = {"limit": limit, **({"after": after} if after else {})}
            response = client.get(items_path(body["batch_uuid"]), params=params)
            assert response.status_code == 200, response.text[:200]
            page = response.json()
            pages.append([i["item_uuid"] for i in page["items"]])
            after = page["next_after"]
            if after is None:
                break
            assert len(after) <= MAX_CURSOR_CHARS  # every cursor handed out is one it accepts
        assert [u for p in pages for u in p] == expected, limit


def test_an_items_page_carries_the_item_dto(client):
    body = batch([item(1), item(2)])
    allocated = allocate(client, body).json()

    page = client.get(items_path(body["batch_uuid"])).json()

    assert page == {"items": allocated["items"], "next_after": None}


def test_the_items_cursor_is_the_last_rows_key(client):
    body = batch([item(1), item(2), item(3)])
    allocate(client, body)

    page = client.get(items_path(body["batch_uuid"]), params={"limit": 1}).json()
    rest = client.get(items_path(body["batch_uuid"]), params={"after": cursor(1, "", uid(2))}).json()

    assert page["next_after"] == cursor(0, "", uid(1))
    assert [i["item_uuid"] for i in rest["items"]] == [uid(3)]


@pytest.mark.parametrize("limit", [0, 101])
def test_an_items_limit_outside_1_to_100_is_a_422(client, limit):
    body = batch([item(1)])
    allocate(client, body)

    assert client.get(items_path(body["batch_uuid"]), params={"limit": limit}).status_code == 422


@pytest.mark.parametrize(
    "after",
    ["garbage!", cursor(1, ""), cursor("1", "", uid(1)), cursor(1, 2, uid(1)), cursor(1, "", "x"),
     cursor(2**63, "", uid(1)),
     # review r1 F1/F2: a lone surrogate member key; deep nesting.
     base64.urlsafe_b64encode(b'[0,"\\ud800","' + uid(1).encode() + b'"]').decode(),
     base64.urlsafe_b64encode(b"[" * 10000).decode()],
    ids=lambda v: v[:20],
)
def test_a_malformed_items_cursor_is_a_422(client, after):
    body = batch([item(1)])
    allocate(client, body)

    response = client.get(items_path(body["batch_uuid"]), params={"after": after})

    assert response.status_code == 422
    assert response.json()["detail"]["error"] == "invalid_cursor"


def test_the_items_of_an_unknown_or_foreign_batch_answer_the_same_404(client):
    sam, sam_headers = _second_user_client(client)
    body = batch([item(1)])
    assert allocate(client, body, headers=sam_headers).status_code == 201

    foreign = client.get(items_path(body["batch_uuid"]))
    unknown = client.get(items_path(uid(77, space=2)))

    assert _not_found(foreign, "upload_batch_not_found") == _not_found(unknown, "upload_batch_not_found")


# ── S10: cancel an unpublished item ────────────────────────────────────────

def item_row(client, item_uuid):
    [row] = rows(
        client,
        "SELECT state, updated_at, progress_at, cancel_requested FROM upload_items WHERE item_uuid = ?",
        (item_uuid,),
    )
    return row


def test_cancelling_an_allocated_item_answers_the_cancelled_item(client):
    body = batch([item(1), item(2)])
    allocate(client, body)
    set_clock(client, NOW + 5)

    response = client.delete(f"/tracks/uploads/items/{uid(1)}")

    assert response.status_code == 200, response.text
    data = response.json()
    assert (data["item_uuid"], data["state"], data["updated_at"]) == (uid(1), "cancelled", NOW + 5)
    assert data == client.get(f"/tracks/uploads/items/{uid(1)}").json()
    assert item_row(client, uid(1)) == ("cancelled", NOW + 5, NOW, 0)
    assert item_row(client, uid(2)) == ("allocated", NOW, NOW, 0)
    summary = client.get(f"/tracks/uploads/{body['batch_uuid']}").json()
    assert (summary["state_counts"], summary["updated_at"]) == ({"allocated": 1, "cancelled": 1}, NOW + 5)


def test_a_repeated_cancel_succeeds_and_changes_nothing(client):
    allocate(client, batch([item(1)]))
    set_clock(client, NOW + 5)
    first = client.delete(f"/tracks/uploads/items/{uid(1)}")
    stored = snapshot(client)
    set_clock(client, NOW + 9)

    again = client.delete(f"/tracks/uploads/items/{uid(1).upper()}")

    assert (first.status_code, again.status_code) == (200, 200)
    assert again.json() == first.json()
    assert snapshot(client) == stored


def test_an_unknown_and_a_foreign_item_cancel_answer_the_same_404(client):
    sam, sam_headers = _second_user_client(client)
    assert allocate(client, batch([item(1)]), headers=sam_headers).status_code == 201
    stored = snapshot(client)

    foreign = client.delete(f"/tracks/uploads/items/{uid(1)}")
    unknown = client.delete(f"/tracks/uploads/items/{uid(77)}")

    assert _not_found(foreign, "upload_item_not_found") == _not_found(unknown, "upload_item_not_found")
    assert snapshot(client) == stored


# Later pieces make some of these cancellable (7A.2c validating / review_ready,
# 7A.3b duplicate_conflict) and change their rows here. 7A.2b made receiving
# cancellable (tests in test_upload_receipt_api.py).
# 7A.2c: validating and review_ready are cancellable now (test_upload_validation_races).
# 7A.2d: an expanded ZIP parent answers 200 and cancels its uncommitted children
# (test_upload_zip_cancel), so it left this list.
OTHER_STATES = {
    "committing": "",
    # failed became cancellable in review r1 7-R1-16 (test_upload_validation_races.py).
    # duplicate_conflict became cancellable in 7A.3b (test_upload_cancel_commit.py).
    "expired": "",
    "imported": ", result_track_uuid = 'feedface-0000-4000-8000-000000000001', result_revision = 3",
    "duplicate": ", result_track_uuid = 'feedface-0000-4000-8000-000000000001', duplicate_kind = 'exact'",
}


@pytest.mark.parametrize("state", sorted(OTHER_STATES))
def test_an_item_in_another_state_is_not_cancelled(client, state):
    allocate(client, batch([item(1)]))
    conn = sqlite3.connect(client.app.state.database.context.database_path)
    try:
        conn.execute(
            f"UPDATE upload_items SET state = ?{OTHER_STATES[state]} WHERE item_uuid = ?", (state, uid(1))
        )
        conn.commit()
    finally:
        conn.close()
    stored = snapshot(client)

    response = client.delete(f"/tracks/uploads/items/{uid(1)}")

    assert response.status_code == 409, response.text
    detail = response.json()["detail"]
    assert (detail["error"], detail["retryable"], detail["state"]) == ("upload_item_not_cancellable", False, state)
    assert snapshot(client) == stored


def test_a_non_uuid_cancel_answers_404(client):
    assert client.delete("/tracks/uploads/items/nope").status_code == 404


# ── self-audit (mutation follow-ups): two users under the same uuids ────────

def test_two_users_sharing_batch_and_item_uuids_see_only_their_own_items_and_counts(client):
    sam, sam_headers = _second_user_client(client)
    shared = batch([item(1), item(2), item(3)], label="Sam's")
    assert allocate(client, shared, headers=sam_headers).status_code == 201
    assert client.delete(f"/tracks/uploads/items/{uid(3)}", headers=sam_headers).status_code == 200
    mine = batch([item(1), item(4)], batch_uuid=shared["batch_uuid"])
    assert allocate(client, mine).status_code == 201

    summary = client.get(f"/tracks/uploads/{shared['batch_uuid']}").json()
    listed = client.get("/tracks/uploads").json()["batches"]
    items = client.get(f"/tracks/uploads/{shared['batch_uuid']}/items").json()["items"]
    one = client.get(f"/tracks/uploads/items/{uid(1)}").json()

    assert (summary["item_count"], summary["state_counts"]) == (2, {"allocated": 2})
    assert listed == [summary]
    assert [i["item_uuid"] for i in items] == [uid(1), uid(4)]
    assert (one["filename"], one["selection_index"]) == ("Track 1.flac", 0)
    theirs = client.get(f"/tracks/uploads/{shared['batch_uuid']}", headers=sam_headers).json()
    assert (theirs["item_count"], theirs["state_counts"]) == (3, {"allocated": 2, "cancelled": 1})


def test_a_cancel_bumps_only_the_callers_batch_when_uuids_are_shared(client):
    sam, sam_headers = _second_user_client(client)
    s_batch, a_batch = uid(1, space=2), uid(2, space=2)
    assert allocate(client, batch([item(1), item(2)], batch_uuid=s_batch), headers=sam_headers).status_code == 201
    assert allocate(client, batch([item(3)], batch_uuid=a_batch), headers=sam_headers).status_code == 201
    assert allocate(client, batch([item(4)], batch_uuid=s_batch)).status_code == 201
    assert allocate(client, batch([item(1)], batch_uuid=a_batch)).status_code == 201
    set_clock(client, NOW + 5)

    assert client.delete(f"/tracks/uploads/items/{uid(1)}").status_code == 200

    admin = client.app.state.admin_user_id
    assert rows(client, "SELECT owner_id, batch_uuid, updated_at FROM upload_batches ORDER BY owner_id, batch_uuid") == sorted([
        (admin, s_batch, NOW), (admin, a_batch, NOW + 5), (sam, s_batch, NOW), (sam, a_batch, NOW),
    ])
    assert rows(client, "SELECT owner_id, state FROM upload_items WHERE item_uuid = ? ORDER BY owner_id", (uid(1),)) == sorted([
        (admin, "cancelled"), (sam, "allocated"),
    ])


# ── review r1 ───────────────────────────────────────────────────────────────

@pytest.mark.parametrize("first, again", [("absent", None), (None, "absent")])
def test_an_absent_and_a_null_label_are_the_same_request(client, first, again):
    # review r1 F4: the label has no "clear" meaning, so absent and null retry alike.
    def body(label):
        b = batch([item(1)])
        if label != "absent":
            b["label"] = label
        return b

    assert allocate(client, body(first)).status_code == 201

    response = allocate(client, body(again))

    assert response.status_code == 200, response.text
    assert response.json()["batch"]["label"] is None


def test_a_cancel_bumps_the_callers_batch_when_another_user_has_the_item_uuid_elsewhere(client):
    # review r1 F3: the admin holds item 1 in batch X; sam holds item 1 in batch Y.
    sam, sam_headers = _second_user_client(client)
    x_batch, y_batch = uid(1, space=2), uid(2, space=2)
    assert allocate(client, batch([item(1)], batch_uuid=x_batch)).status_code == 201
    assert allocate(client, batch([item(1)], batch_uuid=y_batch), headers=sam_headers).status_code == 201
    set_clock(client, NOW + 5)

    assert client.delete(f"/tracks/uploads/items/{uid(1)}", headers=sam_headers).status_code == 200

    admin = client.app.state.admin_user_id
    assert rows(client, "SELECT owner_id, batch_uuid, updated_at FROM upload_batches ORDER BY owner_id") == sorted([
        (admin, x_batch, NOW), (sam, y_batch, NOW + 5),
    ])
