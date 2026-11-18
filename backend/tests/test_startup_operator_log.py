"""Live-gate observation (Phase 6.5 live run): at the server's default log level
nothing said that the schema was upgraded, what the identity startup
reconcile did, or that fingerprinting is off because fpcalc is missing.

The app's own loggers have no handler or level of their own, so their INFO
lines are dropped. uvicorn configures ``uvicorn.error`` at INFO with a handler
(the logger its "Application startup complete." line uses), so these three
operator lines go there. No line carries a path, a secret or a token.
"""

import logging
import sqlite3
from pathlib import Path

import pytest

from app.config import Settings
from app.database.database import Database, DatabaseContext
from app.services.fingerprinter import detect_fingerprinter
from app.services.identity_worker import reconcile_audio_identity
from tests.identity_worker_fixtures import add_track, make_db
from tests.schema_fixtures import INIT_SQL, make_legacy_database

OPERATOR = "uvicorn.error"


def _operator_lines(caplog):
    return [r.getMessage() for r in caplog.records if r.name == OPERATOR and r.levelno == logging.INFO]


def _database(path: Path) -> Database:
    return Database(DatabaseContext(database_path=path, init_sql_path=INIT_SQL))


# --- the schema upgrade -----------------------------------------------------------------------------


def test_the_schema_upgrade_is_logged_with_both_versions(tmp_path, caplog):
    path = tmp_path / "Private Library" / "osml.db"
    make_legacy_database(path, 13)

    with caplog.at_level(logging.INFO, logger=OPERATOR):
        _database(path).initialize()

    [line] = [m for m in _operator_lines(caplog) if "schema" in m]
    assert "13" in line and "15" in line
    assert str(tmp_path) not in line and "Private Library" not in line


def test_no_upgrade_line_for_a_new_or_current_database(tmp_path, caplog):
    path = tmp_path / "osml.db"
    with caplog.at_level(logging.INFO, logger=OPERATOR):
        _database(path).initialize()  # created at the latest version
        _database(path).initialize()  # already current
    assert [m for m in _operator_lines(caplog) if "schema" in m] == []
    conn = sqlite3.connect(path)
    try:
        assert conn.execute("PRAGMA user_version").fetchone()[0] == 15
    finally:
        conn.close()


# --- the identity startup reconcile ------------------------------------------------------------------


def test_the_identity_reconcile_result_is_logged_with_its_counts(tmp_path, caplog):
    db = make_db(tmp_path)
    add_track(db, tmp_path / "Private Song.flac", identity={"_none": True})
    add_track(db, tmp_path / "Other Private Song.flac", identity={"_none": True})

    with caplog.at_level(logging.INFO, logger=OPERATOR):
        reconcile_audio_identity(db, tool_versions="ffmpeg 9.0.2", fingerprinter_present=False)

    [line] = [m for m in _operator_lines(caplog) if m.startswith("identity reconcile")]
    assert "2 rows inserted" in line
    assert "Private" not in line and str(tmp_path) not in line


# --- a missing fingerprint tool -----------------------------------------------------------------------


@pytest.fixture
def no_fpcalc(tmp_path, monkeypatch):
    for var in ("AUDIO_FINGERPRINT_BACKEND", "FPCALC_PATH", "FPCALC_TIMEOUT_S"):
        monkeypatch.delenv(var, raising=False)
    empty = tmp_path / "empty-bin"
    empty.mkdir()
    monkeypatch.setenv("PATH", str(empty))
    return empty


def test_a_missing_fpcalc_is_logged_once_at_detection(no_fpcalc, caplog):
    with caplog.at_level(logging.INFO, logger=OPERATOR):
        assert detect_fingerprinter(Settings(_env_file=None)) is None

    assert _operator_lines(caplog) == ["fingerprinting unavailable: fpcalc not found"]


def test_fingerprinting_turned_off_is_not_reported_as_a_missing_tool(no_fpcalc, caplog):
    with caplog.at_level(logging.INFO, logger=OPERATOR):
        assert detect_fingerprinter(Settings(_env_file=None, audio_fingerprint_backend="off")) is None

    assert not any("not found" in m for m in _operator_lines(caplog))
