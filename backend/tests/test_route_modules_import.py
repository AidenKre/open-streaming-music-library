"""``app.main`` and every router module import
cleanly when each is the first ``app`` module a fresh interpreter loads. An
import loop does not show in the warm test process, where the modules are
already loaded."""

import subprocess
import sys
from pathlib import Path

import pytest

from tests.test_fresh_imports import _environment as fresh_interpreter_environment

BACKEND = Path(__file__).resolve().parents[1]

_CHILD = """
import importlib, sys
for name in sys.argv[1:]:
    for loaded in [m for m in sys.modules if m == "app" or m.startswith("app.")]:
        del sys.modules[loaded]
    importlib.import_module(name)
    print("imported", name, "with app.main" if "app.main" in sys.modules else "without app.main")
"""


def _modules() -> list[str]:
    routers = sorted(p.stem for p in (BACKEND / "app" / "routers").glob("*.py"))
    # The two shared modules the moved routes and start-up both import.
    shared = ["app.services.transcoder", "app.core.bounded_body"]
    return ["app.main", *shared, *(f"app.routers.{name}" for name in routers)]


@pytest.mark.integration
def test_main_and_every_router_import_first_in_a_fresh_interpreter(tmp_path):
    modules = _modules()
    # Not the developer's environment: a setting exported in the shell would
    # reach the child, where a bad value fails every import.
    env = fresh_interpreter_environment(tmp_path)

    # Launched from tmp_path, so no .env of a developer checkout is read.
    done = subprocess.run(
        [sys.executable, "-c", _CHILD, *modules],
        cwd=tmp_path, env=env, capture_output=True, text=True, timeout=120,
    )

    assert done.returncode == 0, done.stderr[-2000:]
    assert [line for line in done.stdout.splitlines() if line.startswith("imported ")] == [
        f"imported {name} " + ("with app.main" if name == "app.main" else "without app.main")
        for name in modules
    ]
    assert "app.routers.uploads" in modules
