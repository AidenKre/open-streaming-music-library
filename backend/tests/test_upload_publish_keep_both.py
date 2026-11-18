"""7A.3b S3: keep-both. In the insert transaction the commit seeds a
``dismissed`` exact duplicate pair for every acknowledged exact library match
(fingerprint-only matches are never seeded, plan D33) and persists its frozen
acknowledgements as ``upload_item_acknowledgements`` rows (only those that
resolve under the owner: SC-28). Import both is symmetric: whichever of two
items commits first, the later one passes through the earlier one's persisted
rows. Everything runs through the real commit worker and publisher."""

import pytest

from app.database.database import DatabaseContext
from app.services.audio_identity import AudioIdentity, identity_to_columns
from tests.identity_worker_fixtures import make_db, sql
from tests.owned_database import OwnedTestDatabase, add_test_user
from tests.schema_fixtures import INIT_SQL
from tests.upload_commit_fixtures import NOW, accept, make_commit_worker, ready_item
from tests.upload_publish_fixtures import frozen_acks, library_track, make_publisher
from tests.upload_validation_fixtures import exact_for, item_row, new_uuid, print_of, stage_item


@pytest.fixture
def db(tmp_path):
    return make_db(tmp_path)


@pytest.fixture
def music(tmp_path):
    path = tmp_path / "music"
    (path / ".uploads").mkdir(parents=True)
    return path


def pairs(db) -> list[dict]:
    return sql(db, "SELECT owner_id, uuid_a, uuid_b, kind, band_rank, sort_score, status"
                   " FROM track_duplicate_candidates ORDER BY uuid_a, uuid_b")


def pair_key(x, y):
    return tuple(sorted((x, y)))


def pair_keys(db) -> list[tuple]:
    return [(p["uuid_a"], p["uuid_b"]) for p in pairs(db)]


def ack_rows(db, commit) -> set:
    return {(r["subject_kind"], r["subject_ref"]) for r in sql(
        db, "SELECT subject_kind, subject_ref FROM upload_item_acknowledgements"
            " WHERE owner_id = ? AND item_uuid = ?", (commit["owner_id"], commit["item_uuid"]))}


def run(db, music, **publisher_kwargs):
    return make_commit_worker(
        db, music, after_prepared=make_publisher(db, music, **publisher_kwargs)).process_one()


def add_print(db, track_uuid, identity):
    cols = identity_to_columns(identity)
    sql(db, "INSERT INTO track_audio_fingerprint (uuid_id, backend, algorithm, duration_s, item_count, data)"
            " VALUES (?, ?, ?, ?, ?, ?)",
        (track_uuid, cols["fp_backend"], cols["fp_algorithm"], cols["fp_duration_s"], cols["fp_item_count"],
         cols["fp_data"]))


def test_one_acknowledged_exact_match_is_seeded_dismissed(db, music):
    lib = library_track(db, music)
    commit = accept(db, ready_item(db, music / ".uploads"), acks=frozen_acks(library_tracks=[lib]))

    assert run(db, music) == "imported"

    a, b = pair_key(commit["track"], lib)
    assert pairs(db) == [{"owner_id": commit["owner_id"], "uuid_a": a, "uuid_b": b, "kind": "exact",
                          "band_rank": 0, "sort_score": 1.0, "status": "dismissed"}]


def test_six_acknowledged_copies_import_in_one_pass_with_six_dismissed_pairs(db, music):
    libs = [library_track(db, music) for _ in range(6)]
    commit = accept(db, ready_item(db, music / ".uploads"), acks=frozen_acks(library_tracks=libs))

    assert run(db, music) == "imported"

    assert pair_keys(db) == sorted(pair_key(commit["track"], t) for t in libs)
    assert {(p["kind"], p["status"]) for p in pairs(db)} == {("exact", "dismissed")}


def _print_identity():
    return AudioIdentity(exact=exact_for(b"audio-A"), fingerprint=print_of(),
                         tool_versions="ffmpeg 8.1", computed_at=1700)


def _fingerprint_only_library_track(db, music):
    lib = library_track(db, music, b"different-audio", identity={"fp_state": "current"})
    add_print(db, lib, _print_identity())
    return lib


def test_an_acknowledged_fingerprint_only_match_is_not_seeded(db, music):
    lib = _fingerprint_only_library_track(db, music)
    commit = accept(db, ready_item(db, music / ".uploads", identity=_print_identity()),
                    acks=frozen_acks(library_tracks=[lib]))

    assert run(db, music) == "imported"

    assert pairs(db) == []
    # The acknowledgement itself is still persisted (this part is what is missing before S3).
    assert ack_rows(db, commit) == {("library_track", lib)}


def test_an_unacknowledged_fingerprint_match_is_never_enforced_or_seeded(db, music):
    _fingerprint_only_library_track(db, music)
    commit = accept(db, ready_item(db, music / ".uploads", identity=_print_identity()))

    assert run(db, music) == "imported"

    assert item_row(db, commit)["state"] == "imported"
    assert pairs(db) == []


def test_only_acknowledgements_that_resolve_under_the_owner_are_stored(db, music):
    other = add_test_user(db, "bob")
    own_track = library_track(db, music)
    foreign_track = library_track(db, music, owner_id=other)
    own_item = stage_item(db, music / ".uploads", state="review_ready")
    foreign_item = stage_item(db, music / ".uploads", owner_id=other, state="review_ready")
    acks = frozen_acks(library_tracks=[own_track, foreign_track, new_uuid()],
                       staged_items=[own_item["item_uuid"], foreign_item["item_uuid"], new_uuid()])
    commit = accept(db, ready_item(db, music / ".uploads"), acks=acks)

    assert run(db, music) == "imported"

    assert ack_rows(db, commit) == {("library_track", own_track), ("staged_item", own_item["item_uuid"])}
    assert pair_keys(db) == [pair_key(commit["track"], own_track)]


def _two_items(db, music, *, b_acks_a=True, zip_children=False):
    """Two items with identical audio in one batch; returns (A, B) accepted
    commits (A's created_at the older one). B acknowledges A."""
    batch = new_uuid()
    items = [ready_item(db, music / ".uploads", batch_uuid=batch) for _ in range(2)]
    if zip_children:
        parent = stage_item(db, music / ".uploads", batch_uuid=batch, state="review_ready")
        sql(db, "UPDATE upload_items SET kind = 'zip', state = 'expanded' WHERE owner_id = ? AND item_uuid = ?",
            (parent["owner_id"], parent["item_uuid"]))
        for n, item in enumerate(items):
            sql(db, "UPDATE upload_items SET parent_item_uuid = ?, member_order_key = ?, expected_bytes = NULL,"
                    " expected_sha256 = NULL WHERE owner_id = ? AND item_uuid = ?",
                (parent["item_uuid"], f"k{n}", item["owner_id"], item["item_uuid"]))
    a_item, b_item = items
    a = accept(db, a_item, created_at=NOW)
    b = accept(db, b_item, created_at=NOW + 1,
               acks=frozen_acks(staged_items=[a_item["item_uuid"]]) if b_acks_a else None)
    return a, b


@pytest.mark.parametrize("zip_children", [False, True], ids=["plain", "zip_children"])
@pytest.mark.parametrize("first", ["A", "B"])
def test_import_both_is_symmetric_whichever_commits_first(db, music, zip_children, first):
    a, b = _two_items(db, music, zip_children=zip_children)
    older, newer = (a, b) if first == "A" else (b, a)
    if first == "B":  # B was accepted first: make its journal the older one
        for commit, created in ((b, NOW), (a, NOW + 1)):
            sql(db, "UPDATE upload_commit_journal SET created_at = ? WHERE owner_id = ? AND operation_uuid = ?",
                (created, commit["owner_id"], commit["op"]))
            sql(db, "UPDATE operation_receipts SET created_at = ? WHERE owner_id = ? AND operation_uuid = ?",
                (created, commit["owner_id"], commit["op"]))

    assert run(db, music) == "imported"
    assert item_row(db, older)["state"] == "imported"
    assert run(db, music) == "imported"
    assert item_row(db, newer)["state"] == "imported"

    assert pair_keys(db) == [pair_key(a["track"], b["track"])]
    assert {(p["kind"], p["status"]) for p in pairs(db)} == {("exact", "dismissed")}
    assert ack_rows(db, b) == {("staged_item", a["item_uuid"])}


def test_a_race_where_only_one_acknowledges_still_imports_both(db, music):
    a, b = _two_items(db, music)
    other_db = OwnedTestDatabase(DatabaseContext(database_path=db.context.database_path, init_sql_path=INIT_SQL))
    assert other_db.initialize()
    assert other_db.owner_id == db.owner_id
    b_outcomes = []

    def seam(name):
        if name == "after_work_unlink":  # A's preflight has passed and A's file is moved
            b_outcomes.append(run(other_db, music))

    assert run(db, music, seam=seam) == "imported"

    assert b_outcomes == ["imported"]
    assert item_row(db, a)["state"] == "imported"
    assert item_row(db, b)["state"] == "imported"
    assert pair_keys(db) == [pair_key(a["track"], b["track"])]
    assert pairs(db)[0]["status"] == "dismissed"
