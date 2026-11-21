"""Schema version, start-up and the server-wide settings rows.

One part of ``Database`` (``app/database/database.py``). It imports the shared
core and never another part.
"""

import errno
import shutil
import sqlite3
import tempfile
import uuid
from contextlib import ExitStack
from pathlib import Path
from typing import Callable
from urllib.parse import quote

from app.core.operator_log import operator_logger
from app.database.core import DatabaseCore


class SchemaVersionRefused(Exception):
    """Fatal startup error: the database file is not at the supported schema."""

    def __init__(
        self,
        found_version: int,
        supported_version: int,
        minimum_version: int | None = None,
    ):
        self.found_version = found_version
        if minimum_version is None:
            minimum_version = supported_version
        if minimum_version <= found_version < supported_version:
            message = (
                f"This database is at schema {found_version}; start the server once "
                f"to upgrade it to schema {supported_version}, then run this command again."
            )
        else:
            message = (
                f"This database has schema {found_version}; this server reads "
                f"schema {supported_version}. Back it up and start with a fresh "
                "APP_DATA_DIR."
            )
        super().__init__(message)


class DatabaseUnreadable(Exception):
    """Fatal: the database path holds a file SQLite cannot read."""


# The refusal for a database file the server cannot open or read. It is a file-system problem, not a damaged
# database, so it does not advise starting over.
UNREADABLE_DATABASE_FILE = (
    "{path} cannot be read ({error}). Check the permissions and owner of this file, "
    "its -wal and -shm files and its folder: the user the server runs as must be able "
    "to read and write them."
)


# The refusal when the temporary copy for the version check cannot be made. The
# server's start-up ends it with SERVER_START_ENDING; the admin tool with
# ADMIN_TOOL_ENDING.
TEMPORARY_COPY_REFUSED = (
    "{path} could not be copied to the temporary folder ({error}) to check its "
    "version. Set TMPDIR to a folder "
)
SERVER_START_ENDING = "the server can write to that has room, then start the server again."
ADMIN_TOOL_ENDING = "this command can write to that has room, then run it again."


def _is_file_system_error(exc: Exception, path: Path) -> bool:
    """A permission error, or SQLite unable to open the database file although
    it is a regular file (it cannot be read: its permissions or owner). Other
    OSErrors (a full or failing disk while copying the -wal) are not."""
    if isinstance(exc, PermissionError):
        return True
    return getattr(exc, "sqlite_errorcode", None) == sqlite3.SQLITE_CANTOPEN and path.is_file()


class DatabaseMissing(Exception):
    """There is no database file yet (the CLI never creates one)."""


class SchemaPart(DatabaseCore):
    """The schema version of the database file, start-up (create or upgrade) and
    the server-wide ``app_settings`` rows, the server's identity among them."""

    # Schema version a freshly-initialized database lands on. ``initialize``
    # accepts MINIMUM_SCHEMA_VERSION..LATEST_SCHEMA_VERSION (upgrading in place);
    # the admin CLI accepts only LATEST. Keep LATEST in sync with ``init.sql``.
    #
    # The schema history was reset before the first release: ``init.sql`` is
    # version 1 and there is no upgrade step, so every other version is
    # refused. While nobody has a database to keep, a schema change is an edit
    # of ``init.sql`` alone. The first change that must keep existing
    # databases raises LATEST to 2 and adds its step to ``_schema_steps``;
    # MINIMUM stays at the oldest version the steps start from.
    LATEST_SCHEMA_VERSION = 1

    MINIMUM_SCHEMA_VERSION = 1

    def _existing_schema_version(self, *, ending: str = SERVER_START_ENDING) -> int | None:
        """Version of the existing file, or None when there is no schema yet.

        Read-only and pragma-free: ``_connection()``'s WAL pragma would rewrite
        the header of a non-WAL file, so a refused file must never reach it.
        ``ending`` ends the refusal for a temporary copy that cannot be made.
        """
        path = self.context.database_path
        # Three cases, none of which may touch the refused file's bytes,
        # mtimes or sidecars:
        # - no -wal: nothing is pending and the main file is exact; a WAL-mode
        #   file cannot open ro without sidecars, so read it immutable.
        # - -wal and -shm: pending frames must be read; readonly_shm=1 stops
        #   sqlite rewriting the -shm index.
        # - -wal but no -shm: sqlite would create the -shm, so read a copy of
        #   the main file and -wal in a temp dir that is removed afterwards.
        wal = path.with_name(path.name + "-wal")
        shm = path.with_name(path.name + "-shm")
        read_path, mode = path, "ro&immutable=1"
        copy_stage = None  # "folder" or "copy" while making the temp copy
        try:
            # Inside the try: a folder without search permission raises here.
            if not path.exists():
                return None
            with ExitStack() as stack:
                if wal.exists() and shm.exists():
                    mode = "ro&readonly_shm=1"
                elif wal.exists():
                    copy_stage = "folder"
                    tmp = Path(stack.enter_context(tempfile.TemporaryDirectory()))
                    copy_stage = "copy"
                    read_path = tmp / path.name
                    shutil.copyfile(path, read_path)
                    shutil.copyfile(wal, tmp / wal.name)
                    copy_stage = None
                    mode = "ro"
                conn = sqlite3.connect(
                    f"file:{quote(str(read_path))}?mode={mode}", uri=True
                )
                stack.callback(conn.close)  # runs before the temp dir goes
                version = conn.execute("PRAGMA user_version").fetchone()[0]
                tables = conn.execute("SELECT count(*) FROM sqlite_master").fetchone()[0]
        except (sqlite3.DatabaseError, OSError) as exc:  # OperationalError is a subclass
            # The temporary folder could not be made or is full: the database
            # is not the problem, so neither piece of advice below applies.
            if isinstance(exc, OSError) and (
                copy_stage == "folder"
                or (copy_stage == "copy" and exc.errno in (errno.ENOSPC, errno.EDQUOT))
            ):
                raise DatabaseUnreadable(
                    TEMPORARY_COPY_REFUSED.format(path=path, error=exc) + ending
                ) from exc
            if _is_file_system_error(exc, path):
                raise DatabaseUnreadable(
                    UNREADABLE_DATABASE_FILE.format(path=path, error=exc)
                ) from exc
            if "not a database" in str(exc):
                reason = "is not a SQLite database"
            else:
                reason = f"cannot be read as a SQLite database ({exc})"
            raise DatabaseUnreadable(
                f"{path} {reason}. Back it up and start with a fresh APP_DATA_DIR."
            ) from exc
        if version == 0 and tables == 0:
            return None
        return version

    def _refuse_unless_current(self, version: int) -> None:
        if version != self.LATEST_SCHEMA_VERSION:
            raise SchemaVersionRefused(
                version, self.LATEST_SCHEMA_VERSION, self.MINIMUM_SCHEMA_VERSION
            )

    def _refuse_unless_upgradable(self, version: int) -> None:
        if not self.MINIMUM_SCHEMA_VERSION <= version <= self.LATEST_SCHEMA_VERSION:
            raise SchemaVersionRefused(
                version, self.LATEST_SCHEMA_VERSION, self.MINIMUM_SCHEMA_VERSION
            )

    def require_current_schema(self) -> None:
        """Read-only check for the admin CLI: never creates, never migrates."""
        version = self._existing_schema_version(ending=ADMIN_TOOL_ENDING)
        if version is None:
            raise DatabaseMissing(
                f"No database at {self.context.database_path}; "
                "start the server once to create it."
            )
        self._refuse_unless_current(version)

    def initialize(self) -> bool:
        version = self._existing_schema_version()
        if version is None:
            with open(self.context.init_sql_path, "r") as f:
                init_script = f.read()
            with self._connection(commit=True) as conn:
                conn.executescript(init_script)
                self._ensure_server_instance_id(conn)
            return True
        self._refuse_unless_upgradable(version)
        self._migrate()
        return True

    def _schema_steps(self) -> dict[int, Callable[[sqlite3.Connection], None]]:
        """The upgrade steps: each one upgrades from the version it is keyed by.

        None yet. A step is a method taking the open connection, entered here
        as ``{1: self._upgrade_1_to_2}``. It runs inside ``_migrate``'s
        transaction, so it uses individual ``conn.execute`` calls
        (``executescript`` would COMMIT first) and ends by stamping the
        version it reaches (``PRAGMA user_version = 2``).
        tests/test_schema_steps.py replaces this table with fake steps.
        """
        return {}

    def _migrate(self):
        with self._connection(commit=True, immediate=True) as conn:
            # Re-read inside the write transaction: the outer read may be stale.
            current = start = conn.execute("PRAGMA user_version").fetchone()[0]
            steps = self._schema_steps()
            if not self.MINIMUM_SCHEMA_VERSION <= current <= self.LATEST_SCHEMA_VERSION:
                raise SchemaVersionRefused(
                    current, self.LATEST_SCHEMA_VERSION, self.MINIMUM_SCHEMA_VERSION
                )
            while current in steps:
                steps[current](conn)
                advanced = conn.execute("PRAGMA user_version").fetchone()[0]
                if advanced <= current:
                    raise RuntimeError(
                        f"Schema step {current} did not advance user_version"
                    )
                current = advanced
            if current != self.LATEST_SCHEMA_VERSION:
                raise RuntimeError(
                    f"Schema steps stop at schema {current}; "
                    f"this server needs schema {self.LATEST_SCHEMA_VERSION}"
                )
            self._ensure_server_instance_id(conn)
        if current > start:
            operator_logger.info("database schema upgraded from %d to %d", start, current)

    # ── App settings ──────────────────────────────────────────────────────

    @staticmethod
    def _ensure_server_instance_id(conn: sqlite3.Connection) -> None:
        conn.execute(
            "INSERT OR IGNORE INTO app_settings (key, value) VALUES (?, ?)",
            ("server_instance_id", str(uuid.uuid4())),
        )

    def get_server_instance_id(self) -> str:
        instance_id = self.get_setting("server_instance_id")
        if instance_id is None:
            raise RuntimeError("Server instance identity has not been initialized")
        return instance_id

    def read_setting(self, key: str) -> str | None:
        """The stored value, or None when there is no row. Raises on any error."""
        with self._connection() as conn:
            row = conn.execute(
                "SELECT value FROM app_settings WHERE key = ?", (key,)
            ).fetchone()
            return row[0] if row else None

    def get_setting(self, key: str) -> str | None:
        try:
            return self.read_setting(key)
        except Exception as e:
            operator_logger.error("Error reading setting %r: %s", key, e)
            return None

    def set_setting(self, key: str, value: str) -> None:
        # Raises on failure so callers can keep in-memory state consistent
        # with what is actually persisted.
        with self._connection(commit=True) as conn:
            conn.execute(
                "INSERT OR REPLACE INTO app_settings (key, value) VALUES (?, ?)",
                (key, value),
            )
