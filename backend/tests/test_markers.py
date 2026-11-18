"""Plan D16: ``requires_ffmpeg``/``requires_fpcalc`` are registered markers
and a collection hook skips the tests carrying them when the tool is absent."""

import pytest

from tests import conftest


def _which_only(*present):
    return lambda name: f"/usr/bin/{name}" if name in present else None


class _FakeItem:
    def __init__(self, *marker_names):
        self._names = marker_names
        self.added = []

    def iter_markers(self, name=None):
        for n in self._names:
            if name is None or n == name:
                yield getattr(pytest.mark, n).mark

    def add_marker(self, marker):
        self.added.append(marker)


def test_markers_are_registered(pytestconfig):
    names = {line.split(":")[0].strip() for line in pytestconfig.getini("markers")}
    assert {"requires_ffmpeg", "requires_fpcalc", "integration"} <= names


def test_requires_ffmpeg_needs_both_ffmpeg_and_ffprobe():
    assert conftest.tool_skip_reason({"requires_ffmpeg"}, _which_only("ffmpeg", "ffprobe")) is None
    reason = conftest.tool_skip_reason({"requires_ffmpeg"}, _which_only("ffmpeg"))
    assert reason is not None and "ffprobe" in reason
    reason = conftest.tool_skip_reason({"requires_ffmpeg"}, _which_only("ffprobe"))
    assert reason is not None and "ffmpeg" in reason


def test_requires_fpcalc_needs_fpcalc_only():
    assert conftest.tool_skip_reason({"requires_fpcalc"}, _which_only("fpcalc")) is None
    reason = conftest.tool_skip_reason({"requires_fpcalc"}, _which_only("ffmpeg", "ffprobe"))
    assert reason is not None and "fpcalc" in reason


def test_unmarked_test_is_never_skipped():
    assert conftest.tool_skip_reason(set(), _which_only()) is None
    assert conftest.tool_skip_reason({"parametrize"}, _which_only()) is None


def _names(markers):
    return [m.name for m in markers]


def test_hook_skips_only_items_whose_tool_is_absent(monkeypatch):
    monkeypatch.setattr(conftest.shutil, "which", _which_only("ffmpeg", "ffprobe"))
    plain, ffmpeg_test, fpcalc_test = _FakeItem(), _FakeItem("requires_ffmpeg"), _FakeItem("requires_fpcalc")
    conftest.pytest_collection_modifyitems(None, [plain, ffmpeg_test, fpcalc_test])
    assert "skip" not in _names(plain.added) and "skip" not in _names(ffmpeg_test.added)
    assert _names(fpcalc_test.added).count("skip") == 1
    skip = next(m for m in fpcalc_test.added if m.name == "skip")
    assert "fpcalc" in skip.kwargs["reason"]


@pytest.mark.parametrize("present", [("ffmpeg", "ffprobe", "fpcalc"), ()])
def test_integration_is_added_to_tool_marked_items_whether_or_not_the_tool_is_present(monkeypatch, present):
    monkeypatch.setattr(conftest.shutil, "which", _which_only(*present))
    ffmpeg_test, fpcalc_test = _FakeItem("requires_ffmpeg"), _FakeItem("requires_fpcalc")
    conftest.pytest_collection_modifyitems(None, [ffmpeg_test, fpcalc_test])
    assert _names(ffmpeg_test.added).count("integration") == 1
    assert _names(fpcalc_test.added).count("integration") == 1


def test_integration_is_not_added_to_unmarked_items(monkeypatch):
    monkeypatch.setattr(conftest.shutil, "which", _which_only())
    plain, other = _FakeItem(), _FakeItem("parametrize")
    conftest.pytest_collection_modifyitems(None, [plain, other])
    assert plain.added == [] and other.added == []


def test_integration_is_added_exactly_once_when_both_tool_markers_are_set(monkeypatch):
    monkeypatch.setattr(conftest.shutil, "which", _which_only("ffmpeg", "ffprobe", "fpcalc"))
    both = _FakeItem("requires_ffmpeg", "requires_fpcalc")
    conftest.pytest_collection_modifyitems(None, [both])
    assert _names(both.added) == ["integration"]
