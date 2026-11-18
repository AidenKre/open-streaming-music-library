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

## Last.fm scrobbling (operator guide)

Last.fm scrobbling is off unless you switch it on. When it is on, each OSML
user can connect their own Last.fm account in the app (Settings → Library
tools → Integrations) and their listens are sent to that account, through
your API key. Read all of this before you switch it on.

### 1. Register a Last.fm API account and configure the server

1. Create an API account at <https://www.last.fm/api/account/create> (free).
   The application name you enter there is what your users see when they
   approve OSML on last.fm. Leave the callback URL blank. You receive an API
   key and a shared secret.
2. Generate the encryption key that protects users' session keys at rest:

   ```sh
   uv run python -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"
   ```

3. Set these in `.env`:

   | Setting | Default | Valid values | Meaning |
   | --- | --- | --- | --- |
   | `LASTFM_ENABLED` | `false` | `true` or `false` | The switch. An unreadable value counts as `false` and is logged. |
   | `LASTFM_API_KEY` | none | 32 characters | Your API key. |
   | `LASTFM_API_SECRET` | none | non-empty | Your shared secret. |
   | `LASTFM_CREDENTIAL_KEY` | none | a Fernet key (32 random bytes, URL-safe base64) | Encrypts session keys in the database. |
   | `LASTFM_SETTLE_DELAY_S` | `60` | whole seconds, 0–3600 | How long a user's oldest unsent scrobble waits before their batch is sent. |
   | `LASTFM_MIN_REQUEST_GAP_S` | `5` | whole seconds, 1–30 | Minimum pause between any two requests to Last.fm, server-wide. |
   | `LASTFM_APP_NAME` | none | up to 100 characters, no control, format or line-break characters | The application name you registered on Last.fm, shown on the app's consent screen. |

   Set `LASTFM_APP_NAME` to the same name you entered when registering the
   application on Last.fm. If it is left unset, the app's consent screen
   describes the application without naming it; if the two names differ, the
   screen shows the wrong name. An invalid name (too long, or with a control,
   format or line-break character) does not stop Last.fm: it is ignored with a
   warning, and the screen describes the application without naming it. It is
   not a secret, so it has no `_FILE` variant.

   `LASTFM_API_KEY`, `LASTFM_API_SECRET` and `LASTFM_CREDENTIAL_KEY` each also
   have a `_FILE` variant (`LASTFM_API_KEY_FILE` and so on) naming a file that
   holds the value; set one or the other, not both. **Put the secrets in the
   `_FILE` variants:** a misspelt setting name in `.env` stops the server (and
   every CLI command) with an error that prints the line's value, so a secret
   typed straight into `.env` can end up on the screen or in a log. Make the
   files readable only by the server's user (`chmod 600`); the server warns
   when one is group- or world-readable. A wrong or missing Last.fm value never
   stops the server: Last.fm scrobbling is then `stopped` (except for an invalid
   `LASTFM_APP_NAME`, which is only ignored) and the log names the setting
   (never its value).

   The server ignores proxy settings in its environment (`HTTP_PROXY`,
   `HTTPS_PROXY`, `ALL_PROXY`) for Last.fm requests and connects to Last.fm
   directly, so a server that can reach the internet only through an HTTP proxy
   cannot scrobble.

### 2. You accept Last.fm's API terms

You, the operator, are the party who accepts Last.fm's
[API Terms of Service](https://www.last.fm/api/tos), which incorporate its
site terms and privacy policy. In particular:

- Non-commercial use only (clause 3).
- No publicity about using Last.fm without its written consent (clause 8.2).
- Follow the data-protection law that applies to you, and do not move the data
  across borders without the consents that requires (clauses 2.3 to 2.5).
- Keep privacy at least as strict as Last.fm's own policy (clause 2.8).
- Never use the data to identify or contact a user (clause 5.1.6).
- You indemnify Last.fm (clause 5.3).

OSML shows no Last.fm logo; the app's text credit links to last.fm. Pages
with Last.fm data are only shown to signed-in users.

### 3. Limits

Clause 4.4 applies to you: do not lower the request gap (`LASTFM_MIN_REQUEST_GAP_S`) after a
rate limit, do not share one API key across servers, and do not register a new
key to get past a suspension. If you need more, write to `partners@last.fm`.

### 4. Open signup

Any signed-in user can connect a Last.fm account and scrobble through your
key, and OSML takes the app's word for what was played. With open signup on an
internet-facing server, sign-in is also not a real limit on who sees the
Integrations page. **Set `OSML_SIGNUP_ENABLED=false` when Last.fm is on.**

### 5. When scrobbling stops

The server's Last.fm state is `off` (switched off), `running` or `stopped`.
It becomes `stopped` when the configuration is invalid, when Last.fm rejects
the API key (error 10) or reports it suspended (error 26), or after ten
scrobble requests in a row are rejected. While stopped, nothing is sent and no
request goes to Last.fm; opted-in users' listens keep queuing and are sent
when it runs again, unless they are older than 14 days by then. Users see
"Scrobbling is stopped on this server. Ask whoever runs it." The cause is
logged once at ERROR, in the server log only. A restart tries again (after a
configuration fix, the restart is what applies it). **After a suspension, set
`LASTFM_ENABLED=false` until Last.fm reinstates the key:** a restart alone
sends one more request with it.

When a Last.fm setting is wrong, scrobbling is `stopped` from the start and
the log names the setting (never its value). Opted-in users' listens keep
queuing meanwhile, and the queue is not cleaned up: records of finished
scrobbles stay past their 30 days, and listens older than 14 days stay queued.
The clean-up runs only after you restart the server with correct settings.
After that restart, listens older than 14 days are dropped and the rest are
sent. Two settings are exceptions (see point 1): an unreadable
`LASTFM_ENABLED` switches Last.fm off, so nothing is queued, and an invalid
`LASTFM_APP_NAME` is only ignored.

### 6. Replacing the encryption key

Replacing `LASTFM_CREDENTIAL_KEY` makes every user reconnect (their stored
session keys no longer decrypt, and listens in between are not sent). It does
not disarm a session key that already leaked: with your API key and secret,
a leaked session key works until its user removes the application under
Last.fm settings → Applications.

### 7. Purging Last.fm data

When the terms require it (for example when your agreement with Last.fm ends,
clause 9.3), switch the integration off first (`LASTFM_ENABLED=false`), stop
the server, then run:

```sh
uv run python -m app.cli lastfm purge
```

It asks you to type `purge`, deletes every user's Last.fm connection and
queued or recorded scrobbles, and compacts the database file (`VACUUM`) so
the deleted rows cannot be read back from it. It refuses while the server
runs, works with or without the Last.fm settings present, and does not touch
listening history. Switching `LASTFM_ENABLED` off only pauses; it deletes
nothing. The purge cannot reach copies outside the database: your backups,
your logs, and the settings themselves (the API key, secret and encryption
key in `.env` or their files): delete those yourself.

### 8. Backups

The database holds Last.fm usernames and encrypted session keys. Back it up
with care, and keep `LASTFM_CREDENTIAL_KEY` out of the same backup: the
database without the key reveals usernames and nothing usable; with the key,
the session keys can be decrypted.

## Tests

Run the suite from this folder with `uv run pytest`. The configured default is `-n auto`: one pytest-xdist worker per CPU. Pin a worker count for like-for-like timing comparisons, for example `uv run pytest -n 2`; focused runs of a few files pass `-n 0` (serial).

"integration" means a test needs a real external tool or a real child process, and the default command still runs everything. Select by marker:

```
uv run pytest -m "not integration"   # unit selection
uv run pytest -m integration         # real-tool / real-process cases only
```

Prerequisites: `ffmpeg`/`ffprobe` and `fpcalc` on PATH. Without them the `requires_*` cases are skipped visibly (the skip reason names the missing tool); they are still selected by `-m integration`.

Test databases do not sync to disk: `tests/conftest.py` makes every SQLite connection opened during the tests issue `PRAGMA synchronous=OFF`. That only decides whether a committed transaction survives an operating-system crash or power loss. Atomicity, isolation, locking and WAL behaviour are unchanged, so no test can observe the difference, and the product's own setting is untouched. A test about durability settings must carry `@pytest.mark.real_sqlite_durability`, which gives it the unwrapped `sqlite3.connect`.
