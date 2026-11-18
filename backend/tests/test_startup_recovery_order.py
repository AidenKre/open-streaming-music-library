"""U01-B-07: the full start-up recovery order, asserted once.

The order itself (and why each step sits where it does) is in
``tests/recovery_steps.py``. Tests elsewhere check one step's place against its
neighbours; this file checks the whole list, and that the crash matrix rig
(``tests/replace_matrix_rig.py``) runs only real start-up steps, in this order.
"""

import pytest
from fastapi.testclient import TestClient

from tests import replace_matrix_rig
from tests.recovery_steps import EXPECTED_ORDER, capture_steps, in_startup_order, named


def test_startup_runs_the_recovery_steps_in_this_order(configure_app, monkeypatch):
    main = configure_app()
    captured = capture_steps(main, monkeypatch)

    with TestClient(main.app):
        pass

    [steps] = captured
    assert named(steps) == EXPECTED_ORDER


def test_the_crash_matrix_rig_runs_real_startup_steps_in_the_startup_order():
    steps = replace_matrix_rig.STARTUP_STEPS

    assert set(steps) <= {name for name, _ in EXPECTED_ORDER}
    assert in_startup_order(steps) == ["edit journal", "conversion jobs", "storage reservations"]


def test_a_step_start_up_does_not_have_is_refused():
    with pytest.raises(ValueError, match="not a start-up recovery step"):
        in_startup_order(["edit journal", "a step that was removed"])
