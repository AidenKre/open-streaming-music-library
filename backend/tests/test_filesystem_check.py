"""Sign-off s7-live-findings item 2 (live findings XF-L-02, XF-L-03, user
decision "warn as unsupported"): edits, conversions, deletions and imports
move files with a rename, which cannot cross filesystems. At startup, next to
the hard-link probe, the server compares the filesystem of the music library
directory with each user's library folder and each import folder that exists,
and logs one operator warning per mismatch (no path; the user's id where the
probe uses it). A folder that cannot be examined gets a "could not be
checked" line, never a false warning. The server still starts; nothing else
changes."""

import errno
import logging
import os
from pathlib import Path

import pytest

from app.library import library_root
from app.services import filesystem_check
from app.services.filesystem_check import warn_other_filesystems
from tests.identity_worker_fixtures import make_db
from tests.owned_database import add_test_user

OPERATOR = "uvicorn.error"
LIBRARY_LINE = ("only uploads work there; edits, conversions, deletions and import-folder imports"
                " fail")
IMPORT_LINE = "files dropped there are not imported"


@pytest.fixture
def db(tmp_path):
    return make_db(tmp_path)


@pytest.fixture
def dirs(tmp_path):
    music = tmp_path / "music"
    music.mkdir()
    return {"music": music, "import": tmp_path / "import", "users": tmp_path / "import-users"}


def _devices(monkeypatch, other=(), unreadable=None):
    """Folders in ``other`` report another device; ``unreadable`` maps a folder
    to the errno its examination raises; everything else is the real device."""
    other = {Path(p).resolve() for p in other}
    unreadable = {Path(p).resolve(): e for p, e in (unreadable or {}).items()}
    real = filesystem_check.device_of

    def device_of(path):
        resolved = Path(path).resolve()
        if resolved in unreadable:
            raise OSError(unreadable[resolved], os.strerror(unreadable[resolved]))
        if resolved in other:
            return -1
        return real(path)

    monkeypatch.setattr(filesystem_check, "device_of", device_of)


def _check(db, dirs, caplog) -> list[str]:
    with caplog.at_level(logging.DEBUG, logger=OPERATOR):
        warn_other_filesystems(db, music_library_dir=dirs["music"], import_dir=dirs["import"],
                               user_import_dir=dirs["users"])
    lines = [r for r in caplog.records if r.name == OPERATOR]
    assert all(r.levelno == logging.WARNING for r in lines)
    return [r.getMessage() for r in lines]


def _root(db, dirs, user_id) -> Path:
    root = library_root(dirs["music"], db.get_user(user_id))
    root.mkdir(parents=True, exist_ok=True)
    return root


def _import_folder(db, dirs, user_id) -> Path:
    folder = dirs["users"] / db.get_user(user_id)["library_folder"]
    folder.mkdir(parents=True, exist_ok=True)
    return folder


def _no_path(lines, dirs):
    for line in lines:
        assert "/" not in line and str(dirs["music"]) not in line


def test_everything_on_one_filesystem_logs_nothing(db, dirs, caplog):
    sam = add_test_user(db, "sam")
    _root(db, dirs, sam)
    _import_folder(db, dirs, sam)
    dirs["import"].mkdir()

    assert _check(db, dirs, caplog) == []


def test_a_users_library_folder_on_another_filesystem_is_warned_once(db, dirs, monkeypatch, caplog):
    sam = add_test_user(db, "sam")
    _devices(monkeypatch, other=[_root(db, dirs, sam)])

    [line] = _check(db, dirs, caplog)

    assert f"user {sam}" in line and LIBRARY_LINE in line and "not supported" in line
    _no_path([line], dirs)


def test_the_shared_import_folder_on_another_filesystem_is_warned_once(db, dirs, monkeypatch, caplog):
    dirs["import"].mkdir()
    _devices(monkeypatch, other=[dirs["import"]])

    [line] = _check(db, dirs, caplog)

    assert "shared import folder" in line and IMPORT_LINE in line and "not supported" in line
    _no_path([line], dirs)


def test_a_users_import_folder_on_another_filesystem_is_warned_once(db, dirs, monkeypatch, caplog):
    sam = add_test_user(db, "sam")
    _devices(monkeypatch, other=[_import_folder(db, dirs, sam)])

    [line] = _check(db, dirs, caplog)

    assert f"import folder of user {sam}" in line and IMPORT_LINE in line and "not supported" in line
    _no_path([line], dirs)


def test_one_line_per_mismatch(db, dirs, monkeypatch, caplog):
    sam = add_test_user(db, "sam")
    kim = add_test_user(db, "kim")
    dirs["import"].mkdir()
    _devices(monkeypatch, other=[_root(db, dirs, sam), _root(db, dirs, kim),
                                 _import_folder(db, dirs, kim), dirs["import"]])

    lines = _check(db, dirs, caplog)

    assert sorted(lines) == sorted(set(lines)) and len(lines) == 4
    assert sum(LIBRARY_LINE in line for line in lines) == 2
    assert sum(IMPORT_LINE in line for line in lines) == 2


def test_folders_that_do_not_exist_are_not_checked(db, dirs, monkeypatch, caplog):
    """A library folder not made yet is made inside the music library; an
    import folder that does not exist receives nothing."""
    add_test_user(db, "sam")
    _devices(monkeypatch, other=[dirs["import"], dirs["users"] / "sam"])

    assert _check(db, dirs, caplog) == []


@pytest.mark.parametrize("which", ["root", "user-import", "shared-import"])
def test_a_folder_that_cannot_be_examined_is_never_called_unsupported(db, dirs, monkeypatch, caplog, which):
    sam = add_test_user(db, "sam")
    dirs["import"].mkdir()
    folder = {"root": lambda: _root(db, dirs, sam), "user-import": lambda: _import_folder(db, dirs, sam),
              "shared-import": lambda: dirs["import"]}[which]()
    kim = add_test_user(db, "kim")
    _devices(monkeypatch, other=[_root(db, dirs, kim)], unreadable={folder: errno.EACCES})

    lines = _check(db, dirs, caplog)

    [unknown] = [line for line in lines if "could not be checked" in line]
    assert "EACCES" in unknown and "not supported" not in unknown
    assert ("shared import folder" in unknown) == (which == "shared-import")
    if which != "shared-import":
        assert f"user {sam}" in unknown
    # The others are still checked.
    assert [line for line in lines if "not supported" in line] == [
        line for line in lines if f"user {kim}" in line]
    assert len(lines) == 2
    _no_path(lines, dirs)


def test_a_music_library_that_cannot_be_examined_checks_nothing_else(db, dirs, monkeypatch, caplog):
    sam = add_test_user(db, "sam")
    _devices(monkeypatch, other=[_root(db, dirs, sam)], unreadable={dirs["music"]: errno.EIO})

    [line] = _check(db, dirs, caplog)

    assert "could not be checked" in line and "EIO" in line and "not supported" not in line
    _no_path([line], dirs)


def test_a_library_folder_name_that_is_not_usable_is_not_checked_and_never_raises(db, dirs, caplog):
    sam = add_test_user(db, "sam")
    from tests.identity_worker_fixtures import sql

    sql(db, "UPDATE users SET library_folder = '..' WHERE id = ?", (sam,))

    lines = _check(db, dirs, caplog)

    assert [line for line in lines if "not supported" in line] == []
    _no_path(lines, dirs)


def test_the_server_starts_and_warns_when_a_folder_is_on_another_filesystem(
        open_app_client, monkeypatch, caplog):
    def device_of(path):
        # The music library directory alone is on "another" filesystem.
        return -1 if Path(path).resolve().name == "music" else os.stat(path).st_dev

    monkeypatch.setattr(filesystem_check, "device_of", device_of)
    with caplog.at_level("WARNING", logger=OPERATOR):
        with open_app_client() as client:
            assert client.get("/app/info").status_code == 200
    lines = [r.getMessage() for r in caplog.records if r.name == OPERATOR and "not supported" in r.getMessage()]
    assert lines and all("/" not in line for line in lines)
