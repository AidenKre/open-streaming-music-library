"""Shared backend test fixtures.

``configure_app`` is the one place that points the app at temporary
directories and re-imports ``app.main`` so ``Settings`` re-reads the environment.
``open_app_client`` starts a ``TestClient`` on such an app, and ``app_client``
is the default client most API tests use.

Extension points for later Phase M pieces: environment every app needs (for
example the master-admin variables) goes into ``configure_app``; anything a
started client needs before a test sends requests (for example logging in)
goes into ``open_app_client``, so every client gets it.

Test databases do not sync to disk (SF-BE-2): every ``sqlite3.connect`` made
in the test process issues ``PRAGMA synchronous=OFF`` (``_connect_without_sync``
below); a child process a test starts is not covered and keeps SQLite's
default. That only decides whether a committed transaction survives an
operating-system crash or power loss. Atomicity, isolation, locking, WAL
behaviour and what other connections see are unchanged, and the product's own
setting is untouched; the one product path that reads the setting,
``Database.make_durable``, skips its full flush of the database file when it is
off. A test about durability settings carries
``@pytest.mark.real_sqlite_durability`` and gets the unwrapped
``sqlite3.connect`` (``tests/test_sqlite_test_durability.py`` pins both sides).

No test reaches a host off this machine (9-R1-02: ``RealNetworkRefused``,
checked at every test's teardown), and the suite's first ``app.config`` import
reads no ``.env`` from the launch directory (9-R1-03);
``tests/test_conftest_env_isolation.py`` pins both.
"""

import atexit
import contextlib
import functools
import ipaddress
import logging
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
from collections.abc import Iterable, Mapping
from types import ModuleType

import httpx
import pytest
from fastapi.testclient import TestClient

# SF-BE-2: installed before any ``app`` import, so a module that captures
# ``sqlite3.connect`` at import time (``table_rebuild``'s default argument)
# gets the wrapper too. Child processes a test starts are not affected.
_REAL_SQLITE_CONNECT = sqlite3.connect
# Switched off for a test marked ``real_sqlite_durability``. A flag instead of
# swapping the function, so a connect captured at import time (for example
# ``table_rebuild.rebuild_tables``' default argument) honours the opt-out too.
_SYNC_OFF = {"enabled": True}


@functools.wraps(_REAL_SQLITE_CONNECT)
def _connect_without_sync(*args, **kwargs):
    """``sqlite3.connect`` with every argument passed through unchanged and
    the very connection it returns, after ``PRAGMA synchronous=OFF``. A file
    that is not a database (or a connection already in a transaction) keeps
    its default: the product's own first statement reports any real error."""
    conn = _REAL_SQLITE_CONNECT(*args, **kwargs)
    if not _SYNC_OFF["enabled"]:
        return conn
    try:
        conn.execute("PRAGMA synchronous=OFF")
    except sqlite3.DatabaseError:
        pass
    return conn


sqlite3.connect = _connect_without_sync


@pytest.fixture(autouse=True)
def _real_sqlite_durability_opt_out(request, monkeypatch):
    """A test marked ``real_sqlite_durability`` gets SQLite's own durability:
    the wrapper stays installed (so connects captured at import time see the
    same switch) but issues no pragma for the duration of the test."""
    if request.node.get_closest_marker("real_sqlite_durability") is not None:
        monkeypatch.setitem(_SYNC_OFF, "enabled", False)


# 9-R1-02: no test may reach a host off this machine through a real httpx
# transport (every app built with ``valid_env()`` holds a client on the real
# Last.fm URL; only a test's own fake keeps it away). Installed at import,
# before any ``app`` import, over the class methods, so every transport any
# code builds is covered. A refused attempt raises ``RealNetworkRefused`` (not
# an ``httpx`` error, which the client would quietly read as "try later"),
# sends nothing, and is recorded: ``_no_refused_network`` fails the test at
# teardown even when the code under test swallowed the error (the sender
# catches every exception per user). Loopback stays the test's own business.
class RealNetworkRefused(RuntimeError):
    """A test tried to reach a host off this machine through a real httpx transport."""


_REFUSED_HOSTS: list[str] = []
_REAL_HTTP_HANDLE = httpx.HTTPTransport.handle_request
_REAL_ASYNC_HTTP_HANDLE = httpx.AsyncHTTPTransport.handle_async_request


def _refuse_off_machine(request) -> None:
    host = request.url.host
    if host == "localhost":
        return
    try:
        if ipaddress.ip_address(host).is_loopback:
            return
    except ValueError:
        pass
    _REFUSED_HOSTS.append(host)
    raise RealNetworkRefused(f"a test tried to reach {host} through a real network transport")


@functools.wraps(_REAL_HTTP_HANDLE)
def _guarded_handle_request(self, request):
    _refuse_off_machine(request)
    return _REAL_HTTP_HANDLE(self, request)


@functools.wraps(_REAL_ASYNC_HTTP_HANDLE)
async def _guarded_handle_async_request(self, request):
    _refuse_off_machine(request)
    return await _REAL_ASYNC_HTTP_HANDLE(self, request)


httpx.HTTPTransport.handle_request = _guarded_handle_request
httpx.AsyncHTTPTransport.handle_async_request = _guarded_handle_async_request


def take_refused_hosts() -> list[str]:
    """The hosts refused since the last call, in order; the record is emptied."""
    hosts = list(_REFUSED_HOSTS)
    del _REFUSED_HOSTS[: len(hosts)]
    return hosts


def check_no_refused_network() -> None:
    """Fails the running test when any refused attempt is on record (and consumes it)."""
    hosts = take_refused_hosts()
    if hosts:
        pytest.fail(
            f"a test tried to reach {', '.join(sorted(set(hosts)))} through a real network transport",
            pytrace=False,
        )


@pytest.fixture(autouse=True)
def _no_refused_network():
    yield
    check_no_refused_network()


# The loggers whose levels and handlers decide what a later test's caplog sees
# (operator lines go to "uvicorn.error"). pytest's own capture handlers, which
# it attaches anew for each phase, are left out of the comparison.
_GUARDED_LOGGERS = ("", "uvicorn", "uvicorn.error", "uvicorn.access")


def _logging_state() -> dict:
    state = {}
    for name in _GUARDED_LOGGERS:
        logger = logging.getLogger(name)
        handlers = tuple(h for h in logger.handlers if not type(h).__module__.startswith("_pytest"))
        state[name or "root"] = (logger.level, handlers, logger.propagate, logger.disabled)
    state["logging.disable"] = logging.root.manager.disable
    return state


@pytest.fixture(autouse=True)
def _logging_left_as_found():
    """Fails a test that leaves a guarded logger with another level, handler
    list, ``propagate`` or ``disabled`` than it found (after caplog's own
    restore), and puts the state back so no later test inherits it."""
    before = _logging_state()
    yield
    after = _logging_state()
    if after == before:
        return
    changed = sorted(k for k in before if before[k] != after[k])
    for name in _GUARDED_LOGGERS:
        logger = logging.getLogger(name)
        level, handlers, propagate, disabled = before[name or "root"]
        own = [h for h in logger.handlers if type(h).__module__.startswith("_pytest")]
        logger.handlers[:] = [*handlers, *own]
        logger.propagate, logger.disabled = propagate, disabled
        logger.setLevel(level)
    logging.disable(before["logging.disable"])
    pytest.fail(f"the test left these loggers changed: {', '.join(changed)}", pytrace=False)


# 9-R1-03: ``app.config`` builds ``settings = Settings()`` at import, and
# Settings reads ``.env`` relative to the working directory: pytest launched
# from a developer's ``backend/`` would load its real ``.env`` (external
# account secrets included) into the test process. The first import happens
# here, from an empty directory of this process's own, so no launch-directory
# ``.env`` is read; ``configure_app`` re-imports it from each test's tmp_path.
_IMPORT_CWD = tempfile.mkdtemp(prefix="osml-tests-import-")
atexit.register(shutil.rmtree, _IMPORT_CWD, ignore_errors=True)
with contextlib.chdir(_IMPORT_CWD):
    import app.config  # noqa: E402,F401

import app.services as _services  # noqa: E402  (after the sqlite3 wrapper)
from app.services import ffmpeg_runner as _ffmpeg_runner  # noqa: E402
from app.services import transcoder as _transcoder  # noqa: E402
from tests.database_fixtures import make_db  # noqa: E402

TEST_ADMIN_USERNAME = "admin"
TEST_ADMIN_PASSWORD = "test-admin-password"


def log_in(client, username: str = TEST_ADMIN_USERNAME, password: str = TEST_ADMIN_PASSWORD) -> dict:
    """``POST /auth/login`` and return the 200 body (tokens, user, instance id)."""
    response = client.post("/auth/login", json={"username": username, "password": password})
    assert response.status_code == 200, response.text
    return response.json()


def bearer(token: str) -> dict:
    """The ``Authorization`` header for an API token."""
    return {"Authorization": f"Bearer {token}"}


# The real process listing (orphan-ffmpeg sweep), the real encoder probe and
# the ``subprocess.run`` it calls, captured before any test can patch them.
_REAL_LIST_PROCESSES = _ffmpeg_runner._list_processes
_REAL_PROBE = _transcoder.probe_available_encoders
_REAL_SUBPROCESS_RUN = subprocess.run
_probe_cache: dict[tuple, frozenset] = {}


def _no_foreign_processes() -> list:
    """The default process list app starts see: none (the sweep's documented
    best-effort result when processes cannot be listed)."""
    return []


def _cached_real_probe() -> frozenset:
    """The real ``probe_available_encoders``, run once per ffmpeg binary in this
    worker process instead of once per app start.

    The probe runs ``ffmpeg -hide_banner -encoders`` found on ``PATH`` at call
    time, so the cache key is ``PATH`` plus the binary ``shutil.which`` finds
    (path, inode, size, mtime): a test that points ``PATH`` at another or no
    ffmpeg gets a real probe of that. Never cached, and probed for real on every
    start as before: no ffmpeg on ``PATH``, an empty result (missing binary,
    failure, timeout) and a patched ``subprocess.run``. An exception propagates.
    """
    found = shutil.which("ffmpeg")
    if found is None or _transcoder.subprocess.run is not _REAL_SUBPROCESS_RUN:
        return _REAL_PROBE()
    stat = os.stat(found)
    key = (os.environ.get("PATH"), found, stat.st_ino, stat.st_size, stat.st_mtime_ns)
    cached = _probe_cache.get(key)
    if cached is None:
        cached = _REAL_PROBE()
        if not cached:
            return cached
        _probe_cache[key] = cached
    return cached


@pytest.fixture
def configure_app(tmp_path, monkeypatch):
    """Return ``configure_app(**overrides) -> app.main``.

    Overrides:
    - ``data_dir``, ``music_dir``, ``import_dir``: directory names under
      ``tmp_path`` (defaults ``data``, ``music``, ``import``).
    - ``encoders``: if given, startup's encoder probe reports exactly these.
      If not, startup gets the real probe's result, run once per worker
      process and ffmpeg binary (``_cached_real_probe``), unless the test
      already patched ``probe_available_encoders`` itself: its patch wins.
    - ``env``: extra environment variables to set before the import
      (applied after the master-admin defaults, so it can override them).
    - ``real_process_list``: start-up's orphan-ffmpeg sweep lists the real
      processes (``ps`` / ``/proc``) instead of the default empty list.

    Explicit default (SF-BE-1c): app starts see an empty foreign-process
    list, so start-up's orphan-ffmpeg sweep (three process listings per start)
    finds nothing, unless the test patches ``ffmpeg_runner._list_processes``
    itself (its patch wins, also when made by an earlier fixture) or passes
    ``real_process_list=True``. The real path stays covered by
    ``test_ffmpeg_runner.py::TestKillOrphanedFfmpeg`` (real processes),
    ``test_internal_dirs.py`` S7 (start-up sweeps every internal dir) and
    ``test_startup_real_process_sweep.py`` (a real start-up and real listing).
    ``test_conversion.py`` replaces the conversion reconcile's own call to
    ``kill_orphaned_ffmpeg`` with a fake, so it covers no real listing.
    """
    # Installed at fixture setup, and only over the real function, so a patch
    # made earlier by another fixture or later in the test body wins.
    if _ffmpeg_runner._list_processes is _REAL_LIST_PROCESSES:
        monkeypatch.setattr(_ffmpeg_runner, "_list_processes", _no_foreign_processes)

    def _configure(
        *,
        data_dir: str = "data",
        music_dir: str = "music",
        import_dir: str = "import",
        encoders: Iterable[str] | None = None,
        env: Mapping[str, str] | None = None,
        real_process_list: bool = False,
    ) -> ModuleType:
        if real_process_list and _ffmpeg_runner._list_processes is _no_foreign_processes:
            monkeypatch.setattr(_ffmpeg_runner, "_list_processes", _REAL_LIST_PROCESSES)
        monkeypatch.setenv("APP_DATA_DIR", str(tmp_path / data_dir))
        monkeypatch.setenv("MUSIC_LIBRARY_DIR", str(tmp_path / music_dir))
        monkeypatch.setenv("IMPORT_DIR", str(tmp_path / import_dir))
        monkeypatch.setenv("USER_IMPORT_DIR", str(tmp_path / "import-users"))
        monkeypatch.setenv("ENABLE_FILE_WATCHER", "false")
        # 6.5A.2d: no background identity writer racing app tests; the
        # worker's own app tests turn it on through ``env``.
        monkeypatch.setenv("ENABLE_IDENTITY_WORKER", "false")
        # 7A.2c: likewise no upload validation thread; its app tests turn it on.
        monkeypatch.setenv("ENABLE_UPLOAD_VALIDATION_WORKER", "false")
        # 7A.3a: and no upload commit thread; its app tests turn it on.
        monkeypatch.setenv("ENABLE_UPLOAD_COMMIT_WORKER", "false")
        # 7A.3c: and no periodic upload janitor thread (the startup pass still runs).
        monkeypatch.setenv("ENABLE_UPLOAD_JANITOR", "false")
        # 8A.3c: and no deletion worker thread; its app tests turn it on.
        monkeypatch.setenv("ENABLE_DELETION_WORKER", "false")
        # 9D.2b (DEV-9D2b-06): and no Last.fm sender thread; its app tests turn
        # it on through ``env``.
        monkeypatch.setenv("ENABLE_LASTFM_SENDER", "false")
        # 6.5B.1b: no fingerprinter unless a test asks for one (fpcalc may be
        # installed on the machine running the tests).
        monkeypatch.setenv("AUDIO_FINGERPRINT_BACKEND", "off")
        # Every app boots a master admin (Phase M bootstrap), hashed with the
        # test-only cheap argon2 parameters. ``env`` may override these.
        monkeypatch.setenv("OSML_ADMIN_USERNAME", TEST_ADMIN_USERNAME)
        monkeypatch.setenv("OSML_ADMIN_PASSWORD", TEST_ADMIN_PASSWORD)
        monkeypatch.delenv("OSML_ADMIN_PASSWORD_FILE", raising=False)
        monkeypatch.setenv("OSML_INSECURE_FAST_PASSWORD_HASHING", "true")
        # No test may ever contact Last.fm: drop any Last.fm configuration
        # exported in the shell, so the only one an app test sees is what the
        # test itself passes through ``env`` (applied next, so it wins).
        for name in list(os.environ):
            if name.startswith(("LASTFM_", "OSML_INSECURE_LASTFM_")):
                monkeypatch.delenv(name)
        for name, value in (env or {}).items():
            monkeypatch.setenv(name, value)
        if encoders is not None:
            # Patched where app.main imports it from (the app.services package
            # re-export) before the reload, so startup's one-time probe --
            # feeding both /app/info and the orchestrator's enqueue guard --
            # sees this set.
            available = frozenset(encoders)
            fake_probe = lambda: available  # noqa: E731
            monkeypatch.setattr("app.services.probe_available_encoders", fake_probe)
            monkeypatch.setattr("app.services.transcoder.probe_available_encoders", fake_probe)
        elif (
            _services.probe_available_encoders is _REAL_PROBE
            and _transcoder.probe_available_encoders is _REAL_PROBE
        ):
            # SF-BE-1b: the real probe, once per worker and binary. Only while
            # both names are still the real function: a test's own patch wins.
            monkeypatch.setattr("app.services.probe_available_encoders", _cached_real_probe)
            monkeypatch.setattr("app.services.transcoder.probe_available_encoders", _cached_real_probe)

        # U01-B-04: Settings reads ``.env`` relative to the working directory,
        # and a developer checkout may hold a real one (external accounts
        # included). Every app starts from the test's own empty tmp_path, so
        # no value from a ``.env`` there can reach it; a test that wants a
        # ``.env`` writes its own under tmp_path.
        monkeypatch.chdir(tmp_path)
        # Drop cached modules so the import executes app.main afresh and a
        # new app.config re-reads the environment (once: no reload needed).
        sys.modules.pop("app.main", None)
        sys.modules.pop("app.config", None)
        import app.main

        return app.main

    return _configure


@pytest.fixture
def open_app_client(configure_app):
    """Return ``open_app_client(**overrides)``: a context manager yielding a
    started ``TestClient`` on a freshly configured app (same overrides as
    ``configure_app``). Each call imports ``app.main`` afresh (``configure_app``
    drops the cached module; nothing is reloaded in place).

    The client is logged in as the master admin (Phase M.1b): its default
    ``Authorization`` header carries the admin's API token, so every API test
    passes through the real auth boundary."""

    @contextlib.contextmanager
    def _open(**overrides):
        main = configure_app(**overrides)
        env = overrides.get("env") or {}
        username = env.get("OSML_ADMIN_USERNAME", TEST_ADMIN_USERNAME)
        password = env.get("OSML_ADMIN_PASSWORD", TEST_ADMIN_PASSWORD)
        with TestClient(main.app) as client:
            client.headers.update(bearer(log_in(client, username, password)["token"]))
            yield client

    return _open


@pytest.fixture
def app_client(open_app_client):
    """A started ``TestClient`` on a default temporary app."""
    with open_app_client() as client:
        yield client


@pytest.fixture
def db(tmp_path):
    """A fresh test database under ``tmp_path`` (``tests/database_fixtures.make_db``).
    A test module that defines its own ``db`` fixture gets that one instead."""
    return make_db(tmp_path)


@pytest.fixture
def fast_stability_poll(monkeypatch):
    """Review r1 m-R1-51: the import tests write their files before the scan,
    so the real 0.2 s stability poll (two polls per file) only adds wall time.
    Poll every 10 ms instead; the timeout and the logic stay as in production."""
    from app.services import file_watcher

    timeout, _interval = file_watcher.wait_until_stable.__defaults__
    monkeypatch.setattr(file_watcher.wait_until_stable, "__defaults__", (timeout, 0.01))
    # Review r2 m-R2-02: and a 30 ms quiet window instead of 2 s.
    monkeypatch.setattr(file_watcher, "STABILITY_QUIET_WINDOW_S", 0.03)


# Other-issues row 62: a test whose fault is a permission that ``chmod`` takes
# away carries ``requires_chmod_denial``. Where chmod does not deny (the tests
# run as root, or the file system ignores mode bits) such a test is skipped,
# never run to a false pass or a false failure. The check is a probe of what
# chmod does here, not a user-id test.
CHMOD_SKIP_REASON = "chmod does not deny access here (root, or mode bits not enforced)"


def pytest_configure(config):
    config.addinivalue_line(
        "markers",
        "requires_chmod_denial: the test's fault is a permission chmod takes away; "
        "skipped where chmod does not deny (tests/conftest.py)",
    )


def probe_chmod_denial() -> bool:
    """Whether chmod takes access away here: a folder made read-only refuses a
    new file and a file made unreadable refuses a read. Runs the probe again on
    every call, in a fresh temporary folder."""
    with tempfile.TemporaryDirectory(prefix="osml-chmod-probe-") as tmp:
        folder = os.path.join(tmp, "folder")
        os.mkdir(folder)
        probe = os.path.join(folder, "probe")
        with open(probe, "wb") as f:
            f.write(b"x")
        os.chmod(probe, 0)
        os.chmod(folder, 0o555)
        try:
            try:
                with open(os.path.join(folder, "new"), "wb"):
                    pass
                write_refused = False
            except PermissionError:
                write_refused = True
            try:
                with open(probe, "rb"):
                    pass
                read_refused = False
            except PermissionError:
                read_refused = True
            return write_refused and read_refused
        finally:
            os.chmod(folder, 0o755)
            os.chmod(probe, 0o644)


@functools.cache
def chmod_denies() -> bool:
    """``probe_chmod_denial`` once per test process (the answer is the machine's,
    the same for every test)."""
    return probe_chmod_denial()


# Phase 6.5 (plan D16): registered markers for process-backed tests. A test
# marked ``requires_ffmpeg`` needs both ``ffmpeg`` and ``ffprobe`` on PATH; one
# marked ``requires_fpcalc`` needs ``fpcalc``. The collection hook skips them
# when a tool is absent, and ``-m requires_ffmpeg`` selects them.
REQUIRED_TOOLS = {
    "requires_ffmpeg": ("ffmpeg", "ffprobe"),
    "requires_fpcalc": ("fpcalc",),
}


def tool_skip_reason(marker_names, which=None):
    """The skip reason for a test carrying ``marker_names``, or None when
    every tool its markers require is on PATH."""
    which = which or shutil.which
    missing = [
        tool
        for marker, tools in REQUIRED_TOOLS.items()
        if marker in marker_names
        for tool in tools
        if which(tool) is None
    ]
    return f"{'/'.join(missing)} not available" if missing else None


def pytest_collection_modifyitems(config, items):
    for item in items:
        names = {marker.name for marker in item.iter_markers()}
        if names & {"requires_ffmpeg", "requires_fpcalc"}:
            item.add_marker(pytest.mark.integration)
        reason = tool_skip_reason(names, shutil.which)
        if reason is not None:
            item.add_marker(pytest.mark.skip(reason=reason))
        if "requires_chmod_denial" in names and not chmod_denies():
            item.add_marker(pytest.mark.skip(reason=CHMOD_SKIP_REASON))
