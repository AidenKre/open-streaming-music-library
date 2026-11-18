"""Phase 6.5A.3: ``LayerCoverage`` and the "no duplicates" rule (spec §5
"Unknown versus none"; review 6.5-U09; plan decision O3 / DEV-6.5-02).

Coverage counts only the subject owner's live tracks, minus ``exclude``. A
track with no identity row is unknown (pending), never "checked". "No
duplicates found" may be said only when the matches are empty, the subject
is ``current`` on each claimed layer, and that layer has nothing pending or
failed; not-comparable rows are disclosed but do not block the claim.
"""

import sqlite3

import pytest

from app.services.audio_identity import (
    KIND_PCM,
    AudioIdentity,
    ExactAudioHash,
    ExactUnavailable,
)
from app.services.duplicate_detection import DuplicateReport, LayerCoverage, find_duplicates
from tests.identity_worker_fixtures import DIGEST_A, DIGEST_B, add_track
from tests.owned_database import add_test_user
from tests.pending_deletion import mark_pending_deletion

T = 1_800_000_000


@pytest.fixture
def conn(db):
    connection = sqlite3.connect(db.context.database_path)
    connection.execute("PRAGMA foreign_keys=ON")
    yield connection
    connection.close()


def ident(exact=None) -> AudioIdentity:
    exact = exact or ExactAudioHash(KIND_PCM, DIGEST_A, 44100, 2, 16)
    return AudioIdentity(exact=exact, tool_versions="ffmpeg 9", computed_at=T)


def track(db, name, *, owner_id=None, exact_state="current", digest=DIGEST_B, fp_state="unavailable", none=False):
    if none:
        return add_track(db, f"/m/{name}.flac", owner_id=owner_id, identity={"_none": True})
    values = {"exact_state": exact_state, "fp_state": fp_state}
    if digest is not None and exact_state in ("current", "pending"):
        values.update(exact_kind=KIND_PCM, exact_digest=digest, sample_rate_hz=44100, channels=2)
    return add_track(db, f"/m/{name}.flac", owner_id=owner_id, identity=values)


def report(db, conn, identity=None, **kwargs) -> DuplicateReport:
    return find_duplicates(conn, identity or ident(), owner_id=db.owner_id, **kwargs)


# --- exact coverage --------------------------------------------------------------------------


def test_exact_coverage_separates_pending_failed_and_not_comparable(db, conn):
    track(db, "current")
    track(db, "pending-digest", exact_state="pending")
    track(db, "pending-none", exact_state="pending", digest=None)
    track(db, "no-row", none=True)
    track(db, "failed-1", exact_state="failed")
    track(db, "failed-2", exact_state="failed")
    for i in range(3):
        track(db, f"unsupported-{i}", exact_state="unsupported")

    coverage = report(db, conn).exact

    assert coverage == LayerCoverage(
        subject_state="current", library_pending=3, library_failed=2, library_not_comparable=3
    )


@pytest.mark.parametrize(
    "exact, state",
    [
        (ExactAudioHash(KIND_PCM, DIGEST_A, 44100, 2, 16), "current"),
        (ExactUnavailable("unsupported", None), "unsupported"),
        (ExactUnavailable("failed", "timeout"), "failed"),
    ],
)
def test_the_subject_state_is_the_subjects_own_exact_state(db, conn, exact, state):
    assert report(db, conn, ident(exact)).exact.subject_state == state


def test_coverage_counts_only_the_owners_live_tracks(db, conn):
    bob = add_test_user(db, "bob")
    track(db, "mine-pending", exact_state="pending")
    track(db, "his-pending", owner_id=bob, exact_state="pending")
    track(db, "his-failed", owner_id=bob, exact_state="failed")
    track(db, "his-unsupported", owner_id=bob, exact_state="unsupported")
    track(db, "his-no-row", owner_id=bob, none=True)

    mine = report(db, conn).exact
    his = find_duplicates(conn, ident(), owner_id=bob).exact

    assert (mine.library_pending, mine.library_failed, mine.library_not_comparable) == (1, 0, 0)
    assert (his.library_pending, his.library_failed, his.library_not_comparable) == (2, 1, 1)


def test_excluded_tracks_are_not_counted(db, conn):
    me = track(db, "me", exact_state="pending")
    track(db, "other", exact_state="pending")

    assert report(db, conn, exclude=frozenset({me})).exact.library_pending == 1


def test_a_track_the_live_tracks_view_leaves_out_is_not_counted(db, conn):
    hidden = track(db, "hidden", exact_state="failed")
    mark_pending_deletion(db.context.database_path, hidden)

    assert report(db, conn).exact.library_failed == 0


# --- fingerprint coverage (no fingerprint layer before 6.5B.2b) ------------------------------


def test_fingerprint_coverage_is_unavailable_for_the_subject_and_counts_the_library(db, conn):
    track(db, "a", fp_state="unavailable")
    track(db, "b", fp_state="pending")
    track(db, "c", none=True)
    track(db, "d", fp_state="failed")
    track(db, "e", fp_state="too_short")
    track(db, "f", fp_state="low_information")
    track(db, "g", fp_state="current")

    coverage = report(db, conn).fingerprint

    # unavailable / pending / no row are all "not computed" (unknown).
    assert coverage == LayerCoverage(
        subject_state="unavailable", library_pending=3, library_failed=1, library_not_comparable=2
    )


# --- the "no duplicates" rule ----------------------------------------------------------------


def test_no_duplicates_is_claimed_on_a_converged_layer_despite_not_comparable_rows(db, conn):
    track(db, "other")  # a different digest: compared, no match
    track(db, "unsupported", exact_state="unsupported")
    track(db, "short", fp_state="too_short")

    r = report(db, conn)

    assert r.matches == ()
    assert r.no_duplicates_found(layers=("exact",)) is True


def test_a_failed_track_blocks_the_claim(db, conn):
    track(db, "other")
    track(db, "failed", exact_state="failed")
    track(db, "short", fp_state="too_short")

    assert report(db, conn).no_duplicates_found(layers=("exact",)) is False


@pytest.mark.parametrize("state", ["pending", "no-row"])
def test_a_pending_or_missing_track_blocks_the_claim(db, conn, state):
    track(db, "other")
    if state == "no-row":
        track(db, "x", none=True)
    else:
        track(db, "x", exact_state="pending", digest=None)

    assert report(db, conn).no_duplicates_found(layers=("exact",)) is False


@pytest.mark.parametrize(
    "exact", [ExactUnavailable("unsupported", None), ExactUnavailable("failed", "timeout")]
)
def test_a_subject_not_current_on_the_layer_blocks_the_claim(db, conn, exact):
    track(db, "other")

    assert report(db, conn, ident(exact)).no_duplicates_found(layers=("exact",)) is False


def test_a_match_blocks_the_claim(db, conn):
    track(db, "copy", digest=DIGEST_A)

    assert report(db, conn).no_duplicates_found(layers=("exact",)) is False


def test_the_fingerprint_layer_cannot_be_claimed_without_a_fingerprint(db, conn):
    track(db, "other")

    r = report(db, conn)

    assert r.no_duplicates_found(layers=("exact", "fingerprint")) is False
    assert r.no_duplicates_found(layers=("fingerprint",)) is False


def test_a_layer_name_must_be_known(db, conn):
    with pytest.raises(ValueError):
        report(db, conn).no_duplicates_found(layers=("bogus",))


def test_an_empty_library_converged_on_the_exact_layer_has_no_duplicates(db, conn):
    me = track(db, "me", digest=DIGEST_A)

    r = report(db, conn, exclude=frozenset({me}))

    assert r.no_duplicates_found(layers=("exact",)) is True
