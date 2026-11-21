"""Piece 8A.3a (review case 8-U05): ``open_track_source`` is the only source-open
path for the stream route and the encoder. Source guards, because a second
open path would silently skip the resolve → open → revalidate rule (SC-16i),
and Phase 8 builds no reader-lease registry (spec §5 "No reader leases")."""

import ast
import inspect
import re
from pathlib import Path

import app.main as main_module
from app.services import track_source

APP = Path(main_module.__file__).resolve().parent
ENCODER_FILES = ("services/encoder_coordinator.py", "services/transcoder.py", "services/encoded_cache.py")


def _tree(relative: str) -> ast.AST:
    return ast.parse((APP / relative).read_text())


def _function(tree: ast.AST, name: str) -> ast.FunctionDef:
    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef) and node.name == name:
            return node
    raise AssertionError(f"{name} not found")


def _attributes(node: ast.AST) -> set[str]:
    return {n.attr for n in ast.walk(node) if isinstance(n, ast.Attribute)}


def _called_names(node: ast.AST) -> set[str]:
    names = set()
    for n in ast.walk(node):
        if isinstance(n, ast.Call):
            f = n.func
            names.add(f.attr if isinstance(f, ast.Attribute) else getattr(f, "id", ""))
    return names


def test_the_stream_route_reads_no_file_path_and_opens_nothing_itself():
    route = _function(_tree("routers/catalog.py"), "stream_track")

    assert "file_path" not in _attributes(route)
    assert {"open", "encode_for_stream", "get_tracks", "get_track_by_uuid"}.isdisjoint(
        _called_names(route)
    )
    assert "open_track_source" in _called_names(route)


def test_encoder_code_never_reads_a_track_rows_file_path():
    for relative in ENCODER_FILES:
        assert "file_path" not in _attributes(_tree(relative)), relative


def test_only_the_helper_calls_encode_for_stream_outside_the_coordinator():
    callers = set()
    for path in APP.rglob("*.py"):
        relative = path.relative_to(APP).as_posix()
        if relative == "services/encoder_coordinator.py":
            continue
        if "encode_for_stream" in _called_names(ast.parse(path.read_text())):
            callers.add(relative)

    assert callers == {"services/track_source.py"}


def test_the_helper_opens_files_only_through_its_one_opener():
    tree = ast.parse(inspect.getsource(track_source))
    openers = [
        node.name
        for node in ast.walk(tree)
        if isinstance(node, ast.FunctionDef) and "open" in _called_names(node)
    ]

    assert openers == ["_open_source"]


def test_no_reader_lease_registry_exists():
    pattern = re.compile(r"(reader|source|stream|track)_?leases?\b", re.IGNORECASE)
    hits = [
        f"{path.relative_to(APP)}:{number}"
        for path in APP.rglob("*.py")
        for number, line in enumerate(path.read_text().splitlines(), 1)
        if pattern.search(line)
    ]

    assert hits == []
