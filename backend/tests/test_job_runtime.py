"""SC-16d durable job runtime (Phase 7A.1b, review case 7-U02 lease).

A claim is a compare-and-swap ``pending -> running`` that stamps the claiming
process's boot id on the row (``lease_boot_id``). The single-process flock
guarantees that a lease carrying any other boot id belongs to a dead process.
No upload table exists yet, so these tests claim rows of a test table.
"""

import sqlite3
import threading
import uuid
from pathlib import Path

import pytest

from app.services.job_runtime import claim, is_live, register_job_table

TABLE = "test_runtime_jobs"


@pytest.fixture(scope="module", autouse=True)
def registered():
    register_job_table(
        TABLE,
        key_columns=("owner_id", "job_uuid"),
        state_column="state",
        terminal_states=("done", "failed", "cancelled"),
    )


def _create(path: Path) -> None:
    conn = sqlite3.connect(path)
    try:
        conn.execute(
            f"CREATE TABLE {TABLE} ("
            " owner_id INTEGER NOT NULL, job_uuid TEXT NOT NULL,"
            " state TEXT NOT NULL, lease_boot_id TEXT,"
            " cancel_requested INTEGER NOT NULL DEFAULT 0,"
            " PRIMARY KEY (owner_id, job_uuid))"
        )
        conn.commit()
    finally:
        conn.close()


@pytest.fixture
def db_path(tmp_path):
    path = tmp_path / "jobs.sqlite"
    _create(path)
    return path


def _connect(path: Path) -> sqlite3.Connection:
    return sqlite3.connect(path, timeout=5)


def _insert(path: Path, owner: int, job: str, state: str = "pending", lease=None) -> None:
    conn = _connect(path)
    try:
        conn.execute(
            f"INSERT INTO {TABLE} (owner_id, job_uuid, state, lease_boot_id) VALUES (?, ?, ?, ?)",
            (owner, job, state, lease),
        )
        conn.commit()
    finally:
        conn.close()


def _row(path: Path, owner: int, job: str) -> dict:
    conn = _connect(path)
    conn.row_factory = sqlite3.Row
    try:
        found = conn.execute(
            f"SELECT * FROM {TABLE} WHERE owner_id = ? AND job_uuid = ?", (owner, job)
        ).fetchone()
        return dict(found) if found is not None else None
    finally:
        conn.close()


def _claim_and_commit(path: Path, key: dict, boot_id: str, **kwargs) -> bool:
    conn = _connect(path)
    try:
        won = claim(conn, TABLE, key, boot_id=boot_id, **kwargs)
        conn.commit()
        return won
    finally:
        conn.close()


BOOT_A = str(uuid.uuid4())
BOOT_B = str(uuid.uuid4())
JOB = "6f1c0a7e-0000-4000-8000-000000000001"


# --- claim ----------------------------------------------------------------------------------------


def test_a_claim_moves_a_pending_row_to_running_and_stamps_the_boot_id(db_path):
    _insert(db_path, 1, JOB)

    assert _claim_and_commit(db_path, {"owner_id": 1, "job_uuid": JOB}, BOOT_A) is True

    row = _row(db_path, 1, JOB)
    assert (row["state"], row["lease_boot_id"]) == ("running", BOOT_A)


def test_two_connections_claiming_the_same_row_only_one_wins(db_path):
    _insert(db_path, 1, JOB)
    key = {"owner_id": 1, "job_uuid": JOB}

    first = _claim_and_commit(db_path, key, BOOT_A)
    second = _claim_and_commit(db_path, key, BOOT_B)

    assert (first, second) == (True, False)
    assert _row(db_path, 1, JOB)["lease_boot_id"] == BOOT_A


def test_concurrent_claims_from_threads_with_their_own_connections_have_one_winner(db_path):
    jobs = [str(uuid.uuid4()) for _ in range(20)]
    for job in jobs:
        _insert(db_path, 1, job)
    barrier = threading.Barrier(2)
    wins: dict[str, list] = {BOOT_A: [], BOOT_B: []}

    def worker(boot_id):
        conn = _connect(db_path)
        try:
            for job in jobs:
                barrier.wait()
                conn.execute("BEGIN IMMEDIATE")
                won = claim(conn, TABLE, {"owner_id": 1, "job_uuid": job}, boot_id=boot_id)
                conn.commit()
                if won:
                    wins[boot_id].append(job)
        finally:
            conn.close()

    threads = [threading.Thread(target=worker, args=(b,)) for b in (BOOT_A, BOOT_B)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(timeout=30)

    assert sorted(wins[BOOT_A] + wins[BOOT_B]) == sorted(jobs)
    assert not set(wins[BOOT_A]) & set(wins[BOOT_B])


@pytest.mark.parametrize("state", ["running", "done", "failed", "cancelled"])
def test_a_row_that_is_not_pending_is_not_claimed_and_keeps_its_lease(db_path, state):
    _insert(db_path, 1, JOB, state=state, lease=BOOT_A)

    assert _claim_and_commit(db_path, {"owner_id": 1, "job_uuid": JOB}, BOOT_B) is False

    row = _row(db_path, 1, JOB)
    assert (row["state"], row["lease_boot_id"]) == (state, BOOT_A)


def test_a_claim_names_the_whole_key_so_another_owners_row_is_untouched(db_path):
    _insert(db_path, 1, JOB)
    _insert(db_path, 2, JOB)

    assert _claim_and_commit(db_path, {"owner_id": 2, "job_uuid": JOB}, BOOT_A) is True

    assert _row(db_path, 1, JOB)["state"] == "pending"
    assert _row(db_path, 2, JOB)["state"] == "running"


def test_a_missing_row_is_not_claimed(db_path):
    assert _claim_and_commit(db_path, {"owner_id": 1, "job_uuid": JOB}, BOOT_A) is False


def test_a_claim_can_name_other_states_for_a_typed_lease(db_path):
    _insert(db_path, 1, JOB, state="allocated")
    key = {"owner_id": 1, "job_uuid": JOB}

    assert _claim_and_commit(db_path, key, BOOT_A) is False  # not 'pending'
    assert _claim_and_commit(db_path, key, BOOT_A, from_state="allocated", to_state="receiving") is True

    row = _row(db_path, 1, JOB)
    assert (row["state"], row["lease_boot_id"]) == ("receiving", BOOT_A)


def test_key_values_are_bound_never_spliced_into_the_sql(db_path):
    _insert(db_path, 1, JOB)
    hostile = f"{JOB}' OR '1'='1"

    assert _claim_and_commit(db_path, {"owner_id": 1, "job_uuid": hostile}, BOOT_A) is False
    assert _row(db_path, 1, JOB)["state"] == "pending"


def test_a_claim_does_not_commit_the_callers_transaction(db_path):
    _insert(db_path, 1, JOB)
    conn = _connect(db_path)
    try:
        assert claim(conn, TABLE, {"owner_id": 1, "job_uuid": JOB}, boot_id=BOOT_A) is True
        conn.rollback()
    finally:
        conn.close()

    assert _row(db_path, 1, JOB)["state"] == "pending"


def test_an_unregistered_table_is_refused(db_path):
    conn = _connect(db_path)
    try:
        with pytest.raises(ValueError):
            claim(conn, "tracks", {"uuid_id": JOB}, boot_id=BOOT_A)
        with pytest.raises(ValueError):
            claim(conn, f"{TABLE}; DROP TABLE {TABLE}", {"owner_id": 1, "job_uuid": JOB}, boot_id=BOOT_A)
    finally:
        conn.close()
    assert _row(db_path, 1, JOB) is None  # table still there, nothing written


@pytest.mark.parametrize(
    "key",
    [
        {"job_uuid": JOB},  # part of the key missing
        {"owner_id": 1, "job_uuid": JOB, "state": "pending"},  # an extra column
        {"owner_id": 1, "job_uuid = job_uuid OR 1": JOB},  # not a key column
    ],
)
def test_key_names_must_be_exactly_the_registered_key_columns(db_path, key):
    _insert(db_path, 1, JOB)
    conn = _connect(db_path)
    try:
        with pytest.raises(ValueError):
            claim(conn, TABLE, key, boot_id=BOOT_A)
    finally:
        conn.close()
    assert _row(db_path, 1, JOB)["state"] == "pending"


@pytest.mark.parametrize(
    "kwargs",
    [
        {"name": "bad name"},
        {"name": "jobs;--"},
        {"key_columns": ("owner_id", "uuid id")},
        {"key_columns": ()},
        {"state_column": "state)"},
    ],
)
def test_registration_refuses_names_that_are_not_plain_identifiers(kwargs):
    args = {"name": "other_jobs", "key_columns": ("job_uuid",), "state_column": "state"} | kwargs
    with pytest.raises(ValueError):
        register_job_table(args.pop("name"), **args)


def test_registering_the_same_table_differently_is_refused():
    with pytest.raises(ValueError):
        register_job_table(TABLE, key_columns=("job_uuid",), state_column="state")


# --- leases across boots --------------------------------------------------------------------------


def test_a_lease_is_live_only_for_the_boot_that_took_it():
    assert is_live(BOOT_A, boot_id=BOOT_A) is True
    assert is_live(BOOT_A, boot_id=BOOT_B) is False
    assert is_live(None, boot_id=BOOT_A) is False


def test_a_lease_left_by_a_previous_process_reads_dead_after_a_restart(db_path):
    _insert(db_path, 1, JOB)
    old_boot = str(uuid.uuid4())
    assert _claim_and_commit(db_path, {"owner_id": 1, "job_uuid": JOB}, old_boot)

    # The process dies; the next one starts with a fresh boot id.
    new_boot = str(uuid.uuid4())
    row = _row(db_path, 1, JOB)

    assert row["state"] == "running"
    assert is_live(row["lease_boot_id"], boot_id=new_boot) is False
    # The CAS never steals it: reclaiming a dead lease is the job type's own startup step.
    assert _claim_and_commit(db_path, {"owner_id": 1, "job_uuid": JOB}, new_boot) is False


# --- review r1 (7A.1b in-piece review) ------------------------------------------------------------


@pytest.mark.parametrize(
    ("name", "kwargs"),
    [
        ("str_key_jobs", {"key_columns": "job_uuid"}),  # a str would register ('j', 'o', 'b', ...)
        ("str_terminal_jobs", {"terminal_states": "failed"}),  # a str would register ('f', 'a', ...)
    ],
)
def test_registration_refuses_a_plain_string_where_a_sequence_of_names_is_expected(name, kwargs):
    args = {"key_columns": ("job_uuid",), "state_column": "state", "terminal_states": ("done",)} | kwargs
    with pytest.raises(ValueError):
        register_job_table(name, **args)


@pytest.mark.parametrize("name", ["jobs\n", "\njobs"])
def test_registration_refuses_names_with_a_trailing_or_leading_newline(name):
    with pytest.raises(ValueError):
        register_job_table(name, key_columns=("job_uuid",), state_column="state")


@pytest.mark.parametrize("state", ["done", "failed", "cancelled"])
def test_a_claim_never_reopens_a_terminal_row(db_path, state):
    _insert(db_path, 1, JOB, state=state, lease=BOOT_A)
    conn = _connect(db_path)
    try:
        with pytest.raises(ValueError):
            claim(conn, TABLE, {"owner_id": 1, "job_uuid": JOB}, boot_id=BOOT_B, from_state=state)
        conn.commit()
    finally:
        conn.close()
    row = _row(db_path, 1, JOB)
    assert (row["state"], row["lease_boot_id"]) == (state, BOOT_A)


def test_a_claim_whose_key_matches_more_than_one_row_is_an_error(tmp_path):
    register_job_table("loose_jobs", key_columns=("job_uuid",), state_column="state")
    path = tmp_path / "loose.sqlite"
    conn = _connect(path)
    try:
        conn.execute("CREATE TABLE loose_jobs (job_uuid TEXT, state TEXT, lease_boot_id TEXT, cancel_requested INTEGER DEFAULT 0)")
        conn.executemany("INSERT INTO loose_jobs (job_uuid, state) VALUES (?, 'pending')", [(JOB,), (JOB,)])
        conn.commit()
        with pytest.raises(RuntimeError):
            claim(conn, "loose_jobs", {"job_uuid": JOB}, boot_id=BOOT_A)
    finally:
        conn.close()
