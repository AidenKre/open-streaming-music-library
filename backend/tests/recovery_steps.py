"""The start-up recovery order of ``main.py``, written down once (U01-B-07).

``tests/test_startup_recovery_order.py`` is the one test that compares the full
order with the steps a real start hands to ``run_startup_recovery``. Other tests
check a step's place next to its neighbours with ``capture_steps`` and
``named``; the crash matrix rig runs its subset of the steps in this order
through ``in_startup_order``, so it cannot keep an order start-up has dropped.
"""

EXPECTED_ORDER = [
    ("edit journal", True),
    ("conversion jobs", True),
    ("audio identity", True),
    # Before receipts and job reclaim (SC-16e).
    ("upload commit journal", False),
    ("deletion journal", False),
    # Receipts settle or release their rows before job reclaim.
    ("upload receipts", False),
    ("upload validation", False),
    ("deletion jobs", False),
    ("storage reservations", False),
    # The janitors last (SC-16e).
    ("upload janitor", False),
    ("deletion janitor", False),
]


def capture_steps(main, monkeypatch) -> list[list]:
    """Records the step list of every ``run_startup_recovery`` call of ``main``;
    the steps still run."""
    captured = []
    real = main.run_startup_recovery

    def capture(steps):
        captured.append(list(steps))
        return real(steps)

    monkeypatch.setattr(main, "run_startup_recovery", capture)
    return captured


def named(steps) -> list[tuple[str, bool]]:
    """(name, fatal) of each step, in order."""
    return [(s.name, s.fatal) for s in steps]


def in_startup_order(names) -> list[str]:
    """``names`` sorted into the order start-up runs them. A name that is not a
    start-up step raises ``ValueError``."""
    order = [name for name, _ in EXPECTED_ORDER]
    unknown = sorted(set(names) - set(order))
    if unknown:
        raise ValueError(f"not a start-up recovery step: {unknown}")
    return sorted(names, key=order.index)
