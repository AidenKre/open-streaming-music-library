"""Duplicate review rules (Phase 8 spec §4)."""

from app.core.keyset_cursor import decode_cursor, page_rows
from app.models.duplicates import (
    DuplicatePairOut,
    DuplicatePairPage,
    DuplicatePairTrack,
    DuplicateSummaryOut,
    PairRequest,
    PairStatusOut,
)
from app.services.deletion_errors import pair_not_found
from app.services.deletion_worker import master_exists_in_root
from app.services.duplicate_detection import BAND_RANK

_BAND_OF_RANK = {rank: band for band, rank in BAND_RANK.items()}


def _track_out(t: dict, root) -> DuplicatePairTrack:
    fields = {k: v for k, v in t.items() if k != "file_path"}
    present, _ = master_exists_in_root(root, t["file_path"])
    return DuplicatePairTrack(**fields, master_present=present)


def _pair_out(row: dict, root) -> DuplicatePairOut:
    return DuplicatePairOut(
        uuid_a=row["uuid_a"],
        uuid_b=row["uuid_b"],
        kind=row["kind"],
        band=_BAND_OF_RANK[row["band_rank"]],
        score=None if row["kind"] == "exact" else row["sort_score"],
        status=row["status"],
        detected_at=row["detected_at"],
        track_a=_track_out(row["track_a"], root),
        track_b=_track_out(row["track_b"], root),
    )


def list_pairs(library, status: str, after: str | None, limit: int) -> DuplicatePairPage:
    cursor = None if after is None else decode_cursor(after, ("int", "float", "uuid", "uuid"))
    rows = library.list_duplicate_candidates(status=status, after=cursor, limit=limit + 1)
    page, next_after = page_rows(
        rows, limit, lambda r: [r["band_rank"], r["sort_score"], r["uuid_a"], r["uuid_b"]]
    )
    return DuplicatePairPage(pairs=[_pair_out(r, library.root) for r in page], next_after=next_after)


def summary(library, fingerprinter_name: str | None) -> DuplicateSummaryOut:
    return DuplicateSummaryOut(
        bands=library.count_duplicate_candidates(),
        coverage=library.get_identity_coverage_summary(),
        fingerprinter=fingerprinter_name,
    )


def set_status(library, body: PairRequest, status: str) -> PairStatusOut:
    a, b = sorted((str(body.uuid_a), str(body.uuid_b)))
    if not library.set_duplicate_candidate_status(a, b, status):
        raise pair_not_found()
    return PairStatusOut(uuid_a=a, uuid_b=b, status=status)
