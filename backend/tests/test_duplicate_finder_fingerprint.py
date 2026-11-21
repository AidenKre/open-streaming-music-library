"""Phase 6.5B.2b: the fingerprint layer of ``find_duplicates`` (spec §5; review 6.5-U09).

- Candidates are the owner's live tracks with ``fp_state='current'`` whose
  stored fingerprint duration (``track_audio_fingerprint.duration_s``, never
  ``trackmetadata.duration``) is within max(3 s, 2%), via ``idx_taf_duration``.
  The window is symmetric (DEV-B2b-1): |d1 - d2| <= max(3 s, 2% of the longer).
- The blobs are fetched in one query and compared; every match at or above
  ``possible`` is returned with its band and score.
- Only the given owner's tracks (SC-28, DEV-6.5-02); only prints of the same
  algorithm (DEV-B2b-2).

Prints are synthetic seeded uint32 arrays. Flipping the k low bits of every
item gives a bit error rate of exactly k/32, so the expected score is
1 - k/32 (random items are fully diverse, so no diversity penalty applies).

The tests pass explicit settings (``EXPLICIT``: strong 0.90, possible 0.80,
window max(3 s, 2%); U09-B-06), never the defaults by accident: k=2 -> 0.9375
strong, k=4 -> 0.875 and k=6 -> 0.8125 possible, k=7 -> 0.78125 no match. The
section "at the defaults" names the shipped defaults (since round 2 of
s7-fingerprint-search: possible 0.70, window max(7 s, 2%)) on purpose.
"""

import sqlite3
from dataclasses import replace
from types import SimpleNamespace

import pytest

from app.services.audio_identity import (
    KIND_PCM,
    AudioIdentity,
    ExactAudioHash,
    FingerprintIdentity,
    FingerprintUnavailable,
)
from app.config import Settings
from app.services import duplicate_detection
from app.services.duplicate_detection import (
    DuplicateMatch,
    MatcherParams,
    StagedIdentity,
    StagedRef,
    TrackRef,
    find_duplicates,
)
from tests.fingerprint_fixtures import ALGO, BASE, EXPLICIT, fp_track, noisy, pin_matcher_settings, random_print
from tests.owned_database import add_test_user
from tests.pending_deletion import mark_pending_deletion

T = 1_800_000_000


@pytest.fixture
def conn(db):
    connection = sqlite3.connect(db.context.database_path)
    connection.execute("PRAGMA foreign_keys=ON")
    yield connection
    connection.close()


def subject(items=BASE, *, duration=200.0, state="current", algorithm=ALGO, fingerprint=...):
    if fingerprint is ...:
        fingerprint = FingerprintIdentity(state, "fpcalc", algorithm, duration, tuple(items))
    exact = ExactAudioHash(KIND_PCM, "ff" * 32, 44100, 2, 16)
    return AudioIdentity(exact=exact, tool_versions="ffmpeg 9; fpcalc 1.6.2", computed_at=T,
                         fingerprint=fingerprint)


def find(db, conn, identity=None, **kwargs):
    kwargs.setdefault("owner_id", db.owner_id)
    kwargs.setdefault("params", EXPLICIT)
    return find_duplicates(conn, identity or subject(), **kwargs)


def fp_matches(report) -> dict:
    return {m.subject: m for m in report.matches if m.kind == "fingerprint"}


# --- comparison and bands ----------------------------------------------------------------------


def test_an_identical_print_is_a_strong_fingerprint_match(db, conn):
    twin = fp_track(db, "twin")

    report = find(db, conn)

    assert report.matches == (DuplicateMatch(TrackRef(twin), "fingerprint", "strong", 1.0),)


@pytest.mark.parametrize("bits, band, score", [
    (2, "strong", 1 - 2 / 32), (4, "possible", 1 - 4 / 32),
    (6, "possible", 1 - 6 / 32),  # 0.8125: none at the old 0.85, possible at 0.80
])
def test_a_close_print_is_banded_by_its_score(db, conn, bits, band, score):
    close = fp_track(db, "close", noisy(BASE, bits))

    match = fp_matches(find(db, conn))[TrackRef(close)]

    assert match.band == band
    assert match.score == pytest.approx(score)


def test_a_print_below_possible_and_an_unrelated_print_are_no_match(db, conn):
    # k=7 -> 0.78125, just below the default possible 0.80 (k=6 was the case at 0.85).
    fp_track(db, "far", noisy(BASE, 7))
    fp_track(db, "unrelated", random_print(2))

    assert find(db, conn).matches == ()


def test_every_match_is_returned_uncapped(db, conn):
    copies = {fp_track(db, f"c{i}", noisy(BASE, i % 3)) for i in range(9)}

    assert set(fp_matches(find(db, conn))) == {TrackRef(u) for u in copies}


def test_a_lookup_prepares_the_subject_once_for_every_candidate(db, conn, monkeypatch):
    # The subject is the same for the whole lookup, so its print is packed
    # and its diversity computed once, not once per candidate (library and staged).
    library = {fp_track(db, f"c{i}", noisy(BASE, 2 + i % 3)) for i in range(4)}
    fp_track(db, "unrelated", random_print(5))  # compared, below possible
    staged = StagedIdentity(StagedRef("item-1"), AudioIdentity(
        exact=ExactAudioHash(KIND_PCM, "ee" * 32, 44100, 2, 16), tool_versions="ffmpeg 9; fpcalc 1.6.2",
        computed_at=T, fingerprint=FingerprintIdentity("current", "fpcalc", ALGO, 200.0, noisy(BASE, 2))))
    with_subject = {"diversity": 0, "pack": 0}
    real_diversity, real_pack = duplicate_detection._penalty_diversity, duplicate_detection.struct.pack

    def diversity(items):
        with_subject["diversity"] += tuple(items) == BASE
        return real_diversity(items)

    def pack(fmt, *items):
        with_subject["pack"] += items == BASE
        return real_pack(fmt, *items)

    monkeypatch.setattr(duplicate_detection, "_penalty_diversity", diversity)
    monkeypatch.setattr(duplicate_detection, "struct", SimpleNamespace(pack=pack))

    report = find(db, conn, extra_subjects=[staged])

    assert set(fp_matches(report)) == {TrackRef(u) for u in library} | {StagedRef("item-1")}
    assert with_subject == {"diversity": 1, "pack": 1}


# --- a lead-in beyond +-24 items inside the length window (s7-fingerprint-search) -------------
# fpcalc emits one item per 1365 samples at 11025 Hz, so k items are k * 1365 / 11025 s.
# A copy with k extra items of lead-in is that much longer; the finder passes both
# prints' stored durations to the comparator, which also searches around that offset.


def lead_in(k: int, items=BASE) -> tuple[int, ...]:
    return tuple(random_print(77, k)) + tuple(items)


def seconds(k: int) -> float:
    return k * 1365 / 11025


@pytest.mark.parametrize("k", [28, 32])  # 3.47 s and 3.96 s: inside 2% of ~204 s
def test_a_library_copy_with_a_longer_lead_in_is_found(db, conn, k):
    copy = fp_track(db, "lead-in", lead_in(k), duration=200.0 + seconds(k))

    assert find(db, conn).matches == (DuplicateMatch(TrackRef(copy), "fingerprint", "strong", 1.0),)


def test_a_subject_with_the_longer_lead_in_finds_the_shorter_copy(db, conn):
    plain = fp_track(db, "plain", BASE, duration=200.0)

    report = find(db, conn, subject(lead_in(30), duration=200.0 + seconds(30)))

    assert report.matches == (DuplicateMatch(TrackRef(plain), "fingerprint", "strong", 1.0),)


def test_a_lead_in_copy_outside_the_length_window_is_still_not_compared(db, conn):
    # 40 items = 4.95 s, beyond 2% of 204.95 s (4.10 s): the window is unchanged.
    fp_track(db, "far-lead-in", lead_in(40), duration=200.0 + seconds(40))

    assert find(db, conn).matches == ()


# --- at the defaults (s7-fingerprint-search round 2, owner 2026-11-17) -------------------------
# temp/audits/fingerprint-validation-jamendo.md: possible 0.70 and a max(7 s, 2%) window.

DEFAULTS = MatcherParams.from_settings(Settings(_env_file=None))


def test_a_copy_5_s_longer_by_its_lead_in_is_compared_and_found_at_the_defaults(db, conn):
    # 41 items = 5.08 s: beyond max(3 s, 2% of 205 s = 4.1 s), inside max(7 s, 2%).
    copy = fp_track(db, "lead-in", lead_in(41), duration=200.0 + seconds(41))

    assert find(db, conn, params=DEFAULTS).matches == (
        DuplicateMatch(TrackRef(copy), "fingerprint", "strong", 1.0),)
    assert find(db, conn, params=EXPLICIT).matches == ()  # the 3 s window never compared it


def test_a_copy_7_5_s_longer_is_still_not_compared_at_the_defaults(db, conn):
    # 61 items = 7.55 s: beyond 7 s and beyond 2% of 207.55 s (4.15 s). Same audio.
    fp_track(db, "far-lead-in", lead_in(61), duration=200.0 + seconds(61))

    assert find(db, conn, params=DEFAULTS).matches == ()


@pytest.mark.parametrize("subject_s, partner_s, expected", [
    (200.0, 206.9, True),    # the 7 s floor (2% of 206.9 is 4.14 s)
    (200.0, 193.1, True),
    (200.0, 207.1, False),
    (200.0, 192.9, False),
    (400.0, 407.9, True),    # 2% wins above 350 s: 8.158 s
    (400.0, 408.3, False),   # 8.3 > 2% of 408.3 = 8.166
])
def test_the_default_window_is_max_7s_or_2_percent(db, conn, subject_s, partner_s, expected):
    # Identical prints, so only the window (SQL prefilter and rule) decides.
    partner = fp_track(db, "p", duration=partner_s)

    report = find(db, conn, subject(duration=subject_s), params=DEFAULTS)

    assert (TrackRef(partner) in fp_matches(report)) is expected


@pytest.mark.parametrize("bits, band", [
    (3, "strong"),     # 0.90625: strong stays at 0.90
    (4, "possible"),   # 0.875
    (8, "possible"),   # 0.75: nothing at the old 0.80
    (9, "possible"),   # 0.71875
    (10, None),        # 0.6875: below 0.70
])
def test_the_default_bands_are_strong_090_and_possible_070(db, conn, bits, band):
    close = fp_track(db, "close", noisy(BASE, bits))

    match = fp_matches(find(db, conn, params=DEFAULTS)).get(TrackRef(close))

    assert (match.band if match else None) == band


def test_without_params_the_finder_reads_the_settings_at_call_time(db, conn, monkeypatch):
    fp_track(db, "close", noisy(BASE, 2))  # 0.9375
    pin_matcher_settings(monkeypatch, replace(EXPLICIT, strong=0.99, possible=0.95))

    assert find(db, conn, params=None).matches == ()


# --- the duration prefilter --------------------------------------------------------------------


@pytest.mark.parametrize("subject_s, partner_s, expected", [
    (100.0, 102.9, True),    # 3 s floor (2% of 102.9 is 2.06 s)
    (100.0, 97.1, True),
    (100.0, 103.1, False),
    (100.0, 96.9, False),
    (200.0, 203.9, True),    # 2% wins above 150 s
    (200.0, 196.1, True),
    (200.0, 204.2, False),   # 4.2 > 2% of 204.2 = 4.084
    (200.0, 195.8, False),   # 4.2 > 2% of 200 = 4.0
])
def test_candidates_must_be_within_max_3s_or_2_percent(db, conn, subject_s, partner_s, expected):
    partner = fp_track(db, "p", duration=partner_s)

    report = find(db, conn, subject(duration=subject_s))

    assert (TrackRef(partner) in fp_matches(report)) is expected


@pytest.mark.parametrize("a_s, b_s", [(200.0, 204.05), (300.0, 306.1)])
def test_the_duration_window_gives_the_same_answer_from_either_side(db, conn, a_s, b_s):
    # |a-b| is within 2% of the longer track but not 2% of the shorter one.
    a = fp_track(db, "a", duration=a_s)
    b = fp_track(db, "b", duration=b_s)

    from_a = find(db, conn, subject(duration=a_s), exclude=frozenset({a}))
    from_b = find(db, conn, subject(duration=b_s), exclude=frozenset({b}))

    assert TrackRef(b) in fp_matches(from_a)
    assert TrackRef(a) in fp_matches(from_b)


def test_the_window_uses_the_fingerprint_duration_never_trackmetadata(db, conn):
    # A file whose probe had no duration (NULL) is matched through its print's duration.
    no_probe = fp_track(db, "no_probe", duration=200.5, metadata_duration=None)
    # Metadata duration far off but the print's duration close: still matched.
    decoy_meta = fp_track(db, "decoy_meta", duration=199.0, metadata_duration=999.0)
    # Metadata duration equal to the subject's but the print's duration far off: no match.
    far_print = fp_track(db, "far_print", duration=260.0, metadata_duration=200.0)

    found = fp_matches(find(db, conn, subject(duration=200.0)))

    assert set(found) == {TrackRef(no_probe), TrackRef(decoy_meta)}
    assert TrackRef(far_print) not in found


# --- which prints are comparable ---------------------------------------------------------------


@pytest.mark.parametrize("state", ["low_information", "pending", "failed", "unavailable"])
def test_a_partner_whose_print_is_not_current_never_matches_even_with_a_stored_blob(db, conn, state):
    fp_track(db, "stale", state=state)

    assert find(db, conn).matches == ()


def test_a_too_short_partner_has_no_print_and_never_matches(db, conn):
    fp_track(db, "short", items=None, state="too_short")

    assert find(db, conn).matches == ()


@pytest.mark.parametrize("fingerprint", [
    None,
    FingerprintUnavailable("timeout"),
    FingerprintIdentity("low_information", "fpcalc", ALGO, 200.0, BASE),
    FingerprintIdentity("too_short", "fpcalc", ALGO, None, ()),
])
def test_a_subject_without_a_current_print_gets_no_fingerprint_match(db, conn, fingerprint):
    fp_track(db, "twin")

    assert find(db, conn, subject(fingerprint=fingerprint)).matches == ()


def test_a_print_of_another_algorithm_is_not_compared(db, conn):
    fp_track(db, "other_algo", algorithm="chromaprint-1")

    assert find(db, conn).matches == ()


def test_another_users_identical_print_is_never_matched(db, conn):
    other_user = add_test_user(db, "other")
    theirs = fp_track(db, "theirs", owner_id=other_user)
    mine = fp_track(db, "mine")

    assert set(fp_matches(find(db, conn))) == {TrackRef(mine)}
    assert set(fp_matches(find(db, conn, owner_id=other_user))) == {TrackRef(theirs)}


def test_exclude_drops_those_tracks(db, conn):
    me = fp_track(db, "me")
    twin = fp_track(db, "twin")

    report = find(db, conn, exclude=frozenset({me}))

    assert set(fp_matches(report)) == {TrackRef(twin)}


def test_a_track_the_live_tracks_view_leaves_out_is_never_matched(db, conn):
    hidden = fp_track(db, "hidden")
    shown = fp_track(db, "shown")
    mark_pending_deletion(db.context.database_path, hidden)

    assert set(fp_matches(find(db, conn))) == {TrackRef(shown)}


# --- the query ---------------------------------------------------------------------------------


def _traced(db, conn, identity):
    statements: list[str] = []
    conn.set_trace_callback(statements.append)
    try:
        find_duplicates(conn, identity, owner_id=db.owner_id)
    finally:
        conn.set_trace_callback(None)
    return [s for s in statements if "track_audio_fingerprint" in s]


def test_the_blobs_come_from_one_query_that_uses_the_duration_index(db, conn):
    other_user = add_test_user(db, "other")
    for i in range(40):
        fp_track(db, f"t{i}", random_print(100 + i), duration=120.0 + 7 * i,
                 owner_id=other_user if i % 2 else None)

    queries = _traced(db, conn, subject())

    assert len(queries) == 1, queries
    plan = " | ".join(row[3] for row in conn.execute("EXPLAIN QUERY PLAN " + queries[0]))
    assert "idx_taf_duration" in plan, plan


def test_no_fingerprint_query_runs_for_a_subject_without_a_current_print(db, conn):
    fp_track(db, "twin")

    assert _traced(db, conn, subject(fingerprint=None)) == []
