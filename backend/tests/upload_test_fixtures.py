"""Shared opt-in pytest fixtures for new upload tests (refactor B.10, U10-A-08).

Most upload test files define the same few fixtures again (``music`` in 31
files, ``root`` in 9, ``world`` in 10). A new test module imports the ones it
uses instead of copying them::

    from tests.upload_test_fixtures import music, uploads_root  # noqa: F401

Opt-in on purpose: nothing here is in ``conftest.py``, so no existing test
changes. An existing file moves to these fixtures only when it is next edited.
The plain helpers stay in the five ``upload_*_fixtures.py`` modules.
"""

import pytest

from tests.upload_recovery_fixtures import World


@pytest.fixture
def music(tmp_path):
    """The music library directory with its empty ``.uploads`` staging root."""
    path = tmp_path / "music"
    (path / ".uploads").mkdir(parents=True)
    return path


@pytest.fixture
def uploads_root(music):
    """The staging root, ``music/.uploads`` (old files call it ``root``)."""
    return music / ".uploads"


@pytest.fixture
def recovery_world(db, music):
    """One library and its cover art over simulated restarts (old files call it
    ``world``); ``db`` is ``conftest.py``'s."""
    return World(db, music)
