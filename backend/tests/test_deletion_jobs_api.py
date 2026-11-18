"""Piece 8A.2b S5 (spec §4 job row and paras 2–5, SC-16b, SC-16c, SC-22, SC-28
rule 4; review 8-U02 body cap, 8-U03): ``POST /tracks/deletions``.

``{operation_uuid, targets: [{uuid_id, base_revision}], confirmed_count}``: the
whole shape, the count (1–100 distinct) and ``confirmed_count`` are validated
before anything is written; then the job is accepted durably and the route
answers 202 with the job. An exact retry answers the same job and writes no
second row; the same UUID with other targets or revisions answers 409
``operation_conflict``. Targets are frozen as given and never looked up: a
foreign UUID is accepted exactly like an unknown one. No item executes in
this piece: every item stays ``pending``. A new job wakes the deletion worker.
"""

import json
import uuid

import pytest

from app.library import Library
from app.models import Track, TrackMetaData
from tests.owned_database import add_test_user
from tests.sqlite_helpers import sql_rows

PATH = "/tracks/deletions"
OP = "11111111-1111-4111-8111-111111111111"
UNKNOWN = "00000000-0000-4000-8000-0000000000ee"
A = "aaaaaaaa-0000-4000-8000-000000000001"
B = "bbbbbbbb-0000-4000-8000-000000000002"


@pytest.fixture
def client(open_app_client):
    with open_app_client(env={"LIBRARY_DELETE_ENABLED": "true"}) as client:
        yield client


@pytest.fixture
def me(client):
    return Library(client.app.state.database, client.app.state.admin_user_id)


def _body(*targets, op=OP, confirmed_count=None):
    return {
        "operation_uuid": op,
        "targets": [{"uuid_id": u, "base_revision": r} for u, r in targets],
        "confirmed_count": len(targets) if confirmed_count is None else confirmed_count,
    }


def _counts(client):
    return tuple(
        sql_rows(client, f"SELECT COUNT(*) FROM {t}")[0][0]
        for t in ("operation_receipts", "deletion_jobs", "deletion_job_items")
    )


def _pending(uuid_id, base_revision):
    return {"uuid_id": uuid_id, "base_revision": base_revision, "status": "pending",
            "error": None, "tombstone_revision": None, "details": []}


class _StoppedWorker:
    """What shutdown needs of a listed background worker (8A.3c: the deletion
    worker is in main._background_workers): a thread that is not running."""

    def __init__(self):
        from concurrent.futures import Future

        self.done = Future()
        self.done.set_result(None)

    def request_stop(self):
        pass

    def join(self, timeout=None):
        return True

    def stop(self, timeout=None):
        return True

    def is_alive(self):
        return False


class _Worker(_StoppedWorker):
    def __init__(self):
        super().__init__()
        self.wakes = 0

    def wake(self):
        self.wakes += 1


# ── acceptance ──────────────────────────────────────────────────────────────

def test_a_job_is_accepted_with_202_and_pending_items_in_request_order(client):
    response = client.post(PATH, json=_body((B, 2), (A, 1)))

    assert response.status_code == 202, response.text
    job = response.json()
    assert job["operation_uuid"] == OP
    assert job["status"] == "pending"
    assert job["item_count"] == 2
    assert job["items"] == [_pending(B, 2), _pending(A, 1)]
    assert isinstance(job["created_at"], int)
    assert sql_rows(client, "SELECT status FROM deletion_jobs") == [("accepted",)]
    assert sql_rows(client, "SELECT uuid_id, position, status FROM deletion_job_items"
                         " ORDER BY position") == [(B, 0, "pending"), (A, 1, "pending")]


def test_an_exact_replay_answers_the_same_job_without_a_second_row(client):
    first = client.post(PATH, json=_body((A, 1), (B, 2)))
    counts = _counts(client)

    again = client.post(PATH, json=_body((A, 1), (B, 2)))

    assert (again.status_code, again.json()) == (202, first.json())
    assert _counts(client) == counts == (1, 1, 2)


@pytest.mark.parametrize("changed", [
    _body((A, 1), (B, 3)),
    _body((A, 1), (UNKNOWN, 2)),
    _body((A, 1)),
], ids=["revision", "target", "fewer-targets"])
def test_a_changed_body_under_the_same_uuid_is_409_operation_conflict(client, changed):
    client.post(PATH, json=_body((A, 1), (B, 2)))
    counts = _counts(client)
    items = sql_rows(client, "SELECT * FROM deletion_job_items ORDER BY position")

    response = client.post(PATH, json=changed)

    assert response.status_code == 409, response.text
    detail = response.json()["detail"]
    assert (detail["error"], detail["retryable"]) == ("operation_conflict", False)
    assert _counts(client) == counts
    assert sql_rows(client, "SELECT * FROM deletion_job_items ORDER BY position") == items


def test_a_hundred_targets_are_accepted(client):
    targets = [(str(uuid.uuid4()), i) for i in range(100)]

    response = client.post(PATH, json=_body(*targets))

    assert response.status_code == 202, response.text
    assert [i["uuid_id"] for i in response.json()["items"]] == [u for u, _ in targets]


def test_targets_are_never_looked_up_so_nothing_executes(client, me, tmp_path):
    path = tmp_path / "Airbag.flac"
    path.write_bytes(b"audio")
    track = Track(file_path=path, metadata=TrackMetaData(title="Airbag", codec="flac", duration=1.0))
    assert me.add_track(track=track)
    live = me.get_track_by_uuid(track.uuid_id)

    response = client.post(PATH, json=_body((live.uuid_id, live.revision)))

    assert response.json()["items"] == [_pending(live.uuid_id, live.revision)]
    assert me.get_track_by_uuid(live.uuid_id).revision == live.revision
    assert path.read_bytes() == b"audio"
    assert sql_rows(client, "SELECT COUNT(*) FROM deletion_journal") == [(0,)]
    assert sql_rows(client, "SELECT COUNT(*) FROM track_tombstones") == [(0,)]


def test_a_foreign_target_is_accepted_exactly_like_an_unknown_one(client):
    db = client.app.state.database
    sam = Library(db, add_test_user(db, "sam"))
    track = Track(file_path="/music/sam/Lucky.flac",
                  metadata=TrackMetaData(title="Lucky", codec="flac", duration=1.0))
    assert sam.add_track(track=track)
    theirs = sam.get_track_by_uuid(track.uuid_id)
    op_two = "22222222-2222-4222-8222-222222222222"

    foreign = client.post(PATH, json=_body((theirs.uuid_id, theirs.revision)))
    unknown = client.post(PATH, json=_body((UNKNOWN, theirs.revision), op=op_two))

    assert (foreign.status_code, unknown.status_code) == (202, 202)
    def same(job, uuid_id, op):  # created_at is the request's own clock
        text = json.dumps({k: v for k, v in job.items() if k != "created_at"}, sort_keys=True)
        return text.replace(uuid_id, "<target>").replace(op, "<op>")
    assert same(foreign.json(), theirs.uuid_id, OP) == same(unknown.json(), UNKNOWN, op_two)
    assert sam.get_track_by_uuid(theirs.uuid_id).revision == theirs.revision


def test_a_new_job_wakes_the_worker_and_a_replay_does_not(client):
    worker = _Worker()
    client.app.state.deletion_worker = worker

    client.post(PATH, json=_body((A, 1)))
    assert worker.wakes == 1

    client.post(PATH, json=_body((A, 1)))
    client.post(PATH, json=_body((B, 1)))  # 409
    assert worker.wakes == 1


def test_a_wake_that_raises_never_turns_an_accepted_job_into_an_error(client):
    # 8A.2b review F3 (deferred to 8A.3c): the wake runs after the job committed.
    class _Broken(_StoppedWorker):
        def wake(self):
            raise RuntimeError("worker gone")

    client.app.state.deletion_worker = _Broken()

    response = client.post(PATH, json=_body((A, 1)))

    assert response.status_code == 202, response.text
    assert response.json()["items"][0]["status"] == "pending"


def test_without_a_worker_the_job_is_still_accepted(client):
    client.app.state.deletion_worker = None

    assert client.post(PATH, json=_body((A, 1))).status_code == 202


# ── validation before acceptance (exit proof) ───────────────────────────────

@pytest.mark.parametrize("body", [
    _body(),
    _body(*[(str(uuid.uuid4()), 1) for _ in range(101)]),
    _body((A, 1), (A, 2)),
    _body((A, 1), (A.upper(), 1)),
    _body((A, 1), (B, 2), confirmed_count=1),
    _body((A, 1), (B, 2), confirmed_count=3),
    _body((A, 1), confirmed_count=0),
    {**_body((A, 1)), "confirmed_count": "1"},
    {**_body((A, 1)), "confirmed_count": None},
    {k: v for k, v in _body((A, 1)).items() if k != "confirmed_count"},
    {k: v for k, v in _body((A, 1)).items() if k != "operation_uuid"},
    {**_body((A, 1)), "operation_uuid": "not-a-uuid"},
    {**_body((A, 1)), "extra": True},
    {"operation_uuid": OP, "targets": [{"uuid_id": A, "base_revision": "1"}], "confirmed_count": 1},
    {"operation_uuid": OP, "targets": [{"uuid_id": A, "base_revision": -1}], "confirmed_count": 1},
    # Review r1 F1: beyond SQLite's 64-bit integer (was a 500 at insert).
    {"operation_uuid": OP, "targets": [{"uuid_id": A, "base_revision": 2**63}], "confirmed_count": 1},
], ids=["zero", "101", "duplicate", "duplicate-case", "count-low", "count-high", "count-zero",
        "count-string", "count-null", "no-count", "no-operation", "bad-operation", "extra-field",
        "string-revision", "negative-revision", "huge-revision"])
def test_an_invalid_body_is_422_before_any_row_is_written(client, body):
    response = client.post(PATH, json=body)

    assert response.status_code == 422, response.text
    assert all("input" not in error for error in response.json()["detail"])
    assert _counts(client) == (0, 0, 0)


def test_a_body_over_64_kib_without_content_length_is_413_before_any_row(client):
    raw = json.dumps(_body((A, 1))).encode()
    raw = raw[:-1] + b" " * (64 * 1024 + 1 - len(raw)) + raw[-1:]

    response = client.post(PATH, content=iter([raw[:500], raw[500:]]),
                           headers={"Content-Type": "application/json"})

    assert response.status_code == 413
    assert _counts(client) == (0, 0, 0)


def test_a_full_hundred_target_body_fits_the_cap(client):
    # The largest valid request, pretty-printed, stays under 64 KiB.
    raw = json.dumps(_body(*[(str(uuid.uuid4()), 2**53) for _ in range(100)]), indent=2).encode()
    assert len(raw) < 64 * 1024

    response = client.post(PATH, content=raw, headers={"Content-Type": "application/json"})

    assert response.status_code == 202, response.text
