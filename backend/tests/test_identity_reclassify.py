"""A change to FP_MIN_ITEMS or FP_MIN_DIVERSITY applies to stored prints (spec §6.4
"a tuning change ... is applied to existing candidates").

The two settings decide a print's class (``current`` / ``too_short`` /
``low_information``). After either changes and the server restarts, the
startup reconcile reclassifies every stored print of the active algorithm
from its stored blob; a ``too_short`` row has no blob, so its print is
computed again. Matching re-runs only for the rows whose class changed: the
two settings are not part of ``matcher_version``, so the rest of the library
is not re-matched. Expected classes come from the item counts and coarse
key counts written out below, not from the classifier.
"""

from dataclasses import replace
from itertools import count

import pytest
from fastapi.testclient import TestClient

from app.config import Settings
from app.services import fingerprinter as fingerprinter_mod
from app.services.audio_identity import KIND_PCM
from app.services.duplicate_detection import MatcherParams, classifier_version, matcher_version
from app.services.fingerprinter import pack_fingerprint
from app.services.identity_worker import reconcile_audio_identity
from tests.identity_worker_fakes import FakeFingerprinter
from tests.identity_worker_fixtures import add_track, identity, sql

ALGO = "chromaprint-2"
SETTING = "fingerprint_classifier_version"

# 200 items with 200 distinct top-14-bit keys: diversity 1.0.
VARIED = tuple(i << 18 for i in range(200))
# 200 items with 40 distinct top-14-bit keys: diversity 0.20.
MID = tuple(((i % 40) << 18) | i for i in range(200))
# 130 fully diverse items.
SHORT = tuple(i << 18 for i in range(130))

BASE = MatcherParams.from_settings(Settings(_env_file=None))  # min_items 120, min_diversity 0.15


_NUMBERS = count()  # one path per track


def printed(db, items, state, *, algorithm=ALGO, match_state="current", owner_id=None):
    uuid_id = add_track(db, f"/m/{next(_NUMBERS)}.flac", owner_id=owner_id, identity={
        "exact_state": "current", "exact_kind": KIND_PCM, "exact_digest": "ab" * 32,
        "sample_rate_hz": 44100, "channels": 2, "fp_state": state, "fp_algorithm": algorithm,
        "match_state": match_state})
    if items is not None:
        sql(db, "INSERT INTO track_audio_fingerprint (uuid_id, backend, algorithm, duration_s, item_count, data) "
                "VALUES (?, 'fpcalc', ?, 30.0, ?, ?)", (uuid_id, algorithm, len(items), pack_fingerprint(items)))
    return uuid_id


def reconcile(db, params, *, fingerprinter_present=True):
    reconcile_audio_identity(
        db, tool_versions=None, fingerprinter_present=fingerprinter_present,
        fingerprint_algorithm=ALGO if fingerprinter_present else None,
        matcher_version=matcher_version(params), classifier_params=params,
    )


def state(db, uuid_id):
    row = identity(db, uuid_id)
    return row["fp_state"], row["match_state"]


def blob(db, uuid_id):
    return sql(db, "SELECT item_count FROM track_audio_fingerprint WHERE uuid_id = ?", (uuid_id,))


def stored_version(db):
    rows = sql(db, "SELECT value FROM app_settings WHERE key = ?", (SETTING,))
    return rows[0]["value"] if rows else None


def settled_at(db, params):
    """The library as it stands after a startup with ``params`` and the worker's
    matching: both versions stored, every row matched."""
    reconcile(db, params)
    assert stored_version(db) == classifier_version(params)
    sql(db, "UPDATE track_audio_identity SET match_state = 'current'")


# --- the versions ----------------------------------------------------------------------------------


@pytest.mark.parametrize("change", [{"min_items": 150}, {"min_diversity": 0.25}])
def test_the_class_settings_change_the_classifier_version_not_the_matcher_version(change):
    changed = replace(BASE, **change)

    assert matcher_version(changed) == matcher_version(BASE)
    assert classifier_version(changed) != classifier_version(BASE)


@pytest.mark.parametrize("change", [{"strong": 0.95}, {"max_offset": 30}, {"min_overlap": 100}])
def test_a_matching_setting_leaves_the_classifier_version_alone(change):
    assert classifier_version(replace(BASE, **change)) == classifier_version(BASE)


@pytest.mark.parametrize("constant", ["COARSE_KEY_BITS"])
def test_the_classifier_version_changes_with_the_diversity_rule(constant, monkeypatch):
    import app.services.duplicate_detection as dd

    before = classifier_version(BASE)
    monkeypatch.setattr(dd, constant, getattr(dd, constant) + 1)

    assert classifier_version(BASE) != before


# --- reclassification at startup -------------------------------------------------------------------


def test_raising_the_diversity_minimum_makes_a_middling_print_low_information(db):
    varied, mid = printed(db, VARIED, "current"), printed(db, MID, "current")
    settled_at(db, BASE)

    reconcile(db, replace(BASE, min_diversity=0.25))

    assert state(db, mid) == ("low_information", "pending")  # re-matched: its pairs are re-decided
    assert blob(db, mid) == [{"item_count": 200}]  # low_information keeps its print
    assert state(db, varied) == ("current", "current")  # unchanged class: not re-matched


def test_lowering_the_diversity_minimum_revives_a_low_information_print(db):
    mid = printed(db, MID, "low_information")
    settled_at(db, replace(BASE, min_diversity=0.25))

    reconcile(db, BASE)

    assert state(db, mid) == ("current", "pending")


def test_raising_the_item_minimum_makes_a_short_print_too_short_and_drops_its_blob(db):
    short, varied = printed(db, SHORT, "current"), printed(db, VARIED, "current")
    settled_at(db, BASE)

    reconcile(db, replace(BASE, min_items=150))

    assert state(db, short) == ("too_short", "pending")
    assert blob(db, short) == []
    assert state(db, varied) == ("current", "current")


def test_a_too_short_row_has_no_blob_so_its_print_is_computed_again(db):
    clip = printed(db, None, "too_short")
    settled_at(db, replace(BASE, min_items=150))

    reconcile(db, BASE)

    assert identity(db, clip)["fp_state"] == "pending"


def test_an_open_pair_goes_when_its_print_becomes_low_information(db):
    x, mid = printed(db, MID, "current"), printed(db, MID, "current")
    settled_at(db, BASE)
    a, b = min(x, mid), max(x, mid)
    sql(db, "INSERT INTO track_duplicate_candidates (owner_id, uuid_a, uuid_b, kind, band_rank, sort_score, "
            "matcher_version, detected_at) VALUES (?, ?, ?, 'fingerprint', 1, 0.99, 'v', 0)", (db.owner_id, a, b))

    reconcile(db, replace(BASE, min_diversity=0.25))

    assert sql(db, "SELECT * FROM track_duplicate_candidates") == []


def test_an_unchanged_classifier_version_changes_nothing(db):
    mid, clip = printed(db, MID, "current"), printed(db, None, "too_short")
    settled_at(db, BASE)
    before = sql(db, "SELECT * FROM track_audio_identity ORDER BY uuid_id")

    reconcile(db, BASE)

    assert sql(db, "SELECT * FROM track_audio_identity ORDER BY uuid_id") == before
    assert state(db, mid) == ("current", "current") and identity(db, clip)["fp_state"] == "too_short"


def test_a_print_of_another_algorithm_is_not_reclassified_here(db):
    # The algorithm step already sends it back to pending; it is never read as this algorithm.
    old = printed(db, MID, "current", algorithm="chromaprint-1")
    settled_at(db, BASE)

    reconcile(db, replace(BASE, min_diversity=0.25))

    assert identity(db, old)["fp_state"] == "pending"


def test_without_a_fingerprinter_stored_prints_are_still_reclassified(db):
    # The worker still matches stored current prints, so they must reflect the settings.
    mid = printed(db, MID, "current")
    settled_at(db, BASE)

    reconcile(db, replace(BASE, min_diversity=0.25), fingerprinter_present=False)

    assert state(db, mid) == ("low_information", "pending")
    assert stored_version(db) == classifier_version(replace(BASE, min_diversity=0.25))


def test_without_a_fingerprinter_a_too_short_print_waits_as_unavailable(db):
    clip = printed(db, None, "too_short")
    settled_at(db, replace(BASE, min_items=150))

    reconcile(db, BASE, fingerprinter_present=False)
    assert identity(db, clip)["fp_state"] == "unavailable"  # nothing could compute it now

    reconcile(db, BASE)  # a fingerprinter appears
    assert identity(db, clip)["fp_state"] == "pending"


def test_a_too_short_print_whose_exact_layer_is_pending_is_also_computed_again(db):
    # A tag write re-pends the exact layer and keeps the print; the lowered item
    # minimum must still reach it.
    clip = printed(db, None, "too_short")
    settled_at(db, replace(BASE, min_items=150))
    sql(db, "UPDATE track_audio_identity SET exact_state = 'pending', attempts = 1, "
            "next_attempt_at = 5, failure_reason = 'timeout' WHERE uuid_id = ?", (clip,))

    reconcile(db, BASE)

    row = identity(db, clip)
    assert row["fp_state"] == "pending"
    # The exact layer owns the attempt columns while it is pending: they are kept.
    assert (row["attempts"], row["next_attempt_at"], row["failure_reason"]) == (1, 5, "timeout")


def test_a_too_short_print_whose_exact_layer_failed_becomes_failed_not_pending(db):
    """The worker never fingerprints a row whose exact layer failed; a 'pending'
    print there would never be computed and would keep coverage "still checking"."""
    clip = printed(db, None, "too_short")
    settled_at(db, replace(BASE, min_items=150))
    sql(db, "UPDATE track_audio_identity SET exact_state = 'failed', attempts = 4, "
            "failure_reason = 'timeout' WHERE uuid_id = ?", (clip,))

    reconcile(db, BASE)

    row = identity(db, clip)
    assert row["fp_state"] == "failed"
    assert (row["attempts"], row["failure_reason"]) == (4, "timeout")  # the exact layer's, kept


def test_without_a_fingerprinter_a_too_short_print_behind_a_failed_exact_layer_is_unavailable(db):
    clip = printed(db, None, "too_short")
    settled_at(db, replace(BASE, min_items=150))
    sql(db, "UPDATE track_audio_identity SET exact_state = 'failed' WHERE uuid_id = ?", (clip,))

    reconcile(db, BASE, fingerprinter_present=False)

    assert identity(db, clip)["fp_state"] == "unavailable"


# --- bounded, resumable, and one bad print does not stop it ----------------------------------------


def _bad_print(db, *, match_state="current"):
    """A stored print whose blob cannot be decoded (length not a multiple of 4)."""
    uuid_id = printed(db, None, "current", match_state=match_state)
    sql(db, "INSERT INTO track_audio_fingerprint (uuid_id, backend, algorithm, duration_s, item_count, data) "
            "VALUES (?, 'fpcalc', ?, 30.0, 1, ?)", (uuid_id, ALGO, b"\x01\x02\x03"))
    return uuid_id


def _classify(params, *, fail_on_call=None):
    from app.services.fingerprinter import RawFingerprint, classify

    calls = []

    def run(items):
        calls.append(1)
        if fail_on_call is not None and len(calls) == fail_on_call:
            raise RuntimeError("the process died here")
        return classify(RawFingerprint(items, None), params)

    return run


def test_reclassification_works_in_batches_and_resumes_after_a_failure_part_way(db, monkeypatch):
    """Each batch commits on its own; the version is stored only when every row is
    done. A failure part-way keeps the finished batches and leaves the rest due."""
    from app.database.database import ANY_OWNER, Database

    monkeypatch.setattr(Database, "RECLASSIFY_BATCH_SIZE", 2, raising=False)
    rows = [printed(db, MID, "current") for _ in range(5)]
    settled_at(db, BASE)
    raised = replace(BASE, min_diversity=0.25)
    old_version = stored_version(db)

    with pytest.raises(RuntimeError):
        db.reclassify_fingerprints(classifier_version(raised), ALGO, _classify(raised, fail_on_call=4),
                                   owner_id=ANY_OWNER)

    assert [state(db, u)[0] for u in rows] == \
        ["low_information", "low_information", "current", "current", "current"]
    assert stored_version(db) == old_version  # not done: due again at the next start

    db.reclassify_fingerprints(classifier_version(raised), ALGO, _classify(raised), owner_id=ANY_OWNER)

    assert [state(db, u)[0] for u in rows] == ["low_information"] * 5
    assert stored_version(db) == classifier_version(raised)


def test_an_undecodable_print_is_computed_again_and_the_rest_are_reclassified(db):
    mid, bad = printed(db, MID, "current"), _bad_print(db)
    raised = replace(BASE, min_diversity=0.25)

    reconcile(db, raised)

    assert state(db, mid) == ("low_information", "pending")
    assert state(db, bad) == ("pending", "pending")  # its print is computed again
    assert blob(db, bad) == []
    assert stored_version(db) == classifier_version(raised)


def test_an_undecodable_print_behind_a_failed_exact_layer_becomes_failed(db):
    bad = _bad_print(db)
    sql(db, "UPDATE track_audio_identity SET exact_state = 'failed' WHERE uuid_id = ?", (bad,))
    raised = replace(BASE, min_diversity=0.25)

    reconcile(db, raised)

    assert identity(db, bad)["fp_state"] == "failed"
    assert blob(db, bad) == []
    assert stored_version(db) == classifier_version(raised)


def test_without_a_fingerprinter_an_undecodable_print_waits_as_unavailable(db):
    bad = _bad_print(db)
    raised = replace(BASE, min_diversity=0.25)

    reconcile(db, raised, fingerprinter_present=False)

    assert identity(db, bad)["fp_state"] == "unavailable"
    assert blob(db, bad) == []
    assert stored_version(db) == classifier_version(raised)


# --- the app ---------------------------------------------------------------------------------------


@pytest.fixture
def fake_detect(monkeypatch):
    found = FakeFingerprinter()
    monkeypatch.setattr(fingerprinter_mod, "detect_fingerprinter", lambda settings: found)
    return found


def test_a_restart_with_a_new_diversity_minimum_reclassifies_stored_prints(configure_app, fake_detect):
    with TestClient(configure_app().app) as c:
        database = c.app.state.database
        assert database.read_setting(SETTING) == classifier_version(
            MatcherParams.from_settings(c.app.state.settings))
        owner = c.app.state.admin_user_id
        mid = printed(database, MID, "current", owner_id=owner)
        varied = printed(database, VARIED, "current", owner_id=owner)

    with TestClient(configure_app(env={"FP_MIN_DIVERSITY": "0.25"}).app) as c:
        database = c.app.state.database
        assert database.read_setting(SETTING) == classifier_version(
            MatcherParams.from_settings(c.app.state.settings))

    assert state(database, mid) == ("low_information", "pending")
    assert state(database, varied) == ("current", "current")


def test_a_classifier_error_aborts_the_run_and_keeps_every_print(db):
    """Only an undecodable blob re-pends a print. A ``ValueError`` raised by the
    classifier itself is a bug, not bad data: the run stops and nothing is dropped."""
    from app.database.database import ANY_OWNER

    rows = [printed(db, MID, "current") for _ in range(2)]
    settled_at(db, BASE)
    raised = replace(BASE, min_diversity=0.25)
    old_version = stored_version(db)

    def broken(items):
        raise ValueError("a classifier bug")

    with pytest.raises(ValueError):
        db.reclassify_fingerprints(classifier_version(raised), ALGO, broken, owner_id=ANY_OWNER)

    assert [state(db, u)[0] for u in rows] == ["current", "current"]
    assert all(blob(db, u) != [] for u in rows)
    assert stored_version(db) == old_version
