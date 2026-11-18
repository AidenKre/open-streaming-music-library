"""7A.3b S8 (spec §4 ``POST /tracks/uploads/items/{item}/resolve-duplicate``:
"`{operation_uuid, expected_review_version, existing_track_uuid}` from
`review_ready` or `duplicate_conflict`. Through the operation-receipt helper
(SC-16c). The UUID must be one of the item's reported library matches (exact
or fingerprint) or one of the matches retained by its `duplicate_conflict`, and
still live; revalidate both under the item lock, then close the item as
terminal `duplicate` pointing at that track. Never edits the existing track.
Repeats return the receipt."; §3 `duplicate` carries the chosen track and
whether the match was exact or fingerprint; SC-16b bounded body; SC-22; SC-28
foreign == unknown)."""

import json
import uuid

import pytest

from tests.identity_worker_fixtures import add_track, sql
from tests.owned_database import add_test_user
from tests.upload_commit_fixtures import accept, ready_item, reservations
from tests.upload_validation_fixtures import stage_item

NOW = 1_700_000_000
UNKNOWN = "00000000-0000-4000-8000-0000000000ff"
LAYER = {"subject_state": "current", "library_pending": 0, "library_failed": 0, "library_not_comparable": 0}


@pytest.fixture
def client(app_client):
    from app.routers.uploads import upload_clock

    app_client.app.dependency_overrides[upload_clock] = lambda: NOW
    return app_client


def report(*matches) -> str:
    """matches: (ref, id, kind) triples."""
    return json.dumps({
        "v": 1, "status": "complete", "exact": LAYER, "fingerprint": LAYER,
        "matches": [{"ref": ref, "id": ref_id, "kind": kind, "band": "exact" if kind == "exact" else "strong",
                     "score": None if kind == "exact" else 0.97} for ref, ref_id, kind in matches]})


class Env:
    def __init__(self, client):
        self.client = client
        self.db = client.app.state.database
        self.admin = client.app.state.admin_user_id
        self.root = client.app.state.upload_receipt.uploads_root
        self.root.mkdir(parents=True, exist_ok=True)
        self.n = 0

    def track(self, owner_id=None) -> str:
        self.n += 1
        return add_track(self.db, self.root.parent / f"lib-{self.n}.flac", owner_id=owner_id or self.admin)

    def item(self, matches=(), state="review_ready", *, owner_id=None, **columns):
        staged = stage_item(self.db, self.root, owner_id=owner_id or self.admin, state="review_ready")
        columns = {"duplicate_report": report(*matches), **columns}
        names = ["state", *columns]
        sql(self.db, "UPDATE upload_items SET " + ", ".join(f"{n} = ?" for n in names)
                     + " WHERE owner_id = ? AND item_uuid = ?",
            (state, *columns.values(), staged["owner_id"], staged["item_uuid"]))
        return staged

    def resolve(self, staged_or_uuid, track, *, op=None, version=0, raw=None, **extra):
        item = staged_or_uuid if isinstance(staged_or_uuid, str) else staged_or_uuid["item_uuid"]
        url = f"/tracks/uploads/items/{item}/resolve-duplicate"
        if raw is not None:
            return self.client.post(url, content=raw, headers={"Content-Type": "application/json"})
        return self.client.post(url, json={
            "operation_uuid": op or str(uuid.uuid4()), "expected_review_version": version,
            "existing_track_uuid": track, **extra})

    def library(self):
        return {t: sql(self.db, f"SELECT * FROM {t} ORDER BY 1")
                for t in ("tracks", "trackmetadata", "track_audio_identity")}

    def state(self):
        return {
            "items": sql(self.db, "SELECT * FROM upload_items ORDER BY item_uuid"),
            "receipts": sql(self.db, "SELECT * FROM operation_receipts ORDER BY operation_uuid"),
            "journal": sql(self.db, "SELECT * FROM upload_commit_journal ORDER BY operation_uuid"),
            "reservations": reservations(self.db, self.admin),
            "library": self.library(),
        }

    def source_rows(self, staged):
        return [r for r in reservations(self.db, staged["owner_id"])
                if r["purpose"] == "upload_source" and r["subject_ref"] == staged["item_uuid"]]


@pytest.fixture
def env(client):
    return Env(client)


def _error(response):
    return response.json()["detail"]["error"]


# ── success ─────────────────────────────────────────────────────────────────

@pytest.mark.parametrize("kind", ["exact", "fingerprint"])
def test_resolving_a_review_ready_item_closes_it_as_duplicate_of_the_track(env, kind):
    track = env.track()
    staged = env.item([("library_track", track, kind)])
    library_before = env.library()

    r = env.resolve(staged, track)

    assert r.status_code == 200, r.text
    body = r.json()
    assert (body["state"], body["result_track_uuid"], body["duplicate_kind"]) == ("duplicate", track, kind)
    assert body["error"] is None and body["result_revision"] is None
    assert env.library() == library_before
    assert not staged["source"].exists()
    assert env.source_rows(staged) == []
    assert env.client.get(f"/tracks/uploads/items/{staged['item_uuid']}").json() == body


def test_a_match_retained_only_by_the_conflict_is_accepted_as_exact(env):
    track, other = env.track(), env.track()
    staged = env.item([("library_track", other, "fingerprint")], "duplicate_conflict",
                      conflict_track_uuids=json.dumps([track]))

    r = env.resolve(staged, track)

    assert r.status_code == 200, r.text
    assert (r.json()["state"], r.json()["result_track_uuid"], r.json()["duplicate_kind"]) == (
        "duplicate", track, "exact")


def test_resolving_never_touches_the_commit_journal(env):
    track = env.track()
    staged = ready_item(env.db, env.root, owner_id=env.admin)
    commit = accept(env.db, staged)
    sql(env.db, "UPDATE upload_commit_journal SET state = 'duplicate_conflict' WHERE operation_uuid = ?",
        (commit["op"],))
    sql(env.db, "UPDATE upload_items SET state = 'duplicate_conflict', conflict_track_uuids = ?"
                " WHERE item_uuid = ?", (json.dumps([track]), staged["item_uuid"]))
    journal = sql(env.db, "SELECT * FROM upload_commit_journal")

    r = env.resolve(staged, track)

    assert r.status_code == 200, r.text
    assert sql(env.db, "SELECT * FROM upload_commit_journal") == journal


# ── repeats ─────────────────────────────────────────────────────────────────

def test_an_exact_replay_returns_the_current_item_and_changes_nothing(env):
    track = env.track()
    staged = env.item([("library_track", track, "exact")])
    op = str(uuid.uuid4())
    first = env.resolve(staged, track, op=op)
    after = env.state()

    again = env.resolve(staged, track, op=op)

    assert (first.status_code, again.status_code) == (200, 200), again.text
    assert again.json()["state"] == "duplicate"
    assert again.json() == first.json()
    assert env.state() == after


@pytest.mark.parametrize("change", ["other_track", "other_version"])
def test_the_same_operation_with_another_body_is_a_conflict(env, change):
    track, other = env.track(), env.track()
    staged = env.item([("library_track", track, "exact"), ("library_track", other, "exact")])
    op = str(uuid.uuid4())
    assert env.resolve(staged, track, op=op).status_code == 200
    after = env.state()

    r = env.resolve(staged, other if change == "other_track" else track, op=op,
                    version=0 if change == "other_track" else 1)

    assert (r.status_code, _error(r)) == (409, "operation_conflict"), r.text
    assert r.json()["detail"]["retryable"] is False
    assert env.state() == after


def test_the_same_operation_on_another_item_is_a_conflict(env):
    track = env.track()
    first = env.item([("library_track", track, "exact")])
    second = env.item([("library_track", track, "exact")])
    op = str(uuid.uuid4())
    assert env.resolve(first, track, op=op).status_code == 200
    after = env.state()

    r = env.resolve(second, track, op=op)

    assert (r.status_code, _error(r)) == (409, "operation_conflict"), r.text
    assert env.state() == after


# ── refusals ────────────────────────────────────────────────────────────────

def test_a_foreign_item_answers_exactly_like_an_unknown_one(env):
    other = add_test_user(env.db, "bob")
    track = env.track(owner_id=other)
    theirs = env.item([("library_track", track, "exact")], owner_id=other)
    before = env.state()

    foreign = env.resolve(theirs, track)
    unknown = env.resolve(UNKNOWN, track)

    assert (foreign.status_code, unknown.status_code) == (404, 404), foreign.text
    assert foreign.json() == unknown.json()
    assert _error(foreign) == "upload_item_not_found"
    assert env.state() == before


def test_a_stale_review_version_is_refused_and_stores_no_receipt(env):
    track = env.track()
    staged = env.item([("library_track", track, "exact")], review_version=2)
    before = env.state()
    op = str(uuid.uuid4())

    r = env.resolve(staged, track, op=op, version=1)

    assert (r.status_code, _error(r)) == (409, "upload_review_version_conflict"), r.text
    assert r.json()["detail"]["review_version"] == 2
    assert env.state() == before
    assert env.resolve(staged, track, op=op, version=2).status_code == 200


NOT_RESOLVABLE = {
    "allocated": {}, "receiving": {}, "validating": {}, "committing": {},
    "imported": {"result_track_uuid": UNKNOWN, "result_revision": 1},
    "duplicate": {"result_track_uuid": UNKNOWN, "duplicate_kind": "exact"},
    "failed": {"error_code": "x"}, "cancelled": {}, "expired": {},
}


@pytest.mark.parametrize("state", sorted(NOT_RESOLVABLE))
def test_only_review_ready_and_duplicate_conflict_items_can_be_resolved(env, state):
    track = env.track()
    staged = env.item([("library_track", track, "exact")], state, **NOT_RESOLVABLE[state])
    before = env.state()

    r = env.resolve(staged, track)

    assert (r.status_code, _error(r)) == (409, "upload_item_not_resolvable"), r.text
    assert r.json()["detail"]["state"] == state
    assert env.state() == before


def test_a_track_that_is_not_a_live_reported_match_is_unavailable_with_one_body(env):
    other = add_test_user(env.db, "bob")
    reported, unreported = env.track(), env.track()
    deleted = env.track()
    foreign = env.track(owner_id=other)
    for table in ("track_audio_identity", "trackmetadata", "tracks"):
        sql(env.db, f"DELETE FROM {table} WHERE uuid_id = ?", (deleted,))
    sibling = env.item([])
    staged = env.item([("library_track", reported, "exact"), ("library_track", deleted, "exact"),
                       ("library_track", foreign, "exact"), ("staged_item", sibling["item_uuid"], "exact")])
    before = env.state()

    responses = [env.resolve(staged, t) for t in (unreported, deleted, foreign, str(uuid.uuid4()),
                                                  sibling["item_uuid"])]

    for r in responses:
        assert (r.status_code, _error(r)) == (409, "upload_duplicate_match_unavailable"), r.text
        assert r.json()["detail"]["retryable"] is False
    assert all(r.json() == responses[0].json() for r in responses)
    assert env.state() == before


# ── body handling ───────────────────────────────────────────────────────────

def test_a_body_over_the_bound_is_413(env):
    staged = env.item([])
    r = env.resolve(staged, None, raw=b" " * (256 * 1024 + 1))
    assert r.status_code == 413


def test_unknown_fields_are_422_without_echoing_the_input(env):
    track = env.track()
    staged = env.item([("library_track", track, "exact")])
    before = env.state()

    r = env.resolve(staged, track, secret_field="hunter2-value")

    assert r.status_code == 422
    assert "hunter2-value" not in r.text  # values are never echoed; the field's name is (shared 422 shape)
    assert env.state() == before


def test_a_retained_exact_conflict_match_stays_exact_when_the_report_says_fingerprint(env):
    """Review r1 F5: exact wins over fingerprint for the same track (finder rule)."""
    track = env.track()
    staged = env.item([("library_track", track, "fingerprint")], "duplicate_conflict",
                      conflict_track_uuids=json.dumps([track]))

    r = env.resolve(staged, track)

    assert r.status_code == 200, r.text
    assert r.json()["duplicate_kind"] == "exact"
