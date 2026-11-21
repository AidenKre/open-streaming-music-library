"""The finder's matches-only path (``find_matches``).

The identity worker stores only the matches of each match step; the coverage
counts of ``find_duplicates`` read every live track of the owner, so computing
them on every step made a backfill or a re-match read N rows N times. The
matches-only path gives exactly the matches the full report gives, and what it
reads does not grow with tracks that cannot match.

Prints: ``noisy(BASE, k)`` scores exactly 1 - k/32 (see ``fingerprint_fixtures``).
"""

import sqlite3

import pytest

from app.services import duplicate_detection
from app.services.audio_identity import (
    KIND_PCM,
    AudioIdentity,
    ExactAudioHash,
    ExactUnavailable,
    FingerprintIdentity,
)
from app.services.duplicate_detection import (
    StagedIdentity,
    StagedRef,
    TrackRef,
    find_duplicates,
    find_matches,
)
from tests.fingerprint_fixtures import ALGO, BASE, EXPLICIT, fp_track, noisy

T = 1_800_000_000
SUBJECT_DIGEST = "ee" * 32


@pytest.fixture
def conn(db):
    connection = sqlite3.connect(db.context.database_path)
    connection.execute("PRAGMA foreign_keys=ON")
    yield connection
    connection.close()


def print_of(items=BASE, duration=200.0):
    return FingerprintIdentity("current", "fpcalc", ALGO, duration, tuple(items))


def ident(*, exact=True, fingerprint=True) -> AudioIdentity:
    return AudioIdentity(
        exact=ExactAudioHash(KIND_PCM, SUBJECT_DIGEST, 44100, 2, 16) if exact
        else ExactUnavailable("unsupported", None),
        tool_versions="ffmpeg 9; fpcalc 1.6.2", computed_at=T,
        fingerprint=print_of() if fingerprint else None)


def staged(item_uuid, *, items=BASE, digest=None) -> StagedIdentity:
    exact = ExactAudioHash(KIND_PCM, digest or (item_uuid.encode().hex() * 64)[:64], 44100, 2, 16)
    return StagedIdentity(StagedRef(item_uuid), AudioIdentity(
        exact=exact, tool_versions="ffmpeg 9", computed_at=T, fingerprint=print_of(items)))


def library(db) -> dict[str, str]:
    """A library with an exact copy, strong and possible prints, a print below
    possible, one outside the length window and the subject itself."""
    return {
        "self": fp_track(db, "self", digest=SUBJECT_DIGEST),
        "exact": fp_track(db, "exact", noisy(BASE, 8), digest=SUBJECT_DIGEST),
        "strong": fp_track(db, "strong", noisy(BASE, 1)),       # 0.96875
        "possible": fp_track(db, "possible", noisy(BASE, 5)),   # 0.84375
        "below": fp_track(db, "below", noisy(BASE, 8)),         # 0.75: below possible 0.80
        "far": fp_track(db, "far", duration=260.0),             # outside max(3 s, 2%)
    }


EXTRA = (
    staged("item-exact", items=noisy(BASE, 8), digest=SUBJECT_DIGEST),
    staged("item-strong", items=noisy(BASE, 2)),
    staged("item-below", items=noisy(BASE, 9)),
)


@pytest.mark.parametrize("subject", [
    ident(), ident(exact=False), ident(fingerprint=False), ident(exact=False, fingerprint=False),
], ids=["both-layers", "fingerprint-only", "exact-only", "neither"])
@pytest.mark.parametrize("excluded", [False, True], ids=["all", "self-excluded"])
def test_the_matches_only_path_gives_the_reports_matches(db, conn, subject, excluded):
    tracks = library(db)
    kwargs = dict(owner_id=db.owner_id, extra_subjects=EXTRA, params=EXPLICIT,
                  exclude=frozenset({tracks["self"]}) if excluded else frozenset())

    matches = find_matches(conn, subject, **kwargs)

    assert matches == find_duplicates(conn, subject, **kwargs).matches
    if isinstance(subject.exact, ExactAudioHash) and subject.fingerprint is not None:
        expected = {TrackRef(tracks[n]) for n in ("self", "exact", "strong", "possible")}
        expected |= {StagedRef("item-exact"), StagedRef("item-strong")}
        if excluded:
            expected.discard(TrackRef(tracks["self"]))
        assert {m.subject for m in matches} == expected


@pytest.mark.parametrize("owner", [None, True, "1"])
def test_the_matches_only_path_requires_a_real_owner(db, conn, owner):
    with pytest.raises(TypeError):
        find_matches(conn, ident(), owner_id=owner, params=EXPLICIT)


class _Reads:
    """What one call reads on ``conn``: its statements, and the virtual machine
    instructions SQLite ran for them (a deterministic count of the work)."""

    def __init__(self, conn):
        self.conn = conn
        self.statements: list[str] = []
        self.steps = 0

    def _step(self):
        self.steps += 1
        return 0

    def __enter__(self):
        self.conn.set_trace_callback(self.statements.append)
        self.conn.set_progress_handler(self._step, 1)
        return self

    def __exit__(self, *exc):
        self.conn.set_trace_callback(None)
        self.conn.set_progress_handler(None, 1)


def _reads(conn, fn, subject, owner_id, exclude):
    """Counted on the second of two identical calls: the first also pays the
    connection's one-off costs (loading the schema, preparing statements)."""
    for _ in range(2):
        with _Reads(conn) as reads:
            fn(conn, subject, owner_id=owner_id, exclude=exclude, params=EXPLICIT)
    return reads


def test_one_match_step_reads_two_queries_and_nothing_that_grows_with_unrelated_tracks(db, conn):
    tracks = library(db)
    exclude = frozenset({tracks["self"]})
    subject = ident()
    paths = (find_matches, find_duplicates)

    small = {fn: _reads(conn, fn, subject, db.owner_id, exclude) for fn in paths}
    for i in range(60):  # other music: another digest, outside the length window
        fp_track(db, f"other-{i}", noisy(BASE, 3), duration=400.0 + i)
    large = {fn: _reads(conn, fn, subject, db.owner_id, exclude) for fn in paths}

    # Before: three queries, the coverage count reading every live track of the owner.
    assert len(small[find_duplicates].statements) == 3
    assert large[find_duplicates].steps > small[find_duplicates].steps
    # After: the exact lookup and the print lookup only, through their indexes.
    assert len(small[find_matches].statements) == 2
    assert not any("live_tracks lt LEFT JOIN" in s for s in small[find_matches].statements)
    assert large[find_matches].steps == small[find_matches].steps


def test_the_report_still_counts_its_coverage(db, conn, monkeypatch):
    library(db)
    calls = []
    real = duplicate_detection._coverage
    monkeypatch.setattr(duplicate_detection, "_coverage", lambda *a: calls.append(1) or real(*a))

    report = find_duplicates(conn, ident(), owner_id=db.owner_id, params=EXPLICIT)
    find_matches(conn, ident(), owner_id=db.owner_id, params=EXPLICIT)

    assert calls == [1]
    assert report.exact.library_pending == 0 and report.fingerprint.subject_state == "current"
