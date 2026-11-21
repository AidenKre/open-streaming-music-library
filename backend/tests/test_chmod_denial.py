"""Other-issues row 62: tests whose fault is a permission chmod takes away are
skipped, never run, where chmod does not deny (``tests/conftest.py``)."""

import ast
from pathlib import Path

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


def _takes_away_owner_access(node) -> bool:
    """A ``.chmod(...)`` call whose constant mode lacks the owner's read or
    write bit: what root, or a volume that ignores mode bits, does not obey."""
    if not (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
            and node.func.attr == "chmod" and node.args):
        return False
    mode = node.args[-1]
    return isinstance(mode, ast.Constant) and isinstance(mode.value, int) and (
        mode.value & 0o600) != 0o600


def test_a_test_that_takes_a_permission_away_itself_carries_the_marker():
    """Without the marker such a test fails, instead of being skipped, under
    root or in a container whose volume ignores mode bits. What this sees: a
    ``.chmod`` call with a whole-number mode written in the test's own body.
    A mode built from ``stat`` flags, passed by keyword, or set inside a helper
    or fixture is not seen; such a test needs the marker by hand."""
    def marked(decorators):
        return any("requires_chmod_denial" in ast.unparse(d) for d in decorators)

    unmarked = []
    for path in sorted(Path(__file__).parent.glob("test_*.py")):
        source = path.read_text()
        if ".chmod(" not in source:
            continue
        tree = ast.parse(source)
        module_marked = any(
            isinstance(n, ast.Assign)
            and any(getattr(t, "id", None) == "pytestmark" for t in n.targets)
            and "requires_chmod_denial" in ast.unparse(n.value)
            for n in tree.body
        )

        def visit(node, outer_marked):
            for child in ast.iter_child_nodes(node):
                if isinstance(child, ast.ClassDef):
                    visit(child, outer_marked or marked(child.decorator_list))
                elif (isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef))
                      and child.name.startswith("test")
                      and any(_takes_away_owner_access(n) for n in ast.walk(child))
                      and not (outer_marked or marked(child.decorator_list))):
                    unmarked.append(f"{path.name}::{child.name}")

        visit(tree, module_marked)
    assert unmarked == []
