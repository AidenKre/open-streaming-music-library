"""Stops the worker threads of every encoder coordinator a test builds.

A coordinator starts its pool when it is made, and the threads wait on the
queue until the coordinator is drained or shut down. A test that never does
(or fails before it does) would leave them running for the rest of the run.
Import ``stop_every_encoder_pool`` into a test module to apply it there."""

import pytest

from app.services.encoder_coordinator import EncoderCoordinator


@pytest.fixture(autouse=True)
def stop_every_encoder_pool(monkeypatch):
    made = []
    start_pool = EncoderCoordinator.__post_init__

    def recording(self):
        start_pool(self)
        made.append(self)

    monkeypatch.setattr(EncoderCoordinator, "__post_init__", recording)
    yield
    for coordinator in made:
        coordinator.shutdown()  # harmless after a drain or an earlier shutdown
