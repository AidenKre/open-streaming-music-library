"""Other-issues row 62: tests whose fault is a permission chmod takes away are
skipped, never run, where chmod does not deny (``tests/conftest.py``)."""

import pytest

from tests import conftest


class _Marker:
    def __init__(self, name):
        self.name = name


class _Item:
    """The part of a collected test the collection hook reads and writes."""

    def __init__(self, *marker_names):
        self.markers = [_Marker(name) for name in marker_names]

    def iter_markers(self):
        return iter(list(self.markers))

    def add_marker(self, marker):
        self.markers.append(_Marker(marker.name))
        self.added = marker


def _skip_reason(item):
    added = getattr(item, "added", None)
    return added.kwargs["reason"] if added is not None and added.name == "skip" else None


def test_the_probe_gives_the_cached_answer_every_time_it_runs():
    """The cached answer is the machine's: probing again in this process, in
    fresh folders, gives it again."""
    assert conftest.probe_chmod_denial() == conftest.probe_chmod_denial() == conftest.chmod_denies()


def test_a_marked_test_is_skipped_where_chmod_does_not_deny(monkeypatch):
    monkeypatch.setattr(conftest, "chmod_denies", lambda: False)
    marked, plain = _Item("requires_chmod_denial"), _Item()

    conftest.pytest_collection_modifyitems(None, [marked, plain])

    assert _skip_reason(marked) == conftest.CHMOD_SKIP_REASON
    assert _skip_reason(plain) is None


def test_a_marked_test_runs_where_chmod_denies(monkeypatch):
    monkeypatch.setattr(conftest, "chmod_denies", lambda: True)
    marked = _Item("requires_chmod_denial")

    conftest.pytest_collection_modifyitems(None, [marked])

    assert _skip_reason(marked) is None


@pytest.mark.requires_chmod_denial
def test_where_a_marked_test_runs_chmod_really_denies(tmp_path):
    folder = tmp_path / "folder"
    folder.mkdir()
    folder.chmod(0o555)
    try:
        with pytest.raises(PermissionError):
            (folder / "new").write_bytes(b"x")
    finally:
        folder.chmod(0o755)
