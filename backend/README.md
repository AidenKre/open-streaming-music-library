# OSML backend

## Hosting constraints

- **Run exactly one server process per data directory, with a single worker**
  (`uvicorn app.main:app --workers 1`). At startup the server takes an
  exclusive `flock` on `APP_DATA_DIR/osml.lock` before running migrations; a
  second process (or a second uvicorn worker) on the same data directory
  refuses to start and logs the lock path.
- **POSIX hosts only** (Linux, macOS): the instance lock uses `fcntl.flock`.
- Schema migrations that rebuild tables keep a copy of the pre-migration
  database next to it (for example `database.db.pre-v11.bak`) for operator
  recovery; it can be deleted once the server has started successfully.
