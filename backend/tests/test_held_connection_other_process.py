"""What reads the database's files while another
process holds the database open, and after that process died.

The server now holds one idle connection for its whole life
(``Database.hold_open``), so the write-ahead log and its index file exist the
whole time, and a commit stays in the log until a checkpoint. Before, a quiet
server left the main file complete and no log beside it. Everything that
looks at the files from another process must work in both states:

- the schema check of the start-up and of the admin tool
  (``Database._existing_schema_version``): it must read what only the log holds;
- the admin tool's commands that run while the server runs (``users list``);
- a write from the other process (as the admin tool's ``users disable``
  makes; here a settings row): its close is not the last one, so it leaves
  the log alone;
- the durable point (``make_durable``);
- the Last.fm purge's ``VACUUM`` and log truncation (the tool takes the
  instance lock first, so this meets a holder only if a worker outlived the
  server's shutdown);
- the next start after the holder was killed: nothing was checkpointed, and
  every commit is read back from the log.

The holder is a real child process running the product's own ``hold_open``.
The state with no holder at all is what the rest of the suite runs in
(``test_schema_refusal.py``, ``test_cli_*.py``, ``test_lastfm_purge.py``).

Audit AU3-01 and AU3-05: the holder must also do what the server does while
it holds, not only hold: write, reach a durable point, check the schema. On a
SQLite build that locks the database file with POSIX locks (the stock build),
a process keeps its lock only as long as it never closes a descriptor of that
file beside SQLite; once the lock is gone, any other process that closes the
database is taken for the last connection and checkpoints and empties or
removes the log under the live holder. The build this Mac's Python links
(3.51.0, with Apple's compile options) keeps its lock
through such a close (measured 2026-11-20), so there these tests pass whatever
the product does with descriptors of its own; on a stock build they are what
catches it. The holder child runs the product with its real settings (no
``tests/conftest.py`` in that process), so every file step of the product
runs in it.
"""

import os
import sqlite3
import subprocess
import sys
from pathlib import Path

import pytest

from app.database.database import Database, DatabaseContext, SchemaVersionRefused
from tests.cli_fixtures import add_user, cli_settings, database_file, open_server_database, run_cli
from tests.database_file_probes import (
    another_process_holds_the_database,
    log_bytes,
    setting_in_the_main_file_alone,
)
from tests.schema_fixtures import INIT_SQL

pytestmark = pytest.mark.integration

BACKEND = Path(__file__).resolve().parents[1]

# argv: the database file, init.sql, then optionally a value the holder itself
# commits (through the product's ``set_setting``) before it reports ready.
# Then one command per line on its input, each answered with one line:
# "durable" (the product's durable point), "write <value>" (commits the row
# 'later'), "schema" (the read-only schema check, then the start-up's).
HOLDER = (
    "import sys\n"
    "from pathlib import Path\n"
    "from app.database.database import Database, DatabaseContext\n"
    "db = Database(DatabaseContext(database_path=Path(sys.argv[1]), init_sql_path=Path(sys.argv[2])))\n"
    "db.hold_open()\n"
    "if len(sys.argv) > 3:\n"
    "    db.set_setting('probe', sys.argv[3])\n"
    "print('ready', flush=True)\n"
    "for line in sys.stdin:\n"
    "    command, _, value = line.strip().partition(' ')\n"
    "    if command == 'durable':\n"
    "        print(db.make_durable(), flush=True)\n"
    "    elif command == 'write':\n"
    "        db.set_setting('later', value)\n"
    "        print('written', flush=True)\n"
    "    elif command == 'schema':\n"
    "        db.require_current_schema()\n"
    "        print(db.initialize(), flush=True)\n"
    "db.close()\n"
)


class Holder:
    """Another process holding the database open; started and ended here."""

    def __init__(self, database_path, cwd, *write):
        self.proc = subprocess.Popen(
            [sys.executable, "-c", HOLDER, str(database_path), str(INIT_SQL), *write],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            cwd=cwd, env={**os.environ, "PYTHONPATH": str(BACKEND)},
        )
        line = self.proc.stdout.readline().strip()
        if line != "ready":
            self.proc.kill()
            raise AssertionError(f"the holder did not start: {self.proc.communicate()[1]}")

    def ask(self, command: str) -> str:
        """Send one command; its one-line answer."""
        self.proc.stdin.write(command + "\n")
        self.proc.stdin.flush()
        answer = self.proc.stdout.readline().strip()
        if not answer:
            self.proc.kill()
            raise AssertionError(f"the holder ended at {command!r}: {self.proc.communicate()[1]}")
        return answer

    def close(self):
        """Let it close its connection and end."""
        if self.proc.poll() is None:
            self.proc.stdin.close()
            self.proc.wait(timeout=30)
        self._release_pipes()

    def kill(self):
        """End it at once: nothing of its own is closed or checkpointed."""
        self.proc.kill()
        self.proc.wait(timeout=30)
        self._release_pipes()

    def _release_pipes(self):
        for pipe in (self.proc.stdin, self.proc.stdout, self.proc.stderr):
            if pipe is not None and not pipe.closed:
                pipe.close()


@pytest.fixture
def settings(tmp_path):
    return cli_settings(tmp_path)


@pytest.fixture
def db(settings):
    return open_server_database(settings)


@pytest.fixture
def hold(db, tmp_path):
    """``hold(*write)`` starts a holder on ``db``'s file; any still running is
    killed when the test ends."""
    started = []

    def start(*write):
        holder = Holder(db.context.database_path, tmp_path, *write)
        started.append(holder)
        return holder

    yield start
    for holder in started:
        if holder.proc.poll() is None:
            holder.kill()
        holder._release_pipes()


def _set_version_in_the_log(db, version: int) -> None:
    conn = sqlite3.connect(db.context.database_path)
    try:
        conn.execute(f"PRAGMA user_version = {version}")
        conn.commit()
    finally:
        conn.close()


def _main_file(db):
    path = Path(db.context.database_path)
    return path.read_bytes(), path.stat().st_mtime_ns


def test_a_write_from_this_process_leaves_the_log_until_the_holder_closes(db, hold, tmp_path):
    holder = hold()

    db.set_setting("probe", "written")

    assert log_bytes(db.context.database_path) > 0
    assert setting_in_the_main_file_alone(db.context.database_path, tmp_path) is None

    holder.close()  # the last close, in the other process: it checkpoints

    assert log_bytes(db.context.database_path) == 0
    assert setting_in_the_main_file_alone(db.context.database_path, tmp_path) == "written"


@pytest.mark.parametrize("check", ["require_current_schema", "initialize"])
def test_the_schema_check_passes_while_another_process_holds_the_database(db, hold, check):
    hold()
    db.set_setting("probe", "written")  # the log is not empty
    before = _main_file(db)

    assert getattr(db, check)() in (None, True)

    if check == "require_current_schema":  # the read-only one writes nothing at all
        assert _main_file(db) == before


@pytest.mark.parametrize("check", ["require_current_schema", "initialize"])
def test_the_schema_check_reads_a_version_that_only_the_log_holds(db, hold, check):
    """The main file alone still says the current version; the log says 99."""
    hold()
    _set_version_in_the_log(db, 99)
    before = _main_file(db)

    with pytest.raises(SchemaVersionRefused) as refused:
        getattr(db, check)()

    assert refused.value.found_version == 99
    assert _main_file(db) == before


def test_the_admin_tool_lists_a_user_that_only_the_log_holds(db, hold, settings, tmp_path):
    hold()
    add_user(db, "ana")

    result = run_cli(settings, tmp_path, "users", "list")

    assert result.code == 0, result.err
    assert "\tana\t" in result.out


def test_the_durable_point_works_while_another_process_holds_the_database(db, hold, tmp_path):
    hold()
    db.set_setting("probe", "written")
    assert setting_in_the_main_file_alone(db.context.database_path, tmp_path) is None

    assert db.make_durable() is True

    assert setting_in_the_main_file_alone(db.context.database_path, tmp_path) == "written"


def test_the_lastfm_purge_compacts_the_files_while_an_idle_process_holds_the_database(db, hold):
    hold()
    db.set_setting("probe", "written")

    assert db.purge_lastfm_data() == (0, 0)

    assert log_bytes(db.context.database_path) == 0
    assert db.read_setting("probe") == "written"


def test_after_the_holder_is_killed_the_next_start_reads_its_commit_from_the_log(
        db, hold, settings, tmp_path):
    """A server process killed right after one of its commits returned: its
    held connection never closed, so nothing was checkpointed."""
    holder = hold("committed by the process that was killed")
    holder.kill()
    path = database_file(settings)
    assert setting_in_the_main_file_alone(path, tmp_path) is None
    assert log_bytes(path) > 0

    restarted = Database(DatabaseContext(database_path=path, init_sql_path=INIT_SQL))
    restarted.require_current_schema()
    assert restarted.initialize() is True

    assert restarted.read_setting("probe") == "committed by the process that was killed"


# ── the holder does what the server does while it holds (AU3-01, AU3-05) ────


@pytest.mark.real_sqlite_durability
def test_after_the_holders_own_durable_point_another_process_close_leaves_the_log(
        db, hold, settings, tmp_path):
    """The server reaches a durable point (every tag edit that moves a file,
    conversion and deletion does). Afterwards it must still hold the database:
    an admin command run beside it must not be taken for the last connection.
    The marker gives this process, which plays the admin tool, the product's
    real settings too.

    This test cannot fail on the SQLite build this Mac's Python links
    (3.51.0, with Apple's compile options): that build keeps
    its lock through a close of another descriptor of the file, so it passed
    there even while the durable point still opened and closed the database
    file itself (measured 2026-11-20). It is the proof for a stock SQLite
    build, where the lock is a POSIX lock: there it fails as soon as the
    holding process closes a descriptor of the file beside SQLite. It has to
    be run once on the owner's Linux server, at the commit before the fix
    (6f9add44: it must fail at the lock after the durable point) and at the
    fix (3684397e: it must pass); on macOS the source guard and the
    durable point's own test
    (``test_database_files_only_through_sqlite.py``,
    ``test_deletion_durable_point.py``) are what fails."""
    path = database_file(settings)
    holder = hold("held")
    seen = {"the holder's lock before its durable point": another_process_holds_the_database(path)}

    assert holder.ask("durable") == "True"
    seen["the holder's lock after its durable point"] = another_process_holds_the_database(path)

    db.set_setting("other", "written")  # the other process: open, commit, close
    seen["the log after the other process's close"] = (
        "kept" if log_bytes(path) > 0 else "emptied or removed"
    )
    seen["the other process's row in the main file alone"] = setting_in_the_main_file_alone(
        path, tmp_path, key="other"
    )

    # The holder commits once more, then dies without closing anything: what it
    # was told is committed must be read back when everything is opened again.
    assert holder.ask("write committed after the other process closed") == "written"
    holder.kill()
    reopened = Database(DatabaseContext(database_path=path, init_sql_path=INIT_SQL))
    assert reopened.initialize() is True
    seen["after reopening"] = {key: reopened.read_setting(key) for key in ("probe", "other", "later")}

    assert seen == {
        "the holder's lock before its durable point": True,
        "the holder's lock after its durable point": True,
        "the log after the other process's close": "kept",
        "the other process's row in the main file alone": None,
        "after reopening": {
            "probe": "held",
            "other": "written",
            "later": "committed after the other process closed",
        },
    }


def test_the_holders_own_schema_check_keeps_its_lock(db, hold, settings):
    """The schema check reads the files through SQLite while the process holds
    them (``-wal`` and ``-shm`` both exist then); SQLite never closes a
    descriptor under its own locks."""
    path = database_file(settings)
    holder = hold("held")

    assert holder.ask("schema") == "True"

    assert another_process_holds_the_database(path) is True


def test_the_holders_own_writes_keep_its_lock(db, hold, settings):
    path = database_file(settings)
    holder = hold("held")

    assert holder.ask("write again") == "written"

    assert another_process_holds_the_database(path) is True
