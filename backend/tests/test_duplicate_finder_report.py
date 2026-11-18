"""Phase 6.5B.2b: the whole ``DuplicateReport`` once both layers exist (spec §5; review 6.5-U09).

- Matches are deduped per subject: a track or staged item matching on both
  layers appears once, as its strongest kind (exact wins).
- Matches are ranked: exact, then strong, then possible; within a band by
  score (highest first); library tracks before staged items on a tie; then id.
- ``extra_subjects`` (Phase 7 staged items) go through the same fingerprint
  code as library tracks: same duration window, same algorithm, same bands.
- The fingerprint ``LayerCoverage.subject_state`` is the subject's own print
  state: ``unavailable`` without a fingerprinter, the classification of a
  computed print, ``failed`` when computing it failed.

Prints: see ``test_duplicate_finder_fingerprint`` (k flipped low bits per
item gives a score of exactly 1 - k/32).
"""

import sqlite3

import pytest

from app.services.audio_identity import (
    KIND_PCM,
    AudioIdentity,
    ExactAudioHash,
    FingerprintIdentity,
    FingerprintUnavailable,
)
from app.services.duplicate_detection import (
    DuplicateMatch,
    StagedIdentity,
    StagedRef,
    TrackRef,
    find_duplicates,
)
from tests.identity_worker_fixtures import add_track
from tests.fingerprint_fixtures import ALGO, BASE, EXPLICIT, fp_track, noisy, random_print

T = 1_800_000_000
SUBJECT_DIGEST = "ee" * 32


@pytest.fixture
def conn(db):
    connection = sqlite3.connect(db.context.database_path)
    connection.execute("PRAGMA foreign_keys=ON")
    yield connection
    connection.close()


def print_of(items=BASE, *, state="current", duration=200.0, algorithm=ALGO):
    if state == "too_short":
        return FingerprintIdentity(state, "fpcalc", algorithm, None, ())
    return FingerprintIdentity(state, "fpcalc", algorithm, duration, tuple(items))


def ident(fingerprint=..., digest=SUBJECT_DIGEST) -> AudioIdentity:
    if fingerprint is ...:
        fingerprint = print_of()
    return AudioIdentity(exact=ExactAudioHash(KIND_PCM, digest, 44100, 2, 16),
                         tool_versions="ffmpeg 9; fpcalc 1.6.2", computed_at=T, fingerprint=fingerprint)


def staged(item_uuid, fingerprint=..., digest=None) -> StagedIdentity:
    return StagedIdentity(ref=StagedRef(item_uuid),
                          identity=ident(fingerprint, digest or (item_uuid.encode().hex() * 64)[:64]))


def find(db, conn, identity=None, **kwargs):
    # Explicit matcher settings, not the defaults (U09-B-06; see fingerprint_fixtures.EXPLICIT).
    kwargs.setdefault("params", EXPLICIT)
    return find_duplicates(conn, identity or ident(), owner_id=db.owner_id, **kwargs)


# --- dedupe per subject ------------------------------------------------------------------------


def test_a_track_matching_on_both_layers_is_reported_once_as_exact(db, conn):
    both = fp_track(db, "both", digest=SUBJECT_DIGEST)

    assert find(db, conn).matches == (DuplicateMatch(TrackRef(both), "exact", "exact", None),)


def test_a_staged_item_matching_on_both_layers_is_reported_once_as_exact(db, conn):
    report = find(db, conn, extra_subjects=(staged("item-1", digest=SUBJECT_DIGEST),))

    assert report.matches == (DuplicateMatch(StagedRef("item-1"), "exact", "exact", None),)


# --- ranking -----------------------------------------------------------------------------------


def test_matches_are_ranked_by_band_then_score_then_library_first_then_id(db, conn):
    exact_tracks = sorted(fp_track(db, f"e{i}", digest=SUBJECT_DIGEST) for i in range(2))
    strong_1 = fp_track(db, "s1", noisy(BASE, 1))                            # 0.96875
    strong_2 = sorted(fp_track(db, f"s2{i}", noisy(BASE, 2)) for i in range(2))  # 0.9375 each
    possible = fp_track(db, "p", noisy(BASE, 4))                             # 0.875

    report = find(db, conn, extra_subjects=(
        staged("item-z", print_of(noisy(BASE, 2))),    # ties the 0.9375 tracks: after them
        staged("item-a", print_of(noisy(BASE, 4))),
        staged("item-e", digest=SUBJECT_DIGEST),
    ))

    assert [m.subject for m in report.matches] == [
        *(TrackRef(u) for u in exact_tracks), StagedRef("item-e"),
        TrackRef(strong_1), *(TrackRef(u) for u in strong_2), StagedRef("item-z"),
        TrackRef(possible), StagedRef("item-a"),
    ]
    assert [m.band for m in report.matches] == ["exact"] * 3 + ["strong"] * 4 + ["possible"] * 2


# --- extra_subjects through the same fingerprint code ------------------------------------------


def test_a_staged_item_with_a_longer_lead_in_is_found_like_a_library_track(db, conn):
    # s7-fingerprint-search: 30 extra items of lead-in (30 * 1365 / 11025 s longer).
    print_ = print_of(random_print(78, 30) + BASE, duration=200.0 + 30 * 1365 / 11025)

    report = find(db, conn, extra_subjects=(staged("item-1", print_),))

    assert report.matches == (DuplicateMatch(StagedRef("item-1"), "fingerprint", "strong", 1.0),)


def test_a_staged_item_with_a_close_print_is_a_fingerprint_match(db, conn):
    report = find(db, conn, extra_subjects=(staged("item-1", print_of(noisy(BASE, 4))),))

    assert report.matches == (
        DuplicateMatch(StagedRef("item-1"), "fingerprint", "possible", pytest.approx(1 - 4 / 32)),
    )


@pytest.mark.parametrize("fingerprint", [
    print_of(duration=204.2),                 # outside the window (2% of 204.2 = 4.084)
    print_of(state="low_information"),
    print_of(state="too_short"),
    print_of(algorithm="chromaprint-1"),
    print_of(random_print(7)),                # unrelated
    FingerprintUnavailable("timeout"),
    None,
])
def test_a_staged_item_is_held_to_the_same_rules_as_a_library_track(db, conn, fingerprint):
    report = find(db, conn, extra_subjects=(staged("item-1", fingerprint),))

    assert report.matches == ()


def test_a_staged_item_inside_the_symmetric_window_matches(db, conn):
    # 4.05 s apart: within 2% of the longer (204.05) though not of the shorter.
    report = find(db, conn, extra_subjects=(staged("item-1", print_of(duration=204.05)),))

    assert [m.subject for m in report.matches] == [StagedRef("item-1")]


def test_staged_items_match_nothing_when_the_subject_has_no_current_print(db, conn):
    report = find(db, conn, ident(print_of(state="low_information")),
                  extra_subjects=(staged("item-1"),))

    assert report.matches == ()


# --- fingerprint coverage ----------------------------------------------------------------------


@pytest.mark.parametrize("fingerprint, state", [
    (None, "unavailable"),
    (print_of(), "current"),
    (print_of(state="low_information"), "low_information"),
    (print_of(state="too_short"), "too_short"),
    (FingerprintUnavailable("timeout"), "failed"),
])
def test_the_fingerprint_subject_state_is_the_subjects_own_print_state(db, conn, fingerprint, state):
    assert find(db, conn, ident(fingerprint)).fingerprint.subject_state == state


def test_no_fingerprint_duplicates_can_be_claimed_over_a_converged_library(db, conn):
    fp_track(db, "unrelated", random_print(3))
    fp_track(db, "drone", state="low_information")
    fp_track(db, "short", items=None, state="too_short")

    report = find(db, conn)

    assert report.fingerprint.library_not_comparable == 2
    assert report.no_duplicates_found(layers=("exact", "fingerprint")) is True


def test_a_failed_library_print_blocks_the_fingerprint_claim(db, conn):
    fp_track(db, "unrelated", random_print(3))
    add_track(db, "/m/broken.flac", identity={"exact_state": "current", "exact_kind": KIND_PCM,
                                               "exact_digest": "12" * 32, "sample_rate_hz": 44100,
                                               "channels": 2, "fp_state": "failed"})

    report = find(db, conn)

    assert report.matches == ()
    assert report.no_duplicates_found(layers=("exact",)) is True
    assert report.no_duplicates_found(layers=("fingerprint",)) is False


# 6.5B.2b review F2: an fp-current library row the finder could not compare (a
# print of another algorithm) is unknown, so it counts as pending and blocks the
# fingerprint claim. (fp 'current' always comes with a stored print: the worker
# writes both in one transaction.)


def test_a_current_print_of_another_algorithm_counts_as_pending(db, conn):
    fp_track(db, "unrelated", random_print(3))
    fp_track(db, "old_algo", algorithm="chromaprint-1")

    report = find(db, conn)

    assert report.fingerprint.library_pending == 1
    assert report.no_duplicates_found(layers=("fingerprint",)) is False


def test_comparable_current_prints_are_not_pending(db, conn):
    fp_track(db, "unrelated", random_print(3))
    fp_track(db, "far", duration=400.0)  # compared through the window, never pending

    assert find(db, conn).fingerprint.library_pending == 0
