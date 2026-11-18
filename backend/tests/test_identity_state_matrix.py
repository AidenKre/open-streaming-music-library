"""Refactor B.10, U08-B-01: every writer of the audio-identity rows, run over one
matrix of starting rows, leaves only legal combinations of the three states
(``exact_state``, ``fp_state``, ``match_state``). Test only.

The rules are spread over the identity worker and 20 ``UPDATE
track_audio_identity`` statements in ``database.py`` (each fixed separately in
the past); this file states them once:

- I1: an exact layer that is ``pending`` has matching ``pending``.
- I2: with a fingerprinter, an exact layer that ``failed`` has no ``pending``
  print (the worker never fingerprints an unreadable file; it would strand).
- I3: a ``failed`` print whose failure came with the exact hash's (exact
  ``failed`` or ``pending``) does not stay ``failed`` once a current exact hash
  is written (DEV-6.5-12).
- I4: an ``unavailable`` print becomes ``pending`` only when a fingerprinter is
  declared present (``set_fingerprint_availability``, the reconcile with one).

Two worlds: with a fingerprinter (no starting print is ``unavailable``) and
without one (a print may be ``pending``: a mark, a conversion or the worker
re-pends it, and only the next start makes it ``unavailable``). Every
combination legal in its world is seeded once per ``failure_reason`` the
writers branch on; a ``duration_unknown`` row carries a new fingerprinter
version, so only the ffmpeg-change reset can retry it. The
writers are reached through ``Database``'s public methods (the conversion and
the track editor call the same ones) and through the identity worker's step;
``tests/test_identity_state_matrix.py::test_every_identity_update_statement_has_a_writer_here``
fails when a new statement appears, so it gets a row here.
"""

import ast
import itertools
import re
from pathlib import Path

import pytest

from app import config
from app.database.database import ANY_OWNER, STALE_REASONS
from app.services.audio_identity import AudioIdentity, ExactAudioHash, ExactUnavailable
from app.services.duplicate_detection import MatcherParams
from app.services.fingerprinter import pack_fingerprint
from app.services.identity_worker import reconcile_audio_identity
from tests.identity_worker_fakes import FLAT_ITEMS, VARIED_ITEMS, FakeCompute, FakeFingerprinter, make_worker
from tests.identity_worker_fixtures import DIGEST_A, add_track, sql

EXACT = ("pending", "current", "failed", "unsupported")
FP_WITH = ("pending", "current", "too_short", "low_information", "failed")
FP_WITHOUT = ("unavailable", "pending", "current", "too_short", "low_information", "failed")
MATCH = ("pending", "current")
REASONS = (None, "master_missing", "duration_unknown")
ALG = "chromaprint-2"
OLD_TOOLS = "ffmpeg 1.0; fakeprint 1.0"
NEW_TOOLS = "ffmpeg 2.0; fakeprint 2.0"
NEW_FINGERPRINTER_ONLY = "ffmpeg 1.0; fakeprint 2.0"


def violations(row: dict, *, fingerprinter: bool) -> list[str]:
    found = []
    if row["exact_state"] == "pending" and row["match_state"] != "pending":
        found.append("I1 exact pending, match not pending")
    if fingerprinter and row["exact_state"] == "failed" and row["fp_state"] == "pending":
        found.append("I2 exact failed, print pending")
    return found


def transition_violations(before: dict, after: dict, *, may_claim_fingerprinter: bool) -> list[str]:
    found = []
    if (before["fp_state"] == "failed" and before["exact_state"] in ("failed", "pending")
            and after["exact_state"] == "current" and after["fp_state"] == "failed"):
        found.append("I3 a print failed with the exact hash stays failed after a current hash")
    if before["fp_state"] == "unavailable" and after["fp_state"] == "pending" and not may_claim_fingerprinter:
        found.append("I4 unavailable became pending without a fingerprinter")
    return found


# ── the matrix of starting rows ─────────────────────────────────────────────

def seed(db, folder: Path, *, fingerprinter: bool, attempts: int = 0) -> list[str]:
    folder.mkdir(parents=True, exist_ok=True)
    uuids = []
    fps = FP_WITH if fingerprinter else FP_WITHOUT
    for n, (exact, fp, match, reason) in enumerate(itertools.product(EXACT, fps, MATCH, REASONS)):
        row = {"exact_state": exact, "fp_state": fp, "match_state": match}
        if violations(row, fingerprinter=fingerprinter):
            continue  # only legal rows are a starting point
        path = folder / f"{n}.flac"
        path.write_bytes(f"audio {n}".encode())
        tools = NEW_FINGERPRINTER_ONLY if reason == "duration_unknown" else OLD_TOOLS
        identity = {**row, "failure_reason": reason, "attempts": attempts, "tool_versions": tools,
                    "fp_algorithm": None if fp in ("pending", "unavailable") else ALG}
        if exact in ("current", "pending"):
            identity.update(exact_kind="pcm_sha256", exact_digest=DIGEST_A, sample_rate_hz=44100,
                            channels=2, bits_per_sample=16)
        uuid_id = add_track(db, path, identity=identity)
        if fp in ("current", "low_information"):
            items = VARIED_ITEMS if fp == "current" else FLAT_ITEMS
            sql(db, "INSERT INTO track_audio_fingerprint (uuid_id, backend, algorithm, duration_s, item_count,"
                    " data) VALUES (?, 'fakeprint', ?, 30.0, ?, ?)", (uuid_id, ALG, len(items), pack_fingerprint(items)))
        uuids.append(uuid_id)
    return uuids


def states(db) -> dict[str, dict]:
    return {r["uuid_id"]: r for r in sql(
        db, "SELECT uuid_id, exact_state, fp_state, match_state FROM track_audio_identity")}


def check(before: dict, after: dict, *, fingerprinter: bool, may_claim_fingerprinter: bool = False) -> list:
    bad = []
    for uuid_id, row in after.items():
        found = violations(row, fingerprinter=fingerprinter)
        if uuid_id in before:
            found += transition_violations(before[uuid_id], row, may_claim_fingerprinter=may_claim_fingerprinter)
        bad += [(tuple(before.get(uuid_id, {}).get(k) for k in ("exact_state", "fp_state", "match_state")),
                 tuple(row[k] for k in ("exact_state", "fp_state", "match_state")), v) for v in found]
    return bad


# ── the writers ─────────────────────────────────────────────────────────────

HASH = ExactAudioHash("pcm_sha256", "cc" * 32, 44100, 2, 16)
CONVERSION_IDENTITIES = {
    "hash": HASH,
    "unsupported": ExactUnavailable("unsupported", None),
    "failed": ExactUnavailable("failed", "decode_error"),
}


def _per_row(fn):
    def run(db, uuids):
        for uuid_id in uuids:
            fn(db, uuid_id)
    return run


def _restore_pairs(db, uuids):
    """Dismissed pairs, then restored: the restore re-queues both tracks' matching."""
    for a, b in zip(uuids[::2], uuids[1::2]):
        a, b = min(a, b), max(a, b)
        sql(db, "INSERT INTO track_duplicate_candidates (owner_id, uuid_a, uuid_b, kind, band_rank, sort_score,"
                " matcher_version, detected_at, status) VALUES (?, ?, ?, 'exact', 0, 1.0, 'm0', 0, 'dismissed')",
            (db.owner_id, a, b))
        assert db.set_duplicate_candidate_status(a, b, "open", owner_id=db.owner_id)


def _reclassify(*, fingerprinter: bool, classify):
    def run(db, uuids):
        sql(db, "INSERT OR REPLACE INTO app_settings (key, value) VALUES ('fingerprint_classifier_version', 'old')")
        db.reclassify_fingerprints("new", ALG if fingerprinter else None, classify, owner_id=ANY_OWNER,
                                   fingerprinter_present=fingerprinter)
    return run


def _undecodable_prints_reclassified(*, fingerprinter: bool):
    def run(db, uuids):
        sql(db, "UPDATE track_audio_fingerprint SET data = x'010203'")  # not a multiple of 4 bytes
        _reclassify(fingerprinter=fingerprinter, classify=lambda items: "current")(db, uuids)
    return run


def _swap_class(items):
    return "low_information" if tuple(items) == VARIED_ITEMS else "current"


def _reconcile(*, fingerprinter: bool):
    def run(db, uuids):
        sql(db, "INSERT OR REPLACE INTO app_settings (key, value) VALUES ('fingerprint_classifier_version', 'old')")
        reconcile_audio_identity(
            db, tool_versions=NEW_TOOLS, fingerprinter_present=fingerprinter, matcher_version="m2",
            fingerprint_algorithm="chromaprint-3" if fingerprinter else None,
            classifier_params=MatcherParams.from_settings(config.settings))
    return run


def _insert_missing(*, fingerprinter: bool):
    def run(db, uuids):
        for n in range(2):
            add_track(db, f"/nowhere/new-{n}.flac", identity={"_none": True})
        db.insert_missing_identity_rows(fingerprinter_present=fingerprinter, owner_id=ANY_OWNER)
    return run


# (name, starting world has a fingerprinter, a fingerprinter afterwards, writer, may claim one)
WRITERS = [
    *[(f"mark_audio_identity_stale[{reason},{w}]", w, w,
       _per_row(lambda db, u, reason=reason: db.mark_audio_identity_stale(u, reason, owner_id=db.owner_id)), False)
      for reason in sorted(STALE_REASONS) for w in (True, False)],
    *[(f"write_conversion_identity[{name},unchanged={unchanged},{w}]", w, w,
       _per_row(lambda db, u, identity=identity, unchanged=unchanged: db.write_conversion_identity(
           u, AudioIdentity(exact=identity, tool_versions=NEW_TOOLS, computed_at=1), audio_unchanged=unchanged,
           owner_id=db.owner_id)), False)
      for name, identity in CONVERSION_IDENTITIES.items() for unchanged in (True, False) for w in (True, False)],
    *[(f"set_duplicate_candidate_status[restore,{w}]", w, w, _restore_pairs, False) for w in (True, False)],
    ("set_fingerprint_availability[present,algorithm]", False, True,
     lambda db, u: db.set_fingerprint_availability(True, algorithm="chromaprint-3", owner_id=ANY_OWNER), True),
    # Documented to leave an exact-failed row's print as it is (pending included);
    # no production caller passes "present" without the algorithm (main.py), so
    # I2 is not asked of it: the "afterwards" flag is False.
    ("set_fingerprint_availability[present,no algorithm]", False, False,
     lambda db, u: db.set_fingerprint_availability(True, owner_id=ANY_OWNER), True),
    ("set_fingerprint_availability[absent]", True, False,
     lambda db, u: db.set_fingerprint_availability(False, owner_id=ANY_OWNER), False),
    ("requeue_fingerprint_algorithm", True, True,
     lambda db, u: db.requeue_fingerprint_algorithm("chromaprint-3", owner_id=ANY_OWNER), False),
    *[(f"requeue_matching[{w}]", w, w, lambda db, u: db.requeue_matching("m2", owner_id=ANY_OWNER), False)
      for w in (True, False)],
    ("requeue_unknown_duration_prints", True, True,
     lambda db, u: db.requeue_unknown_duration_prints("rule-2", owner_id=ANY_OWNER), False),
    *[(f"reclassify_fingerprints[{w}]", w, w, _reclassify(fingerprinter=w, classify=_swap_class), False)
      for w in (True, False)],
    *[(f"reclassify_fingerprints[undecodable,{w}]", w, w, _undecodable_prints_reclassified(fingerprinter=w), False)
      for w in (True, False)],
    *[(f"reset_failed_identity_rows[{w}]", w, w,
       lambda db, u, w=w: db.reset_failed_identity_rows(NEW_TOOLS, owner_id=ANY_OWNER, fingerprint=w), False)
      for w in (True, False)],
    *[(f"reset_master_missing_identity[{w}]", w, w,
       lambda db, u, w=w: db.reset_master_missing_identity(u, owner_id=ANY_OWNER, fingerprint=w), False)
      for w in (True, False)],
    *[(f"insert_missing_identity_rows[{w}]", w, w, _insert_missing(fingerprinter=w), w) for w in (True, False)],
    ("reconcile_audio_identity[tool stays]", True, True, _reconcile(fingerprinter=True), True),
    ("reconcile_audio_identity[tool appears]", False, True, _reconcile(fingerprinter=True), True),
    ("reconcile_audio_identity[tool goes]", True, False, _reconcile(fingerprinter=False), False),
    ("reconcile_audio_identity[no tool]", False, False, _reconcile(fingerprinter=False), False),
]


@pytest.mark.parametrize("name, start_with, end_with, writer, may_claim", WRITERS, ids=[w[0] for w in WRITERS])
def test_a_writer_leaves_every_starting_row_legal(db, tmp_path, caplog, name, start_with, end_with, writer,
                                                  may_claim):
    uuids = seed(db, tmp_path / "music", fingerprinter=start_with)
    before = states(db)

    with caplog.at_level("WARNING"):
        writer(db, uuids)

    assert check(before, states(db), fingerprinter=end_with, may_claim_fingerprinter=may_claim) == []
    # The reconcile logs and swallows a failing part: a row must not pass because a part never ran.
    assert [r.getMessage() for r in caplog.records if "identity reconcile:" in r.getMessage()] == []


# ── the worker: exact, fingerprint and match steps, checked after every step ──

class _Always:
    """A result queue that never runs dry."""

    def __init__(self, value):
        self.value = value

    def pop(self, _index=0):
        return self.value

    def __bool__(self):
        return True


WORKER_RESULTS = {
    "computes": (None, None),
    "fails for good": (ExactUnavailable("failed", "decode_error"), RuntimeError("fpcalc failed")),
    "unsupported": (ExactUnavailable("unsupported", None), None),
}


@pytest.mark.parametrize("with_fingerprinter", [True, False], ids=["with fingerprinter", "without"])
@pytest.mark.parametrize("results", sorted(WORKER_RESULTS))
def test_every_worker_step_leaves_every_row_legal(db, tmp_path, results, with_fingerprinter):
    exact_result, fp_error = WORKER_RESULTS[results]
    # Three attempts already spent: a failure now is the final one.
    uuids = seed(db, tmp_path / "music", fingerprinter=with_fingerprinter,
                 attempts=3 if results == "fails for good" else 0)
    compute = FakeCompute()
    if exact_result is not None:
        compute.results = _Always(exact_result)
    fingerprinter = None
    if with_fingerprinter:
        fingerprinter = FakeFingerprinter()
        if fp_error is not None:
            fingerprinter.raises = _Always(fp_error)
    worker = make_worker(db, compute=compute, fingerprinter=fingerprinter, matcher_version="m1")

    steps, bad = 0, []
    for steps in range(1, 6 * len(uuids)):
        before = states(db)
        outcome = worker.process_one().outcome
        bad += [(steps, outcome, *v) for v in check(before, states(db), fingerprinter=with_fingerprinter)]
        if outcome == "idle":
            break
    else:
        pytest.fail(f"the worker did not settle in {steps} steps")

    assert bad == []
    assert steps > len(uuids) // 2  # the worker really worked through the matrix


# ── every statement has a writer above ──────────────────────────────────────

STATEMENTS_BY_METHOD = {
    "_requeue_match_in": 1,  # set_duplicate_candidate_status (restore)
    "_mark_audio_identity_stale_in": 1,  # mark_audio_identity_stale, apply_track_metadata_edit
    "_write_conversion_identity_in": 1,  # write_conversion_identity, complete_conversion_job
    "update_identity_if_unchanged": 1,  # the worker's exact and fingerprint steps
    "_write_fingerprint_in": 1,  # the worker's fingerprint step, reclassify, a precomputed insert
    "store_duplicate_candidates": 1,  # the worker's match step
    "set_fingerprint_availability": 3,
    "requeue_fingerprint_algorithm": 1,
    "requeue_matching": 1,
    "requeue_unknown_duration_prints": 1,
    "reclassify_fingerprints": 3,
    "reset_failed_identity_rows": 3,
    "reset_master_missing_identity": 2,
}


UPDATE = re.compile(r"update\s+track_audio_identity\b", re.I)


def test_every_identity_update_statement_has_a_writer_here():
    """A structural tripwire (it names methods on purpose): a new UPDATE of the
    identity rows fails here until it gets a writer row above."""
    source = (Path(__file__).parent.parent / "app" / "database" / "database.py").read_text()
    found = {}
    for node in ast.walk(ast.parse(source)):
        if isinstance(node, ast.FunctionDef):
            text = ast.get_source_segment(source, node)
            count = len(UPDATE.findall(text))
            nested = sum(len(UPDATE.findall(ast.get_source_segment(source, inner)))
                         for inner in ast.walk(node) if inner is not node and isinstance(inner, ast.FunctionDef))
            if count - nested:
                found[node.name] = count - nested
    assert found == STATEMENTS_BY_METHOD
    assert sum(found.values()) == 20
