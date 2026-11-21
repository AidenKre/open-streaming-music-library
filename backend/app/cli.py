"""Admin CLI: ``uv run python -m app.cli users ...`` (spec §6.4)."""

import sqlite3
import argparse
import getpass
import os
import sys
import time
from pathlib import Path
from datetime import datetime, timezone

from app.auth.passwords import AuthBusy, WeakPassword, hash_password, validate_password
from app.auth.usernames import username_key
from app.config import Settings
from app.core.instance_lock import InstanceLockHeld, acquire_instance_lock
from app.services.library_check import (
    ReportNotWritten, ReportOutput, check_library, files_tracks_reach,
)
from app.services.user_delete import (
    RECORDED_ROOT_KEYS,
    DeletePaths,
    DeleteRefused,
    check_delete_guards,
    run_user_delete,
)
from app.database.database import (
    DatabaseMissing,
    DatabaseUnreadable,
    LastfmPurgeBusy,
    LastfmPurgeIncomplete,
    SchemaVersionRefused,
    server_database,
)


class _UsageError(Exception):
    pass


class _Parser(argparse.ArgumentParser):
    def error(self, message):
        raise _UsageError(self.format_usage() + f"app.cli: error: {message}")


def _build_parser() -> argparse.ArgumentParser:
    parser = _Parser(prog="app.cli", description="The OSML server's admin tool.")
    sub = parser.add_subparsers(dest="group", required=True, parser_class=_Parser)

    def command(group, name, text):  # one sentence: in the group's list and its own help
        return group.add_parser(name, help=text, description=text)

    users = command(sub, "users", "Manage user accounts.")
    cmds = users.add_subparsers(dest="command", required=True, parser_class=_Parser)
    command(cmds, "list", "List every user with their role, folder and track count.")
    for name, text in (
        ("reset-password", "Set a new password for a user and sign them out everywhere."),
        ("disable", "Stop a user from signing in and sign them out (their data stays)."),
        ("enable", "Let a disabled user sign in again."),
        ("delete", "Delete a user and all their data; the server must be stopped."),
    ):
        command(cmds, name, text).add_argument("name", help="the username")
    lastfm = command(sub, "lastfm", "Manage the Last.fm data of every user.")
    lastfm_cmds = lastfm.add_subparsers(dest="command", required=True, parser_class=_Parser)
    command(
        lastfm_cmds, "purge",
        "Delete every user's Last.fm connection and queued scrobbles; "
        "the server must be stopped.",
    )
    library = command(sub, "library", "Check users' music folders against their tracks.")
    library_cmds = library.add_subparsers(dest="command", required=True, parser_class=_Parser)
    command(
        library_cmds, "check",
        # The promise first, so help's line wrapping never splits it.
        "A report: it writes no library file and no database row, and runs beside "
        "the server. It lists the files no track uses, the tracks whose file is "
        "missing and what could not be read, for one user or every user.",
    ).add_argument("name", nargs="?", help="the username (default: every user)")
    return parser


# Commands that take the instance lock and refuse while the server runs, with the
# trailing phrase of the refusal.
_LOCKED_COMMANDS = {
    ("users", "delete"): "stop it before deleting a user.",
    ("lastfm", "purge"): "stop it before purging Last.fm data.",
}


_NO_CONFIRMATION = "No confirmation was read; nothing was deleted."
_NO_PASSWORD = "No answer was read at the prompt; the password was not changed."


def _ask(ask, text):
    """The answer to one prompt, or None on Ctrl-C or end of input. Only around
    the prompts: every one comes before any write."""
    try:
        return ask(text)
    except (KeyboardInterrupt, EOFError):
        return None


def _iso(ts) -> str:
    if ts is None:
        return "-"
    return datetime.fromtimestamp(ts, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _list(db, out) -> int:
    print("id\tusername\trole\tfolder\tcreated\tdisabled\tdeleting\ttracks", file=out)
    for u in db.list_users():
        role = "master-admin" if u["is_master_admin"] else "admin" if u["is_admin"] else "user"
        print(
            "\t".join(
                str(v)
                for v in (
                    u["id"], u["username"], role, u["library_folder"],
                    _iso(u["created_at"]), _iso(u["disabled_at"]),
                    _iso(u["deleting_at"]), u["track_count"],
                )
            ),
            file=out,
        )
    return 0


def main(
    argv=None, *, settings=None, out=None, err=None, prompt=getpass.getpass, confirm=input
) -> int:
    out = out if out is not None else sys.stdout
    err = err if err is not None else sys.stderr
    try:
        args = _build_parser().parse_args(argv)
    except _UsageError as exc:
        print(exc, file=err)
        return 2
    except SystemExit as exc:  # --help
        return exc.code if isinstance(exc.code, int) else 0
    if settings is None:
        settings = Settings()
    lock = None
    if (args.group, args.command) in _LOCKED_COMMANDS:
        # Read-only schema check first: nothing is created for a wrong data dir.
        if not _schema_ok(server_database(settings.app_data_dir), err):
            return 1
        lock_path = Path(settings.app_data_dir).resolve() / "osml.lock"
        try:
            lock = acquire_instance_lock(Path(settings.app_data_dir))
        except InstanceLockHeld:
            print(
                f"The server is running (it holds {lock_path}); "
                + _LOCKED_COMMANDS[(args.group, args.command)],
                file=err,
            )
            return 1
    try:
        return _run(args, settings, out, err, prompt, confirm)
    finally:
        if lock is not None:
            lock.release()


def _schema_ok(db, err) -> bool:
    try:
        db.require_current_schema()
    except (DatabaseMissing, SchemaVersionRefused, DatabaseUnreadable) as exc:
        print(str(exc), file=err)
        return False
    except KeyboardInterrupt:  # it runs before anything else in every command
        print("Stopped before anything was done.", file=err)
        return False
    return True


def _folder_bytes(folder: Path) -> int:
    total = 0
    for dirpath, _dirs, files in os.walk(folder, followlinks=False):
        for name in files:
            path = os.path.join(dirpath, name)
            if not os.path.islink(path):
                total += os.path.getsize(path)
    return total


def _roots_match_server(db, settings, err, *, ending="nothing was deleted") -> bool:
    """Fails closed: recorded roots that cannot be read or parsed refuse the
    delete. Nothing recorded at all (the server never started) proceeds."""
    for key in RECORDED_ROOT_KEYS:
        try:
            recorded = db.read_setting(key)
        except (sqlite3.Error, OSError) as exc:
            print(
                f"could not read the server's recorded folders ({exc}); {ending}",
                file=err,
            )
            return False
        if recorded is None:
            continue
        try:
            if not recorded or "\0" in recorded or not Path(recorded).is_absolute():
                raise ValueError("not an absolute path")
            server_side = Path(recorded).resolve()
        except (ValueError, OSError) as exc:
            print(
                f"could not read the server's recorded folders: {key} is {recorded!r} "
                f"({exc}); {ending}",
                file=err,
            )
            return False
        mine = Path(getattr(settings, key)).resolve()
        if server_side != mine:
            print(
                f"{key} differs from the server's: the server uses {recorded}, "
                f"this command resolved {mine}; run it with the server's environment",
                file=err,
            )
            return False
    return True


def _delete(db, user, settings, out, err, confirm) -> int:
    name = user["username"]
    if not _roots_match_server(db, settings, err):
        return 1
    paths = DeletePaths.from_settings(settings)
    try:
        listing = db.list_users()
        others = [u for u in db.list_user_folders() if u["id"] != user["id"]]
        check_delete_guards(user, paths, others=others)
        tracks = next(u["track_count"] for u in listing if u["id"] == user["id"])
        folder = paths.music_library_dir / user["library_folder"]
        print(f"{name}: {tracks} tracks, {_folder_bytes(folder)} bytes in {folder}", file=out)
        answer = _ask(confirm, f"Type the username ({name}) to delete it and all its data: ")
        if answer is None:
            print(_NO_CONFIRMATION, file=err)
            return 1
        if answer != name:
            print("Confirmation did not match; nothing was deleted.", file=err)
            return 1
        run_user_delete(db, user["id"], paths)
    except DeleteRefused as exc:
        print(str(exc), file=err)
        return 1
    except OSError as exc:
        print(
            f"Could not finish deleting {name}: {exc}; fix it and run users delete again",
            file=err,
        )
        return 1
    print(f"Deleted {name} and all their data.", file=out)
    return 0


def _lastfm_purge(db, out, err, confirm) -> int:
    answer = _ask(
        confirm, "Type purge to delete every user's Last.fm connection and queued scrobbles: "
    )
    if answer is None:
        print(_NO_CONFIRMATION, file=err)
        return 1
    if answer != "purge":
        print("Confirmation did not match; nothing was deleted.", file=err)
        return 1
    try:
        connections, outbox = db.purge_lastfm_data()
    except LastfmPurgeIncomplete:
        print(
            "Deleted the Last.fm rows, but could not compact the database file "
            "(another program may have it open, or the disk may be full); "
            "fix that and run lastfm purge again.",
            file=err,
        )
        return 1
    except LastfmPurgeBusy:
        print(
            "Nothing was deleted: another program is writing to the database; "
            "close it and run lastfm purge again.",
            file=err,
        )
        return 1
    print(
        f"Purged Last.fm data: {connections} connections and {outbox} queued scrobbles "
        "deleted; the database file was compacted.",
        file=out,
    )
    return 0


def _library_check(db, settings, name, out, err) -> int:
    """Read-only; runs beside the server. Findings are not an error; a user not
    checked in full (not checked, or something unreadable) is: exit 1. It
    never ends in a traceback: Ctrl-C, a database error and an output that
    cannot be written each end it in one line on ``err`` (a closed pipe in
    none)."""
    try:
        if not _roots_match_server(db, settings, err, ending="nothing was checked"):
            return 1
        return _check_users(db, settings, name, ReportOutput(out), err)
    except KeyboardInterrupt:
        print("The check was stopped.", file=err)
        return 1
    except sqlite3.Error as exc:  # its text holds no path
        print(
            f"The check stopped: the database could not be read ({exc}); "
            "run library check again.",
            file=err,
        )
        return 1
    except ReportNotWritten as exc:
        if isinstance(exc.error, BrokenPipeError):  # the reader went away (`| head`)
            if out is sys.stdout:  # so the flush at exit is silent too
                os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
            return 1
        reason = exc.error.strerror or type(exc.error).__name__
        print(f"The check stopped: the report could not be written ({reason}).", file=err)
        return 1


def _check_users(db, settings, name, out, err) -> int:
    if name is None:
        everyone = db.list_user_folders()
        users = sorted(everyone, key=lambda u: u["id"])
    else:
        user = db.get_user_by_username_key(username_key(name))
        if user is None:
            print(f"No user named '{name}'", file=err)
            return 1
        users = [user]
        everyone = db.list_user_folders()
    out.write(
        "The library is read while the server runs: a file imported or removed "
        "during the check may be listed; run the check again before acting on a "
        "finding.\n"
    )
    # Every user's tracks, once, before any walk: a file any of them reaches,
    # directly or through symbolic links, is never listed as unused.
    reached = files_tracks_reach(db, settings, everyone, users)
    if reached is None:  # once per run, no name and no path
        out.write(
            "Files no track uses are not listed in this run: a track's path could "
            "not be followed (a link loop, or a folder that cannot be read).\n"
        )
    in_full = True
    for user in users:  # one user not checked does not stop the others
        in_full = check_library(db, settings, user, out, reached) and in_full
    out.flush()  # a closed pipe shows here, not at exit
    return 0 if in_full else 1


def _run(args, settings, out, err, prompt, confirm) -> int:
    db = server_database(settings.app_data_dir)
    if not _schema_ok(db, err):
        return 1
    if args.group == "lastfm":
        return _lastfm_purge(db, out, err, confirm)
    if args.group == "library":
        return _library_check(db, settings, args.name, out, err)
    if args.command == "list":
        return _list(db, out)
    user = db.get_user_by_username_key(username_key(args.name))
    if user is None:
        print(f"No user named '{args.name}'", file=err)
        return 1
    name = user["username"]
    if user["is_master_admin"]:
        print(f"{name} is the master admin; it is managed through .env", file=err)
        return 1
    if user["deleting_at"] is not None and args.command != "delete":
        print(f"{name} is being deleted; run `users delete {name}` to finish", file=err)
        return 1
    now = int(time.time())
    if args.command in ("disable", "enable"):
        db.set_user_disabled(user["id"], args.command == "disable", now)
        print(f"{name} {args.command}d", file=out)
        return 0
    if args.command == "reset-password":
        password = _ask(prompt, "New password: ")
        repeated = None if password is None else _ask(prompt, "Repeat new password: ")
        if repeated is None:
            print(_NO_PASSWORD, file=err)
            return 1
        if password != repeated:
            print("Passwords do not match", file=err)
            return 1
        try:
            password_hash = hash_password(settings, validate_password(password))
        except WeakPassword as exc:
            print(str(exc), file=err)
            return 1
        except AuthBusy:
            print("Password hashing is busy; try again", file=err)
            return 1
        db.set_password_hash_and_revoke_sessions(user["id"], password_hash, now)
        print(f"Password reset for {name}; their sessions were revoked", file=out)
        return 0
    return _delete(db, user, settings, out, err, confirm)


if __name__ == "__main__":
    sys.exit(main())
