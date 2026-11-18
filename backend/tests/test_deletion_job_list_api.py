"""Piece 8A.2b S7 (spec §4 receipts row, plan O5, SC-28 rule 4; review 8-U01):
``GET /tracks/deletions?after=&limit=`` lists the caller's own deletion jobs
as a keyset page in ``(created_at, operation_uuid)`` order, 25 by default and
at most 100, with an opaque cursor that holds only that key. Jobs that share
a ``created_at`` page through with no duplicate and no skip. Each row is a
receipt summary (aggregate status, item count, per-status counts). The list
stays readable with the switch off and never shows another user's job.
"""

import base64
import json
import sqlite3
import uuid

import pytest

from app.library import Library
from app.models.deletions import DeletionJobRequest
from tests.owned_database import add_test_user

PATH = "/tracks/deletions"


@pytest.fixture
def client(open_app_client):
    with open_app_client() as client:  # switch off: the list must still work
        yield client


def _me(client):
    return Library(client.app.state.database, client.app.state.admin_user_id)


def _create(library, *, now, op=None, targets=1):
    op = op or str(uuid.uuid4())
    request = DeletionJobRequest.model_validate({
        "operation_uuid": op,
        "targets": [{"uuid_id": str(uuid.uuid4()), "base_revision": 1} for _ in range(targets)],
        "confirmed_count": targets,
    })
    assert library.create_deletion_job(request, now=now)
    return op


def _all_pages(client, limit=None):
    ops, after, pages = [], None, 0
    while True:
        params = {}
        if after is not None:
            params["after"] = after
        if limit is not None:
            params["limit"] = limit
        response = client.get(PATH, params=params)
        assert response.status_code == 200, response.text
        body = response.json()
        pages += 1
        ops += [(j["created_at"], j["operation_uuid"]) for j in body["jobs"]]
        after = body["next_after"]
        if after is None:
            return ops, pages
        assert pages < 50


def test_an_empty_list(client):
    assert client.get(PATH).json() == {"jobs": [], "next_after": None}


def test_a_receipt_summarises_its_job(client):
    op = _create(_me(client), now=500, targets=3)
    conn = sqlite3.connect(client.app.state.database.context.database_path)
    conn.execute("UPDATE deletion_job_items SET status = 'deleted', tombstone_revision = 4"
                 " WHERE position = 0")
    conn.commit()
    conn.close()

    assert client.get(PATH).json() == {
        "jobs": [{
            "operation_uuid": op, "created_at": 500, "status": "running", "item_count": 3,
            "state_counts": {"deleted": 1, "pending": 2},
        }],
        "next_after": None,
    }


def test_more_than_25_jobs_with_tied_created_at_page_with_no_duplicate_or_skip(client):
    me = _me(client)
    made = [(1000, _create(me, now=1000)) for _ in range(60)]
    made += [(999, _create(me, now=999)) for _ in range(3)]
    made += [(1001, _create(me, now=1001)) for _ in range(3)]

    ops, pages = _all_pages(client)

    assert ops == sorted(made)  # independent expectation: (created_at, uuid) ascending
    assert len(set(ops)) == len(made) == 66
    assert pages == 3  # 25 + 25 + 16


def test_limit_pages_and_100_is_the_maximum(client):
    me = _me(client)
    made = sorted((7, _create(me, now=7)) for _ in range(105))

    first = client.get(PATH, params={"limit": 100}).json()
    ops, _ = _all_pages(client, limit=4)

    assert len(first["jobs"]) == 100 and first["next_after"] is not None
    assert ops == made


@pytest.mark.parametrize("limit", [0, 101, -1, "x"])
def test_a_limit_out_of_range_is_422(client, limit):
    assert client.get(PATH, params={"limit": limit}).status_code == 422


def _cursor(key) -> str:
    return base64.urlsafe_b64encode(json.dumps(key).encode()).rstrip(b"=").decode()


@pytest.mark.parametrize("after", [
    "not base64!",
    _cursor([1]),
    _cursor([1, "not-a-uuid"]),
    _cursor(["1", str(uuid.uuid4())]),
    _cursor([1, str(uuid.uuid4()), "extra"]),
    _cursor({"created_at": 1}),
    "A" * 600,
], ids=["garbage", "short", "bad-uuid", "string-time", "long", "object", "oversized"])
def test_an_invalid_cursor_is_422_invalid_cursor(client, after):
    response = client.get(PATH, params={"after": after})

    assert response.status_code == 422, response.text
    assert response.json()["detail"]["error"] == "invalid_cursor"


def test_the_cursor_holds_only_the_key(client):
    me = _me(client)
    for _ in range(3):
        _create(me, now=5)

    after = client.get(PATH, params={"limit": 1}).json()["next_after"]
    key = json.loads(base64.urlsafe_b64decode(after + "=" * (-len(after) % 4)))

    assert isinstance(key, list) and len(key) == 2
    assert key[0] == 5 and str(uuid.UUID(key[1])) == key[1]


def test_another_users_jobs_are_never_listed(client):
    db = client.app.state.database
    sam = Library(db, add_test_user(db, "sam"))
    _create(sam, now=1)
    _create(sam, now=3)
    mine = _create(_me(client), now=2)

    ops, _ = _all_pages(client)

    assert ops == [(2, mine)]
