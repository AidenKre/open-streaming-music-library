# OSML backend

## Hosting constraints

- **Run exactly one server process per data directory, with a single worker**
  (`uvicorn app.main:app --workers 1`). At startup the server takes an
  exclusive `flock` on `APP_DATA_DIR/osml.lock` before opening the database; a
  second process (or a second uvicorn worker) on the same data directory
  refuses to start and logs the lock path.
- **POSIX hosts only** (Linux, macOS): the instance lock uses `fcntl.flock`.
- **Fresh schema (Phase M, schema 13).** A database from an older (or newer)
  server is refused at startup and its files are left untouched (the data
  directory and an empty `osml.lock` may be created before the check): back it
  up, start with a fresh `APP_DATA_DIR`, and re-import your music. An older
  database stops the server with: "This database predates multi-user support
  (schema N). Back it up, start with a fresh APP_DATA_DIR, and re-import your
  music."

## Setup

Run the server and the admin CLI **from this `backend/` directory**: both read
`.env` from the working directory, and the default folders below resolve
against it too. Start the server with
`uv run uvicorn app.main:app --workers 1`.

### Folders

| Variable | Default | Holds |
| --- | --- | --- |
| `APP_DATA_DIR` | `./data` | the database, caches, cover art, `osml.lock` |
| `MUSIC_LIBRARY_DIR` | `./music` | the organized masters, one folder per user (`music/<folder>/`) |
| `IMPORT_DIR` | `./import` | drops for the master admin |
| `USER_IMPORT_DIR` | `./import-users` | drops for each user, in `import-users/<folder>/` |

Every path is made absolute when the settings load. The import, user-import
and library folders must not be the same or nested in each other, and the data
directory must not be inside any of them; otherwise the server refuses to start
with `<name_a> (<path>) and <name_b> (<path>) must not overlap`.

A user's `<folder>` is the lower-case username, made portable; a reserved name
(`root`, `system`, `con`, `prn`, `aux`, `nul`, `com1`-`com9`, `lpt1`-`lpt9`) or
one already taken in any letter case gets `-2`, `-3`, ... At startup the server
creates `import-users/` and an import folder for every user, the admin
included. A folder pre-created as `import-users/<name>/` is adopted (compared
case-insensitively) when a user with that folder name signs up.

### Master admin

Set `OSML_ADMIN_USERNAME` and either `OSML_ADMIN_PASSWORD` or
`OSML_ADMIN_PASSWORD_FILE` (a file holding the password; not both) in the
environment or `.env`. The username is 3-32 ASCII letters, digits, `_` or `-`,
not starting with `-`; the password needs 8 to 1024 characters. Both are
required on every start, and the server refuses to start without them. Changing
the username renames the admin (refused if another user holds the name);
changing the password re-hashes it and ends the admin's sessions. The server
warns when `.env` or the password file is group- or world-readable; run
`chmod 600 .env`.

### Other settings

- `OSML_SIGNUP_ENABLED` (default `true`): whether the app may create accounts.
- `OSML_MAX_USERS` (default `25`): signup stops at this many users; the admin,
  disabled users and users being deleted count.
- `DEFAULT_STREAMING_QUALITY` (default `original`): seeds the admin's streaming
  quality on the first start. The admin's tracks are pre-encoded at that
  quality as they are imported; with `original` nothing is pre-encoded.
  Other users' tracks are never pre-encoded.
- `ENABLE_FILE_WATCHER` (default `true`): `false` turns off the import
  watchers, the startup scans and the settle check, so nothing is imported.

## Import folders

Drop supported audio (`.mp3 .wav .flac .m4a`) or archives
(`.zip .rar .tar .tar.gz`) into `IMPORT_DIR` (the admin) or
`USER_IMPORT_DIR/<folder>/` (each user). Files directly in `import-users/`,
folders no user owns, and anything under a folder whose name starts with `.`
are ignored (logged).

- **When.** A file is imported once its size and modification time have stayed
  unchanged for 2 s. If a copy pauses for longer, the file may be imported
  early; the server then checks it again 30 s later and, if it has changed,
  re-reads its duration, bitrate and codec (not after a restart in that
  window).
- **Archives.** An archive still being copied is kept until it is complete. A
  finished archive is unpacked once and moved to `.imported/` in its import
  folder (never deleted); moving it back out imports it again. An archive kept
  because of a problem outside the file (a missing `ffprobe`, a busy database,
  a failed move) is logged as `archive kept: <path> (<reason>)` and retried at
  the next server start or when it changes. A RAR written without its end
  block (RAR before 3.0, or `-en`) is never imported.
- **Refused files.** A file that is not audio, a duplicate, or fails the
  `ffprobe` audio check stays where it is, is logged as
  `import failed: <path> (<reason>)`, and is retried at the next start.
  The audio check trusts the `.flac` extension: a text file named `.flac`
  passes it and is imported as a track with empty metadata that can't play.

## Admin CLI

Run from `backend/` so it reads the same `.env` as the server:

```sh
uv run python -m app.cli users list
uv run python -m app.cli users reset-password NAME
uv run python -m app.cli users disable NAME
uv run python -m app.cli users enable NAME
uv run python -m app.cli users delete NAME
```

- `list` prints `id`, `username`, `role`, `folder`, `created`, `disabled`,
  `deleting` and `tracks`. It needs no admin settings.
- `reset-password` asks `New password:` and `Repeat new password:`, applies the
  registration rules and ends the user's sessions.
- `disable` ends the user's sessions and blocks login; `enable` lifts it.
- `reset-password`, `disable` and `delete` refuse the master admin
  (`NAME is the master admin; it is managed through .env`).
- Every command except `delete` works while the server runs. Every command
  refuses a database of another schema version and never migrates it.
- **`delete` only with the server stopped.** It refuses while the server holds
  the lock (`The server is running (it holds <path>); stop it before deleting a
  user.`). It also refuses when its music, import or user-import folder differs
  from the one the server recorded at its last start (both sides are resolved
  first, so two spellings of one folder match), or when that record cannot be
  read or is not an absolute path (`could not read the server's recorded
  folders ...; nothing was deleted`). If the server has never started, nothing
  is recorded and it proceeds. It prints `NAME: N tracks, B bytes in <folder>`,
  then asks `Type the username (NAME) to delete it and all its data:`, and
  removes the user's music folder, import folder, rows, sessions and cached
  encodings. An interrupted delete is finished by rerunning it or at the next
  server start.
- Exit codes: `0` done, `1` refused or failed, `2` bad usage.

## Tests

Run the suite from this folder with `uv run pytest`. The configured default is `-n auto`: one pytest-xdist worker per CPU. Pin a worker count for like-for-like timing comparisons, for example `uv run pytest -n 2`; focused runs of a few files pass `-n 0` (serial).

"integration" means a test needs a real external tool or a real child process, and the default command still runs everything. Select by marker:

```
uv run pytest -m "not integration"   # unit selection
uv run pytest -m integration         # real-tool / real-process cases only
```

Prerequisites: `ffmpeg`/`ffprobe` and `fpcalc` on PATH. Without them the `requires_*` cases are skipped visibly (the skip reason names the missing tool); they are still selected by `-m integration`.

Test databases do not sync to disk: `tests/conftest.py` makes every SQLite connection opened during the tests issue `PRAGMA synchronous=OFF`. That only decides whether a committed transaction survives an operating-system crash or power loss. Atomicity, isolation, locking and WAL behaviour are unchanged, so no test can observe the difference, and the product's own setting is untouched. A test about durability settings must carry `@pytest.mark.real_sqlite_durability`, which gives it the unwrapped `sqlite3.connect`.
