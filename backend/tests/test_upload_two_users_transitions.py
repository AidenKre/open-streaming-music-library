"""Review r1 7-R1-30 (SC-28; decision O2: ids are per owner): two users hold
the same batch and item uuids, both rows in the same state. Every public
item transition, run for one user, changes that user's row only. Dropping the
owner predicate from the central compare-and-swap must fail here for every
transition, not only for cancel."""
import json
import uuid

import pytest

from app.library import Library
from app.models.uploads import CommitRequest, ResolveDuplicateOperation, ResolveDuplicateRequest
from app.services import upload_commit
from tests.identity_worker_fixtures import sql
from tests.owned_database import add_test_user
from tests.upload_commit_fixtures import journal, library_root, ready_item
from tests.upload_publish_fixtures import library_track, make_publisher, prepared_commit
from tests.upload_validation_fixtures import item_row

BATCH = "c3000000-0000-4000-8000-000000000001"
ITEM = "c3000000-0000-4000-8000-000000000002"
NOW = 1_700_000_000


@pytest.fixture
def music(tmp_path):
    path = tmp_path / "music"
    (path / ".uploads").mkdir(parents=True)
    return path


@pytest.fixture
def pair(db, music):
    """Alice (the admin) and Sam each with a review_ready item of the same uuids."""
    sam = add_test_user(db, "sam")
    staged = [ready_item(db, music / ".uploads", owner_id=o, batch_uuid=BATCH, item_uuid=ITEM)
              for o in (db.owner_id, sam)]
    return staged  # [alice's, sam's]


def _set(db, staged, state, **fields):
    extra = "".join(f", {k} = ?" for k in fields)
    sql(db, f"UPDATE upload_items SET state = ?{extra} WHERE owner_id = ? AND item_uuid = ?",
        (state, *fields.values(), staged["owner_id"], ITEM))


def _both(db, pair, state, **fields):
    for staged in pair:
        _set(db, staged, state, **fields)


def _cancel(db, music, mine):
    return db.cancel_upload_item(ITEM, owner_id=mine["owner_id"], from_states=["review_ready"], now=NOW)[0]


def _transition(db, music, mine):
    return db.transition_upload_item(ITEM, owner_id=mine["owner_id"], from_states=("review_ready",),
                                     to_state="failed", now=NOW,
                                     fields={"error_code": "probe_failed"})[0]


def _expire(db, music, mine):
    return db.expire_upload_item(ITEM, owner_id=mine["owner_id"], from_state="review_ready",
                                 progress_before=NOW * 2, now=NOW)


def _retry(db, music, mine):
    return db.retry_upload_item(ITEM, owner_id=mine["owner_id"], expected_review_version=0,
                                source_present=lambda _p: True, now=NOW)[0] == "validating"


def _accept_commit(db, music, mine):
    request = CommitRequest.model_validate({
        "operation_uuid": str(uuid.uuid4()), "base_review_version": 0, "edits": {}, "write_tags": False,
        "acknowledged_duplicates": {"library_tracks": [], "staged_items": []}})
    status, _row = upload_commit.accept(Library(db, mine["owner_id"]), request, ITEM,
                                        uploads_root=music / ".uploads", now=NOW)
    return status == 202


def _resolve(db, music, mine):
    track = library_track(db, music, owner_id=mine["owner_id"])
    request = ResolveDuplicateRequest(operation_uuid=uuid.uuid4(), expected_review_version=0,
                                      existing_track_uuid=uuid.UUID(track))
    outcome, _row = db.resolve_upload_duplicate(
        ITEM, owner_id=mine["owner_id"],
        request_model=ResolveDuplicateOperation(item_uuid=ITEM, request=request),
        decide=lambda row, is_live: (track, "exact"), now=NOW)
    return outcome == "resolved"


CASES = {
    "cancel": ("review_ready", {}, _cancel),
    "transition": ("review_ready", {}, _transition),
    "expire": ("review_ready", {"progress_at": 1}, _expire),
    "retry": ("duplicate_conflict", {}, _retry),
    "accept_commit": ("review_ready", {}, _accept_commit),
    "resolve_duplicate": ("review_ready", {}, _resolve),
}


@pytest.mark.parametrize("case", sorted(CASES))
def test_an_item_transition_touches_only_the_callers_row(db, music, pair, case):
    state, fields, run = CASES[case]
    _both(db, pair, state, **fields)
    mine, theirs = pair
    before = item_row(db, theirs)

    assert run(db, music, mine)

    assert item_row(db, mine)["state"] != state
    assert item_row(db, theirs) == before


# ── the journal-driven transitions of a commit (both users committing) ─────

@pytest.fixture
def committing(db, music, pair):
    """Both users' items committing, each with a prepared journal of its own."""
    commits = [prepared_commit(db, music, staged=s) for s in pair]
    for c in commits:
        sql(db, "UPDATE upload_items SET state = 'committing' WHERE owner_id = ? AND item_uuid = ?",
            (c["owner_id"], ITEM))
        final = library_root(db, music, c["owner_id"]) / f"{c['track']}.flac"
        sql(db, "UPDATE upload_commit_journal SET final_path = ? WHERE owner_id = ? AND operation_uuid = ?",
            (str(final), c["owner_id"], c["op"]))
    return commits


def _record_conflict(db, music, mine):
    return db.record_upload_commit_conflict(owner_id=mine["owner_id"], operation_uuid=mine["op"],
                                            track_uuids=[str(uuid.uuid4())], now=NOW)


def _fail_publish(db, music, mine):
    return db.fail_upload_publish(owner_id=mine["owner_id"], operation_uuid=mine["op"],
                                  error_code="upload_commit_failed", error_message="x", now=NOW)


def _publish(db, music, mine):
    mine["work"].write_bytes(mine["source"].read_bytes())
    outcome = make_publisher(db, music)(journal(db, mine))
    assert outcome == "imported", (outcome, item_row(db, mine)["error_code"])
    return True


JOURNAL_CASES = {"record_conflict": _record_conflict, "fail_publish": _fail_publish,
                 "publish": _publish}


@pytest.mark.parametrize("case", sorted(JOURNAL_CASES))
def test_a_commit_transition_touches_only_the_callers_row(db, music, committing, case):
    mine, theirs = committing
    before = (item_row(db, theirs), journal(db, theirs))

    assert JOURNAL_CASES[case](db, music, mine)

    assert item_row(db, mine)["state"] != "committing"
    assert (item_row(db, theirs), journal(db, theirs)) == before
    assert json.loads(journal(db, theirs)["acknowledged_duplicates"]) is not None
