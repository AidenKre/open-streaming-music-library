"""The server's messages are log lines, never ``print`` output, and they do not
carry a library file's full path (the owner asked for it after a live run
showed a failed move printing both full paths). Only the admin command-line
tool prints: what it prints is its answer.

The five samples below each provoke one former ``print`` and check that what
is logged holds no absolute path of the test's folder."""

import ast
import logging
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app.core.operator_log import operator_logger
from app.database import ANY_OWNER
from app.models import Track, TrackMetaData
from app.services import file_ops, organizer
from app.services.cover_art_manager import CoverArtContext, CoverArtManager
from app.services.file_watcher import wait_until_stable
from tests.cli_fixtures import add_user, cli_settings, open_server_database

APP_DIR = Path(__file__).resolve().parents[1] / "app"
# The one module whose output is printed on purpose.
PRINTING_ALLOWED = {APP_DIR / "cli.py"}


def _print_calls(path: Path) -> list[int]:
    tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    return [
        node.lineno for node in ast.walk(tree)
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == "print"
    ]


def test_no_module_but_the_admin_tool_calls_print():
    found = {
        str(path.relative_to(APP_DIR)): lines
        for path in sorted(APP_DIR.rglob("*.py"))
        if path not in PRINTING_ALLOWED and (lines := _print_calls(path))
    }
    assert found == {}


def test_the_guard_sees_a_print_call(tmp_path):
    sample = tmp_path / "sample.py"
    sample.write_text("def f(x):\n    print(x)\n", encoding="utf-8")
    assert _print_calls(sample) == [2]


def _metadata(**fields) -> TrackMetaData:
    values = dict(title="Hidden Song", artist="Secret Artist", album="Secret Album", codec="flac",
                  duration=1.0, track_number=1, disc_number=1)
    values.update(fields)
    return TrackMetaData(**values)


def test_a_tracks_representation_does_not_name_its_file(tmp_path):
    track = Track(file_path=tmp_path / "private-folder" / "Hidden Song.flac", metadata=_metadata())

    for text in (repr(track), str(track)):
        assert "private-folder" not in text
        assert str(tmp_path) not in text
    assert track.file_path == tmp_path / "private-folder" / "Hidden Song.flac"  # still there


# --- five former prints ----------------------------------------------------------------


@pytest.fixture
def lines(caplog, capsys, tmp_path):
    """The log lines a sample caused; asserts nothing was printed and none of
    them holds an absolute path of the test's folder."""
    caplog.set_level(logging.DEBUG)
    # The operator logger is caught directly too, whatever an earlier test set
    # on it (uvicorn's own configuration stops it propagating); restored below.
    level = operator_logger.level
    operator_logger.setLevel(logging.DEBUG)
    operator_logger.addHandler(caplog.handler)

    def check() -> list[str]:
        out, err = capsys.readouterr()
        assert (out, err) == ("", "")
        messages = [r.getMessage() for r in caplog.records]
        assert messages, "the sample logged nothing"
        for message in messages:
            for root in {str(tmp_path), str(Path(tmp_path).resolve())}:
                assert root not in message, message
        return messages

    yield check
    operator_logger.removeHandler(caplog.handler)
    operator_logger.setLevel(level)


def test_a_track_the_database_cannot_add(tmp_path, lines):
    settings = cli_settings(tmp_path)
    db = open_server_database(settings)
    add_user(db, "Sam")
    path = settings.music_library_dir / "Sam" / "Hidden Song.flac"
    path.parent.mkdir(parents=True)
    path.write_bytes(b"audio")
    track = Track(file_path=path, metadata=_metadata())

    assert db.add_track(track, owner_id=999) is False  # no such user: the insert fails

    # The database's own reason, which names no path, tells disk-full from a lock.
    assert any("FOREIGN KEY" in line for line in lines())


def test_a_move_that_cannot_be_rolled_back(tmp_path, lines):
    placed = tmp_path / "library" / "Secret Artist" / "Hidden Song.flac"
    original = tmp_path / "import" / "Hidden Song.flac"
    for path in (placed, original):
        path.parent.mkdir(parents=True)
        path.write_bytes(b"audio")

    assert file_ops.rollback_move(placed, original) is False

    lines()


def test_a_cover_art_backfill_that_skips_a_missing_file(tmp_path, lines):
    missing = Track(file_path=tmp_path / "library" / "Hidden Song.flac",
                    metadata=_metadata(has_album_art=True), owner_id=1)

    class Database:
        def get_tracks_missing_cover_art(self, *, owner_id):
            assert owner_id is ANY_OWNER
            return [missing]

        def get_deleting_user_ids(self):
            return set()

    CoverArtManager(CoverArtContext(cover_art_dir=tmp_path / "art", database=Database())).backfill_cover_art()

    lines()


def test_a_stable_check_of_an_import_file(tmp_path, lines):
    path = tmp_path / "import" / "Hidden Song.flac"
    path.parent.mkdir()
    path.write_bytes(b"audio")
    ticks = iter(range(100))

    assert wait_until_stable(path, interval=0, quiet_window=1, clock=lambda: next(ticks)) is True

    lines()


def test_an_import_file_without_tags(tmp_path, lines, monkeypatch):
    source = tmp_path / "import" / "Hidden Song.flac"
    source.parent.mkdir()
    source.write_bytes(b"audio")
    monkeypatch.setattr(organizer, "get_track_metadata", lambda file_path: None)
    ctx = organizer.OrganizerContext(
        music_library_dir=tmp_path / "library", should_organize_files=True,
        should_copy_files=False, add_to_database=lambda track: True, owner_id=7,
    )

    assert organizer.Organizer(ctx).organize(source) is organizer.ImportOutcome.FAILS_CHECK

    # Two users may drop files of one name: the line names whose it was.
    assert any("Hidden Song.flac" in line and "user 7" in line for line in lines())


def test_a_server_start_and_stop_log_no_absolute_path_for_the_operator(tmp_path, configure_app, caplog):
    # The operator's lines (the logger uvicorn shows) name no folder of the
    # server's, the data folder and the watched import folder included.
    main = configure_app(env={"ENABLE_FILE_WATCHER": "true"})
    with caplog.at_level(logging.DEBUG, logger=operator_logger.name):
        with TestClient(main.app):
            pass

    lines = [r.getMessage() for r in caplog.records if r.name == operator_logger.name]
    assert any("File watcher started" in line for line in lines)  # the watcher ran
    # The server's own data folder is named once for the operator: it is no
    # library file, and an operator needs to know which folder is in use.
    data = [line for line in lines if line.startswith("app data dir: ")]
    assert len(data) == 1 and data[0].endswith(str(Path(tmp_path).resolve() / "data")), lines
    for line in lines:
        if line in data:
            continue
        for root in {str(tmp_path), str(Path(tmp_path).resolve())}:
            assert root not in line, line


# --- the import lines name a file relative to its import folder -------------------------


def test_an_import_file_the_server_cannot_use(tmp_path, lines):
    from app.services.import_archive import ArchiveUnpacker, default_limits
    from app.services.import_outcome import ImportOutcome
    from app.services.ingestion import Ingestor, IngestorContext

    folder = tmp_path / "import-users" / "sam"
    notes = folder / "Album" / "notes.txt"
    notes.parent.mkdir(parents=True)
    notes.write_bytes(b"not audio")
    ingestor = Ingestor(IngestorContext(
        workspace_dir=tmp_path / "workspace",
        organize_function=lambda path: ImportOutcome.IMPORTED,
        archives=ArchiveUnpacker(owner_id=7, ledger=None, limits=default_limits),
    ))

    assert ingestor.ingest(notes, imported_dir=folder / ".imported") is ImportOutcome.NOT_AUDIO

    messages = lines()
    assert any("Album/notes.txt" in m and "user 7" in m for m in messages), messages


def test_an_import_that_raises_in_the_watcher(tmp_path, lines, monkeypatch, caplog):
    import errno

    from app.services import file_watcher

    root = tmp_path / "import-users"
    path = root / "sam" / "Hidden Song.flac"
    path.parent.mkdir(parents=True)
    path.write_bytes(b"audio")

    def refuse(p):
        raise PermissionError(errno.EACCES, "Permission denied", str(p))

    monkeypatch.setattr(file_watcher, "wait_until_ready", lambda p, stop=None: True)
    watcher = file_watcher.FileWatcher(import_dir=root, on_file=refuse)
    try:
        assert watcher.process_file_after_stable(path) is False
    finally:
        watcher.executor.shutdown(wait=True)

    messages = lines()
    assert any("sam/Hidden Song.flac" in m for m in messages), messages
    # The traceback (its error text names the file in full) only at DEBUG.
    assert all(r.exc_info is None for r in caplog.records if r.levelno > logging.DEBUG)
