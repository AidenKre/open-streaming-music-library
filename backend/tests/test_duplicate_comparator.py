"""Phase 6.5B.2a (6.5-U08): the pure fingerprint comparator, on synthetic
uint32 arrays. Every expected value is computed here from how the arrays
were built (seeded randomness only), not by re-running the comparator."""

import ast
import random
from dataclasses import replace
from pathlib import Path

import pytest

from app.config import Settings
from app.services.duplicate_detection import (
    MatcherParams,
    band_for,
    coarse_diversity,
    compare_fingerprints,
    prepare_fingerprint,
)

BACKEND = Path(__file__).resolve().parents[1]

KEY_SHIFT = 18  # top 14 bits of a uint32
LOW_MASK = (1 << KEY_SHIFT) - 1


def rand_items(seed: int, n: int) -> list[int]:
    rng = random.Random(seed)
    return [rng.getrandbits(32) for _ in range(n)]


def keyed(keys, seed: int) -> list[int]:
    """Items with the given top-14-bit keys and random low bits (hiss)."""
    rng = random.Random(seed)
    return [(k << KEY_SHIFT) | rng.getrandbits(KEY_SHIFT) for k in keys]


# --- coarse diversity (spec §4.2) -------------------------------------------


def test_all_distinct_coarse_keys_give_full_diversity():
    keys = list(range(0, 1 << 14, 82))  # 200 distinct keys up to 16318
    assert coarse_diversity(keyed(keys, 1)) == 1.0


def test_the_highest_coarse_key_counts():
    items = [(16383 << KEY_SHIFT) | 5, (16382 << KEY_SHIFT) | 5, 16383 << KEY_SHIFT]
    assert coarse_diversity(items) == pytest.approx(2 / 3)


def test_low_bit_noise_does_not_inflate_diversity():
    # One coarse key; the low 18 bits differ on every item (hiss/dither).
    items = keyed([5] * 300, 2)
    assert len(set(items)) > 290  # full 32-bit values are nearly all distinct
    assert coarse_diversity(items) == pytest.approx(1 / 300)


def test_diversity_is_the_unique_coarse_key_fraction():
    keys = [k * 7 for k in range(20)] * 10  # 20 keys over 200 items
    assert coarse_diversity(keyed(keys, 3)) == pytest.approx(20 / 200)


def test_empty_fingerprint_has_unknown_diversity():
    assert coarse_diversity([]) is None


# --- alignment and bit error rate (spec §5) ---------------------------------

N = 900  # about 112 s of fpcalc items at about 8.08 items/s

BASE = MatcherParams(
    max_offset=24,
    min_overlap=120,
    min_items=120,
    min_diversity=0.15,
    strong=0.875,
    possible=0.75,
    duration_tolerance_s=3.0,
    duration_tolerance_frac=0.02,
)


def flip_bits(items: list[int], n: int, seed: int, *, low_only: bool = False) -> list[int]:
    """A copy with exactly ``n`` distinct bits flipped."""
    width = KEY_SHIFT if low_only else 32
    rng = random.Random(seed)
    out = list(items)
    for pos in rng.sample(range(len(items) * width), n):
        out[pos // width] ^= 1 << (pos % width)
    return out


def shifted(items: list[int], k: int, seed: int) -> tuple[list[int], list[int]]:
    """(a, b) where a[i] == b[i + k]: b is ``items`` behind k extra items
    when k > 0, a is ``items`` behind |k| extra items when k < 0."""
    pad = rand_items(seed, abs(k))
    if k >= 0:
        return list(items), pad + list(items)
    return pad + list(items), list(items)


def test_identical_fingerprints_score_one_at_offset_zero():
    a = rand_items(10, N)

    result = compare_fingerprints(a, list(a), BASE)

    assert result.score == 1.0
    assert result.ber == 0.0
    assert result.offset == 0
    assert result.overlap == N


@pytest.mark.parametrize("k", [1, 7, 23, 24, -1, -7, -23, -24])
def test_a_shift_within_the_window_is_found(k):
    a, b = shifted(rand_items(11, N), k, seed=12)

    result = compare_fingerprints(a, b, BASE)

    assert result.score == 1.0
    assert result.offset == k
    assert result.overlap == N


@pytest.mark.parametrize("k", [25, -25])
def test_a_shift_just_beyond_the_window_is_not_found(k):
    a, b = shifted(rand_items(13, N), k, seed=14)

    result = compare_fingerprints(a, b, BASE)

    assert result is not None
    assert abs(result.offset) <= 24
    assert result.score < 0.6


def test_a_wider_window_reaches_the_same_shift():
    a, b = shifted(rand_items(13, N), 25, seed=14)

    result = compare_fingerprints(a, b, replace(BASE, max_offset=25))

    assert result.score == 1.0
    assert result.offset == 25


@pytest.mark.parametrize("n", [1, 100, 2880])
def test_bit_error_rate_counts_flipped_bits(n):
    a = rand_items(15, N)
    b = flip_bits(a, n, seed=16)

    result = compare_fingerprints(a, b, BASE)

    assert result.offset == 0
    assert result.ber == pytest.approx(n / (32 * N), abs=1e-12)
    assert result.score == pytest.approx(1 - n / (32 * N), abs=1e-12)


def test_the_comparison_is_symmetric():
    a, b = shifted(rand_items(17, N), 9, seed=18)
    b = flip_bits(b, 500, seed=19)

    ab = compare_fingerprints(a, b, BASE)
    ba = compare_fingerprints(b, a, BASE)

    assert ab.score == ba.score
    assert ab.offset == -ba.offset == 9


def test_unrelated_fingerprints_score_about_one_half():
    a = rand_items(20, N)
    b = rand_items(21, N)

    result = compare_fingerprints(a, b, BASE)

    assert 0.47 < result.score < 0.53


def test_an_alignment_with_exactly_the_minimum_overlap_counts():
    a = rand_items(22, 130)
    b = rand_items(23, 10) + a[:120]  # a[i] == b[i + 10] for i < 120

    result = compare_fingerprints(a, b, BASE)

    assert result.score == 1.0
    assert result.offset == 10
    assert result.overlap == 120


def test_an_alignment_below_the_minimum_overlap_is_ignored():
    a = rand_items(22, 130)
    b = rand_items(23, 11) + a[:119]  # true alignment overlaps 119 items

    result = compare_fingerprints(a, b, BASE)

    assert result is not None  # small offsets still overlap >= 120
    assert result.overlap >= 120
    assert result.offset != 11
    assert result.score < 0.6


def test_no_offset_with_the_minimum_overlap_means_not_comparable():
    a = rand_items(24, 100)

    assert compare_fingerprints(a, list(a), BASE) is None


def test_the_comparator_does_not_import_numpy():
    # ``app.services`` itself pulls numpy in through imagehash, so check the
    # module's own imports rather than ``sys.modules``.
    source = (BACKEND / "app" / "services" / "duplicate_detection.py").read_text()
    imported = set()
    for node in ast.walk(ast.parse(source)):
        if isinstance(node, ast.Import):
            imported.update(alias.name.split(".")[0] for alias in node.names)
        elif isinstance(node, ast.ImportFrom) and node.module:
            imported.add(node.module.split(".")[0])
    assert "numpy" not in imported


# --- diversity penalty (spec §4.2, as in pg_acoustid compare2) ---------------
# compare2 maps each side's unique coarse-key count u over n items to
# min(1, (u + 10) / n + 0.5), takes the lower side, and raises the score to
# the power 8 - 7 * diversity. Ordinary prints (u/n >= 0.5) are unpenalized.


def low_diversity(n: int, unique: int, seed: int) -> list[int]:
    keys = [(k * 7) for k in range(unique)]
    return keyed([keys[i % unique] for i in range(n)], seed)


def test_a_low_diversity_pair_is_penalized():
    a = low_diversity(400, 30, seed=30)  # 30 coarse keys over 400 items
    b = flip_bits(a, 400, seed=31, low_only=True)  # keys unchanged
    raw = 1 - 400 / (32 * 400)
    diversity = (30 + 10) / 400 + 0.5  # 0.6
    expected = raw ** (8 - 7 * diversity)  # exponent 3.8

    result = compare_fingerprints(a, b, BASE)

    assert result.offset == 0
    assert result.ber == pytest.approx(400 / (32 * 400), abs=1e-12)
    assert result.score == pytest.approx(expected, rel=1e-9)
    assert result.score < raw


def test_the_less_diverse_side_sets_the_penalty():
    a = low_diversity(400, 30, seed=32)
    b = list(a)
    for i in range(200, 400):  # new, distinct coarse keys in b's second half
        b[i] = ((5000 + i) << KEY_SHIFT) | (a[i] & LOW_MASK)
    flipped = sum(bin(x ^ y).count("1") for x, y in zip(a, b))
    raw = 1 - flipped / (32 * 400)
    diversity_a = (30 + 10) / 400 + 0.5  # 0.6; b is >= 1 (capped)
    expected = raw ** (8 - 7 * diversity_a)

    ab = compare_fingerprints(a, b, BASE)
    ba = compare_fingerprints(b, a, BASE)

    assert ab.offset == 0
    assert ab.score == pytest.approx(expected, rel=1e-9)
    assert ba.score == ab.score


def test_half_unique_coarse_keys_are_not_penalized():
    # (u + 10) / n + 0.5 >= 1 exactly at u = n/2 - 10.
    a = low_diversity(400, 190, seed=33)
    b = flip_bits(a, 400, seed=34, low_only=True)

    result = compare_fingerprints(a, b, BASE)

    assert result.score == pytest.approx(1 - 400 / (32 * 400), abs=1e-12)


def test_one_coarse_key_short_of_half_is_penalized():
    a = low_diversity(400, 189, seed=35)
    b = flip_bits(a, 400, seed=36, low_only=True)
    raw = 1 - 400 / (32 * 400)
    diversity = (189 + 10) / 400 + 0.5  # 0.9975

    result = compare_fingerprints(a, b, BASE)

    assert result.score == pytest.approx(raw ** (8 - 7 * diversity), rel=1e-9)
    assert result.score < raw


# --- bands (spec §5) ----------------------------------------------------------
# 128 diverse items = 4096 bits; with strong 0.875 and possible 0.75 the
# edges are exactly 512 and 1024 flipped bits (binary-exact arithmetic).

EDGES = replace(BASE, min_overlap=100)


@pytest.mark.parametrize(
    ("flipped", "band"),
    [
        (0, "strong"),
        (511, "strong"),
        (512, "strong"),  # score == strong
        (513, "possible"),
        (1023, "possible"),
        (1024, "possible"),  # score == possible
        (1025, None),
    ],
)
def test_flipped_bits_around_each_band_edge(flipped, band):
    a = rand_items(40, 128)
    b = flip_bits(a, flipped, seed=41)

    result = compare_fingerprints(a, b, EDGES)

    assert result.offset == 0
    assert result.score == pytest.approx(1 - flipped / 4096, abs=1e-12)
    assert band_for(result.score, EDGES) == band


def test_bands_follow_the_configured_thresholds():
    params = replace(BASE, strong=0.95, possible=0.9)

    assert band_for(0.95, params) == "strong"
    assert band_for(0.9499, params) == "possible"
    assert band_for(0.9, params) == "possible"
    assert band_for(0.8999, params) is None


def test_default_bands():
    # s7-fingerprint-search: possible 0.85 -> 0.80 (round 1), -> 0.70 (round 2, after
    # the Jamendo validation; owner, 2026-11-17). Strong stays 0.90.
    params = MatcherParams.from_settings(Settings(_env_file=None))

    assert band_for(0.90, params) == "strong"
    assert band_for(0.8999, params) == "possible"
    assert band_for(0.80, params) == "possible"
    assert band_for(0.7999, params) == "possible"
    assert band_for(0.75, params) == "possible"
    assert band_for(0.70, params) == "possible"
    assert band_for(0.6999, params) is None


def test_unrelated_fingerprints_get_no_band_at_the_defaults():
    params = MatcherParams.from_settings(Settings(_env_file=None))
    result = compare_fingerprints(rand_items(42, N), rand_items(43, N), params)

    assert band_for(result.score, params) is None


# --- the search around the length difference (s7-fingerprint-search) ----------------
# Report temp/audits/fingerprint-threshold-research.md §1 option 1: besides
# +-max_offset around 0, the comparator also searches +-max_offset around the
# offset the two measured durations imply: an extra lead-in of d seconds on b
# puts a[i] at b[i + d * rate]. fpcalc emits one item per 1365 samples at
# 11025 Hz (Chromaprint's frame hop), so ``seconds(k)`` is exactly k items.
# Overlapping ranges are searched once. An unknown duration on either side
# leaves today's single range. ``alignments`` counts the offsets whose
# overlap was compared and ``items_compared`` the items XORed over them: the
# comparison work, counted, not timed.

ITEMS_PER_SECOND = 11025 / 1365  # about 8.077


def seconds(k: int) -> float:
    return k * 1365 / 11025


TODAY = 2 * BASE.max_offset + 1  # offsets today's search compares at full overlap


@pytest.mark.parametrize("k", [25, 28, 32, 40, 48])
def test_a_lead_in_beyond_the_window_is_found_at_the_offset_the_lengths_imply(k):
    # b is a with k extra items in front, and k items' worth longer.
    a, b = shifted(rand_items(50, N), k, seed=51)

    result = compare_fingerprints(a, b, BASE, duration_a_s=200.0, duration_b_s=200.0 + seconds(k))

    assert result.score == 1.0
    assert result.offset == k


@pytest.mark.parametrize("k", [-28, -32, -48])
def test_the_longer_side_may_be_either_one(k):
    # a carries the lead-in, so a is the longer track and the offset is negative.
    a, b = shifted(rand_items(52, N), k, seed=53)

    result = compare_fingerprints(a, b, BASE, duration_a_s=200.0 + seconds(-k), duration_b_s=200.0)

    assert result.score == 1.0
    assert result.offset == k


def test_the_duration_aware_search_is_symmetric():
    a, b = shifted(rand_items(54, N), 30, seed=55)
    b = flip_bits(b, 700, seed=56)
    da, db = 200.0, 200.0 + seconds(30)

    ab = compare_fingerprints(a, b, BASE, duration_a_s=da, duration_b_s=db)
    ba = compare_fingerprints(b, a, BASE, duration_a_s=db, duration_b_s=da)

    assert ab.score == ba.score
    assert ab.offset == -ba.offset == 30
    assert ab.alignments == ba.alignments


@pytest.mark.parametrize("da, db", [(None, 200.0 + seconds(30)), (200.0, None), (None, None),
                                    (float("nan"), 203.7), (0.0, 203.7)])
def test_an_unknown_duration_leaves_todays_search(da, db):
    a, b = shifted(rand_items(57, N), 30, seed=58)

    result = compare_fingerprints(a, b, BASE, duration_a_s=da, duration_b_s=db)
    today = compare_fingerprints(a, b, BASE)

    assert result == today
    assert abs(result.offset) <= 24 and result.score < 0.6  # the lead-in is not found
    assert result.alignments == TODAY


def test_equal_lengths_search_exactly_as_today():
    a, b = shifted(rand_items(59, N), 7, seed=60)
    b = flip_bits(b, 900, seed=61)

    result = compare_fingerprints(a, b, BASE, duration_a_s=200.0, duration_b_s=200.0)

    assert result == compare_fingerprints(a, b, BASE)  # same score, offset, overlap and work
    assert result.offset == 7
    assert result.alignments == TODAY


def test_a_length_difference_under_half_an_item_searches_as_today():
    a, b = shifted(rand_items(62, N), 3, seed=63)

    result = compare_fingerprints(a, b, BASE, duration_a_s=200.0, duration_b_s=200.0 + seconds(1) * 0.4)

    assert result == compare_fingerprints(a, b, BASE)


# With 65 implied items the two ranges are [-24, 24] and [41, 89]: disjoint.
IMPLIED = 65


@pytest.mark.parametrize("k, found", [
    (24, True), (25, False), (33, False), (40, False),   # the gap between the ranges
    (41, True), (65, True), (89, True), (90, False),     # the second range's edges
    (-24, True), (-25, False), (-41, False),             # nothing mirrored on the other side
])
def test_the_search_looks_only_inside_the_two_ranges(k, found):
    a, b = shifted(rand_items(64, N), k, seed=65)

    result = compare_fingerprints(a, b, BASE, duration_a_s=200.0, duration_b_s=200.0 + seconds(IMPLIED))

    assert (result.score == 1.0 and result.offset == k) is found
    if not found:
        assert result.score < 0.6


def test_disjoint_ranges_cost_twice_todays_work_at_most():
    a, b = rand_items(66, N), rand_items(67, N)

    wide = compare_fingerprints(a, b, BASE, duration_a_s=200.0, duration_b_s=200.0 + seconds(IMPLIED))
    today = compare_fingerprints(a, b, BASE)

    assert today.alignments == TODAY
    assert wide.alignments == 2 * TODAY
    assert wide.items_compared <= 2 * today.items_compared
    # Today: every offset in [-24, 24] at overlap N - |offset|.
    assert today.items_compared == sum(N - abs(o) for o in range(-24, 25))
    # The second range [41, 89] overlaps N - offset items each.
    assert wide.items_compared == today.items_compared + sum(N - o for o in range(41, 90))


def test_at_the_widest_default_floor_of_7_s_the_work_bound_holds():
    # Round 2: lengths up to 7 s apart are compared; 7 s implies round(7 * 8.077) = 57
    # items, so the ranges are [-24, 24] and [33, 81]: disjoint, at most twice today.
    a, b = rand_items(73, N), rand_items(74, N)

    wide = compare_fingerprints(a, b, BASE, duration_a_s=200.0, duration_b_s=207.0)
    today = compare_fingerprints(a, b, BASE)

    assert wide.alignments == 2 * TODAY
    assert wide.items_compared == today.items_compared + sum(N - o for o in range(33, 82))
    assert wide.items_compared <= 2 * today.items_compared


def test_a_7_s_lead_in_is_found_at_the_offset_the_lengths_imply():
    a, b = shifted(rand_items(75, N), 57, seed=76)

    result = compare_fingerprints(a, b, BASE, duration_a_s=200.0, duration_b_s=207.0)

    assert (result.score, result.offset) == (1.0, 57)


@pytest.mark.parametrize("implied", [1, 10, 24, 48])
def test_overlapping_ranges_are_searched_once(implied):
    # Ranges [-24, 24] and [implied - 24, implied + 24] share offsets; each is compared once.
    a, b = rand_items(68, N), rand_items(69, N)

    result = compare_fingerprints(a, b, BASE, duration_a_s=200.0, duration_b_s=200.0 + seconds(implied))

    assert result.alignments == TODAY + implied
    assert result.items_compared == sum(N - abs(o) for o in range(-24, 25 + implied))


def test_offsets_without_the_minimum_overlap_are_not_compared_in_the_second_range():
    # 300 items: offsets above 300 - 120 = 180 cannot reach the minimum overlap.
    a, b = rand_items(70, 300), rand_items(71, 300)

    result = compare_fingerprints(a, b, BASE, duration_a_s=200.0, duration_b_s=200.0 + seconds(170))

    assert result.alignments == TODAY + len(range(146, 181))


def test_a_tie_still_goes_to_the_smallest_offset():
    # The same items at offset 0 and at the implied offset 30 (a repeating print):
    # both align perfectly; the reported alignment is offset 0, as today.
    unit = rand_items(72, 30)
    a = unit * 30
    b = unit * 31

    result = compare_fingerprints(a, b, replace(BASE, min_overlap=100),
                                  duration_a_s=100.0, duration_b_s=100.0 + seconds(30))

    assert result.ber == 0.0
    assert result.offset == 0


# --- a subject prepared once per lookup ------------------------------------------
# The finder prepares its subject once (items, packed bytes, diversity) and compares
# it with every candidate. The prepared call must give exactly the plain call's
# result, in both argument orders. The pairs are this file's fixtures. The plain
# call prepares ``a`` itself, so this guards only against the two paths drifting
# apart; that the results equal today's is pinned by the hand-computed values above.

PAIRS = {
    "identical": lambda: (rand_items(10, N), rand_items(10, N), BASE, None, None),
    "shift inside the window": lambda: (*shifted(rand_items(11, N), 23, seed=12), BASE, None, None),
    "shift beyond the window": lambda: (*shifted(rand_items(13, N), -25, seed=14), BASE, None, None),
    "flipped bits": lambda: (rand_items(15, N), flip_bits(rand_items(15, N), 100, seed=16), BASE, None, None),
    "unrelated": lambda: (rand_items(20, N), rand_items(21, N), BASE, None, None),
    "minimum overlap": lambda: (rand_items(22, 130), rand_items(23, 10) + rand_items(22, 130)[:120],
                                BASE, None, None),
    "not comparable": lambda: (rand_items(24, 100), rand_items(24, 100), BASE, None, None),
    "empty": lambda: ([], rand_items(25, N), BASE, None, None),
    "low diversity": lambda: (low_diversity(400, 30, seed=30),
                              flip_bits(low_diversity(400, 30, seed=30), 400, seed=31, low_only=True),
                              BASE, None, None),
    "one side less diverse": lambda: (low_diversity(400, 30, seed=32),
                                      low_diversity(400, 30, seed=32)[:200] + rand_items(33, 200),
                                      BASE, None, None),
    "band edge": lambda: (rand_items(40, 128), flip_bits(rand_items(40, 128), 512, seed=41), EDGES, None, None),
    "lead-in found by the lengths": lambda: (*shifted(rand_items(50, N), 40, seed=51), BASE,
                                             200.0, 200.0 + seconds(40)),
    "unknown duration": lambda: (*shifted(rand_items(57, N), 30, seed=58), BASE, float("nan"), 203.7),
    "tie on a repeating print": lambda: (rand_items(72, 30) * 30, rand_items(72, 30) * 31,
                                         replace(BASE, min_overlap=100), 100.0, 100.0 + seconds(30)),
}


@pytest.mark.parametrize("pair", PAIRS)
def test_a_prepared_subject_compares_exactly_as_the_plain_print(pair):
    a, b, params, da, db = PAIRS[pair]()

    ab = compare_fingerprints(a, b, params, duration_a_s=da, duration_b_s=db)
    ba = compare_fingerprints(b, a, params, duration_a_s=db, duration_b_s=da)

    assert compare_fingerprints(prepare_fingerprint(a), b, params, duration_a_s=da, duration_b_s=db) == ab
    assert compare_fingerprints(prepare_fingerprint(b), a, params, duration_a_s=db, duration_b_s=da) == ba
