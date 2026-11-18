"""Phase M.0c (SC-28 rule 7): cross-user access is granted in one place.

``policy.can(viewer, action, owner)`` returns ``viewer == owner`` in Phase M;
future friend features extend this module instead of adding owner checks.
"""

import pytest

from app import policy


@pytest.mark.parametrize("action", ["read", "stream", "edit", "delete", "anything"])
def test_a_user_may_act_on_their_own_data(action):
    assert policy.can(7, action, 7) is True


@pytest.mark.parametrize("action", ["read", "stream", "edit", "delete", "anything"])
def test_nobody_may_act_on_another_users_data(action):
    assert policy.can(7, action, 8) is False
    assert policy.can(8, action, 7) is False


@pytest.mark.parametrize("viewer, owner", [(None, None), (True, 1), ("1", "1"), (1.0, 1.0)])
def test_only_real_user_ids_are_accepted(viewer, owner):
    # Review r1 #7: None == None must never grant access.
    with pytest.raises(TypeError):
        policy.can(viewer, "read", owner)
