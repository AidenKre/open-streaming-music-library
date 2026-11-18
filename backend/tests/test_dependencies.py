"""Review r1 (m-R1-41, m-R1-42): the server imports only what it declares.

- Every third-party package imported by ``app/`` is a direct dependency in
  ``pyproject.toml`` (not one that merely arrives through another package).
- ``app/`` imports no private module of a third-party package (such as
  ``starlette._utils``): those move without notice, and the dependency is not
  pinned.
"""

import ast
import re
import sys
import tomllib
from importlib.metadata import packages_distributions
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]
APP = BACKEND / "app"


def _imported_modules() -> list[tuple[Path, str]]:
    found = []
    for path in sorted(APP.rglob("*.py")):
        tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                found += [(path, alias.name) for alias in node.names]
            elif isinstance(node, ast.ImportFrom) and node.level == 0 and node.module:
                found.append((path, node.module))
    return found


def _third_party(module: str) -> bool:
    top = module.split(".")[0]
    return top != "app" and top not in sys.stdlib_module_names


def _declared() -> set[str]:
    project = tomllib.loads((BACKEND / "pyproject.toml").read_text(encoding="utf-8"))
    names = set()
    for requirement in project["project"]["dependencies"]:
        name = re.split(r"[\s<>=!~;\[]", requirement, maxsplit=1)[0]
        names.add(name.lower().replace("_", "-"))
    return names


def test_every_third_party_import_is_a_declared_dependency():
    distributions = packages_distributions()
    declared = _declared()
    missing = set()
    for path, module in _imported_modules():
        if not _third_party(module):
            continue
        top = module.split(".")[0]
        dists = {d.lower().replace("_", "-") for d in distributions.get(top, [top])}
        if not dists & declared:
            missing.add(f"{top} ({path.relative_to(BACKEND)})")
    assert not missing, f"imported but not declared in pyproject.toml: {sorted(missing)}"


def test_no_private_third_party_module_is_imported():
    private = sorted(
        f"{module} ({path.relative_to(BACKEND)})"
        for path, module in _imported_modules()
        if _third_party(module)
        and any(part.startswith("_") for part in module.split(".")[1:])
    )
    assert not private, f"private third-party modules imported: {private}"
