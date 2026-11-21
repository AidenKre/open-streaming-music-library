"""Duplicate detection (Phase 6.5, spec §5).

Holds the pure comparator (no I/O, no numpy) and the finder.
"""

from __future__ import annotations

import hashlib
import json
import math
import struct
from dataclasses import asdict, dataclass
from typing import Literal, Sequence

from app.core.owner import _require_owner
from app.services.audio_identity import (
    AudioIdentity,
    ExactAudioHash,
    FingerprintIdentity,
    FingerprintUnavailable,
    exact_match,
)

# Bump whenever the comparator's logic changes.
COMPARATOR_ALGORITHM = "osml-fp-ber-v2"

# Diversity looks only at the top 14 bits of each uint32 item (spec 4.2,
# following pg_acoustid compare2); the low bits carry hiss and dither.
COARSE_KEY_BITS = 14
# Names the rule that turns a print into current / too_short / low_information.
CLASSIFIER_ALGORITHM = "osml-fp-class-v1"
# compare2 (pg_acoustid acoustid_compare.c): per-side penalty diversity is
# min(1.0, (unique_keys + SMOOTHING) / items + SHIFT).
COMPARE2_DIVERSITY_SMOOTHING = 10
COMPARE2_DIVERSITY_SHIFT = 0.5
# Fingerprint items per second of audio: Chromaprint resamples to 11025 Hz and
# emits one item per 4096-sample frame with a hop of 1365 samples. Matches the
# measured (948 - 221) / 90 ~ 8.08 items per second of fpcalc 1.6.2.
FP_ITEMS_PER_SECOND = 11025 / 1365


@dataclass(frozen=True)
class MatcherParams:
    max_offset: int
    min_overlap: int
    min_items: int
    min_diversity: float
    strong: float
    possible: float
    duration_tolerance_s: float
    duration_tolerance_frac: float

    @classmethod
    def from_settings(cls, settings) -> "MatcherParams":
        return cls(
            max_offset=settings.fp_max_offset,
            min_overlap=settings.fp_min_overlap,
            min_items=settings.fp_min_items,
            min_diversity=settings.fp_min_diversity,
            strong=settings.fp_strong,
            possible=settings.fp_possible,
            duration_tolerance_s=settings.fp_duration_tolerance_s,
            duration_tolerance_frac=settings.fp_duration_tolerance_frac,
        )


def _unique_coarse_keys(items) -> int:
    shift = 32 - COARSE_KEY_BITS
    return len({item >> shift for item in items})


def _penalty_diversity(items) -> float:
    return min(
        1.0,
        (_unique_coarse_keys(items) + COMPARE2_DIVERSITY_SMOOTHING) / len(items)
        + COMPARE2_DIVERSITY_SHIFT,
    )


def coarse_diversity(items) -> float | None:
    """Fraction of unique top-14-bit keys among the uint32 items.

    Returns None for an empty fingerprint (unknown, never 0). The
    ``low_information`` classification (``fingerprinter.classify``) calls this.
    """
    n = len(items)
    if n == 0:
        return None
    return _unique_coarse_keys(items) / n


@dataclass(frozen=True)
class FingerprintComparison:
    score: float
    ber: float
    offset: int
    overlap: int
    alignments: int
    items_compared: int


def _implied_offset(duration_a_s, duration_b_s) -> int | None:
    """Offset the length difference implies (b longer -> positive), or None if unknown."""
    for d in (duration_a_s, duration_b_s):
        if d is None or not math.isfinite(d) or d <= 0:
            return None
    return round((duration_b_s - duration_a_s) * FP_ITEMS_PER_SECOND)


def _search_offsets(max_offset: int, implied: int | None) -> list[int]:
    """[-M, M] plus [implied - M, implied + M], each once, as 0, 1, -1, 2, -2, ..."""
    offsets = list(range(-max_offset, max_offset + 1))
    if implied:
        offsets.extend(o for o in range(implied - max_offset, implied + max_offset + 1)
                       if abs(o) > max_offset)
    offsets.sort(key=lambda o: (abs(o), -o))
    return offsets


@dataclass(frozen=True)
class PreparedFingerprint:
    """A print packed and measured once, to compare with many others (one lookup's subject)."""

    items: tuple[int, ...]
    packed: bytes
    diversity: float | None  # compare2 penalty diversity; None for an empty print


def prepare_fingerprint(items) -> PreparedFingerprint:
    items = tuple(items)
    return PreparedFingerprint(
        items=items,
        packed=struct.pack(f"<{len(items)}I", *items),
        diversity=_penalty_diversity(items) if items else None,
    )


def compare_fingerprints(
    a, b, params: MatcherParams, *, duration_a_s=None, duration_b_s=None
) -> FingerprintComparison | None:
    """Best alignment of two uint32 fingerprints by minimum bit error rate.

    ``a[i]`` is compared with ``b[i + offset]`` for offsets within
    ``+-max_offset`` of 0 and, when both durations are known (finite, > 0),
    also within ``+-max_offset`` of the offset the length difference implies
    (``round((duration_b_s - duration_a_s) * FP_ITEMS_PER_SECOND)``, so an
    extra lead-in on one side is found). Each offset is tried once. An unknown
    duration on either side leaves only the search around 0. Offsets whose
    overlap is below ``min_overlap`` are skipped. Returns None when no offset
    qualifies (not comparable). Ties go to the smallest |offset|, then the
    positive one. ``score`` is ``1 - ber``, then, as in compare2, raised to
    ``8 - 7 * diversity`` when the less diverse side's whole-fingerprint
    diversity is below 1.0. ``alignments`` and ``items_compared`` count the
    offsets compared and the items XORed over them. ``a`` may be a
    ``PreparedFingerprint`` (the same result, without repacking it).
    """
    prepared = a if isinstance(a, PreparedFingerprint) else prepare_fingerprint(a)
    na, nb = len(prepared.items), len(b)
    pa = prepared.packed
    pb = struct.pack(f"<{nb}I", *b)
    from_bytes = int.from_bytes
    best = None  # (ber, offset, overlap)
    alignments = items_compared = 0
    min_overlap = params.min_overlap
    # Increasing |offset| with a strict "<" keeps the smallest |offset| on ties.
    for offset in _search_offsets(params.max_offset, _implied_offset(duration_a_s, duration_b_s)):
        start = max(0, -offset)
        stop = min(na, nb - offset)
        overlap = stop - start
        if overlap < min_overlap or overlap <= 0:
            continue
        sa = pa[start * 4 : stop * 4]
        sb = pb[(start + offset) * 4 : (stop + offset) * 4]
        bits = (from_bytes(sa, "little") ^ from_bytes(sb, "little")).bit_count()
        ber = bits / (32 * overlap)
        alignments += 1
        items_compared += overlap
        if best is None or ber < best[0]:
            best = (ber, offset, overlap)
    if best is None:
        return None
    ber, offset, overlap = best
    score = 1 - ber
    diversity = min(prepared.diversity, _penalty_diversity(b))
    if diversity < 1.0:
        score = score ** (8 - 7 * diversity)
    return FingerprintComparison(
        score=score, ber=ber, offset=offset, overlap=overlap,
        alignments=alignments, items_compared=items_compared,
    )


FingerprintBand = Literal["strong", "possible"]


def band_for(score: float, params: MatcherParams) -> FingerprintBand | None:
    """Band a comparison score: strong (>= strong), possible (>= possible), else None."""
    if score >= params.strong:
        return "strong"
    if score >= params.possible:
        return "possible"
    return None


def matcher_version(params: MatcherParams) -> str:
    """Stable hash of the algorithm id, the matching parameters and the diversity rule.

    A change re-queues matching (spec 6.4). Constants are read at call time.
    ``min_items`` and ``min_diversity`` are left out: they decide a print's class
    (see ``classifier_version``), not how two prints are compared.
    """
    matching = asdict(params)
    matching.pop("min_items")
    matching.pop("min_diversity")
    payload = {
        "algorithm": COMPARATOR_ALGORITHM,
        "params": matching,
        "layers": ["exact", "fingerprint"],
        "items_per_second": FP_ITEMS_PER_SECOND,
        "diversity_rule": {
            "coarse_key_bits": COARSE_KEY_BITS,
            "smoothing": COMPARE2_DIVERSITY_SMOOTHING,
            "shift": COMPARE2_DIVERSITY_SHIFT,
        },
    }
    canonical = json.dumps(payload, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()[:16]


def classifier_version(params: MatcherParams) -> str:
    """Stable hash of what decides a print's class: the classifier id, the item and
    diversity minimums and the coarse key width. A change reclassifies stored
    prints. Constants are read at call time."""
    payload = {
        "algorithm": CLASSIFIER_ALGORITHM,
        "min_items": params.min_items,
        "min_diversity": params.min_diversity,
        "coarse_key_bits": COARSE_KEY_BITS,
    }
    canonical = json.dumps(payload, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()[:16]


# --- the finder (spec §5) -------------------------------------------------------------------


@dataclass(frozen=True)
class TrackRef:
    """A library track, by its uuid."""

    uuid_id: str


@dataclass(frozen=True)
class StagedRef:
    """A Phase 7 staged upload item, by its item uuid."""

    item_uuid: str


@dataclass(frozen=True)
class StagedIdentity:
    """A staged item and its computed identity, passed as ``extra_subjects``."""

    ref: StagedRef
    identity: AudioIdentity


# ``matcher_version`` of a pair seeded as dismissed (Phase 7 keep-both); the worker's
# next refresh overwrites it.
SEEDED_MATCHER_VERSION = "seeded"

# Stored ``band_rank`` of a candidate row (spec 6.1): lower sorts first.
BAND_RANK: dict[str, int] = {"exact": 0, "strong": 1, "possible": 2}


@dataclass(frozen=True)
class DuplicateMatch:
    subject: TrackRef | StagedRef
    kind: Literal["exact", "fingerprint"]
    band: Literal["exact", "strong", "possible"]
    score: float | None  # None for exact


@dataclass(frozen=True)
class LayerCoverage:
    """How much of one owner's live library a layer could actually compare.

    Counts cover only the subject owner's live tracks, minus ``exclude``.
    A track with no identity row counts as pending (unknown), never checked.
    """

    subject_state: str  # the subject's own state on this layer, e.g. "current", "too_short", "unavailable"
    library_pending: int  # not yet computed for this layer (unknown)
    library_failed: int  # computation failed (unknown)
    library_not_comparable: int  # unsupported / too_short / low_information by design; disclosed, not blocking


@dataclass(frozen=True)
class DuplicateReport:
    exact: LayerCoverage
    fingerprint: LayerCoverage
    matches: tuple[DuplicateMatch, ...]

    def no_duplicates_found(self, *, layers) -> bool:
        """THE spec section 5 rule: may a consumer say "no duplicates found"?

        True only when ``matches`` is empty and, for every named layer
        ("exact" and/or "fingerprint"), the subject's state is "current" and
        the library has nothing pending and nothing failed on that layer.
        Not-comparable counts are disclosed but do not block the claim.
        """
        layers = tuple(layers)
        if not layers or any(name not in ("exact", "fingerprint") for name in layers):
            raise ValueError(f"layers must be a non-empty subset of exact/fingerprint, got {layers!r}")
        if self.matches:
            return False
        for name in layers:
            cov = getattr(self, name)
            if cov.subject_state != "current" or cov.library_pending or cov.library_failed:
                return False
        return True


def _coverage(
    conn, identity: AudioIdentity, owner_id: int, exclude: frozenset[str]
) -> tuple[LayerCoverage, LayerCoverage]:
    """Per-layer coverage of the owner's live tracks (minus ``exclude``), one query.

    The counts are real counts, so 0 is a true zero. A live track with no
    identity row is unknown, hence pending on both layers. On the fingerprint
    layer a 'current' row whose print is of another algorithm than the subject's
    (its identity row's ``fp_algorithm``) cannot be compared, so it is pending too.
    """
    excluded = sorted(exclude)
    # ?1 = the subject's print algorithm (NULL: none), ?2 = owner, ?3.. = excluded uuids.
    not_in = f" AND lt.uuid_id NOT IN ({','.join(f'?{i + 3}' for i in range(len(excluded)))})" if excluded else ""
    fp = identity.fingerprint
    algorithm = fp.algorithm if isinstance(fp, FingerprintIdentity) else None
    row = conn.execute(
        "SELECT "
        "COALESCE(SUM(i.uuid_id IS NULL OR i.exact_state = 'pending'), 0), "
        "COALESCE(SUM(i.exact_state = 'failed'), 0), "
        "COALESCE(SUM(i.exact_state = 'unsupported'), 0), "
        "COALESCE(SUM(i.uuid_id IS NULL OR i.fp_state IN ('pending','unavailable') "
        "OR (?1 IS NOT NULL AND i.fp_state = 'current' AND i.fp_algorithm IS NOT ?1)), 0), "
        "COALESCE(SUM(i.fp_state = 'failed'), 0), "
        "COALESCE(SUM(i.fp_state IN ('too_short','low_information')), 0) "
        "FROM live_tracks lt LEFT JOIN track_audio_identity i ON i.uuid_id = lt.uuid_id "
        "WHERE lt.owner_id = ?2" + not_in,
        (algorithm, owner_id, *excluded),
    ).fetchone()
    exact = identity.exact
    state = "current" if isinstance(exact, ExactAudioHash) else exact.state
    return (
        LayerCoverage(state, int(row[0]), int(row[1]), int(row[2])),
        LayerCoverage(_fingerprint_state(identity.fingerprint), int(row[3]), int(row[4]), int(row[5])),
    )


def duration_window(duration_s: float, params: MatcherParams) -> tuple[float, float]:
    """Symmetric window: |d1 - d2| <= max(tol_s, frac * max(d1, d2)), seen from ``duration_s``."""
    tol, frac = params.duration_tolerance_s, params.duration_tolerance_frac
    lo = min(duration_s - tol, duration_s * (1 - frac))
    hi = max(duration_s + tol, duration_s / (1 - frac)) if frac < 1 else float("inf")
    return lo, hi


def within_duration_window(d1: float, d2: float, params: MatcherParams) -> bool:
    """THE duration rule: |d1 - d2| <= max(tol_s, frac * max(d1, d2)). Symmetric."""
    return abs(d1 - d2) <= max(
        params.duration_tolerance_s, params.duration_tolerance_frac * max(d1, d2)
    )


def _compare_prints(
    subject: FingerprintIdentity, prepared: PreparedFingerprint, algorithm: str, duration_s: float,
    items, params: MatcherParams,
) -> tuple[FingerprintBand, float] | None:
    """THE fingerprint match rule: same algorithm, inside the window, comparable, banded.
    ``prepared`` is ``subject.items`` prepared once for the lookup."""
    if algorithm != subject.algorithm:
        return None
    if not within_duration_window(subject.duration_s, duration_s, params):
        return None
    cmp = compare_fingerprints(
        prepared, items, params, duration_a_s=subject.duration_s, duration_b_s=duration_s
    )
    if cmp is None:
        return None
    band = band_for(cmp.score, params)
    return None if band is None else (band, cmp.score)


def _fingerprint_matches(
    conn,
    subject: FingerprintIdentity | FingerprintUnavailable | None,
    owner: int,
    exclude: frozenset[str],
    extra_subjects: Sequence[StagedIdentity],
    params: MatcherParams,
) -> list[DuplicateMatch]:
    from app.services.fingerprinter import unpack_fingerprint  # import cycle

    if not isinstance(subject, FingerprintIdentity) or subject.state != "current":
        return []
    lo, hi = duration_window(subject.duration_s, params)
    rows = conn.execute(
        "SELECT f.uuid_id, f.algorithm, f.duration_s, f.data FROM track_audio_fingerprint f "
        "JOIN track_audio_identity i ON i.uuid_id = f.uuid_id "
        "JOIN live_tracks lt ON lt.uuid_id = f.uuid_id "
        "WHERE i.fp_state = 'current' AND +lt.owner_id = ? AND f.algorithm = ? "
        "AND f.duration_s BETWEEN ? AND ?",
        (owner, subject.algorithm, lo, hi),
    ).fetchall()
    found: list[DuplicateMatch] = []
    prepared = prepare_fingerprint(subject.items)
    for uuid_id, algorithm, duration_s, blob in rows:
        if uuid_id in exclude:
            continue
        hit = _compare_prints(subject, prepared, algorithm, duration_s, unpack_fingerprint(blob), params)
        if hit is not None:
            found.append(DuplicateMatch(TrackRef(uuid_id), "fingerprint", hit[0], hit[1]))
    for staged in extra_subjects:
        other = staged.identity.fingerprint
        if not isinstance(other, FingerprintIdentity) or other.state != "current":
            continue
        hit = _compare_prints(subject, prepared, other.algorithm, other.duration_s, other.items, params)
        if hit is not None:
            found.append(DuplicateMatch(staged.ref, "fingerprint", hit[0], hit[1]))
    return found


def _rank_key(m: DuplicateMatch):
    ref = m.subject
    is_staged = isinstance(ref, StagedRef)
    return (
        BAND_RANK[m.band],
        0.0 if m.score is None else -m.score,
        is_staged,
        ref.item_uuid if is_staged else ref.uuid_id,
    )


def _fingerprint_state(fp) -> str:
    if fp is None:
        return "unavailable"
    if isinstance(fp, FingerprintUnavailable):
        return "failed"
    return fp.state


def find_matches(
    conn,
    identity: AudioIdentity,
    *,
    owner_id: int,
    exclude: frozenset[str] = frozenset(),
    extra_subjects: Sequence[StagedIdentity] = (),
    params: MatcherParams | None = None,
) -> tuple[DuplicateMatch, ...]:
    """The matches of ``find_duplicates``, without the coverage counts.

    Same arguments and the same results as ``find_duplicates(...).matches``;
    it skips the coverage query, which reads every live track of the owner.
    """
    owner = _require_owner(owner_id)
    subject = identity.exact
    library: list[str] = []
    staged: list[StagedRef] = []
    if isinstance(subject, ExactAudioHash):
        rows = conn.execute(
            "SELECT i.uuid_id, i.sample_rate_hz, i.channels, i.bits_per_sample "
            "FROM track_audio_identity i JOIN live_tracks lt ON lt.uuid_id = i.uuid_id "
            "WHERE i.exact_kind = ? AND i.exact_digest = ? AND i.exact_digest IS NOT NULL "
            "AND i.exact_state IN ('current','pending') AND lt.owner_id = ?",
            (subject.kind, subject.digest, owner),
        ).fetchall()
        for row in rows:
            uuid_id = row[0]
            if uuid_id in exclude:
                continue
            candidate = ExactAudioHash(subject.kind, subject.digest, row[1], row[2], row[3])
            if exact_match(subject, candidate):
                library.append(uuid_id)
        staged = [
            s.ref for s in extra_subjects if exact_match(subject, s.identity.exact)
        ]
    if params is None:
        from app.config import settings

        params = MatcherParams.from_settings(settings)
    exact_matches = [DuplicateMatch(TrackRef(u), "exact", "exact", None) for u in library] + [
        DuplicateMatch(r, "exact", "exact", None) for r in staged
    ]
    seen = {m.subject for m in exact_matches}
    fp_matches = [
        m
        for m in _fingerprint_matches(conn, identity.fingerprint, owner, exclude, extra_subjects, params)
        if m.subject not in seen
    ]
    return tuple(sorted(exact_matches + fp_matches, key=_rank_key))


def find_duplicates(
    conn,
    identity: AudioIdentity,
    *,
    owner_id: int,
    exclude: frozenset[str] = frozenset(),
    extra_subjects: Sequence[StagedIdentity] = (),
    params: MatcherParams | None = None,
) -> DuplicateReport:
    """Find the tracks and staged items whose audio matches ``identity``.

    Two layers. The exact layer matches identical decoded-audio hashes. The
    fingerprint layer (when the subject has a current fingerprint) fetches
    the owner's current library prints of the same algorithm in one query,
    and compares them and the staged items' prints through one shared rule:
    same algorithm, duration within max(tol_s, frac * max(d1, d2)), compared
    and banded at or above ``possible``. The window is symmetric, so X finds
    Y exactly when Y finds X. ``params`` defaults to the settings-derived
    ``MatcherParams`` read at call time.

    A track or staged item matching on both layers appears once, as its
    strongest kind (exact wins). ``matches`` is ranked by band (exact,
    strong, possible), then score descending, then library tracks before
    staged items, then uuid / item uuid.

    Scoping: only ``owner_id``'s live tracks are considered. Two users'
    identical audio is never paired. ``owner_id`` must be a real int.

    ``exclude`` is a set of track uuids that must not match or be counted,
    typically the subject track itself when re-checking an existing track.

    ``extra_subjects`` are other candidates that are not library tracks yet
    (Phase 7's active staged items). They go through both layers and are
    reported as ``StagedRef`` matches. They must be the same owner's staged
    items: the finder cannot check their owner, so passing another user's
    staged items would pair across users.

    Results are never capped; display limits belong to the caller. A subject
    without a usable hash or print matches nothing on that layer.

    The coverage counts read every live track of the owner; a caller that
    needs only the matches uses ``find_matches``.

    The queries run on the caller's connection and inside the caller's
    transaction; this function never opens, commits or closes anything.
    """
    matches = find_matches(
        conn, identity, owner_id=owner_id, exclude=exclude,
        extra_subjects=extra_subjects, params=params,
    )
    exact_cov, fp_cov = _coverage(conn, identity, owner_id, exclude)
    return DuplicateReport(exact_cov, fp_cov, matches)
