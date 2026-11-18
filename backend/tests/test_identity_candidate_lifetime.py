"""Open candidate pairs end when a layer settles as not comparable (sign-off DEV-6.5-15).

When a track's fingerprint settles as ``too_short`` or ``low_information``,
its open fingerprint pairs are removed; when its exact layer settles as
``unsupported``, its open exact pairs are removed. ``failed`` means unknown,
and unknown is not "no match": a layer that fails keeps its pairs as they are.
The pair rested on evidence that no longer exists. Dismissed pairs record the
user's decision and are never removed by this rule. A pair of the other kind
is kept. When the layer becomes ``current`` again, matching recreates the pair.
"""

import pytest

from app.services.audio_identity import KIND_PCM, ExactUnavailable
from app.services.fingerprinter import FingerprintFailure, RawFingerprint, pack_fingerprint
from tests.fingerprint_fixtures import ALGO, BASE
from tests.identity_worker_fakes import (
    FLAT_ITEMS,
    FakeClock,
    FakeCompute,
    FakeFingerprinter,
    bytes_digest,
    make_worker,
)
from tests.identity_worker_fixtures import add_track, identity, set_identity, sql
from tests.owned_database import add_test_user

V1 = "matcher-v1"


@pytest.fixture
def music(tmp_path):
    root = tmp_path / "music"
    root.mkdir()
    return root


def printed(db, music, name, *, content=None, owner_id=None):
    """A settled track waiting only for matching, with a stored current print BASE."""
    path = music / f"{name}.flac"
    path.write_bytes(content if content is not None else name.encode())
    uuid_id = add_track(db, path, owner_id=owner_id, identity={
        "exact_state": "current", "exact_kind": KIND_PCM, "exact_digest": bytes_digest(path),
        "sample_rate_hz": 44100, "channels": 2, "bits_per_sample": 16,
        "fp_state": "current", "fp_algorithm": ALGO})
    sql(db, "INSERT INTO track_audio_fingerprint (uuid_id, backend, algorithm, duration_s, item_count, data) "
            "VALUES (?, 'fpcalc', ?, 200.0, ?, ?)", (uuid_id, ALGO, len(BASE), pack_fingerprint(BASE)))
    return uuid_id


def drain(worker, limit=200):
    for _ in range(limit):
        if worker.process_one().outcome == "idle":
            return
    raise AssertionError("worker never went idle")


def pair(db, a, b):
    rows = sql(db, "SELECT * FROM track_duplicate_candidates WHERE uuid_a = ? AND uuid_b = ?",
               (min(a, b), max(a, b)))
    return rows[0] if rows else None


def fingerprinter(*results):
    fp = FakeFingerprinter()
    fp.results.extend(results)
    return fp


def refingerprint(db, uuid_id, **values):
    """The print goes back to pending (as after an algorithm change); matching stays current."""
    set_identity(db, uuid_id, fp_state="pending", **values)


NOT_COMPARABLE_PRINTS = {
    "too_short": (RawFingerprint(BASE[:40], 6.0), {}),
    "low_information": (RawFingerprint(FLAT_ITEMS, 200.0), {}),
}
# One attempt left: this failure is the last one.
FAILED_PRINT = (FingerprintFailure("decode_error"), {"attempts": 3})


# --- fingerprint layer ---------------------------------------------------------------------------


@pytest.mark.parametrize("state", sorted(NOT_COMPARABLE_PRINTS))
def test_an_open_fingerprint_pair_goes_when_a_print_settles_not_comparable(db, music, state):
    x, y = printed(db, music, "x"), printed(db, music, "y")
    drain(make_worker(db, matcher_version=V1))
    assert pair(db, x, y)["kind"] == "fingerprint"

    result, extra = NOT_COMPARABLE_PRINTS[state]
    refingerprint(db, y, **extra)
    drain(make_worker(db, matcher_version=V1, fingerprinter=fingerprinter(result)))

    assert identity(db, y)["fp_state"] == state
    assert pair(db, x, y) is None


@pytest.mark.parametrize("state", sorted(NOT_COMPARABLE_PRINTS))
def test_a_dismissed_fingerprint_pair_is_kept(db, music, state):
    x, y = printed(db, music, "x"), printed(db, music, "y")
    drain(make_worker(db, matcher_version=V1))
    sql(db, "UPDATE track_duplicate_candidates SET status = 'dismissed'")

    result, extra = NOT_COMPARABLE_PRINTS[state]
    refingerprint(db, y, **extra)
    drain(make_worker(db, matcher_version=V1, fingerprinter=fingerprinter(result)))

    assert identity(db, y)["fp_state"] == state
    assert pair(db, x, y)["status"] == "dismissed"


def test_an_exact_pair_survives_a_print_that_settles_too_short(db, music):
    x = printed(db, music, "x", content=b"same-audio")
    y = printed(db, music, "y", content=b"same-audio")
    drain(make_worker(db, matcher_version=V1))
    assert pair(db, x, y)["kind"] == "exact"

    refingerprint(db, y)
    drain(make_worker(db, matcher_version=V1,
                      fingerprinter=fingerprinter(NOT_COMPARABLE_PRINTS["too_short"][0])))

    assert identity(db, y)["fp_state"] == "too_short"
    assert pair(db, x, y)["kind"] == "exact"


def test_only_the_settled_tracks_pairs_go(db, music):
    x, y, z = printed(db, music, "x"), printed(db, music, "y"), printed(db, music, "z")
    drain(make_worker(db, matcher_version=V1))

    refingerprint(db, y)
    drain(make_worker(db, matcher_version=V1,
                      fingerprinter=fingerprinter(NOT_COMPARABLE_PRINTS["low_information"][0])))

    assert pair(db, x, y) is None and pair(db, y, z) is None
    assert pair(db, x, z)["status"] == "open"


def test_another_owners_pairs_that_do_not_involve_the_track_are_untouched(db, music):
    """The drop is scoped to the settled track's own pairs. (A pair can never span
    owners: the composite foreign keys forbid it, tested with the candidate store.)"""
    other = add_test_user(db, "other")
    x, y = printed(db, music, "x"), printed(db, music, "y")
    ox = printed(db, music, "ox", owner_id=other)
    oy = printed(db, music, "oy", owner_id=other)
    drain(make_worker(db, matcher_version=V1))

    refingerprint(db, y)
    drain(make_worker(db, matcher_version=V1,
                      fingerprinter=fingerprinter(NOT_COMPARABLE_PRINTS["too_short"][0])))

    assert pair(db, x, y) is None
    assert pair(db, ox, oy)["status"] == "open"


def test_the_pair_comes_back_when_the_print_is_current_again(db, music):
    x, y = printed(db, music, "x"), printed(db, music, "y")
    drain(make_worker(db, matcher_version=V1))
    refingerprint(db, y)
    drain(make_worker(db, matcher_version=V1,
                      fingerprinter=fingerprinter(NOT_COMPARABLE_PRINTS["too_short"][0])))
    assert pair(db, x, y) is None

    refingerprint(db, y)
    drain(make_worker(db, matcher_version=V1, fingerprinter=fingerprinter(RawFingerprint(BASE, 200.0))))

    assert identity(db, y)["fp_state"] == "current"
    assert pair(db, x, y)["status"] == "open"


# --- exact layer ---------------------------------------------------------------------------------


def copy(db, music, name, content=b"same-audio", **values):
    path = music / f"{name}.flac"
    path.write_bytes(content)
    return add_track(db, path, identity=values or None)


NOT_COMPARABLE_EXACT = {
    "unsupported": (ExactUnavailable("unsupported", None), {}),
}
FAILED_EXACT = (ExactUnavailable("failed", "decode_error"), {"attempts": 3})


def reexact(db, uuid_id, **values):
    """The exact layer goes back to pending (digest kept, as after a tag-write mark)."""
    set_identity(db, uuid_id, exact_state="pending", match_state="pending", **values)


@pytest.mark.parametrize("state", sorted(NOT_COMPARABLE_EXACT))
def test_an_open_exact_pair_goes_when_the_exact_layer_settles_not_comparable(db, music, state):
    x, y = copy(db, music, "x"), copy(db, music, "y")
    drain(make_worker(db, matcher_version=V1))
    assert pair(db, x, y)["kind"] == "exact"

    result, extra = NOT_COMPARABLE_EXACT[state]
    reexact(db, y, **extra)
    compute = FakeCompute()
    compute.results.append(result)
    drain(make_worker(db, matcher_version=V1, compute=compute, clock=FakeClock()))

    assert identity(db, y)["exact_state"] == state
    assert pair(db, x, y) is None


@pytest.mark.parametrize("state", sorted(NOT_COMPARABLE_EXACT))
def test_a_dismissed_exact_pair_is_kept(db, music, state):
    x, y = copy(db, music, "x"), copy(db, music, "y")
    drain(make_worker(db, matcher_version=V1))
    sql(db, "UPDATE track_duplicate_candidates SET status = 'dismissed'")

    result, extra = NOT_COMPARABLE_EXACT[state]
    reexact(db, y, **extra)
    compute = FakeCompute()
    compute.results.append(result)
    drain(make_worker(db, matcher_version=V1, compute=compute))

    assert identity(db, y)["exact_state"] == state
    assert pair(db, x, y)["status"] == "dismissed"


def test_the_exact_pair_comes_back_when_the_hash_is_current_again(db, music):
    x, y = copy(db, music, "x"), copy(db, music, "y")
    drain(make_worker(db, matcher_version=V1))
    reexact(db, y)
    compute = FakeCompute()
    compute.results.append(ExactUnavailable("unsupported", None))
    drain(make_worker(db, matcher_version=V1, compute=compute))
    assert pair(db, x, y) is None

    reexact(db, y)
    drain(make_worker(db, matcher_version=V1))

    assert identity(db, y)["exact_state"] == "current"
    assert pair(db, x, y)["status"] == "open"


# --- a failed layer is unknown: its pairs stay ------------------------------------------------------


@pytest.mark.parametrize("both", [False, True], ids=["partner-fails", "both-fail"])
def test_an_open_fingerprint_pair_survives_a_print_that_fails(db, music, both):
    x, y = printed(db, music, "x"), printed(db, music, "y")
    drain(make_worker(db, matcher_version=V1))
    assert pair(db, x, y)["band_rank"] == 1  # strong

    failing = [y, x] if both else [y]
    result, extra = FAILED_PRINT
    for uuid_id in failing:
        refingerprint(db, uuid_id, **extra)
    drain(make_worker(db, matcher_version=V1, fingerprinter=fingerprinter(*[result] * len(failing))))

    assert all(identity(db, u)["fp_state"] == "failed" for u in failing)
    row = pair(db, x, y)
    assert row is not None, "a failed (unknown) print must keep its pair"
    assert (row["status"], row["kind"], row["band_rank"]) == ("open", "fingerprint", 1)


@pytest.mark.parametrize("both", [False, True], ids=["partner-fails", "both-fail"])
def test_an_open_exact_pair_survives_an_exact_layer_that_fails(db, music, both):
    x, y = copy(db, music, "x"), copy(db, music, "y")
    drain(make_worker(db, matcher_version=V1))
    assert pair(db, x, y)["kind"] == "exact"

    failing = [y, x] if both else [y]
    result, extra = FAILED_EXACT
    for uuid_id in failing:
        reexact(db, uuid_id, **extra)
    compute = FakeCompute()
    compute.results.extend([result] * len(failing))
    drain(make_worker(db, matcher_version=V1, compute=compute))

    assert all(identity(db, u)["exact_state"] == "failed" for u in failing)
    row = pair(db, x, y)
    assert row is not None, "a failed (unknown) exact layer must keep its pair"
    assert (row["status"], row["kind"]) == ("open", "exact")


# --- the insert and conversion writers (Phase 7's upload path reaches both) -----------------------


def _unsupported():
    from app.services.audio_identity import AudioIdentity

    return AudioIdentity(exact=ExactUnavailable("unsupported", None), tool_versions=None, computed_at=0)


def _write_unsupported_by_insert(conn, uuid_id):
    from app.database.database import Database

    Database._insert_audio_identity_in(conn, uuid_id, _unsupported(), fingerprinter_present=False)


def _write_unsupported_by_conversion(conn, uuid_id):
    from app.database.database import Database

    assert Database._write_conversion_identity_in(conn, uuid_id, _unsupported(), audio_unchanged=False)


WRITERS = {"insert": _write_unsupported_by_insert, "conversion": _write_unsupported_by_conversion}


@pytest.mark.parametrize("writer", sorted(WRITERS))
@pytest.mark.parametrize("status,kept", [("open", False), ("dismissed", True)])
def test_a_writer_that_stores_an_unsupported_exact_layer_drops_only_open_exact_pairs(
    db, music, writer, status, kept
):
    x, y = copy(db, music, "x"), copy(db, music, "y")
    drain(make_worker(db, matcher_version=V1))
    assert pair(db, x, y)["kind"] == "exact"
    sql(db, "UPDATE track_duplicate_candidates SET status = ?", (status,))

    with db._connection(commit=True, immediate=True) as conn:
        WRITERS[writer](conn, y)

    assert identity(db, y)["exact_state"] == "unsupported"
    row = pair(db, x, y)
    assert (row is not None and row["status"] == status) if kept else row is None
