"""The server's code reaches its database files only through SQLite (audit AU3-01).

SQLite's locks on the database file are, on a stock build, POSIX locks: they
belong to the process, and the kernel drops all of them when the process
closes *any* descriptor of that file (SQLite, "How To Corrupt An SQLite
Database File", section 2.2). A process that holds a connection (the server
holds one from start-up to shutdown) and opens and closes ``database.db``
itself therefore stops holding the database without noticing; the next
program that closes the database beside it is taken for the last connection
and checkpoints and empties or removes the log under the live server.

Three kinds of rule here (the third is the run-time guard at the end: an
audit hook in ``tests/conftest.py`` that sees product code open a held
database's file itself, whatever variable or helper the path travelled
through; its own limits are written beside it):

- **A source guard** over every module under ``backend/app``: which functions
  name the database path or its ``-wal`` / ``-shm`` files, what they may call,
  and what the path may be handed to. One exception is named with its reason.
- **The exception's reason, pinned**: the schema check copies the database
  file and its log only when a log exists without its index file (``-shm``),
  a state no process with an open connection is in, and the server runs the
  check before it holds its connection.

What the guard matches is written out below. It reads names, not data flow.
Not seen: a path handed on under another variable name into another function;
a path built from the data folder with the file name computed, not spelled;
a file call whose name is not in the list; anything under
``backend/scripts``. The behaviour test for all of these is
``test_held_connection_other_process.py`` (on a stock SQLite build).
"""

import ast
import os
import shutil
import sqlite3
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app.core import durable_fs
from app.database.database import Database, DatabaseContext
from tests.conftest import _RAW_DATABASE_OPENS, check_no_raw_database_open
from tests.database_file_probes import setting_in_the_main_file_alone
from tests.database_fixtures import plain_database
from tests.schema_fixtures import INIT_SQL

APP = Path(__file__).resolve().parents[1] / "app"

# Rule 1. The functions under backend/app that read the attribute
# ``.database_path``, each with why it may. A new one is added here only after
# checking the two rules below for it.
NAMES_THE_DATABASE_PATH = {
    ("database/core.py", "_connection"): "hands it to open_connection",
    ("database/core.py", "hold_open"): "hands it to open_connection",
    ("database/schema.py", "_existing_schema_version"): "the read-only schema check (the exception below)",
    ("database/schema.py", "require_current_schema"): "puts it into the 'No database at …' sentence",
    ("database/lastfm.py", "purge_lastfm_data"): "hands it to a SQLite connection for VACUUM",
    ("main.py", "_startup_locked"): "creates the database's folder before the first start",
}
# A long function whose one use of the path is one statement: rule 2 looks at
# the statements that name the path, not at the whole function (start-up may
# open, replace and remove other files), and the path may not be put into a
# variable there (it would leave the statement the rule looks at).
ONLY_THE_NAMING_STATEMENT = {("main.py", "_startup_locked")}

# Rule 2. In a function that names the database path, or that spells a
# ``-wal`` / ``-shm`` suffix, no call may have one of these names (the last
# name of the call: ``os.open`` and ``path.open`` are both ``open``). They are
# the ways to open, copy, move, remove or flush a file beside SQLite.
RAW_FILE_CALLS = {
    "open", "fdopen", "copy", "copyfile", "copy2", "copyfileobj", "copytree", "move",
    "read_bytes", "read_text", "write_bytes", "write_text", "unlink", "remove", "rmtree",
    "rename", "replace", "touch", "truncate", "fsync", "fdatasync", "fcntl", "lockf", "flock",
    "mmap", "sendfile", "fsync_file", "fsync_dir", "link", "symlink", "hardlink_to",
    "symlink_to", "chmod", "NamedTemporaryFile",
}
# The one exception. ``_existing_schema_version`` copies the database file and
# its log to a temporary folder when a log exists and its index file does not
# (SQLite would otherwise create the index beside a file that may be refused).
# It is safe because a process with an open connection to a WAL database has
# created that index file, so the branch is not reached while the process
# holds; the tests below pin that, and that the server checks before it holds.
ALLOWED_RAW_FILE_CALLS = {("database/schema.py", "_existing_schema_version"): {"copyfile"}}

# Rule 3. A call that is given ``….database_path`` itself as an argument is a
# SQLite open: the product's one opener, or ``sqlite3.connect``.
MAY_BE_GIVEN_THE_DATABASE_PATH = {"open_connection", "connect"}

# Rule 4. The suffixes of SQLite's two side files are spelled in code only
# where the schema check builds their paths.
SPELLS_A_SIDE_FILE_SUFFIX = {("database/schema.py", "_existing_schema_version")}
SIDE_FILE_SUFFIXES = {"-wal", "-shm"}

# Rule 6. ``sqlite3.connect`` is called in three places only, each with why it
# is not the opener. A connection to the server's database made anywhere else
# would miss the durable settings (and one to another file must say so here).
CALLS_SQLITE3_CONNECT = {
    ("database/core.py", "open_connection"): "the opener itself",
    ("database/schema.py", "_existing_schema_version"):
        "read-only, and must not switch a refused file to WAL (the opener would)",
    ("database/table_rebuild.py", "rebuild_tables"):
        "the backup copy: another file, not database.db; the opener would write it "
        "through a log of its own and leave side files beside it",
}

# Rule 5. The database file's name is spelled once, where the server's
# ``Database`` is built; everything else gets the path from that object (so
# rule 1 sees it).
SPELLS_THE_DATABASE_FILE_NAME = {("database/database.py", "server_database")}
DATABASE_FILE_NAME = "database.db"


def _functions(tree):
    """Every function of a module with the nodes of its own body (a nested
    function's nodes belong to the nested one) and its statements."""
    found = []

    def visit(node, owner, statements):
        for child in ast.iter_child_nodes(node):
            if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef)):
                nodes, own_statements = [], []
                found.append((child.name, nodes, own_statements))
                visit(child, nodes, own_statements)
            else:
                if owner is not None:
                    owner.append(child)
                    if isinstance(child, ast.stmt):
                        statements.append(child)
                visit(child, owner, statements)

    visit(tree, None, None)
    return found


def _naming_statements(statements):
    """The innermost statements that name the database path."""
    naming = [s for s in statements if any(_is_the_database_path(n) for n in ast.walk(s))]
    return [
        s for s in naming
        if not any(o is not s and o in naming for o in ast.walk(s) if isinstance(o, ast.stmt))
    ]


def _call_name(call: ast.Call) -> str | None:
    if isinstance(call.func, ast.Attribute):
        return call.func.attr
    if isinstance(call.func, ast.Name):
        return call.func.id
    return None


def _is_sqlite3_connect(call: ast.Call) -> bool:
    func = call.func
    return (
        isinstance(func, ast.Attribute) and func.attr == "connect"
        and isinstance(func.value, ast.Name) and func.value.id == "sqlite3"
    )


def _is_the_database_path(node) -> bool:
    return isinstance(node, ast.Attribute) and node.attr == "database_path"


def _scan_source(module: str, source: str, found: dict) -> None:
    for function, nodes, statements in _functions(ast.parse(source)):
        key = (module, function)
        mentions = any(_is_the_database_path(n) for n in nodes)
        constants = {n.value for n in nodes if isinstance(n, ast.Constant) and isinstance(n.value, str)}
        suffix = bool(constants & SIDE_FILE_SUFFIXES)
        if mentions:
            found["names_path"].add(key)
        if suffix:
            found["spells_suffix"].add(key)
        if DATABASE_FILE_NAME in constants:
            found["spells_file_name"].add(key)
        calls = [n for n in nodes if isinstance(n, ast.Call)]
        if any(_is_sqlite3_connect(c) for c in calls):
            found["sqlite3_connect"].add(key)
        if mentions or suffix:
            looked_at = calls
            if key in ONLY_THE_NAMING_STATEMENT:
                naming = _naming_statements(statements)
                looked_at = [n for s in naming for n in ast.walk(s) if isinstance(n, ast.Call)]
                if any(isinstance(s, (ast.Assign, ast.AnnAssign, ast.AugAssign)) for s in naming) or any(
                    isinstance(n, ast.NamedExpr) for s in naming for n in ast.walk(s)
                ):
                    found["raw_calls"].setdefault(key, set()).add("<the path is put into a variable>")
            raw = {_call_name(c) for c in looked_at} & RAW_FILE_CALLS
            if raw:
                found["raw_calls"].setdefault(key, set()).update(raw)
        for call in calls:
            arguments = [*call.args, *(k.value for k in call.keywords)]
            if any(_is_the_database_path(a) for a in arguments):
                found["given_to"].setdefault(key, set()).add(_call_name(call))


def _empty_scan() -> dict:
    return {"names_path": set(), "raw_calls": {}, "given_to": {}, "spells_suffix": set(),
            "spells_file_name": set(), "sqlite3_connect": set()}


def _scan() -> dict:
    """What the six rules look at, per (module, function), over backend/app."""
    found = _empty_scan()
    for path in sorted(APP.rglob("*.py")):
        _scan_source(path.relative_to(APP).as_posix(), path.read_text(), found)
    return found


def test_only_the_listed_functions_name_the_database_path():
    assert _scan()["names_path"] == set(NAMES_THE_DATABASE_PATH)
    assert ONLY_THE_NAMING_STATEMENT <= set(NAMES_THE_DATABASE_PATH)


def test_a_function_that_names_the_database_files_makes_no_raw_file_call():
    assert _scan()["raw_calls"] == ALLOWED_RAW_FILE_CALLS


def test_the_database_path_is_handed_only_to_a_sqlite_open():
    given_to = _scan()["given_to"]

    assert {key: names - MAY_BE_GIVEN_THE_DATABASE_PATH for key, names in given_to.items()} == {
        key: set() for key in given_to
    }
    assert given_to  # the scan found the opens it is about


def test_only_the_schema_check_spells_the_side_files_suffixes():
    assert _scan()["spells_suffix"] == SPELLS_A_SIDE_FILE_SUFFIX


def test_the_database_files_name_is_spelled_only_where_the_database_is_built():
    assert _scan()["spells_file_name"] == SPELLS_THE_DATABASE_FILE_NAME


def test_sqlite3_connect_is_called_only_where_listed():
    assert _scan()["sqlite3_connect"] == set(CALLS_SQLITE3_CONNECT)


def _scan_text(module: str, source: str) -> dict:
    found = _empty_scan()
    _scan_source(module, source, found)
    return found


def test_the_guard_sees_a_raw_open_of_the_database_path():
    """The guard's own check: the defect it exists for, as source text."""
    found = _scan_text(
        "database/core.py",
        "class DatabaseCore:\n"
        "    def make_durable(self):\n"
        "        fd = os.open(self.context.database_path, os.O_RDONLY)\n"
        "        os.close(fd)\n",
    )

    assert found["names_path"] == {("database/core.py", "make_durable")}
    assert found["raw_calls"] == {("database/core.py", "make_durable"): {"open"}}
    assert found["given_to"] == {("database/core.py", "make_durable"): {"open"}}


def test_in_the_startup_function_the_guard_looks_at_the_statement_that_names_the_path():
    """Start-up may open and replace other files; it may not touch the database's."""
    harmless = (
        "def _startup_locked():\n"
        "    database.context.database_path.parent.mkdir(parents=True, exist_ok=True)\n"
        "    name = folder.name.replace('a', 'b')\n"
        "    with open(other_file) as f:\n"
        "        f.read()\n"
    )
    direct = (
        "def _startup_locked():\n"
        "    size = len(database.context.database_path.read_bytes())\n"
    )
    through_a_variable = (
        "def _startup_locked():\n"
        "    path = database.context.database_path\n"
        "    open(path).close()\n"
    )
    key = ("main.py", "_startup_locked")

    assert _scan_text("main.py", harmless)["raw_calls"] == {}
    assert _scan_text("main.py", direct)["raw_calls"] == {key: {"read_bytes", "<the path is put into a variable>"}}
    assert _scan_text("main.py", through_a_variable)["raw_calls"] == {key: {"<the path is put into a variable>"}}


# ── the exception's reason: when the schema check copies ────────────────────


@pytest.fixture
def copies(monkeypatch):
    """The source path of every ``shutil.copyfile`` from here on."""
    made = []
    real = shutil.copyfile

    def copyfile(src, dst, *args, **kwargs):
        made.append(Path(src).name)
        return real(src, dst, *args, **kwargs)

    monkeypatch.setattr(shutil, "copyfile", copyfile)
    return made


def _database_at(tmp_path, state: str) -> Database:
    """A current-schema database whose files are in ``state``, made from one
    that a plain connection keeps open (so its log and index file exist and
    the log holds a row)."""
    source = plain_database(tmp_path)
    holder = sqlite3.connect(source.context.database_path)
    try:
        holder.execute("PRAGMA journal_mode=WAL").fetchone()
        source.set_setting("probe", "in the log")
        main = Path(source.context.database_path)
        target = tmp_path / state.replace(" ", "-") / main.name
        target.parent.mkdir()
        shutil.copyfile(main, target)
        if state != "no log":
            shutil.copyfile(f"{main}-wal", f"{target}-wal")
        if state == "a log and its index":
            shutil.copyfile(f"{main}-shm", f"{target}-shm")
    finally:
        holder.close()
    return Database(DatabaseContext(database_path=target, init_sql_path=INIT_SQL))


@pytest.mark.parametrize(
    "state, copied",
    [
        ("no log", []),
        ("a log and its index", []),
        ("a log without its index", ["db.sqlite", "db.sqlite-wal"]),
    ],
)
def test_the_schema_check_copies_the_files_only_for_a_log_without_its_index(
        tmp_path, copies, state, copied):
    database = _database_at(tmp_path, state)
    del copies[:]  # the set-up's own copies

    database.require_current_schema()

    assert copies == copied


@pytest.mark.parametrize("check", ["require_current_schema", "initialize"])
def test_the_schema_check_makes_no_copy_while_this_process_holds_a_connection(tmp_path, copies, check):
    """The held connection has made the index file, so the check reads through
    SQLite (which never closes a descriptor under its own locks)."""
    database = plain_database(tmp_path)
    database.hold_open()
    try:
        database.set_setting("probe", "in the log")

        assert getattr(database, check)() in (None, True)

        assert copies == []
    finally:
        database.close()


def test_the_schema_check_makes_no_copy_while_one_of_its_calls_is_open(tmp_path, copies):
    """Any open connection of the process counts, not only the held one."""
    database = plain_database(tmp_path)

    with database._connection(commit=True) as conn:
        conn.execute("INSERT OR REPLACE INTO app_settings (key, value) VALUES ('probe', 'x')")
        database.require_current_schema()

    assert copies == []


def test_the_server_checks_the_schema_before_it_holds_its_connection(configure_app, monkeypatch):
    """At start-up the check (which may copy the files) runs first, with no
    connection of the process open; nothing checks again once it holds."""
    main = configure_app()
    order = []
    real_check, real_hold = Database._existing_schema_version, Database.hold_open

    def check(self):
        order.append("schema check")
        return real_check(self)

    def hold(self):
        order.append("hold")
        return real_hold(self)

    monkeypatch.setattr(Database, "_existing_schema_version", check)
    monkeypatch.setattr(Database, "hold_open", hold)

    with TestClient(main.app) as client:
        assert client.get("/").status_code == 200

    assert order.count("hold") == 1
    held_at = order.index("hold")
    assert "schema check" in order[:held_at]
    assert "schema check" not in order[held_at:]


# ── the run-time guard: product code that opens a held database's file ──────
#
# ``durable_fs.fsync_file`` stands in for the product code the source guard
# cannot see: it lives under backend/app, opens the path it is given and
# closes it, and never names the database.


def _raw_opens() -> list[str]:
    seen = sorted(set(_RAW_DATABASE_OPENS))
    del _RAW_DATABASE_OPENS[:]
    return seen


def test_product_code_opening_a_held_database_file_is_seen(tmp_path):
    database = plain_database(tmp_path)
    main = str(database.context.database_path)
    database.hold_open()
    try:
        database.set_setting("probe", "in the log")
        durable_fs.fsync_file(Path(main))
        durable_fs.fsync_file(Path(main + "-wal"))
    finally:
        database.close()

    assert _raw_opens() == [os.path.realpath(main), os.path.realpath(main) + "-wal"]


def test_a_seen_open_fails_the_test_at_its_end(tmp_path):
    database = plain_database(tmp_path)
    database.hold_open()
    try:
        durable_fs.fsync_file(Path(database.context.database_path))
    finally:
        database.close()

    with pytest.raises(pytest.fail.Exception, match="opened .*db.sqlite itself while a connection"):
        check_no_raw_database_open()
    check_no_raw_database_open()  # the record was emptied: this test itself ends clean


def test_the_products_own_work_on_a_held_database_is_not_seen(tmp_path):
    """SQLite's opens are its own: calls, the durable point, the schema check."""
    database = plain_database(tmp_path)
    database.hold_open()
    try:
        database.set_setting("probe", "in the log")
        assert database.make_durable() is True
        database.require_current_schema()
        assert database.read_setting("probe") == "in the log"
    finally:
        database.close()

    assert _raw_opens() == []


def test_a_tests_own_look_at_a_held_database_file_is_not_seen(tmp_path):
    database = plain_database(tmp_path)
    database.hold_open()
    try:
        database.set_setting("probe", "in the log")
        setting_in_the_main_file_alone(database.context.database_path, tmp_path)
        with open(database.context.database_path, "rb") as f:
            f.read(16)
    finally:
        database.close()

    assert _raw_opens() == []


def test_a_database_file_nobody_holds_may_be_opened(tmp_path):
    """Not held at all, held and closed again, and another database's file of
    the same name while this one is held."""
    database = plain_database(tmp_path)
    (tmp_path / "other").mkdir()
    other = plain_database(tmp_path / "other")
    durable_fs.fsync_file(Path(database.context.database_path))
    database.hold_open()
    try:
        durable_fs.fsync_file(Path(other.context.database_path))
    finally:
        database.close()
    durable_fs.fsync_file(Path(database.context.database_path))

    assert _raw_opens() == []


def test_a_held_database_file_reached_through_another_spelling_of_its_folder_is_seen(tmp_path):
    database = plain_database(tmp_path)
    main = str(database.context.database_path)
    other_spelling = tmp_path.parent / "link-to-the-data-folder"
    other_spelling.symlink_to(tmp_path, target_is_directory=True)
    database.hold_open()
    try:
        durable_fs.fsync_file(other_spelling / "db.sqlite")
    finally:
        database.close()
        other_spelling.unlink()

    assert _raw_opens() == [os.path.realpath(main)]


def test_the_run_time_guard_is_on_for_every_test(request):
    """The check runs at the end of each test without being asked for."""
    assert "_no_raw_open_of_a_held_database" in request.fixturenames

