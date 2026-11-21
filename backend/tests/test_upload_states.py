"""The named upload state sets (``app/core/upload_states.py``) name only states
the schema allows. ``init.sql`` is the schema's one description (version 1),
so the allowed list is read from its ``CHECK`` on ``upload_items.state``."""

import re

import pytest

from app.core.upload_states import (
    ENDED_STATES, SOURCE_GIVEN_BACK_STATES, SOURCE_RELEASE_STATES, STAGED_MATCH_STATES,
)
from tests.schema_fixtures import INIT_SQL

SETS = {
    "ENDED_STATES": ENDED_STATES,
    "SOURCE_GIVEN_BACK_STATES": SOURCE_GIVEN_BACK_STATES,
    "SOURCE_RELEASE_STATES": SOURCE_RELEASE_STATES,
    "STAGED_MATCH_STATES": STAGED_MATCH_STATES,
}


def _allowed_item_states() -> set[str]:
    sql = INIT_SQL.read_text()
    table = re.search(r"CREATE TABLE IF NOT EXISTS upload_items \((.*?)\n\);", sql, re.S)
    assert table is not None, "upload_items is not in init.sql"
    check = re.search(r"^\s*state\s+TEXT NOT NULL CHECK \(state IN \(([^)]*)\)\)", table.group(1), re.M)
    assert check is not None, "upload_items.state has no CHECK list"
    return set(re.findall(r"'([a-z_]+)'", check.group(1)))


def test_the_schema_list_is_read():
    # Guards the parser: a few states every upload passes through.
    assert {"allocated", "receiving", "validating", "imported", "cancelled"} <= _allowed_item_states()


@pytest.mark.parametrize("name", sorted(SETS))
def test_each_set_names_only_states_the_schema_allows(name):
    states = SETS[name]
    assert states, name
    assert len(set(states)) == len(states), f"{name} repeats a state"
    assert set(states) <= _allowed_item_states(), set(states) - _allowed_item_states()


def test_a_state_that_gives_its_source_back_is_ended_and_releasable():
    # The janitor reads the ended items and keeps those of SOURCE_GIVEN_BACK_STATES,
    # then releases each with its own state as from_states.
    assert set(SOURCE_GIVEN_BACK_STATES) <= set(ENDED_STATES)
    assert set(SOURCE_GIVEN_BACK_STATES) <= set(SOURCE_RELEASE_STATES)


def test_a_staged_match_is_compared_and_shown_only_while_its_upload_has_not_ended():
    # The validation worker compares a new upload with the other items in
    # STAGED_MATCH_STATES, and the duplicate report shows such a match as
    # available: nothing can be imported from an upload that has ended.
    assert not set(STAGED_MATCH_STATES) & set(ENDED_STATES)
