"""The Last.fm outbox reads use their indexes.

The plans are taken of the statements the product methods run, recorded with
their bound values while they run (not of SQL written here), so a changed
query or a lost index fails here. Production opens connections without
``ANALYZE`` data, so the planner's choice is the one a real server makes.

The expected plan lines are SQLite's own wording; they pass with SQLite 3.51.0
(Python 3.12.9's ``sqlite3.sqlite_version`` on the machine they were last
checked on). Another SQLite version may word the same plan differently (``SCAN TABLE``
instead of ``SCAN`` before 3.36, for example). When a test here fails on another
version, take the statement's ``EXPLAIN QUERY PLAN`` there, check that it still
reads through the same index with no full scan and no sort the test forbids, and
only then change the expected text.
"""

import sqlite3
from contextlib import contextmanager
from unittest.mock import patch

from tests.owned_database import add_test_user

_real_connect = sqlite3.connect

LISTENED_S = 1_799_000_000
NOW_MS = (LISTENED_S + 3_600) * 1000


@contextmanager
def _statements():
    """Every ``(sql, parameters)`` the product passes to ``execute`` inside the
    block, exactly as it binds them (a bound ``LIMIT ?`` can plan differently
    from a written-in number)."""
    seen = []

    class Recording(sqlite3.Connection):
        def execute(self, sql, parameters=(), /):
            seen.append((sql, parameters))
            return super().execute(sql, parameters)

    def recording_connect(*args, **kwargs):
        return _real_connect(*args, factory=Recording, **kwargs)

    with patch("app.database.core.sqlite3.connect", side_effect=recording_connect):
        yield seen


def _outbox_statements(statements):
    # Every statement that names the outbox, so a read written another way
    # (a WITH, a write that reads) is planned too and changes the pinned list.
    return [s for s in statements if "scrobble_outbox" in s[0]]


def _plan(db, sql, parameters):
    conn = _real_connect(db.context.database_path)
    try:
        return [row[3] for row in conn.execute("EXPLAIN QUERY PLAN " + sql, parameters)]
    finally:
        conn.close()


def _seed(db):
    """Two connected users, each with pending rows (none sent alone), sent rows
    and problem rows."""
    owners = [add_test_user(db, "ana"), add_test_user(db, "bea")]
    conn = _real_connect(db.context.database_path)
    try:
        with conn:
            for owner in owners:
                conn.execute(
                    "INSERT INTO lastfm_connections (owner_id, connection_id, account_name,"
                    " session_key_enc, opted_in, needs_reconnect, created_at, updated_at)"
                    " VALUES (?, ?, 'account', 'not-a-key', 1, 0, 0, 0)",
                    (owner, f"connection-{owner}"),
                )
                rows = []
                for n in range(60):
                    status, code, done_at = [
                        ("pending", None, None),
                        ("sent", None, NOW_MS - 1_000 * n),
                        ("failed", "invalid_row", NOW_MS - 1_000 * n),
                    ][n % 3]
                    rows.append((
                        f"{owner:04d}0000-0000-4000-8000-{n:012d}", owner,
                        '{"artist": "A", "track": "T", "timestamp": %d}' % (LISTENED_S + n),
                        LISTENED_S + n, status, code, NOW_MS - 10_000 + n, done_at,
                    ))
                conn.executemany(
                    "INSERT INTO scrobble_outbox (event_uuid, owner_id, payload, listened_at_s,"
                    " status, result_code, attempts, alone, created_at, done_at)"
                    " VALUES (?, ?, ?, ?, ?, ?, 0, 0, ?, ?)",
                    rows,
                )
    finally:
        conn.close()
    return owners


def _plans_of_outbox_reads(db, call):
    """``call()``'s result and the plan of each statement it ran that reads the
    outbox, in the order it ran them."""
    with _statements() as seen:
        result = call()
    plans = [_plan(db, sql, parameters) for sql, parameters in _outbox_statements(seen)]
    # Never the whole table: every outbox read goes through an index.
    assert not [line for plan in plans for line in plan
                if line.startswith("SCAN") and "INDEX" not in line], plans
    return result, plans


def test_the_due_scan_walks_only_the_index_of_pending_rows(db):
    """Server-wide by design (spec 7.8): it reads every user's pending rows, from
    the partial index that holds only those, and never the table."""
    ana, bea = _seed(db)

    due, plans = _plans_of_outbox_reads(db, lambda: db.list_due_lastfm_owners(
        listened_by_s=LISTENED_S + 3_600, queued_by=NOW_MS))

    assert due == [ana, bea]
    assert plans == [[
        "SCAN o USING COVERING INDEX idx_scrobble_outbox_due",
        "SEARCH c USING INDEX sqlite_autoindex_lastfm_connections_1 (owner_id=?)",
        "SEARCH u USING INTEGER PRIMARY KEY (rowid=?)",
    ]]


# The first read (``alone = 1 ... LIMIT 1``) usually finds nothing. The partial
# index holds only the pending rows to send alone, in send order, so the read
# never walks the user's other pending rows and sorts nothing.
_ALONE_PLAN = [
    "SEARCH scrobble_outbox USING INDEX idx_scrobble_outbox_alone"
    " (owner_id=? AND listened_at_s>? AND listened_at_s<?)",
]

# The batch read. The index gives the rows in listen order; the temporary B-tree
# only orders the rows that share a listen second by queue time and event id. It
# walks the user's pending rows inside the age limit, reading each row for
# ``alone`` (not in the index), and stops at its limit.
_BATCH_PLAN = [
    "SEARCH scrobble_outbox USING INDEX idx_scrobble_outbox_owner"
    " (owner_id=? AND status=? AND listened_at_s>? AND listened_at_s<?)",
    "USE TEMP B-TREE FOR LAST 2 TERMS OF ORDER BY",
]


def test_a_batch_is_read_from_the_owner_index_in_listen_order(db):
    ana, _bea = _seed(db)

    batch, plans = _plans_of_outbox_reads(db, lambda: db.read_lastfm_batch(
        owner_id=ana, listened_by_s=LISTENED_S + 3_600, listened_since_s=LISTENED_S - 100,
        limit=50))

    assert len(batch["rows"]) == 20  # no row is sent alone, so both reads ran
    # First the one row to send alone, then the batch.
    assert plans == [_ALONE_PLAN, _BATCH_PLAN]


def test_the_prune_reads_only_the_rows_it_may_delete_or_drop(db):
    """Server-wide by design (the sender's retention step). The delete reads
    only the done rows, from the partial index that holds those in done order;
    the too-old drop walks only the pending rows."""
    _ana, bea = _seed(db)

    _result, plans = _plans_of_outbox_reads(db, lambda: db.prune_lastfm_outbox(
        NOW_MS, keep_done_ms=30_000, max_age_s=3_600, skip_owners=(bea,)))

    assert plans == [
        ["SEARCH scrobble_outbox USING INDEX idx_scrobble_outbox_done (done_at<?)"],
        ["SCAN scrobble_outbox USING INDEX idx_scrobble_outbox_due"],
    ]


def test_the_status_summary_reads_only_the_owners_rows_from_the_owner_index(db):
    ana, _bea = _seed(db)

    summary, plans = _plans_of_outbox_reads(db, lambda: db.get_lastfm_outbox_summary(
        NOW_MS - 100_000, owner_id=ana))

    assert summary["counts"] == {"pending": 20, "sent": 20, "ignored": 0, "failed": 20, "dropped": 0}
    assert len(summary["recent_problems"]) == 20
    assert plans == [
        # The counts: the index is in status order, so no sort for GROUP BY.
        ["SEARCH scrobble_outbox USING INDEX idx_scrobble_outbox_owner (owner_id=?)"],
        # The newest problems: the sort is over this user's problem rows done
        # since done_since, which retention keeps short.
        ["SEARCH scrobble_outbox USING INDEX idx_scrobble_outbox_owner (owner_id=? AND status=?)",
         "USE TEMP B-TREE FOR ORDER BY"],
        # The newest sent time.
        ["SEARCH scrobble_outbox USING INDEX idx_scrobble_outbox_owner (owner_id=? AND status=?)"],
    ]
