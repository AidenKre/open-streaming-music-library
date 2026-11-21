"""Each module below imports cleanly as the first import of a new interpreter.

An import loop does not show in the test process: by the time a test runs,
``tests/conftest.py`` has imported ``app.services`` and ``app.database`` in an
order that happens to work. A loop shows only when the looping module is the
first one a process imports (the server, the command line, a script). So each
module here gets an interpreter of its own, started in an empty folder (no
``.env`` there) with the folders the settings need.

The modules of ``app/database`` and ``app/core`` are found from their files,
and so are the services the database package imports inside its functions;
only the entry points and the services that import the database at their top
are listed by hand (``IMPORTERS_OF_THE_DATABASE``).
"""

import ast
import os
import subprocess
import sys
from pathlib import Path

import pytest

BACKEND = Path(__file__).resolve().parents[1]

APP = BACKEND / "app"


def _modules_of(folder: str) -> list[str]:
    """Every module file directly in ``app/<folder>``, as a module name."""
    return [
        f"app.{folder}.{path.stem}"
        for path in sorted((APP / folder).glob("*.py"))
        if path.stem != "__init__"
    ]


def _services_the_database_imports() -> list[str]:
    """The ``app.services`` modules the database package imports (inside its
    functions: none may be at a module's top)."""
    found = set()
    for path in (APP / "database").glob("*.py"):
        for node in ast.walk(ast.parse(path.read_text())):
            if isinstance(node, ast.ImportFrom) and (node.module or "").startswith("app.services."):
                found.add(node.module)
            elif isinstance(node, ast.Import):
                found.update(a.name for a in node.names if a.name.startswith("app.services."))
    return sorted(found)


# Services that import names from the database package at their top, or that
# took over names the database module used to define; finding them would mean
# reading every service, so they are listed.
IMPORTERS_OF_THE_DATABASE = [
    "app.services.job_runtime",
    "app.services.storage_ledger",
    "app.services.deletion_errors",
    "app.services.upload_receipt",
    "app.services.organizer",
    "app.services.file_ops",
    "app.models.deletions",
]

MODULES = list(dict.fromkeys([
    # The entry points.
    "app.main",
    "app.cli",
    # The two packages whose modules import each other.
    "app.services",
    "app.database",
    *_modules_of("database"),
    *_modules_of("core"),
    *_services_the_database_imports(),
    *IMPORTERS_OF_THE_DATABASE,
]))

# Interpreters started at once (the test's wall time is that of the slowest group).
_AT_ONCE = 8


def _environment(folder: Path) -> dict[str, str]:
    # Not the developer's environment: a setting exported in the shell must not
    # reach the child, where a bad value would fail every import.
    env = {name: os.environ[name] for name in ("PATH", "TMPDIR", "LANG") if name in os.environ}
    env.update(
        PYTHONPATH=str(BACKEND),
        PYTHONDONTWRITEBYTECODE="1",
        APP_DATA_DIR=str(folder / "data"),
        MUSIC_LIBRARY_DIR=str(folder / "music"),
        IMPORT_DIR=str(folder / "import"),
        USER_IMPORT_DIR=str(folder / "import-users"),
    )
    return env


def import_failures(modules, folder: Path) -> dict[str, str]:
    """``{module: the end of its stderr}`` for each module whose import, as the
    first import of a new interpreter started in ``folder``, failed."""
    env = _environment(folder)
    failures = {}
    for start in range(0, len(modules), _AT_ONCE):
        started = [
            (
                module,
                subprocess.Popen(
                    [sys.executable, "-c", f"import {module}"],
                    cwd=folder, env=env, text=True,
                    stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                ),
            )
            for module in modules[start : start + _AT_ONCE]
        ]
        try:
            for module, process in started:
                _, stderr = process.communicate(timeout=120)
                if process.returncode != 0:
                    failures[module] = stderr[-1500:]
        finally:
            # A child that hung (or whose neighbour did) does not outlive the test.
            for _, process in started:
                if process.poll() is None:
                    process.kill()
                    process.communicate()
    return failures


@pytest.mark.integration
def test_each_module_imports_first_in_a_new_interpreter(tmp_path):
    # The derived parts of the list found what they are for.
    assert {
        "app.database.core", "app.database.uploads", "app.database.operation_receipts",
        "app.core.owner", "app.core.job_runtime", "app.services.audio_identity",
    } <= set(MODULES)
    assert import_failures(MODULES, tmp_path) == {}
    # Importing reads settings and creates nothing.
    assert list(tmp_path.iterdir()) == []


@pytest.mark.integration
def test_a_module_that_cannot_be_imported_is_reported(tmp_path):
    failures = import_failures(["app.no_such_module", "app.version"], tmp_path)

    assert list(failures) == ["app.no_such_module"]
    assert "ModuleNotFoundError" in failures["app.no_such_module"]


_CLAIM_BOTH_TABLES = """
import sqlite3
from app.core import job_runtime

conn = sqlite3.connect(":memory:")
conn.execute("CREATE TABLE upload_items (owner_id, item_uuid, state, lease_boot_id, cancel_requested)")
conn.execute("INSERT INTO upload_items VALUES (1, 'i', 'allocated', NULL, 0)")
conn.execute(
    "CREATE TABLE deletion_job_items"
    " (owner_id, operation_uuid, uuid_id, status, lease_boot_id, cancel_requested)"
)
conn.execute("INSERT INTO deletion_job_items VALUES (1, 'o', 'u', 'pending', NULL, 0)")
print(
    job_runtime.claim(
        conn, "upload_items", {"owner_id": 1, "item_uuid": "i"},
        boot_id="b", from_state="allocated", to_state="receiving",
    ),
    job_runtime.claim(
        conn, "deletion_job_items", {"owner_id": 1, "operation_uuid": "o", "uuid_id": "u"},
        boot_id="b",
    ),
)
"""


@pytest.mark.integration
def test_both_job_tables_can_be_claimed_with_only_the_runtime_imported(tmp_path):
    """The two claimable tables are registered with the runtime itself, not by
    a service module's import or by the first call of one database method."""
    done = subprocess.run(
        [sys.executable, "-c", _CLAIM_BOTH_TABLES],
        cwd=tmp_path, env=_environment(tmp_path), capture_output=True, text=True, timeout=120,
    )

    assert done.returncode == 0, done.stderr[-1500:]
    assert done.stdout.split() == ["True", "True"]
