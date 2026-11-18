"""Phase 6.5A.3: the exact layer of ``find_duplicates`` (spec §5; review 6.5-U09).

- One indexed equality lookup on ``(exact_kind, exact_digest)`` over
  ``live_tracks``, ``current`` rows plus ``pending`` rows that still carry a
  digest; equality parameters per kind (§3 matching rule); never capped.
- Only the given owner's live tracks (SC-28, plan decisions 2 + 3,
  DEV-6.5-02): two users' identical audio is never paired.
- ``extra_subjects`` (Phase 7 staged items) go through the same rule.

Rows are written with plain SQL (``identity_worker_fixtures``); expected
matches come from how the rows were built.
"""

import sqlite3

import pytest

from app.database import ANY_OWNER
from app.services.audio_identity import (
    KIND_PACKETS,
    KIND_PCM,
    KIND_PCM_FLOAT,
    AudioIdentity,
    ExactAudioHash,
    ExactUnavailable,
)
from app.services.duplicate_detection import (
    DuplicateMatch,
    DuplicateReport,
    StagedIdentity,
    StagedRef,
    TrackRef,
    find_duplicates,
)
from tests.identity_worker_fixtures import DIGEST_A, DIGEST_B, add_track, make_db, sql
from tests.owned_database import add_test_user

T = 1_800_000_000


@pytest.fixture
def db(tmp_path):
    return make_db(tmp_path)


@pytest.fixture
def conn(db):
    connection = sqlite3.connect(db.context.database_path)
    connection.execute("PRAGMA foreign_keys=ON")
    yield connection
    connection.close()


def pcm(digest=DIGEST_A, rate=44100, channels=2, kind=KIND_PCM):
    return ExactAudioHash(kind, digest, rate, channels, 16)


def ident(exact) -> AudioIdentity:
    return AudioIdentity(exact=exact, tool_versions="ffmpeg 9", computed_at=T)


def row(exact_state="current", kind=KIND_PCM, digest=DIGEST_A, rate=44100, channels=2):
    return {
        "exact_state": exact_state, "exact_kind": kind, "exact_digest": digest,
        "sample_rate_hz": rate, "channels": channels, "bits_per_sample": 16,
    }


def track(db, name, owner_id=None, **identity):
    return add_track(db, f"/music/{name}.flac", owner_id=owner_id, identity=row(**identity))


def matched(report: DuplicateReport) -> list:
    return [m.subject for m in report.matches]


# --- the lookup ------------------------------------------------------------------------------


def test_a_current_copy_is_an_exact_match(db, conn):
    other = track(db, "b")

    report = find_duplicates(conn, ident(pcm()), owner_id=db.owner_id)

    assert report.matches == (
        DuplicateMatch(subject=TrackRef(other), kind="exact", band="exact", score=None),
    )


def test_a_pending_row_still_carrying_its_digest_matches(db, conn):
    stale = track(db, "stale", exact_state="pending")
    track(db, "no-digest", exact_state="pending", digest=None, kind=None, rate=None, channels=None)

    report = find_duplicates(conn, ident(pcm()), owner_id=db.owner_id)

    assert matched(report) == [TrackRef(stale)]


@pytest.mark.parametrize("state", ["failed", "unsupported"])
def test_failed_and_unsupported_rows_never_match_even_with_a_digest(db, conn, state):
    track(db, "x", exact_state=state)

    assert find_duplicates(conn, ident(pcm()), owner_id=db.owner_id).matches == ()


@pytest.mark.parametrize("kind", [KIND_PCM, KIND_PCM_FLOAT])
@pytest.mark.parametrize(
    "rate, channels, expected",
    [(44100, 2, True), (48000, 2, False), (44100, 1, False), (None, 2, False), (44100, None, False)],
)
def test_pcm_kinds_also_need_equal_known_rate_and_channels(db, conn, kind, rate, channels, expected):
    other = track(db, "b", kind=kind, rate=rate, channels=channels)

    report = find_duplicates(conn, ident(pcm(kind=kind)), owner_id=db.owner_id)

    assert matched(report) == ([TrackRef(other)] if expected else [])


def test_a_subject_with_unknown_rate_never_matches_a_pcm_row(db, conn):
    track(db, "b")

    report = find_duplicates(conn, ident(pcm(rate=None)), owner_id=db.owner_id)

    assert report.matches == ()


def test_the_packet_kind_ignores_the_reported_stream_parameters(db, conn):
    other = track(db, "b", kind=KIND_PACKETS, rate=22050, channels=1)

    report = find_duplicates(
        conn, ident(ExactAudioHash(KIND_PACKETS, DIGEST_A, 44100, 2, None)), owner_id=db.owner_id
    )

    assert matched(report) == [TrackRef(other)]


def test_the_same_digest_under_another_kind_or_another_digest_is_no_match(db, conn):
    track(db, "packets", kind=KIND_PACKETS)
    track(db, "float", kind=KIND_PCM_FLOAT)
    track(db, "other", digest=DIGEST_B)

    assert find_duplicates(conn, ident(pcm()), owner_id=db.owner_id).matches == ()


@pytest.mark.parametrize(
    "exact", [ExactUnavailable("unsupported", None), ExactUnavailable("failed", "decode_error")]
)
def test_a_subject_without_an_exact_hash_matches_nothing(db, conn, exact):
    track(db, "b")

    assert find_duplicates(conn, ident(exact), owner_id=db.owner_id).matches == ()


def test_exclude_drops_those_tracks(db, conn):
    me = track(db, "me")
    other = track(db, "b")

    report = find_duplicates(conn, ident(pcm()), owner_id=db.owner_id, exclude=frozenset({me}))

    assert matched(report) == [TrackRef(other)]


def test_the_exact_layer_is_never_capped_and_is_ordered_by_uuid(db, conn):
    copies = [track(db, f"c{i}") for i in range(30)]

    report = find_duplicates(conn, ident(pcm()), owner_id=db.owner_id)

    assert matched(report) == [TrackRef(u) for u in sorted(copies)]


# --- owner isolation (SC-28; DEV-6.5-02) -----------------------------------------------------


def test_two_users_with_identical_audio_never_see_each_others_tracks(db, conn):
    bob = add_test_user(db, "bob")
    mine = track(db, "mine")
    his = track(db, "his", owner_id=bob)

    alice_report = find_duplicates(conn, ident(pcm()), owner_id=db.owner_id)
    bob_report = find_duplicates(conn, ident(pcm()), owner_id=bob)

    assert matched(alice_report) == [TrackRef(mine)]
    assert matched(bob_report) == [TrackRef(his)]


@pytest.mark.parametrize("owner", [ANY_OWNER, None, True, "1"])
def test_the_owner_is_required_and_must_be_a_real_id(db, conn, owner):
    with pytest.raises(TypeError):
        find_duplicates(conn, ident(pcm()), owner_id=owner)


def test_owner_is_keyword_only_and_required(db, conn):
    with pytest.raises(TypeError):
        find_duplicates(conn, ident(pcm()))  # type: ignore[call-arg]


# --- liveness comes only from live_tracks ----------------------------------------------------


def test_a_track_the_live_tracks_view_leaves_out_is_never_matched(db, conn):
    hidden = track(db, "hidden")
    shown = track(db, "shown")
    # Phase 8 will add its pending-deletion marker to this view; simulate it.
    sql(db, "DROP VIEW live_tracks")
    sql(
        db,
        "CREATE VIEW live_tracks AS SELECT id, uuid_id, owner_id, file_path FROM tracks "
        f"WHERE uuid_id <> '{hidden}'",
    )

    report = find_duplicates(conn, ident(pcm()), owner_id=db.owner_id)

    assert matched(report) == [TrackRef(shown)]


# --- extra_subjects (Phase 7 staged items) ---------------------------------------------------


def test_staged_items_go_through_the_same_rule(db, conn):
    library = track(db, "b")
    same = StagedIdentity(ref=StagedRef("item-2"), identity=ident(pcm()))
    other_rate = StagedIdentity(ref=StagedRef("item-3"), identity=ident(pcm(rate=48000)))
    other_digest = StagedIdentity(ref=StagedRef("item-4"), identity=ident(pcm(digest=DIGEST_B)))
    unsupported = StagedIdentity(
        ref=StagedRef("item-5"), identity=ident(ExactUnavailable("unsupported", None))
    )
    same_too = StagedIdentity(ref=StagedRef("item-1"), identity=ident(pcm()))

    report = find_duplicates(
        conn, ident(pcm()), owner_id=db.owner_id,
        extra_subjects=(same, other_rate, other_digest, unsupported, same_too),
    )

    # Library tracks first, then staged items, each in id order.
    assert matched(report) == [TrackRef(library), StagedRef("item-1"), StagedRef("item-2")]
    assert {m.band for m in report.matches} == {"exact"}


def test_the_finder_works_inside_the_callers_immediate_transaction(db, conn):
    other = track(db, "b")
    conn.execute("BEGIN IMMEDIATE")

    report = find_duplicates(conn, ident(pcm()), owner_id=db.owner_id)

    assert conn.in_transaction
    assert matched(report) == [TrackRef(other)]
    conn.rollback()
