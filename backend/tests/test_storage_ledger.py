"""Phase 7A.2a: the SC-16g storage reservation ledger.

A reservation is admitted only while the library filesystem's free space,
minus every live reservation, minus the configured floor, still covers it.
Free space is read inside the ledger's write transaction, so two reservers
on independent connections can never both spend the same bytes. Unknown
free space is refused, never read as 0 or as unlimited. Errors carry a
stable code and numbers, never a path.
"""

import sqlite3
from types import SimpleNamespace

import pytest

from app.database import ANY_OWNER, DatabaseContext
from app.services.storage_ledger import (
    CONVERSION,
    InsufficientStorage,
    StorageLedger,
)
from tests.owned_database import OwnedTestDatabase
from tests.schema_fixtures import INIT_SQL

BOOT = "boot-current"


class FakeDisk:
    """``shutil.disk_usage`` stand-in: a settable free-byte count, records each read."""

    def __init__(self, free):
        self.free = free
        self.paths = []
        self.error = None
        self.on_read = None

    def __call__(self, path):
        self.paths.append(path)
        if self.on_read is not None:
            self.on_read()
        if self.error is not None:
            raise self.error
        return SimpleNamespace(total=10 * self.free + 1, used=0, free=self.free)


@pytest.fixture
def db(tmp_path):
    database = OwnedTestDatabase(
        DatabaseContext(database_path=tmp_path / "db.sqlite", init_sql_path=INIT_SQL)
    )
    assert database.initialize()
    return database


@pytest.fixture
def library_dir(tmp_path):
    path = tmp_path / "music"
    path.mkdir()
    return path


def _ledger(db, library_dir, disk, *, floor=100, boot_id=BOOT):
    return StorageLedger(
        db, path=library_dir, floor_bytes=floor, boot_id=boot_id, disk_usage=disk
    )


def _rows(db):
    conn = sqlite3.connect(db.context.database_path)
    try:
        return conn.execute(
            "SELECT id, owner_id, purpose, subject_ref, bytes, lease_boot_id, created_at "
            "FROM storage_reservations ORDER BY id"
        ).fetchall()
    finally:
        conn.close()


# --- reserve / release and the floor ----------------------------------------------------


def test_a_reservation_within_free_space_minus_the_floor_is_stored(db, library_dir):
    ledger = _ledger(db, library_dir, FakeDisk(1000))

    rid = ledger.reserve(
        owner_id=db.owner_id, purpose=CONVERSION, nbytes=400, subject_ref="7"
    )

    [row] = _rows(db)
    assert row[:6] == (rid, db.owner_id, "conversion", "7", 400, BOOT)
    assert isinstance(row[6], int) and row[6] > 0


def test_the_exact_boundary_passes_and_one_byte_more_is_refused(db, library_dir):
    ledger = _ledger(db, library_dir, FakeDisk(1000), floor=100)

    with pytest.raises(InsufficientStorage) as refused:
        ledger.reserve(owner_id=db.owner_id, purpose=CONVERSION, nbytes=901, subject_ref="1")
    assert _rows(db) == []
    assert (refused.value.code, refused.value.needed, refused.value.available) == (
        "insufficient_storage", 901, 900,
    )

    ledger.reserve(owner_id=db.owner_id, purpose=CONVERSION, nbytes=900, subject_ref="1")
    assert len(_rows(db)) == 1


def test_live_reservations_reduce_what_the_next_reserver_may_take(db, library_dir):
    ledger = _ledger(db, library_dir, FakeDisk(1000), floor=100)
    ledger.reserve(owner_id=db.owner_id, purpose=CONVERSION, nbytes=600, subject_ref="1")

    with pytest.raises(InsufficientStorage) as refused:
        ledger.reserve(owner_id=db.owner_id, purpose=CONVERSION, nbytes=301, subject_ref="2")
    assert refused.value.available == 300

    ledger.reserve(owner_id=db.owner_id, purpose=CONVERSION, nbytes=300, subject_ref="2")
    assert [r[4] for r in _rows(db)] == [600, 300]


def test_below_the_floor_even_an_empty_reservation_is_refused(db, library_dir):
    ledger = _ledger(db, library_dir, FakeDisk(50), floor=100)

    with pytest.raises(InsufficientStorage) as refused:
        ledger.reserve(owner_id=db.owner_id, purpose=CONVERSION, nbytes=0, subject_ref="1")

    # Never a negative "available": the floor is already breached.
    assert (refused.value.needed, refused.value.available) == (0, 0)
    assert _rows(db) == []


def test_a_release_frees_the_bytes_and_happens_exactly_once(db, library_dir):
    ledger = _ledger(db, library_dir, FakeDisk(1000), floor=100)
    first = ledger.reserve(owner_id=db.owner_id, purpose=CONVERSION, nbytes=900, subject_ref="1")

    assert ledger.release(first) is True
    assert ledger.release(first) is False
    assert _rows(db) == []
    ledger.reserve(owner_id=db.owner_id, purpose=CONVERSION, nbytes=900, subject_ref="2")


def test_releasing_an_id_nobody_holds_touches_nothing(db, library_dir):
    ledger = _ledger(db, library_dir, FakeDisk(1000))
    held = ledger.reserve(owner_id=db.owner_id, purpose=CONVERSION, nbytes=10, subject_ref="1")

    assert ledger.release(held + 1) is False
    assert [r[0] for r in _rows(db)] == [held]


def test_free_space_is_read_from_the_library_filesystem_on_every_reserve(db, library_dir):
    disk = FakeDisk(1000)
    ledger = _ledger(db, library_dir, disk, floor=0)
    ledger.reserve(owner_id=db.owner_id, purpose=CONVERSION, nbytes=500, subject_ref="1")

    disk.free = 600  # someone else wrote 400 bytes meanwhile: no cached reading
    with pytest.raises(InsufficientStorage) as refused:
        ledger.reserve(owner_id=db.owner_id, purpose=CONVERSION, nbytes=101, subject_ref="2")

    assert refused.value.available == 100
    assert disk.paths == [library_dir, library_dir]


def test_unknown_free_space_is_refused_as_unknown_not_zero_or_unlimited(db, library_dir):
    disk = FakeDisk(10**12)
    disk.error = OSError(5, "I/O error", str(library_dir))
    ledger = _ledger(db, library_dir, disk)

    with pytest.raises(InsufficientStorage) as refused:
        ledger.reserve(owner_id=db.owner_id, purpose=CONVERSION, nbytes=1, subject_ref="1")

    assert (refused.value.code, refused.value.needed, refused.value.available) == (
        "free_space_unknown", 1, None,
    )
    assert _rows(db) == []


@pytest.mark.parametrize("free", [10, None])
def test_a_refusal_message_never_names_a_path(db, library_dir, free):
    disk = FakeDisk(free or 0)
    if free is None:
        disk.error = OSError(5, "I/O error", str(library_dir))
    ledger = _ledger(db, library_dir, disk)

    with pytest.raises(InsufficientStorage) as refused:
        ledger.reserve(owner_id=db.owner_id, purpose=CONVERSION, nbytes=10**6, subject_ref="1")

    assert str(library_dir) not in str(refused.value)
    assert refused.value.message and str(library_dir) not in refused.value.message


def test_check_applies_the_same_rule_and_stores_nothing(db, library_dir):
    ledger = _ledger(db, library_dir, FakeDisk(1000), floor=100)
    ledger.reserve(owner_id=db.owner_id, purpose=CONVERSION, nbytes=600, subject_ref="1")

    ledger.check(owner_id=db.owner_id, purpose=CONVERSION, nbytes=300)
    with pytest.raises(InsufficientStorage) as refused:
        ledger.check(owner_id=db.owner_id, purpose=CONVERSION, nbytes=301)

    assert refused.value.available == 300
    assert len(_rows(db)) == 1


@pytest.mark.parametrize("owner", [ANY_OWNER, None, True, "1"])
def test_a_reservation_needs_a_real_owner(db, library_dir, owner):
    ledger = _ledger(db, library_dir, FakeDisk(1000))

    with pytest.raises(TypeError):
        ledger.reserve(owner_id=owner, purpose=CONVERSION, nbytes=1, subject_ref="1")
    assert _rows(db) == []


@pytest.mark.parametrize("nbytes", [-1, 1.5, True, None])
def test_a_reservation_size_must_be_a_non_negative_int(db, library_dir, nbytes):
    ledger = _ledger(db, library_dir, FakeDisk(1000))

    with pytest.raises((TypeError, ValueError)):
        ledger.reserve(owner_id=db.owner_id, purpose=CONVERSION, nbytes=nbytes, subject_ref="1")
    assert _rows(db) == []


def test_an_unregistered_purpose_is_refused(db, library_dir):
    ledger = _ledger(db, library_dir, FakeDisk(1000))

    with pytest.raises(ValueError):
        ledger.reserve(owner_id=db.owner_id, purpose="no_such_purpose", nbytes=1, subject_ref="1")
    assert _rows(db) == []


def test_the_floor_setting_defaults_to_256_mib():
    from app.config import Settings

    assert Settings.model_fields["storage_free_space_floor_bytes"].default == 256 * 1024**2


# --- two reservers on independent connections (exit proof 1) ----------------------------


def test_free_space_is_read_while_the_ledger_holds_the_database_write_lock(db, library_dir):
    """Deterministic half of the race proof: at the moment the reserver reads
    free space, no other connection can start a write, so nobody can insert a
    reservation between this reserver's sum and its own insert."""
    disk = FakeDisk(1000)
    probes = []

    def probe():
        other = sqlite3.connect(db.context.database_path, timeout=0)
        try:
            other.execute("BEGIN IMMEDIATE")
            other.execute("ROLLBACK")
            probes.append("free")
        except sqlite3.OperationalError as e:
            probes.append("locked" if "locked" in str(e) else str(e))
        finally:
            other.close()

    disk.on_read = probe
    ledger = _ledger(db, library_dir, disk, floor=0)

    ledger.reserve(owner_id=db.owner_id, purpose=CONVERSION, nbytes=10, subject_ref="1")

    assert probes == ["locked"]


def test_two_reservers_on_independent_connections_cannot_both_spend_the_same_bytes(
    db, library_dir
):
    import threading

    second_db = OwnedTestDatabase(db.context)  # its own connections, no shared Python lock
    a_inside, go = threading.Event(), threading.Event()
    disk_a, disk_b = FakeDisk(1000), FakeDisk(1000)

    def hold():
        a_inside.set()
        assert go.wait(10)

    disk_a.on_read = hold
    ledger_a = _ledger(db, library_dir, disk_a, floor=0)
    ledger_b = _ledger(second_db, library_dir, disk_b, floor=0, boot_id=BOOT)
    outcomes = {}

    def run(name, ledger, owner):
        try:
            ledger.reserve(owner_id=owner, purpose=CONVERSION, nbytes=600, subject_ref=name)
            outcomes[name] = "reserved"
        except InsufficientStorage:
            outcomes[name] = "refused"

    a = threading.Thread(target=run, args=("a", ledger_a, db.owner_id))
    a.start()
    assert a_inside.wait(10)
    b = threading.Thread(target=run, args=("b", ledger_b, db.owner_id))
    b.start()
    go.set()
    a.join(10)
    b.join(10)

    assert sorted(outcomes.values()) == ["refused", "reserved"]
    assert outcomes["a"] == "reserved"  # a held the lock first
    assert [r[4] for r in _rows(db)] == [600]


# --- staged quotas (per user and server-wide; SC-16g M note, DEV-7-02) --------------------

from app.services.storage_ledger import StagedQuota, register_purpose  # noqa: E402

# A stand-in for the upload purposes later pieces register (7A.2b/2d/3a): only
# the flag matters to the ledger.
STAGED = "test_staged"
register_purpose(STAGED, staged_quota=True)

BIG_DISK = 10**12


def _other_user(db, name="other"):
    conn = sqlite3.connect(db.context.database_path)
    try:
        with conn:
            return conn.execute(
                "INSERT INTO users (username, username_key, password_hash, library_folder, "
                "created_at) VALUES (?, ?, 'h', ?, 0)",
                (name, name, name),
            ).lastrowid
    finally:
        conn.close()


def test_a_users_staged_quota_holds_at_the_exact_boundary(db, library_dir):
    ledger = _ledger(db, library_dir, FakeDisk(BIG_DISK), floor=0)
    quota = StagedQuota(user_bytes=500, total_bytes=10_000)
    ledger.reserve(owner_id=db.owner_id, purpose=STAGED, nbytes=300, subject_ref="a", quota=quota)

    with pytest.raises(InsufficientStorage) as refused:
        ledger.reserve(owner_id=db.owner_id, purpose=STAGED, nbytes=201, subject_ref="b", quota=quota)
    assert (refused.value.code, refused.value.needed, refused.value.available, refused.value.limit) == (
        "user_staged_quota_exceeded", 201, 200, 500,
    )

    ledger.reserve(owner_id=db.owner_id, purpose=STAGED, nbytes=200, subject_ref="b", quota=quota)
    assert [r[4] for r in _rows(db)] == [300, 200]


def test_another_users_staged_bytes_never_count_against_my_quota_or_show_in_my_error(
    db, library_dir
):
    other = _other_user(db)
    ledger = _ledger(db, library_dir, FakeDisk(BIG_DISK), floor=0)
    quota = StagedQuota(user_bytes=500, total_bytes=10_000)
    ledger.reserve(owner_id=other, purpose=STAGED, nbytes=450, subject_ref="o", quota=quota)

    ledger.reserve(owner_id=db.owner_id, purpose=STAGED, nbytes=400, subject_ref="m", quota=quota)
    with pytest.raises(InsufficientStorage) as refused:
        ledger.reserve(owner_id=db.owner_id, purpose=STAGED, nbytes=101, subject_ref="n", quota=quota)

    # My own numbers only: 500 - 400, never the other user's 450.
    assert (refused.value.code, refused.value.available, refused.value.limit) == (
        "user_staged_quota_exceeded", 100, 500,
    )
    assert "450" not in str(refused.value) and "450" not in refused.value.message


def test_the_server_wide_staged_quota_holds_across_users(db, library_dir):
    other = _other_user(db)
    ledger = _ledger(db, library_dir, FakeDisk(BIG_DISK), floor=0)
    quota = StagedQuota(user_bytes=600, total_bytes=1000)
    ledger.reserve(owner_id=other, purpose=STAGED, nbytes=600, subject_ref="o", quota=quota)

    with pytest.raises(InsufficientStorage) as refused:
        ledger.reserve(owner_id=db.owner_id, purpose=STAGED, nbytes=401, subject_ref="m", quota=quota)
    # Only the server-wide total is revealed (what is left of the shared quota).
    assert (refused.value.code, refused.value.needed, refused.value.available, refused.value.limit) == (
        "staged_quota_exceeded", 401, 400, 1000,
    )

    ledger.reserve(owner_id=db.owner_id, purpose=STAGED, nbytes=400, subject_ref="m", quota=quota)


def test_a_conversion_counts_against_free_space_but_never_against_a_staged_quota(
    db, library_dir
):
    ledger = _ledger(db, library_dir, FakeDisk(2000), floor=100)
    quota = StagedQuota(user_bytes=500, total_bytes=500)
    ledger.reserve(owner_id=db.owner_id, purpose=CONVERSION, nbytes=1000, subject_ref="7")

    # Quota untouched by the conversion: the full 500 is still mine...
    ledger.reserve(owner_id=db.owner_id, purpose=STAGED, nbytes=500, subject_ref="a", quota=quota)
    # ...but free space is shared: 2000 - 1000 - 500 - 100 floor = 400 left.
    with pytest.raises(InsufficientStorage) as refused:
        ledger.reserve(owner_id=db.owner_id, purpose=CONVERSION, nbytes=401, subject_ref="8")
    assert (refused.value.code, refused.value.available) == ("insufficient_storage", 400)


def test_staged_reservations_count_against_free_space_and_the_floor(db, library_dir):
    ledger = _ledger(db, library_dir, FakeDisk(1000), floor=100)
    quota = StagedQuota(user_bytes=10_000, total_bytes=10_000)
    ledger.reserve(owner_id=db.owner_id, purpose=STAGED, nbytes=800, subject_ref="a", quota=quota)

    with pytest.raises(InsufficientStorage) as refused:
        ledger.reserve(owner_id=db.owner_id, purpose=STAGED, nbytes=101, subject_ref="b", quota=quota)
    assert (refused.value.code, refused.value.available) == ("insufficient_storage", 100)


def test_a_staged_purpose_needs_a_quota(db, library_dir):
    ledger = _ledger(db, library_dir, FakeDisk(BIG_DISK))

    with pytest.raises(ValueError):
        ledger.reserve(owner_id=db.owner_id, purpose=STAGED, nbytes=1, subject_ref="a")
    assert _rows(db) == []


def test_check_applies_the_quota_rule_too(db, library_dir):
    ledger = _ledger(db, library_dir, FakeDisk(BIG_DISK), floor=0)
    quota = StagedQuota(user_bytes=500, total_bytes=10_000)
    ledger.reserve(owner_id=db.owner_id, purpose=STAGED, nbytes=500, subject_ref="a", quota=quota)

    with pytest.raises(InsufficientStorage) as refused:
        ledger.check(owner_id=db.owner_id, purpose=STAGED, nbytes=1, quota=quota)
    assert refused.value.code == "user_staged_quota_exceeded"


def test_a_purpose_cannot_be_registered_twice_differently():
    register_purpose(STAGED, staged_quota=True)  # identical: fine
    with pytest.raises(ValueError):
        register_purpose(STAGED, staged_quota=False)


@pytest.mark.parametrize("boot_id", [None, ""])
def test_a_ledger_needs_a_boot_id_so_every_reservation_it_takes_is_leased(db, library_dir, boot_id):
    """Review r1 #3: a ledger without a boot id would write unleased rows that
    look durable and that the startup reconcile never releases."""
    with pytest.raises((TypeError, ValueError)):
        StorageLedger(db, path=library_dir, floor_bytes=0, boot_id=boot_id, disk_usage=FakeDisk(1))
