"""Phase 8A.2a (8-U09 "one liveness definition", plan D2/D3/D4; spec §5 step 2):
the pending-deletion marker.

"The marker is the existence of a ``deletion_journal`` row for the UUID
(removed when a deletion rolls back). ``live_tracks`` becomes ``SELECT ...
FROM tracks t WHERE NOT EXISTS (SELECT 1 FROM deletion_journal d WHERE
d.uuid_id = t.uuid_id)``." Every reader of ``live_tracks`` therefore treats a
track with a journal row as not live, with no predicate of its own, and the
track comes back as soon as the row is removed.

Each test checks the consumer three times on one fixture: live, pending
(a journal row written with plain SQL), restored (the row deleted). The
expected values are written out here, never derived from production SQL.
"""

import sqlite3
import uuid as uuidlib

import pytest
from pydantic import BaseModel

from app.database import ANY_OWNER
from app.services.audio_identity import KIND_PCM, AudioIdentity, ExactAudioHash, FingerprintIdentity
from app.services.duplicate_detection import DuplicateMatch, TrackRef, find_duplicates
from tests.pending_deletion import clear_pending_deletion, mark_pending_deletion
from tests.fingerprint_fixtures import ALGO, BASE, fp_track
from tests.identity_worker_fixtures import DIGEST_A, DIGEST_B, add_track, make_db, sql

NOW = 1_800_000_000


@pytest.fixture
def db(tmp_path):
    return make_db(tmp_path)


def hashed(digest=DIGEST_A, **extra):
    values = {"exact_state": "current", "exact_kind": KIND_PCM, "exact_digest": digest,
              "sample_rate_hz": 44100, "channels": 2, "match_state": "current"}
    values.update(extra)
    return values


def track(db, name, owner_id=None, **identity):
    return add_track(db, f"/m/{name}.flac", owner_id=owner_id, identity=hashed(**identity))


def pair(a, b):
    return tuple(sorted((a, b)))


def candidates(db):
    return {(r["uuid_a"], r["uuid_b"]): r["status"]
            for r in sql(db, "SELECT uuid_a, uuid_b, status FROM track_duplicate_candidates")}


def seed_pair(db, a, b, status="open"):
    ua, ub = pair(a, b)
    sql(db, "INSERT INTO track_duplicate_candidates (owner_id, uuid_a, uuid_b, kind, band_rank, "
            "sort_score, matcher_version, detected_at, status) "
            "VALUES (?, ?, ?, 'exact', 0, 1.0, 'm', 1, ?)", (db.owner_id, ua, ub, status))


# --- the view itself --------------------------------------------------------------------------


def test_the_view_keeps_its_columns_and_hides_a_pending_track(db):
    keep = track(db, "keep")
    gone = track(db, "gone")

    def view():
        rows = sql(db, "SELECT * FROM live_tracks ORDER BY file_path")
        return [tuple(r.values()) for r in rows]

    columns = [r["name"] for r in sql(db, "PRAGMA table_info(live_tracks)")]
    assert columns == ["id", "uuid_id", "owner_id", "file_path"]
    live = view()
    assert [r[1] for r in live] == [gone, keep]

    mark_pending_deletion(db.context.database_path, gone)
    assert [r[1] for r in view()] == [keep]
    # The track row itself is untouched: only liveness changed.
    assert sql(db, "SELECT count(*) AS n FROM tracks WHERE uuid_id = ?", (gone,))[0]["n"] == 1

    clear_pending_deletion(db.context.database_path, gone)
    assert view() == live


# --- the finder (SC-25) ------------------------------------------------------------------------


def _find_exact(db, subject_uuid):
    conn = sqlite3.connect(db.context.database_path)
    try:
        report = find_duplicates(
            conn,
            AudioIdentity(exact=ExactAudioHash(KIND_PCM, DIGEST_A, 44100, 2, None),
                          tool_versions=None, computed_at=NOW),
            owner_id=db.owner_id, exclude=frozenset({subject_uuid}),
        )
    finally:
        conn.close()
    return report


def test_the_exact_layer_never_matches_a_pending_track(db):
    subject = track(db, "subject")
    copy = track(db, "copy")

    def matched():
        return [m.subject for m in _find_exact(db, subject).matches]

    assert matched() == [TrackRef(copy)]
    mark_pending_deletion(db.context.database_path, copy)
    assert matched() == []
    clear_pending_deletion(db.context.database_path, copy)
    assert matched() == [TrackRef(copy)]


def test_the_fingerprint_layer_never_matches_a_pending_track(db):
    twin = fp_track(db, "twin")
    exact = ExactAudioHash(KIND_PCM, "ff" * 32, 44100, 2, 16)
    identity = AudioIdentity(
        exact=exact, tool_versions=None, computed_at=NOW,
        fingerprint=FingerprintIdentity("current", "fpcalc", ALGO, 200.0, tuple(BASE)),
    )

    def matched():
        conn = sqlite3.connect(db.context.database_path)
        try:
            report = find_duplicates(conn, identity, owner_id=db.owner_id)
        finally:
            conn.close()
        return [m for m in report.matches if m.kind == "fingerprint"]

    assert matched() == [DuplicateMatch(TrackRef(twin), "fingerprint", "strong", 1.0)]
    mark_pending_deletion(db.context.database_path, twin)
    assert matched() == []
    clear_pending_deletion(db.context.database_path, twin)
    assert matched() == [DuplicateMatch(TrackRef(twin), "fingerprint", "strong", 1.0)]


def test_the_finders_coverage_does_not_count_a_pending_track(db):
    subject = track(db, "subject")
    waiting = track(db, "waiting", exact_state="pending", exact_digest=None, exact_kind=None)

    def pending_count():
        return _find_exact(db, subject).exact.library_pending

    assert pending_count() == 1
    mark_pending_deletion(db.context.database_path, waiting)
    assert pending_count() == 0
    clear_pending_deletion(db.context.database_path, waiting)
    assert pending_count() == 1


# --- the candidate store API (SC-25, Phase 8's dismiss/restore and summary) -------------------


def test_the_coverage_summary_does_not_count_a_pending_track(db):
    track(db, "a")
    gone = track(db, "b", exact_state="failed", exact_digest=None, exact_kind=None)

    def exact_counts():
        summary = db.get_identity_coverage_summary(owner_id=db.owner_id)["exact"]
        return summary["current"], summary["failed"]

    assert exact_counts() == (1, 1)
    mark_pending_deletion(db.context.database_path, gone)
    assert exact_counts() == (1, 0)
    clear_pending_deletion(db.context.database_path, gone)
    assert exact_counts() == (1, 1)


def test_a_pair_with_a_pending_member_cannot_be_dismissed_or_restored(db):
    a = track(db, "a")
    b = track(db, "b")
    seed_pair(db, a, b)

    mark_pending_deletion(db.context.database_path, b)
    assert db.set_duplicate_candidate_status(b, a, "dismissed", owner_id=db.owner_id) is False
    assert candidates(db) == {pair(a, b): "open"}

    clear_pending_deletion(db.context.database_path, b)
    assert db.set_duplicate_candidate_status(b, a, "dismissed", owner_id=db.owner_id) is True
    assert candidates(db) == {pair(a, b): "dismissed"}


def _store(db, subject, matches):
    row = sql(db, "SELECT generation, exact_state, fp_state FROM track_audio_identity "
                  "WHERE uuid_id = ?", (subject,))[0]
    sql(db, "UPDATE track_audio_identity SET match_state = 'pending' WHERE uuid_id = ?", (subject,))
    return db.store_duplicate_candidates(
        subject, generation=row["generation"], exact_state=row["exact_state"],
        fp_state=row["fp_state"], matches=tuple(matches), matcher_version="m2", now=NOW,
        owner_id=db.owner_id,
    )


def _exact(uuid_id):
    return DuplicateMatch(subject=TrackRef(uuid_id), kind="exact", band="exact", score=None)


def test_the_store_never_pairs_a_subject_with_a_pending_partner(db):
    subject = track(db, "subject")
    partner = track(db, "partner")

    mark_pending_deletion(db.context.database_path, partner)
    assert _store(db, subject, [_exact(partner)]) is True
    assert candidates(db) == {}

    clear_pending_deletion(db.context.database_path, partner)
    assert _store(db, subject, [_exact(partner)]) is True
    assert candidates(db) == {pair(subject, partner): "open"}


def test_the_store_does_not_judge_an_open_pair_by_a_pending_partner(db):
    """Unknown is not "no match": a pending partner is not compared, so its
    pair is kept; once it is live again, the mismatch removes the pair."""
    subject = track(db, "subject", digest=DIGEST_A)
    partner = track(db, "partner", digest=DIGEST_B)
    seed_pair(db, subject, partner)

    mark_pending_deletion(db.context.database_path, partner)
    assert _store(db, subject, []) is True
    assert candidates(db) == {pair(subject, partner): "open"}

    clear_pending_deletion(db.context.database_path, partner)
    assert _store(db, subject, []) is True
    assert candidates(db) == {}


def test_keep_both_never_seeds_a_pair_with_a_pending_partner(db):
    from app.database.database import Database

    new = track(db, "new")
    old = track(db, "old")

    def seed():
        conn = sqlite3.connect(db.context.database_path)
        conn.execute("PRAGMA foreign_keys=ON")
        try:
            conn.execute("BEGIN IMMEDIATE")
            changed = Database._seed_dismissed_candidates_in(conn, new, [old])
            conn.commit()
            return changed
        finally:
            conn.close()

    mark_pending_deletion(db.context.database_path, old)
    assert seed() == 0
    assert candidates(db) == {}

    clear_pending_deletion(db.context.database_path, old)
    assert seed() == 1
    assert candidates(db) == {pair(new, old): "dismissed"}


# --- Phase 7's "is this library track still live" check ----------------------------------------


class _Inner(BaseModel):
    operation_uuid: str


class _Request(BaseModel):
    request: _Inner


class _Refused(Exception):
    pass


def test_the_upload_duplicate_resolution_sees_a_pending_track_as_gone(db):
    existing = track(db, "existing")
    item = str(uuidlib.uuid4())
    sql(db, "INSERT INTO upload_batches (owner_id, batch_uuid, created_at, updated_at) "
            "VALUES (?, 'b', 0, 0)", (db.owner_id,))
    sql(db, "INSERT INTO upload_items (owner_id, item_uuid, batch_uuid, kind, filename, "
            "selection_index, expected_bytes, expected_sha256, state, created_at, updated_at, "
            "progress_at) VALUES (?, ?, 'b', 'audio', 'a.flac', 0, 1, ?, 'review_ready', 0, 0, 0)",
        (db.owner_id, item, "0" * 64))

    def is_live():
        seen = []

        def decide(row, live):
            seen.append(live(existing))
            raise _Refused  # refuse: everything rolls back, nothing is written

        with pytest.raises(_Refused):
            db.resolve_upload_duplicate(
                item, owner_id=db.owner_id, now=NOW, decide=decide,
                request_model=_Request(request=_Inner(operation_uuid=str(uuidlib.uuid4()))),
            )
        return seen

    assert is_live() == [True]
    mark_pending_deletion(db.context.database_path, existing)
    assert is_live() == [False]
    clear_pending_deletion(db.context.database_path, existing)
    assert is_live() == [True]


# --- the marker is per uuid, never wider ------------------------------------------------------


def test_a_pending_track_hides_only_itself(db):
    a = track(db, "a")
    b = track(db, "b")

    mark_pending_deletion(db.context.database_path, a)

    assert [r["uuid_id"] for r in sql(db, "SELECT uuid_id FROM live_tracks")] == [b]


# --- plan D3: the store's subject check reads live_tracks too -----------------------------------


def test_the_store_discards_a_result_for_a_pending_subject(db):
    subject = track(db, "subject")
    partner = track(db, "partner")
    sql(db, "UPDATE track_audio_identity SET match_state = 'pending' WHERE uuid_id = ?", (subject,))
    before = sql(db, "SELECT * FROM track_audio_identity WHERE uuid_id = ?", (subject,))

    mark_pending_deletion(db.context.database_path, subject)
    assert _store(db, subject, [_exact(partner)]) is False
    assert candidates(db) == {}
    assert sql(db, "SELECT * FROM track_audio_identity WHERE uuid_id = ?", (subject,)) == before

    clear_pending_deletion(db.context.database_path, subject)
    assert _store(db, subject, [_exact(partner)]) is True
    assert candidates(db) == {pair(subject, partner): "open"}


# --- plan D4: the identity worker never hashes or matches a pending track ----------------------


def test_the_identity_queue_skips_a_pending_track(db):
    waiting = track(db, "waiting", exact_state="pending", exact_digest=None, exact_kind=None)

    def next_work():
        return db.next_identity_work(NOW, skip={}, owner_id=ANY_OWNER)

    assert next_work() == waiting
    mark_pending_deletion(db.context.database_path, waiting)
    assert next_work() is None
    clear_pending_deletion(db.context.database_path, waiting)
    assert next_work() == waiting


def test_the_identity_write_is_discarded_for_a_pending_track(db):
    uuid_id = add_track(db, "/m/w.flac", identity={"generation": 3})
    before = sql(db, "SELECT * FROM track_audio_identity WHERE uuid_id = ?", (uuid_id,))

    def write():
        return db.update_identity_if_unchanged(
            uuid_id, generation=3, file_path="/m/w.flac", owner_id=db.owner_id,
            values={"exact_state": "current", "exact_kind": KIND_PCM, "exact_digest": DIGEST_A,
                    "sample_rate_hz": 44100, "channels": 2, "computed_at": NOW},
        )

    mark_pending_deletion(db.context.database_path, uuid_id)
    assert write() is False
    assert sql(db, "SELECT * FROM track_audio_identity WHERE uuid_id = ?", (uuid_id,)) == before

    clear_pending_deletion(db.context.database_path, uuid_id)
    assert write() is True
    assert sql(db, "SELECT exact_state FROM track_audio_identity WHERE uuid_id = ?",
               (uuid_id,)) == [{"exact_state": "current"}]
