"""``python -m app.cli library check [name]``: a report of the files in a
user's library folder that no track names, and of the tracks whose file is
missing. It runs beside a running server and changes nothing: no file is
deleted, moved or written, and nothing is written to the database.

Output, one line per finding, then one summary line per user::

    Sam<TAB>unused<TAB>Radiohead/OK Computer/notes.txt
    Sam<TAB>missing<TAB>Radiohead/OK Computer/02 Airbag.flac
    Sam<TAB>unreadable<TAB>Locked
    Sam: files no track uses: 1; tracks whose file is missing: 1; folders or files that could not be read: 1

Paths are relative to the user's library folder. Files the server keeps for
itself are never reported: copy temporaries next to a track's name, the
internal folders at the top of the music folder, and cover art and caches in
the data folder (only users' library folders are walked).

Everything lives under the test's ``tmp_path`` (see ``cli_fixtures``).
"""

import errno
import io
import os
import sqlite3
from pathlib import Path

import pytest

from app.core.instance_lock import acquire_instance_lock
from app.services.file_ops import temp_name_for
from tests.cli_fixtures import (  # noqa: F401  (interpreter_noise is a fixture)
    ADMIN, add_track, add_user, child_env, cli_settings, interpreter_noise, open_server_database,
    run_cli, sql,
)
from tests.user_delete_world import dump

LUCKY = "Radiohead/OK Computer/01 Lucky.flac"
# Ends a summary when something could not be read: the counts are not complete.
LOWER_BOUNDS = (
    "folders or files that could not be read: 1; "
    "not everything could be read, so these counts are lower bounds"
)


@pytest.fixture
def lib(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    settings = cli_settings(tmp_path)
    db = open_server_database(settings)
    add_user(db, ADMIN, master=True)
    sam = add_user(db, "Sam")
    alex = add_user(db, "Alex")
    add_track(db, settings, sam)
    return settings, db, sam, alex


def _folder(settings, name) -> Path:
    return settings.music_library_dir / name


def _put(path: Path, data: bytes = b"bytes") -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return path


def _check(settings, tmp_path, *names):
    return run_cli(settings, tmp_path, "library", "check", *names)


# The first line of every check: the library is read while the server runs.
HEADER = (
    "The library is read while the server runs: a file imported or removed during "
    "the check may be listed; run the check again before acting on a finding."
)


def _body(result) -> str:
    """The output after its first line, which must be the header."""
    first, _, rest = result.out.partition("\n")
    assert first == HEADER, result.out
    return rest


def _findings(result, kind):
    return sorted(
        tuple(line.split("\t")[::2]) for line in result.out.splitlines()
        if line.count("\t") == 2 and line.split("\t")[1] == kind
    )


def _summary(result, name):
    lines = [line for line in result.out.splitlines() if line.startswith(f"{name}: ")]
    assert len(lines) == 1, result.out
    return lines[0]


def _tree(root: Path) -> dict:
    """Every entry under ``root`` with what a change would alter."""
    out = {}
    for directory, dirs, files in os.walk(root, followlinks=False):
        for name in dirs + files:
            path = Path(directory) / name
            info = os.lstat(path)
            out[str(path)] = (info.st_mode, info.st_size, info.st_mtime_ns, info.st_ino)
    return out


# --- what it reports -------------------------------------------------------------------


def test_it_lists_the_files_no_track_names_relative_to_the_folder(lib, tmp_path):
    settings, db, sam, alex = lib
    sam_root = _folder(settings, "Sam")
    _put(sam_root / "Radiohead" / "OK Computer" / "notes.txt")
    _put(sam_root / "stray.flac")
    _put(sam_root / "A" / "B" / "c.mp3")

    result = _check(settings, tmp_path, "Sam")

    assert result.code == 0, result.err
    assert _findings(result, "unused") == [
        ("Sam", "A/B/c.mp3"), ("Sam", "Radiohead/OK Computer/notes.txt"), ("Sam", "stray.flac"),
    ]
    assert _findings(result, "missing") == []
    assert _summary(result, "Sam") == (
        "Sam: files no track uses: 3; tracks whose file is missing: 0; "
        "symbolic links, not followed: 0; "
        "tracks stored behind a symbolic link, not checked: 0; "
        "tracks stored outside the library folder, not checked: 0; "
        "folders or files that could not be read: 0"
    )
    assert str(tmp_path) not in result.out
    assert str(Path(tmp_path).resolve()) not in result.out
    assert result.err == ""
    assert result.out.splitlines()[0] == HEADER


def test_a_name_with_control_characters_cannot_forge_an_output_line(lib, tmp_path):
    # A newline, a tab or a terminal escape in a file name is written escaped,
    # so one finding is always one line of three fields.
    settings, db, sam, alex = lib
    _put(_folder(settings, "Sam") / "evil\nSam\tmissing\tforged.flac")
    _put(_folder(settings, "Sam") / "bell\x1b[2Jback\\slash.txt")

    result = _check(settings, tmp_path, "Sam")

    assert result.code == 0, result.err
    assert _findings(result, "missing") == []
    assert _findings(result, "unused") == [
        ("Sam", "bell\\x1b[2Jback\\\\slash.txt"),
        ("Sam", "evil\\nSam\\tmissing\\tforged.flac"),
    ]
    assert "\x1b" not in result.out
    assert len(_body(result).splitlines()) == 3  # two findings and the summary


def test_it_lists_the_tracks_whose_file_is_missing(lib, tmp_path):
    settings, db, sam, alex = lib
    add_track(db, settings, sam, title="Airbag", track_number=2)
    (_folder(settings, "Sam") / "Radiohead" / "OK Computer" / "02 Airbag.flac").unlink()

    result = _check(settings, tmp_path, "Sam")

    assert result.code == 0, result.err
    assert _findings(result, "missing") == [("Sam", "Radiohead/OK Computer/02 Airbag.flac")]
    assert _findings(result, "unused") == []
    assert "tracks whose file is missing: 1;" in _summary(result, "Sam")


def test_a_track_being_deleted_is_not_reported_missing(lib, tmp_path):
    # Its file has been moved out of the library by the deletion in progress.
    settings, db, sam, alex = lib
    track = add_track(db, settings, sam, title="Airbag", track_number=2)
    sql(db, "INSERT INTO deletion_journal (owner_id, operation_uuid, uuid_id, original_path, "
            "base_revision, master_missing, stage, created_at, updated_at) "
            "VALUES (?, 'op', ?, ?, 1, 1, 'intent', 0, 0)",
        (sam, track.uuid_id, str(track.file_path)))
    Path(track.file_path).unlink()

    result = _check(settings, tmp_path, "Sam")

    assert result.code == 0, result.err
    assert _findings(result, "missing") == []


def test_without_a_name_it_checks_every_user(lib, tmp_path):
    settings, db, sam, alex = lib
    _put(_folder(settings, "Sam") / "sam-stray.txt")
    _put(_folder(settings, "Alex") / "Some" / "alex-stray.txt")

    result = _check(settings, tmp_path)

    assert result.code == 0, result.err
    assert _findings(result, "unused") == [("Alex", "Some/alex-stray.txt"), ("Sam", "sam-stray.txt")]
    for name in (ADMIN, "Sam", "Alex"):
        _summary(result, name)


@pytest.mark.requires_chmod_denial
def test_a_folder_it_cannot_read_is_counted_not_skipped_silently(lib, tmp_path):
    settings, db, sam, alex = lib
    locked = _put(_folder(settings, "Sam") / "Locked" / "inside.txt").parent
    locked.chmod(0)
    try:
        result = _check(settings, tmp_path, "Sam")
    finally:
        locked.chmod(0o755)

    assert result.code == 1  # not checked in full
    assert _findings(result, "unreadable") == [("Sam", "Locked")]
    assert _summary(result, "Sam").endswith(LOWER_BOUNDS)


@pytest.mark.requires_chmod_denial
def test_a_library_folder_it_cannot_list_is_not_checked(lib, tmp_path):
    # Nothing in it was looked at: no count may read as "none".
    settings, db, sam, alex = lib
    root = _folder(settings, "Sam")  # Lucky's file lies inside
    root.chmod(0)
    try:
        result = _check(settings, tmp_path, "Sam")
    finally:
        root.chmod(0o755)

    assert result.code == 1
    assert _body(result) == "Sam: not checked: the library folder could not be read (Permission denied)\n"
    assert ": 0" not in result.out


def test_one_user_not_checked_makes_the_exit_code_1_and_the_others_are_checked(lib, tmp_path):
    settings, db, sam, alex = lib
    _put(_folder(settings, "Sam") / "sam-stray.txt")
    sql(db, "UPDATE users SET deleting_at = 1 WHERE id = ?", (alex,))

    result = _check(settings, tmp_path)

    assert result.code == 1
    assert _findings(result, "unused") == [("Sam", "sam-stray.txt")]
    assert "Alex: not checked: the user is being deleted" in result.out.splitlines()
    _summary(result, ADMIN)


def test_an_unknown_user_is_refused(lib, tmp_path):
    settings, db, sam, alex = lib

    result = _check(settings, tmp_path, "Zed")

    assert result.code == 1
    assert result.err == "No user named 'Zed'\n"
    assert result.out == ""


# --- it is safe beside a running server ------------------------------------------------


def test_it_runs_while_the_server_holds_the_lock(lib, tmp_path):
    settings, db, sam, alex = lib
    lock = acquire_instance_lock(settings.app_data_dir)
    try:
        result = _check(settings, tmp_path, "Sam")
    finally:
        lock.release()

    assert result.code == 0, result.err


def test_it_changes_nothing(lib, tmp_path):
    settings, db, sam, alex = lib
    sam_root = _folder(settings, "Sam")
    _put(sam_root / "stray.flac")
    _put(sam_root / "Empty" / "Nested" / "x.txt").unlink()  # empty folders stay
    add_track(db, settings, sam, title="Airbag", track_number=2)
    (sam_root / "Radiohead" / "OK Computer" / "02 Airbag.flac").unlink()
    rows, files = dump(db), _tree(settings.music_library_dir)

    result = _check(settings, tmp_path)

    assert result.code == 0, result.err
    assert dump(db) == rows
    assert _tree(settings.music_library_dir) == files


def test_it_follows_no_symbolic_link_and_never_calls_one_unused(lib, tmp_path):
    settings, db, sam, alex = lib
    outside = tmp_path / "outside"
    _put(outside / "behind-the-link.flac")
    sam_root = _folder(settings, "Sam")
    (sam_root / "linked-folder").symlink_to(outside, target_is_directory=True)
    (sam_root / "linked-file.flac").symlink_to(outside / "behind-the-link.flac")

    result = _check(settings, tmp_path, "Sam")

    assert result.code == 1  # what the links point at was not checked
    # A link is listed as a link, never as unused; what it points at is not read.
    assert _findings(result, "link") == [("Sam", "linked-file.flac"), ("Sam", "linked-folder")]
    assert _findings(result, "unused") == []
    assert "behind-the-link" not in result.out
    assert "symbolic links, not followed: 2;" in _summary(result, "Sam")


def _move_behind_a_link(settings, tmp_path, relative):
    """Moves ``relative`` (inside Sam's folder) to a disk outside and links it back."""
    inside = _folder(settings, "Sam") / relative
    outside = tmp_path / "external" / relative
    outside.parent.mkdir(parents=True, exist_ok=True)
    inside.rename(outside)
    inside.symlink_to(outside, target_is_directory=outside.is_dir())
    return outside


def test_a_linked_folder_that_holds_tracks_is_not_reported_unused(lib, tmp_path):
    # An operator moved an artist's folder to another disk and linked it back:
    # deleting the link would lose every track stored through it.
    settings, db, sam, alex = lib
    _move_behind_a_link(settings, tmp_path, "Radiohead")

    result = _check(settings, tmp_path, "Sam")

    assert result.code == 1
    assert _findings(result, "unused") == []
    assert _findings(result, "missing") == []
    assert _findings(result, "link") == [("Sam", "Radiohead")]
    assert "symbolic links, not followed: 1; tracks stored behind a symbolic link, not checked: 1;" \
        in _summary(result, "Sam")


def test_a_linked_file_a_track_names_is_not_reported_unused_or_missing(lib, tmp_path):
    settings, db, sam, alex = lib
    _move_behind_a_link(settings, tmp_path, LUCKY)

    result = _check(settings, tmp_path, "Sam")

    assert result.code == 1
    assert _findings(result, "unused") == []
    assert _findings(result, "missing") == []
    assert _findings(result, "link") == [("Sam", LUCKY)]
    assert "tracks stored behind a symbolic link, not checked: 1;" in _summary(result, "Sam")


def test_a_dangling_link_is_listed_as_a_link(lib, tmp_path):
    settings, db, sam, alex = lib
    (_folder(settings, "Sam") / "dangling").symlink_to(tmp_path / "nowhere")

    result = _check(settings, tmp_path, "Sam")

    assert result.code == 1
    assert _findings(result, "link") == [("Sam", "dangling")]
    assert _findings(result, "unused") == []


def test_a_link_back_into_the_users_own_folder_is_not_walked(lib, tmp_path):
    # A loop: walking it would never end.
    settings, db, sam, alex = lib
    (_folder(settings, "Sam") / "loop").symlink_to(_folder(settings, "Sam"), target_is_directory=True)

    result = _check(settings, tmp_path, "Sam")

    assert result.code == 1
    assert _findings(result, "link") == [("Sam", "loop")]
    assert _findings(result, "missing") == []
    assert "symbolic links, not followed: 1;" in _summary(result, "Sam")


NOT_CHECKED_LINK = (
    "Alex: not checked: the library folder is a symbolic link or not a folder "
    "inside the music folder\n"
)


def test_a_library_folder_that_links_outside_the_music_folder_is_not_checked(lib, tmp_path):
    settings, db, sam, alex = lib
    elsewhere = tmp_path / "elsewhere"
    _put(elsewhere / "behind-the-link.flac")
    _folder(settings, "Alex").symlink_to(elsewhere, target_is_directory=True)

    result = _check(settings, tmp_path, "Alex")

    assert result.code == 1  # a user not checked
    assert _body(result) == NOT_CHECKED_LINK  # no counts: nothing was looked at


def test_a_library_folder_that_links_to_another_users_folder_is_not_checked(lib, tmp_path):
    settings, db, sam, alex = lib
    _put(_folder(settings, "Sam") / "sam-stray.txt")
    _folder(settings, "Alex").symlink_to(_folder(settings, "Sam"), target_is_directory=True)

    result = _check(settings, tmp_path, "Alex")

    assert result.code == 1  # a user not checked
    assert _body(result) == NOT_CHECKED_LINK


def test_a_user_being_deleted_is_not_checked(lib, tmp_path):
    # An interrupted delete has removed some of the user's files already.
    settings, db, sam, alex = lib
    sql(db, "UPDATE users SET deleting_at = 1 WHERE id = ?", (sam,))
    (_folder(settings, "Sam") / LUCKY).unlink()

    result = _check(settings, tmp_path, "Sam")

    assert result.code == 1  # a user not checked
    assert _body(result) == "Sam: not checked: the user is being deleted\n"


def test_a_user_with_no_music_yet_has_no_folder_and_no_findings(lib, tmp_path):
    # A library folder is made when the user's first file is placed.
    settings, db, sam, alex = lib
    assert not os.path.lexists(_folder(settings, "Alex"))

    result = _check(settings, tmp_path, "Alex")

    assert result.code == 0, result.err
    assert _body(result) == (
        "Alex: files no track uses: 0; tracks whose file is missing: 0; "
        "symbolic links, not followed: 0; "
        "tracks stored behind a symbolic link, not checked: 0; "
        "tracks stored outside the library folder, not checked: 0; "
        "folders or files that could not be read: 0\n"
    )


def test_it_refuses_a_music_folder_other_than_the_servers(lib, tmp_path):
    settings, db, sam, alex = lib
    for key in ("music_library_dir", "import_dir", "user_import_dir"):
        db.set_setting(key, str(getattr(settings, key).resolve()))
    db.set_setting("music_library_dir", str(tmp_path / "elsewhere"))

    result = _check(settings, tmp_path, "Sam")

    assert result.code == 1
    assert "music_library_dir differs from the server's" in result.err
    assert result.out == ""


# --- files the server keeps for itself are not reported (one test per rule) ------------


def test_a_copy_temporary_next_to_a_track_name_is_not_reported(lib, tmp_path):
    # A copy into the library is written under a hidden temporary name first.
    settings, db, sam, alex = lib
    album = _folder(settings, "Sam") / "Radiohead" / "OK Computer"
    _put(temp_name_for(album / "02 Airbag.flac"))
    lookalike = _put(album / ".not-a-copy-temporary.osml-part")

    result = _check(settings, tmp_path, "Sam")

    assert result.code == 0, result.err
    assert _findings(result, "unused") == [("Sam", str(lookalike.relative_to(_folder(settings, "Sam"))))]


def test_the_internal_folders_and_the_data_folder_are_not_walked(lib, tmp_path):
    # Staging, uploads and deletions in progress live in hidden folders at the
    # top of the music folder; cover art and caches live in the data folder.
    settings, db, sam, alex = lib
    for internal in (".staging", ".uploads", ".deleting"):
        _put(settings.music_library_dir / internal / "Sam" / "kept-by-the-server.flac")
    for kept in ("cover_art/abc.jpg", "encoded_cache/x__q1.m4a", "default_cache/y__q2.m4a"):
        _put(settings.app_data_dir / kept)

    result = _check(settings, tmp_path)

    assert result.code == 0, result.err
    assert _findings(result, "unused") == []
    assert "kept-by-the-server" not in result.out


# --- it ends in one line, never a traceback --------------------------------------------


@pytest.mark.parametrize("failing", ["track_identities_in_folder", "live_track_paths"])
def test_a_database_that_cannot_be_read_mid_check_ends_in_one_line(lib, tmp_path, monkeypatch, failing):
    settings, db, sam, alex = lib
    from app.database.database import Database

    def locked(self, *args, **kwargs):
        raise sqlite3.OperationalError("database is locked")

    monkeypatch.setattr(Database, failing, locked)

    try:
        result = _check(settings, tmp_path, "Sam")
    except sqlite3.Error as exc:  # would end the tool with a traceback
        pytest.fail(f"{type(exc).__name__} escaped the tool")

    assert result.code == 1
    assert result.err.count("\n") == 1, result.err
    assert "database is locked" in result.err
    assert "Traceback" not in result.err


@pytest.mark.requires_chmod_denial
def test_a_track_inside_an_unreadable_folder_is_counted_once(lib, tmp_path):
    settings, db, sam, alex = lib
    album = _folder(settings, "Sam") / "Radiohead" / "OK Computer"  # holds Lucky's file
    album.chmod(0)
    try:
        result = _check(settings, tmp_path, "Sam")
    finally:
        album.chmod(0o755)

    assert result.code == 1  # not checked in full
    assert _findings(result, "unreadable") == [("Sam", "Radiohead/OK Computer")]
    assert _summary(result, "Sam").endswith(LOWER_BOUNDS)


def _drop_settings(db):
    conn = sqlite3.connect(db.context.database_path)
    conn.execute("DROP TABLE app_settings")
    conn.commit()
    conn.close()


@pytest.mark.parametrize("broken", ["unreadable", "relative"])
def test_a_refusal_over_the_recorded_folders_says_nothing_was_checked(lib, tmp_path, broken):
    settings, db, sam, alex = lib
    if broken == "unreadable":
        _drop_settings(db)
    else:
        db.set_setting("music_library_dir", "relative/music")

    result = _check(settings, tmp_path, "Sam")

    assert result.code == 1
    assert "could not read the server's recorded folders" in result.err
    assert result.err.rstrip("\n").endswith("nothing was checked")
    assert "deleted" not in result.err
    assert result.out == ""


# --- no read snapshot is held through the file checks -----------------------------------


def _checkpoint(db) -> int:
    """A write and a full checkpoint from a second connection, as the server's
    durable points do; 0 when the checkpoint completed (no reader in the way)."""
    other = sqlite3.connect(db.context.database_path, timeout=0)
    try:
        other.execute("INSERT OR REPLACE INTO app_settings (key, value) VALUES ('probe', '1')")
        other.commit()
        return other.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone()[0]
    finally:
        other.close()


def test_reading_the_track_paths_holds_no_transaction_between_pages(lib, tmp_path, monkeypatch):
    settings, db, sam, alex = lib
    for n in range(2, 7):
        add_track(db, settings, sam, title=f"Song {n}", track_number=n)
    from app.database import tracks as tracks_part
    monkeypatch.setattr(tracks_part, "TRACK_PATH_PAGE", 2, raising=False)

    paths = db.live_track_paths(owner_id=sam)
    first = next(paths)
    busy = _checkpoint(db)
    rest = list(paths)

    assert busy == 0
    assert len({first, *rest}) == 6


def test_a_checkpoint_completes_while_the_check_reads_files(lib, tmp_path, monkeypatch):
    settings, db, sam, alex = lib
    for n in range(2, 6):  # rows still to read when Lucky's file is checked
        add_track(db, settings, sam, title=f"Song {n}", track_number=n)
    real_lstat = os.lstat
    seen = []

    def lstat(path, *args, **kwargs):
        if not seen and str(path).endswith("01 Lucky.flac"):
            seen.append(_checkpoint(db))
        return real_lstat(path, *args, **kwargs)

    monkeypatch.setattr(os, "lstat", lstat)

    result = _check(settings, tmp_path, "Sam")

    assert result.code == 0, result.err
    assert seen == [0]


# --- no traceback, ever ----------------------------------------------------------------


def _main_with(settings, out, err, *argv):
    from app.cli import main

    try:
        return main(["library", "check", *argv], settings=settings, out=out, err=err)
    except BaseException as exc:  # would end the tool with a traceback
        pytest.fail(f"{type(exc).__name__} escaped the tool")


class _FailingOutput:
    """An output whose second write fails, as a closed pipe or a full disk does."""

    def __init__(self, error):
        self.written, self.error = [], error

    def write(self, text):
        if self.written:
            raise self.error
        self.written.append(text)
        return len(text)

    def flush(self):
        pass


def test_ctrl_c_during_the_check_ends_in_one_line(lib, tmp_path, monkeypatch):
    settings, db, sam, alex = lib
    from app.database.database import Database

    def interrupted(self, *args, **kwargs):
        raise KeyboardInterrupt

    monkeypatch.setattr(Database, "track_identities_in_folder", interrupted)
    out, err = io.StringIO(), io.StringIO()

    assert _main_with(settings, out, err, "Sam") == 1
    assert err.getvalue() == "The check was stopped.\n"


def test_a_closed_output_ends_quietly(lib, tmp_path):
    settings, db, sam, alex = lib
    _put(_folder(settings, "Sam") / "stray.txt")
    out, err = _FailingOutput(BrokenPipeError(errno.EPIPE, "Broken pipe")), io.StringIO()

    assert _main_with(settings, out, err, "Sam") == 1
    assert err.getvalue() == ""
    assert not any("unreadable" in text for text in out.written)


def test_a_failed_write_is_not_counted_as_an_unreadable_folder(lib, tmp_path):
    settings, db, sam, alex = lib
    _put(_folder(settings, "Sam") / "stray.txt")
    out, err = _FailingOutput(OSError(errno.ENOSPC, "No space left on device")), io.StringIO()

    assert _main_with(settings, out, err, "Sam") == 1
    assert err.getvalue() == "The check stopped: the report could not be written (No space left on device).\n"
    assert not any("unreadable" in text for text in out.written)


@pytest.mark.parametrize("lookup,argv", [
    ("list_user_folders", ()), ("get_user_by_username_key", ("Sam",)),
])
def test_a_database_error_in_the_user_lookup_ends_in_one_line(lib, tmp_path, monkeypatch, lookup, argv):
    settings, db, sam, alex = lib
    from app.database.database import Database

    def locked(self, *args, **kwargs):
        raise sqlite3.OperationalError("database is locked")

    monkeypatch.setattr(Database, lookup, locked)
    out, err = io.StringIO(), io.StringIO()

    assert _main_with(settings, out, err, *argv) == 1
    assert err.getvalue() == (
        "The check stopped: the database could not be read (database is locked); "
        "run library check again.\n"
    )


def test_a_library_folder_that_links_to_itself_is_not_checked(lib, tmp_path):
    settings, db, sam, alex = lib
    _folder(settings, "Alex").symlink_to(_folder(settings, "Alex"), target_is_directory=True)

    result = _check(settings, tmp_path, "Alex")

    assert result.code == 1
    assert _body(result) == NOT_CHECKED_LINK


@pytest.mark.integration
def test_a_reader_that_stops_early_gets_no_traceback(lib, tmp_path, interpreter_noise):
    # ``library check | head -1``: the reader goes away before the tool is done.
    import subprocess
    import sys

    settings, db, sam, alex = lib
    for n in range(200):
        _put(_folder(settings, "Sam") / f"stray-{n:03}.txt")

    tool = subprocess.Popen([sys.executable, "-m", "app.cli", "library", "check", "Sam"],
                            cwd=tmp_path, env=child_env(settings), stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    tool.stdout.close()  # the reader is gone before the tool writes
    stderr = tool.communicate(timeout=60)[1]

    assert tool.returncode == 1
    assert stderr.startswith(interpreter_noise), stderr
    assert stderr[len(interpreter_noise):] == ""


# --- a file a track may reach another way is never listed as unused --------------------


def test_a_file_reached_through_a_link_inside_the_folder_is_not_listed_unused(lib, tmp_path):
    # Radiohead moved into Archive/ with a link left in its place; Lucky is still
    # stored through the link, so its real file must not be called unused.
    settings, db, sam, alex = lib
    sam_root = _folder(settings, "Sam")
    (sam_root / "Archive").mkdir()
    (sam_root / "Radiohead").rename(sam_root / "Archive" / "Radiohead")
    (sam_root / "Radiohead").symlink_to(sam_root / "Archive" / "Radiohead", target_is_directory=True)
    _put(sam_root / "Archive" / "stray.txt")

    result = _check(settings, tmp_path, "Sam")

    assert result.code == 1
    assert _findings(result, "unused") == []
    assert _findings(result, "link") == [("Sam", "Radiohead")]
    summary = _summary(result, "Sam")
    assert summary.startswith("Sam: files no track uses: not checked; ")
    assert "tracks stored behind a symbolic link, not checked: 1;" in summary


def test_tracks_stored_through_a_moved_music_folder_do_not_make_their_files_unused(lib, tmp_path, monkeypatch):
    # The music folder moved to a bigger disk and a link was left at the old
    # place: the tracks keep their old paths, the server reads them through it.
    settings, db, sam, alex = lib
    moved = tmp_path / "bigger-disk" / "music"
    moved.parent.mkdir()
    settings.music_library_dir.rename(moved)
    settings.music_library_dir.symlink_to(moved, target_is_directory=True)
    now = cli_settings(tmp_path, music_library_dir=moved)
    _put(moved / "Sam" / "stray.txt")

    result = _check(now, tmp_path, "Sam")

    assert result.code == 1
    assert _findings(result, "unused") == []
    assert _findings(result, "missing") == []
    summary = _summary(result, "Sam")
    assert summary.startswith("Sam: files no track uses: not checked; ")
    assert "tracks stored outside the library folder, not checked: 1;" in summary


def test_a_folder_name_that_is_not_text_cannot_be_a_tracks_folder(lib, tmp_path, monkeypatch):
    # On Linux a folder's name may be bytes that are not UTF-8: the database
    # cannot be asked about it (no track can be stored there), and that is no error.
    settings, db, sam, alex = lib
    from app.database.database import Database

    odd = _put(_folder(settings, "Sam") / "Odd" / "inside.txt").parent
    real = Database.track_identities_in_folder

    def lookup(self, folder, **kwargs):
        if folder == str(odd):
            "\udcff".encode("utf-8")  # what SQLite meets for such a name
        return real(self, folder, **kwargs)

    monkeypatch.setattr(Database, "track_identities_in_folder", lookup)

    result = _check(settings, tmp_path, "Sam")

    assert result.code == 0, result.err
    assert _findings(result, "unused") == [("Sam", "Odd/inside.txt")]


@pytest.mark.requires_chmod_denial
def test_a_track_behind_a_folder_that_cannot_be_searched_keeps_the_unused_list_off(lib, tmp_path):
    # Whether Lucky's path runs through a link cannot be seen: the file the link
    # may point at must not be called unused.
    from app.database.core import track_path_values

    settings, db, sam, alex = lib
    sam_root = _folder(settings, "Sam")
    (sam_root / "Archive").mkdir()
    (sam_root / "Radiohead").rename(sam_root / "Archive" / "Radiohead")
    locked = sam_root / "Locked"
    locked.mkdir()
    (locked / "Radiohead").symlink_to(sam_root / "Archive" / "Radiohead", target_is_directory=True)
    stored = str(locked / LUCKY)
    sql(db, "UPDATE tracks SET file_path = ?, file_path_fold = ?, file_folder_fold = ? WHERE owner_id = ?",
        (*track_path_values(stored), sam))
    locked.chmod(0)
    try:
        result = _check(settings, tmp_path, "Sam")
    finally:
        locked.chmod(0o755)

    assert result.code == 1
    assert _findings(result, "unused") == []
    assert _summary(result, "Sam").startswith("Sam: files no track uses: not checked; ")


# --- the same rules without a real permission (they hold when the suite runs as root) ---


def _refusing_scandir(monkeypatch, refused: Path):
    """``os.scandir`` that refuses ``refused`` as a folder without permission does."""
    import errno

    real = os.scandir

    def scandir(path="."):
        if Path(path) == refused:
            raise PermissionError(errno.EACCES, "Permission denied", str(path))
        return real(path)

    monkeypatch.setattr(os, "scandir", scandir)


def test_a_library_folder_that_refuses_listing_is_not_checked_without_chmod(lib, tmp_path, monkeypatch):
    settings, db, sam, alex = lib
    _refusing_scandir(monkeypatch, _folder(settings, "Sam"))

    result = _check(settings, tmp_path, "Sam")

    assert result.code == 1
    assert _body(result) == "Sam: not checked: the library folder could not be read (Permission denied)\n"
    assert ": 0" not in result.out


def test_a_folder_that_refuses_listing_makes_the_counts_lower_bounds_without_chmod(lib, tmp_path, monkeypatch):
    settings, db, sam, alex = lib
    locked = _put(_folder(settings, "Sam") / "Locked" / "inside.txt").parent
    _refusing_scandir(monkeypatch, locked)

    result = _check(settings, tmp_path, "Sam")

    assert result.code == 1
    assert _findings(result, "unreadable") == [("Sam", "Locked")]
    assert _summary(result, "Sam").endswith(LOWER_BOUNDS)


# --- another user's folder that is a link into this one -------------------------------


def test_a_file_another_users_track_reaches_through_their_linked_folder_is_not_unused(lib, tmp_path):
    # Alex's library folder is a link to Sam's: Alex's imports land in Sam's
    # folder, stored under Alex's spelling of the path.
    settings, db, sam, alex = lib
    _folder(settings, "Alex").symlink_to(_folder(settings, "Sam"), target_is_directory=True)
    add_track(db, settings, alex, title="Creep", album="Pablo Honey", track_number=2)
    _put(_folder(settings, "Sam") / "stray.txt")

    result = _check(settings, tmp_path)

    assert _findings(result, "unused") == [("Sam", "stray.txt")]
    assert "Alex: not checked: the library folder is a symbolic link or not a folder inside the music folder" \
        in result.out.splitlines()
    assert result.code == 1


# --- a file any user's live track resolves to is never listed as unused ----------------


def _unused_list_made(result, name) -> bool:
    return not _summary(result, name).startswith(f"{name}: files no track uses: not checked;")


def _alex_lucky(db, settings, alex):
    """Alex's own Lucky, stored as music/Alex/Radiohead/OK Computer/01 Lucky.flac."""
    add_track(db, settings, alex)
    return _folder(settings, "Alex") / "Radiohead"


def test_a_file_another_users_track_reaches_through_a_link_inside_their_folder_is_not_unused(lib, tmp_path):
    # The operator shares an artist: Alex's Radiohead moved into Sam's folder,
    # a link left in Alex's folder; Alex's tracks still play through it.
    settings, db, sam, alex = lib
    radiohead = _alex_lucky(db, settings, alex)
    radiohead.rename(_folder(settings, "Sam") / "Shared")
    radiohead.symlink_to(_folder(settings, "Sam") / "Shared", target_is_directory=True)
    _put(_folder(settings, "Sam") / "stray.txt")

    result = _check(settings, tmp_path, "Sam")

    assert _findings(result, "unused") == [("Sam", "stray.txt")]  # the list is made
    assert "Alex" not in _body(result) and "Lucky" not in _body(result).replace(LUCKY, "")


def test_the_mirror_a_link_in_the_checked_users_folder_into_the_other_users(lib, tmp_path):
    # Sam's own link into Alex's folder: Sam's track there uses Alex's file.
    settings, db, sam, alex = lib
    shared = _folder(settings, "Alex") / "Shared"
    shared.mkdir(parents=True)
    (_folder(settings, "Sam") / "L").symlink_to(shared, target_is_directory=True)
    add_track(db, settings, sam, artist="L", album="Dummy", title="Roads", track_number=3)
    assert (shared / "Dummy" / "03 Roads.flac").exists()  # stored through Sam's link

    result = _check(settings, tmp_path, "Alex")

    assert _findings(result, "unused") == []
    assert _unused_list_made(result, "Alex")


def test_a_link_two_levels_down_in_the_other_users_folder(lib, tmp_path):
    settings, db, sam, alex = lib
    radiohead = _alex_lucky(db, settings, alex)
    deep = _folder(settings, "Sam") / "Deep"
    deep.mkdir()
    (radiohead / "OK Computer").rename(deep / "OK Computer")
    (radiohead / "OK Computer").symlink_to(deep / "OK Computer", target_is_directory=True)

    result = _check(settings, tmp_path, "Sam")

    assert _findings(result, "unused") == []
    assert _unused_list_made(result, "Sam")


def test_a_chain_of_two_links(lib, tmp_path):
    settings, db, sam, alex = lib
    radiohead = _alex_lucky(db, settings, alex)
    radiohead.rename(_folder(settings, "Sam") / "Shared")
    hop = _folder(settings, "Alex") / "Hop"
    hop.symlink_to(_folder(settings, "Sam") / "Shared", target_is_directory=True)
    radiohead.symlink_to(hop, target_is_directory=True)

    result = _check(settings, tmp_path, "Sam")

    assert _findings(result, "unused") == []
    assert _unused_list_made(result, "Sam")


def test_a_link_to_a_single_file_in_the_other_users_folder(lib, tmp_path):
    settings, db, sam, alex = lib
    radiohead = _alex_lucky(db, settings, alex)
    lucky = radiohead / "OK Computer" / "01 Lucky.flac"
    lucky.rename(_folder(settings, "Sam") / "Single.flac")
    lucky.symlink_to(_folder(settings, "Sam") / "Single.flac")

    result = _check(settings, tmp_path, "Sam")

    assert _findings(result, "unused") == []
    assert _unused_list_made(result, "Sam")


def test_a_dangling_link_among_another_users_tracks_reaches_no_file(lib, tmp_path):
    # It points at nothing that exists, so no file can depend on it: the list is made.
    settings, db, sam, alex = lib
    radiohead = _alex_lucky(db, settings, alex)
    import shutil

    shutil.rmtree(radiohead)
    radiohead.symlink_to(_folder(settings, "Sam") / "Nothing", target_is_directory=True)
    _put(_folder(settings, "Sam") / "stray.txt")

    result = _check(settings, tmp_path, "Sam")

    assert _findings(result, "unused") == [("Sam", "stray.txt")]


def test_a_link_loop_among_another_users_tracks_turns_the_unused_list_off(lib, tmp_path):
    # Where that track leads cannot be known: unknown is never "unused".
    settings, db, sam, alex = lib
    radiohead = _alex_lucky(db, settings, alex)
    import shutil

    shutil.rmtree(radiohead)
    radiohead.symlink_to(radiohead, target_is_directory=True)
    _put(_folder(settings, "Sam") / "stray.txt")

    result = _check(settings, tmp_path, "Sam")

    assert result.code == 1
    assert _findings(result, "unused") == []
    assert not _unused_list_made(result, "Sam")


def test_three_users_a_links_into_b_and_b_into_c(lib, tmp_path):
    settings, db, sam, alex = lib
    cleo = add_user(db, "Cleo")
    real = _folder(settings, "Cleo") / "X"
    real.mkdir(parents=True)
    (_folder(settings, "Sam") / "X").symlink_to(real, target_is_directory=True)
    _folder(settings, "Alex").mkdir()
    (_folder(settings, "Alex") / "X").symlink_to(_folder(settings, "Sam") / "X", target_is_directory=True)
    add_track(db, settings, alex, artist="X", album="Album", title="Song", track_number=1)
    assert (real / "Album" / "01 Song.flac").exists()

    result = _check(settings, tmp_path, "Cleo")

    assert _findings(result, "unused") == []
    assert _unused_list_made(result, "Cleo")


def test_the_check_reads_in_pages_not_once_per_file(lib, tmp_path, monkeypatch):
    # Three users, 40 tracks behind links: the reads grow with pages and
    # folders, never with the number of files.
    settings, db, sam, alex = lib
    from app.database import core

    radiohead = _alex_lucky(db, settings, alex)
    for n in range(2, 41):
        add_track(db, settings, alex, title=f"Song {n}", track_number=n)
    radiohead.rename(_folder(settings, "Sam") / "Shared")
    radiohead.symlink_to(_folder(settings, "Sam") / "Shared", target_is_directory=True)
    add_user(db, "Cleo")
    reads = []
    real_open = core.open_connection

    def counting(*args, **kwargs):
        reads.append(1)
        return real_open(*args, **kwargs)

    monkeypatch.setattr(core, "open_connection", counting)

    result = _check(settings, tmp_path)

    assert _findings(result, "unused") == []
    assert len(reads) < 30, len(reads)


NOT_FOLLOWED = (
    "Files no track uses are not listed in this run: a track's path could not be "
    "followed (a link loop, or a folder that cannot be read)."
)


def test_another_users_folder_that_cannot_be_searched_turns_the_unused_list_off(lib, tmp_path, monkeypatch):
    # Whether Alex's track runs through a link into Sam's folder cannot be seen.
    import errno

    settings, db, sam, alex = lib
    radiohead = _alex_lucky(db, settings, alex)
    _put(_folder(settings, "Sam") / "stray.txt")
    real_lstat = os.lstat

    def lstat(path, *args, **kwargs):
        if Path(path) == radiohead / "OK Computer":
            raise PermissionError(errno.EACCES, "Permission denied", str(path))
        return real_lstat(path, *args, **kwargs)

    monkeypatch.setattr(os, "lstat", lstat)

    result = _check(settings, tmp_path, "Sam")

    assert result.code == 1
    assert _findings(result, "unused") == []
    assert not _unused_list_made(result, "Sam")
    assert NOT_FOLLOWED in result.out.splitlines()  # the reason, once, with no name or path


def test_one_users_link_loop_turns_every_users_unused_list_off_and_says_why(lib, tmp_path):
    import shutil

    settings, db, sam, alex = lib
    radiohead = _alex_lucky(db, settings, alex)
    shutil.rmtree(radiohead)
    radiohead.symlink_to(radiohead, target_is_directory=True)
    _put(_folder(settings, "Sam") / "stray.txt")

    result = _check(settings, tmp_path)

    assert result.code == 1
    assert _findings(result, "unused") == []
    assert not _unused_list_made(result, "Sam") and not _unused_list_made(result, ADMIN)
    assert result.out.splitlines().count(NOT_FOLLOWED) == 1
