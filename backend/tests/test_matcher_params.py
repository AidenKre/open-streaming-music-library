"""Phase 6.5B.2a (6.5-U08): the comparator's parameters come from
configuration (``FP_*`` settings, overridable per deployment) and ship as
provisional defaults (DEV-6.5-04)."""

from dataclasses import fields, replace

import pytest
from pydantic import ValidationError

from app.config import Settings
from app.services.duplicate_detection import MatcherParams, matcher_version

_ENV = (
    "FP_MAX_OFFSET",
    "FP_MIN_OVERLAP",
    "FP_MIN_ITEMS",
    "FP_MIN_DIVERSITY",
    "FP_STRONG",
    "FP_POSSIBLE",
    "FP_DURATION_TOLERANCE_S",
    "FP_DURATION_TOLERANCE_FRAC",
)


@pytest.fixture(autouse=True)
def _clean_env(monkeypatch):
    for var in _ENV:
        monkeypatch.delenv(var, raising=False)


def test_defaults_are_the_provisional_values():
    params = MatcherParams.from_settings(Settings(_env_file=None))

    assert params == MatcherParams(
        max_offset=24,
        min_overlap=120,
        min_items=120,
        min_diversity=0.15,
        strong=0.90,
        possible=0.70,  # s7-fingerprint-search: 0.85 -> 0.80 -> 0.70 (owner, 2026-11-17)
        duration_tolerance_s=7.0,  # round 2: max(7 s, 2%), was 3 s
        duration_tolerance_frac=0.02,
    )


def test_environment_overrides_every_parameter(monkeypatch):
    values = {
        "FP_MAX_OFFSET": "30",
        "FP_MIN_OVERLAP": "150",
        "FP_MIN_ITEMS": "160",
        "FP_MIN_DIVERSITY": "0.2",
        "FP_STRONG": "0.95",
        "FP_POSSIBLE": "0.9",
        "FP_DURATION_TOLERANCE_S": "4.5",
        "FP_DURATION_TOLERANCE_FRAC": "0.03",
    }
    for var, value in values.items():
        monkeypatch.setenv(var, value)

    params = MatcherParams.from_settings(Settings(_env_file=None))

    assert params == MatcherParams(
        max_offset=30,
        min_overlap=150,
        min_items=160,
        min_diversity=0.2,
        strong=0.95,
        possible=0.9,
        duration_tolerance_s=4.5,
        duration_tolerance_frac=0.03,
    )


@pytest.mark.parametrize(
    "overrides",
    [
        {"fp_possible": 0.95, "fp_strong": 0.9},  # possible above strong
        {"fp_strong": 1.01},
        {"fp_possible": 0.0},
        {"fp_max_offset": -1},
        {"fp_min_overlap": 0},
        {"fp_min_items": 0},
        {"fp_min_diversity": -0.1},
        {"fp_min_diversity": 1.1},
        {"fp_duration_tolerance_s": -1.0},
        {"fp_duration_tolerance_frac": -0.01},
    ],
)
def test_invalid_values_are_refused(overrides):
    with pytest.raises(ValidationError) as caught:
        Settings(_env_file=None, **overrides)

    # Refused for its value, not because the setting doesn't exist.
    assert all(e["type"] != "extra_forbidden" for e in caught.value.errors())


def test_possible_equal_to_strong_is_allowed():
    params = MatcherParams.from_settings(
        Settings(_env_file=None, fp_strong=0.9, fp_possible=0.9)
    )

    assert params.strong == params.possible == 0.9


# --- matcher_version (spec §6.4) ----------------------------------------------
# "a hash of the comparator algorithm id, the thresholds, the offset window,
# the overlap minimum, the duration tolerance and the diversity rule".

_CHANGED = {
    "max_offset": 25,
    "min_overlap": 121,
    "min_items": 121,
    "min_diversity": 0.16,
    "strong": 0.91,
    "possible": 0.86,
    "duration_tolerance_s": 3.5,
    "duration_tolerance_frac": 0.025,
}


# The two class settings decide a print's class, not how two prints compare: they
# are in the classifier version (test_identity_reclassify.py), not the matcher version.
_CLASS_SETTINGS = ("min_items", "min_diversity")
_MATCHING = {name: value for name, value in _CHANGED.items() if name not in _CLASS_SETTINGS}


def _defaults() -> MatcherParams:
    return MatcherParams.from_settings(Settings(_env_file=None))


def test_matcher_version_is_stable_for_equal_parameters():
    first = matcher_version(_defaults())
    second = matcher_version(_defaults())

    assert isinstance(first, str) and first
    assert first == second


def test_every_parameter_is_covered():
    # A new MatcherParams field must be added here (and to the hash).
    assert set(_CHANGED) == {f.name for f in fields(MatcherParams)}


@pytest.mark.parametrize("name", sorted(_MATCHING))
def test_matcher_version_changes_with_each_parameter(name):
    base = _defaults()

    assert matcher_version(replace(base, **{name: _CHANGED[name]})) != matcher_version(base)


def test_every_single_parameter_change_gives_a_distinct_version():
    base = _defaults()
    versions = {matcher_version(base)}
    versions |= {
        matcher_version(replace(base, **{name: value})) for name, value in _MATCHING.items()
    }

    assert len(versions) == len(_MATCHING) + 1


@pytest.mark.parametrize("name", _CLASS_SETTINGS)
def test_a_class_setting_leaves_the_matcher_version_alone(name):
    base = _defaults()

    assert matcher_version(replace(base, **{name: _CHANGED[name]})) == matcher_version(base)


def test_a_configured_override_changes_the_version():
    tuned = MatcherParams.from_settings(Settings(_env_file=None, fp_strong=0.95))

    assert matcher_version(tuned) != matcher_version(_defaults())


@pytest.mark.parametrize(
    "constant",
    [
        "COMPARATOR_ALGORITHM",
        "COARSE_KEY_BITS",
        "COMPARE2_DIVERSITY_SMOOTHING",
        "COMPARE2_DIVERSITY_SHIFT",
        "FP_ITEMS_PER_SECOND",
    ],
)
def test_matcher_version_changes_with_the_algorithm_and_diversity_rule(
    constant, monkeypatch
):
    import app.services.duplicate_detection as dd

    before = matcher_version(_defaults())
    original = getattr(dd, constant)
    monkeypatch.setattr(dd, constant, original + (1 if not isinstance(original, str) else "-x"))

    assert matcher_version(_defaults()) != before


def test_adding_the_fingerprint_layer_changed_the_matcher_version():
    # 6.5B.2b review F1: at INT 4b0f8f1 (exact-only finder) the default parameters
    # gave "a7762fe0622b563d". Rows matched then must be re-matched once the finder
    # also has the fingerprint layer, so the version must differ.
    assert matcher_version(_defaults()) != "a7762fe0622b563d"


# s7-fingerprint-search: the default version at 90b36274 (search +-24 around 0 only,
# possible 0.85). Pairs stored under it must be re-matched in the background.
BEFORE_SEARCH_FIX = "846d5c929870979d"


def test_the_new_defaults_give_a_new_matcher_version():
    assert matcher_version(_defaults()) != BEFORE_SEARCH_FIX


def test_the_search_change_alone_gives_a_new_matcher_version():
    # An operator who pinned FP_POSSIBLE=0.85 still gets a re-match for the wider search.
    pinned = MatcherParams.from_settings(Settings(_env_file=None, fp_possible=0.85))

    assert matcher_version(pinned) != BEFORE_SEARCH_FIX


# Round 2 (possible 0.70, window 7 s): the default version at eeffbd73 (round 1:
# possible 0.80, 3 s window, the length-implied search). It must change again.
BEFORE_WINDOW_CHANGE = "cce4c5cc8e71a4f4"


@pytest.mark.parametrize("overrides", [
    {},                                      # both new defaults
    {"fp_possible": 0.80},                   # the window change alone
    {"fp_duration_tolerance_s": 3.0},        # the threshold change alone
])
def test_round_2_defaults_give_a_new_matcher_version(overrides):
    params = MatcherParams.from_settings(Settings(_env_file=None, **overrides))

    assert matcher_version(params) != BEFORE_WINDOW_CHANGE


def test_the_round_1_values_still_give_the_round_1_version():
    # Guards the constant above: only the two defaults moved.
    round_1 = MatcherParams.from_settings(Settings(_env_file=None, fp_possible=0.80, fp_duration_tolerance_s=3.0))

    assert matcher_version(round_1) == BEFORE_WINDOW_CHANGE
