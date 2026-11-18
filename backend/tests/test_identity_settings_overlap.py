"""The fingerprint overlap minimum can never exceed the item minimum.

Every ``current`` print has at least ``FP_MIN_ITEMS`` items, so two of them
always overlap by at least that much at offset 0. If ``FP_MIN_OVERLAP`` were
larger, two short ``current`` prints could not be compared at all, and the
finder, the coverage counts and the candidate store would read "could not
compare" as "compared, no match".
"""

import pytest
from pydantic import ValidationError

from app.config import Settings
from app.services.duplicate_detection import MatcherParams


def test_an_overlap_minimum_above_the_item_minimum_is_refused():
    with pytest.raises(ValidationError) as caught:
        Settings(_env_file=None, fp_min_overlap=200, fp_min_items=120)

    assert "fp_min_overlap" in str(caught.value)


def test_an_overlap_minimum_equal_to_the_item_minimum_is_allowed():
    params = MatcherParams.from_settings(
        Settings(_env_file=None, fp_min_overlap=150, fp_min_items=150)
    )

    assert params.min_overlap == params.min_items == 150


def test_an_overlap_minimum_below_the_item_minimum_is_allowed():
    params = MatcherParams.from_settings(
        Settings(_env_file=None, fp_min_overlap=100, fp_min_items=150)
    )

    assert (params.min_overlap, params.min_items) == (100, 150)
