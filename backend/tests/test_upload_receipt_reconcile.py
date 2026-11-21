"""Phase 7A.2b S13 (spec §5 "On process restart reconcile receiving rows";
SC-16d leases, SC-16e registry, SC-16g; 7-U03 restart, 7-U07 lease).

No transfer survives a restart, so every ``receiving`` row found at startup
belongs to a dead process. If the item's complete source exists with the
allocated length and digest (the process died after the rename, before the
commit), the item advances to ``validating`` and keeps its staged bytes on
the quota. Otherwise the owned partial is removed and the item returns to
``allocated`` with ``upload_interrupted``. A filename is never trusted: the
source is re-hashed. The step runs before the reservation reconcile, is
non-fatal and idempotent.
"""

import hashlib
import sqlite3
import uuid
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from tests.conftest import bearer, log_in

DEAD = "boot-of-a-killed-server"


def sha(data):
    return hashlib.sha256(data).hexdigest()


def uid(n, space=5):
    return str(uuid.UUID(int=(0xC0DE << 96) + (space << 64) + n, version=4))


CONTENTS = [b"first complete file", b"second file, partial", b"third: wrong bytes!", b"fourth one"]
BATCH = uid(0, space=6)


class Server:
    """Start, stop and restart one app over the same directories."""

    def __init__(self, configure_app, monkeypatch):
        self.configure_app = configure_app
        self.monkeypatch = monkeypatch
        self.captured = []

    def start(self, capture=False):
        main = self.configure_app()
        if capture:
            real_run = main.run_startup_recovery

            def capture_run(steps):
                self.captured.append(list(steps))
                return real_run(steps)

            self.monkeypatch.setattr(main, "run_startup_recovery", capture_run)
        self.main = main
        return TestClient(main.app)


@pytest.fixture
def world(configure_app, monkeypatch):
    """One batch of four allocated items, then the server stops."""
    server = Server(configure_app, monkeypatch)
    with server.start() as client:
        client.headers.update(bearer(log_in(client)["token"]))
        items = [
            {"item_uuid": uid(i + 1), "filename": f"{i}.flac", "byte_length": len(c), "sha256": sha(c)}
            for i, c in enumerate(CONTENTS)
        ]
        r = client.post("/tracks/uploads", json={"batch_uuid": BATCH, "items": items})
        assert r.status_code == 201, r.text
        server.db_path = client.app.state.database.context.database_path
        server.owner = client.app.state.admin_user_id
        server.root = Path(client.app.state.settings.music_library_dir).resolve() / ".uploads"
    server.items = [i["item_uuid"] for i in items]
    return server


def sql(server, statement, params=()):
    conn = sqlite3.connect(server.db_path)
    try:
        with conn:
            return conn.execute(statement, params).fetchall()
    finally:
        conn.close()


def item_dir(server, item_uuid):
    return server.root / str(server.owner) / BATCH / item_uuid  # 7A.2c review r1 R1


def died_while_receiving(server, n, *, part=b"", source=None, reservation=True):
    """Leave item n as a killed server would: receiving, leased by a dead
    boot, its part path recorded, the part (and maybe the source) on disk."""
    it = server.items[n]
    folder = item_dir(server, it)
    folder.mkdir(parents=True, exist_ok=True)
    part_path = folder / f"{uuid.uuid4()}.part"
    if part is not None:
        part_path.write_bytes(part)
    if source is not None:
        (folder / "source").write_bytes(source)
    sql(
        server,
        "UPDATE upload_items SET state = 'receiving', lease_boot_id = ?, part_path = ?, "
        "received_bytes = ? WHERE item_uuid = ?",
        (DEAD, str(part_path), len(part or b""), it),
    )
    if reservation:
        sql(
            server,
            "INSERT INTO storage_reservations (owner_id, purpose, subject_ref, bytes, lease_boot_id, "
            "created_at) VALUES (?, 'upload_receive', ?, ?, ?, 1)",
            (server.owner, it, len(CONTENTS[n]), DEAD),
        )
    return part_path


def item(server, n):
    [row] = sql(
        server,
        "SELECT state, error_code, error_retryable, received_bytes, received_sha256, part_path, "
        "source_path, lease_boot_id FROM upload_items WHERE item_uuid = ?",
        (server.items[n],),
    )
    return dict(zip(
        ("state", "error_code", "error_retryable", "received_bytes", "received_sha256",
         "part_path", "source_path", "lease_boot_id"),
        row,
    ))


def reservations(server):
    return sql(
        server,
        "SELECT purpose, subject_ref, bytes, lease_boot_id FROM storage_reservations ORDER BY id",
    )


def files(server):
    return sorted(str(p.relative_to(server.root)) for p in server.root.rglob("*") if p.is_file())


# ── receiving rows ──────────────────────────────────────────────────────────

def test_a_complete_source_left_by_a_dead_transfer_advances_to_validating(world):
    died_while_receiving(world, 0, part=None, source=CONTENTS[0])

    with world.start():
        pass

    source = item_dir(world, world.items[0]) / "source"
    assert item(world, 0) == {
        "state": "validating",
        "error_code": None,
        "error_retryable": None,
        "received_bytes": len(CONTENTS[0]),
        "received_sha256": sha(CONTENTS[0]),
        "part_path": None,
        "source_path": str(source),
        "lease_boot_id": None,
    }
    assert source.read_bytes() == CONTENTS[0]
    # Its bytes stay on the quota as a durable on-disk row.
    assert reservations(world) == [("upload_source", world.items[0], len(CONTENTS[0]), None)]


def test_a_complete_source_whose_reservation_is_gone_gets_its_quota_row_back(world):
    died_while_receiving(world, 0, part=None, source=CONTENTS[0], reservation=False)

    with world.start():
        pass

    assert item(world, 0)["state"] == "validating"
    assert reservations(world) == [("upload_source", world.items[0], len(CONTENTS[0]), None)]


def test_a_partial_transfer_is_removed_and_the_item_returns_to_allocated(world):
    part = died_while_receiving(world, 1, part=CONTENTS[1][:7])

    with world.start():
        pass

    row = item(world, 1)
    assert (row["state"], row["error_code"], row["error_retryable"]) == (
        "allocated", "upload_interrupted", 1,
    )
    assert (row["received_bytes"], row["part_path"], row["source_path"], row["lease_boot_id"]) == (
        0, None, None, None,
    )
    assert not part.exists()
    assert files(world) == []
    assert reservations(world) == []


@pytest.mark.parametrize(
    "source",
    [b"x" * len(CONTENTS[2]), CONTENTS[2][:-1], CONTENTS[2] + b"!"],
    ids=["same-length-other-bytes", "short", "long"],
)
def test_a_source_that_is_not_the_allocated_bytes_is_never_trusted(world, source):
    died_while_receiving(world, 2, part=None, source=source)

    with world.start():
        pass

    row = item(world, 2)
    assert (row["state"], row["error_code"], row["source_path"]) == (
        "allocated", "upload_interrupted", None,
    )
    assert files(world) == []
    assert reservations(world) == []


def test_after_a_restart_the_interrupted_item_takes_a_complete_resend(world):
    from tests.upload_stream import put

    died_while_receiving(world, 1, part=CONTENTS[1][:3])

    with world.start() as client:
        client.headers.update(bearer(log_in(client)["token"]))
        sent = put(client, world.items[1], [CONTENTS[1]])

    assert sent.status == 200, sent.body
    assert item(world, 1)["state"] == "validating"


# ── leftovers of a cancel race, and the received files' quota rows ──────────

def test_a_cancelled_items_leftover_part_and_source_are_removed(world):
    """DELETE won while the transfer was finishing and the server then died
    before the transfer's own cleanup: the item is cancelled but still names
    its part."""
    part = died_while_receiving(world, 3, part=b"four", source=CONTENTS[3], reservation=False)
    sql(world, "UPDATE upload_items SET state = 'cancelled', cancel_requested = 1 WHERE item_uuid = ?",
        (world.items[3],))

    with world.start():
        pass

    row = item(world, 3)
    assert (row["state"], row["part_path"], row["lease_boot_id"]) == ("cancelled", None, None)
    assert not part.exists()
    assert files(world) == []


def _staged(world, n, *, state, source=True):
    it = world.items[n]
    path = item_dir(world, it) / "source"
    if source:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(CONTENTS[n])
    error = "x" if state == "failed" else None
    sql(world, "UPDATE upload_items SET state = ?, source_path = ?, error_code = ? WHERE item_uuid = ?",
        (state, str(path), error, it))
    sql(world, "INSERT INTO storage_reservations (owner_id, purpose, subject_ref, bytes, lease_boot_id, "
               "created_at) VALUES (?, 'upload_source', ?, ?, NULL, 1)", (world.owner, it, len(CONTENTS[n])))


def test_a_received_files_quota_row_stays_while_its_item_holds_the_source(world):
    _staged(world, 0, state="validating")
    _staged(world, 1, state="failed")

    with world.start():
        pass

    assert reservations(world) == [
        ("upload_source", world.items[0], len(CONTENTS[0]), None),
        ("upload_source", world.items[1], len(CONTENTS[1]), None),
    ]


def test_a_quota_row_whose_item_no_longer_holds_its_source_is_released(world):
    # 7A.2c review r1 R10: a cancelled item's row goes only once its file is gone.
    # The reconcile alone: a whole start also runs the janitor, which removes the
    # expired item's file and releases its row itself.
    _staged(world, 0, state="cancelled", source=False)
    _staged(world, 1, state="validating", source=False)  # the file is gone
    _staged(world, 2, state="expired")  # ended, but its file is still there
    sql(world, "INSERT INTO storage_reservations (owner_id, purpose, subject_ref, bytes, lease_boot_id, "
               "created_at) VALUES (?, 'upload_source', ?, 5, NULL, 1)", (world.owner, uid(77)))
    _staged(world, 3, state="validating")

    reconcile(world)

    assert reservations(world) == [
        ("upload_source", world.items[2], len(CONTENTS[2]), None),
        ("upload_source", world.items[3], len(CONTENTS[3]), None),
    ]


@pytest.mark.parametrize("where", ["outside the uploads tree", "another owner's folder"])
def test_an_ended_items_source_recorded_outside_its_owners_folder_keeps_no_quota_row(
        world, tmp_path, where):
    """An ended item's recorded source is counted only while it is a file in
    the item's own owner's folder, as for an item that still holds it: a path
    anywhere else is not this upload's, and the file there is never touched."""
    elsewhere = (tmp_path / "precious.flac" if where == "outside the uploads tree"
                 else world.root / str(world.owner + 1000) / BATCH / "source")
    elsewhere.parent.mkdir(parents=True, exist_ok=True)
    elsewhere.write_bytes(b"keep me")
    _staged(world, 2, state="expired", source=False)
    sql(world, "UPDATE upload_items SET source_path = ? WHERE item_uuid = ?",
        (str(elsewhere), world.items[2]))
    _staged(world, 3, state="expired")  # its own source, still on disk: stays counted

    reconcile(world)

    assert reservations(world) == [("upload_source", world.items[3], len(CONTENTS[3]), None)]
    assert elsewhere.read_bytes() == b"keep me"


def test_a_recorded_path_outside_the_uploads_tree_is_never_touched(world, tmp_path):
    """A tampered or corrupt row cannot make the reconcile delete elsewhere."""
    outside = tmp_path / "precious.part"
    outside.write_bytes(b"keep me")
    died_while_receiving(world, 1, part=b"x")
    sql(world, "UPDATE upload_items SET part_path = ? WHERE item_uuid = ?", (str(outside), world.items[1]))

    with world.start():
        pass

    assert outside.read_bytes() == b"keep me"
    assert item(world, 1)["state"] == "allocated"


def test_a_recorded_path_in_another_owners_folder_is_never_touched(world):
    """Review r1 7-R1-34 (DEV-7-11: a path is trusted only inside its owner's
    folder): a corrupt row of this owner naming a part under another owner's
    folder never removes that file."""
    theirs = world.root / str(world.owner + 1000) / BATCH / "x.part"
    theirs.parent.mkdir(parents=True)
    theirs.write_bytes(b"keep me")
    died_while_receiving(world, 1, part=b"x")
    sql(world, "UPDATE upload_items SET part_path = ? WHERE item_uuid = ?", (str(theirs), world.items[1]))

    with world.start():
        pass

    assert theirs.read_bytes() == b"keep me"


# ── the registry step ───────────────────────────────────────────────────────

def test_the_receipt_reconcile_is_a_non_fatal_step_right_before_the_reservation_reconcile(world):
    with world.start(capture=True):
        pass

    [steps] = world.captured
    assert [(s.name, s.fatal) for s in steps][-6:] == [
        ("upload receipts", False),
        ("upload validation", False),  # 7A.2c
        ("deletion jobs", False),  # 8A.3d
        ("storage reservations", False),
        ("upload janitor", False),  # 7A.3c
        ("deletion janitor", False),  # 8A.3d
    ]


def test_the_step_runs_twice_with_the_same_result(world):
    died_while_receiving(world, 0, part=None, source=CONTENTS[0])
    died_while_receiving(world, 1, part=CONTENTS[1][:5])

    with world.start(capture=True):
        first = ([item(world, n) for n in range(4)], reservations(world), files(world))
        [steps] = world.captured
        [step] = [s for s in steps if s.name == "upload receipts"]
        step.fn()
        second = ([item(world, n) for n in range(4)], reservations(world), files(world))

    assert first == second
    assert first[0][0]["state"] == "validating" and first[0][1]["state"] == "allocated"


def test_a_failing_receipt_reconcile_does_not_stop_startup(world, monkeypatch):
    from app.services import upload_receipt

    def boom(*args, **kwargs):
        raise sqlite3.OperationalError("database is locked")

    monkeypatch.setattr(upload_receipt, "reconcile_upload_receipts", boom)

    with world.start() as client:
        assert client.get("/").status_code == 200


# ── review r1 ───────────────────────────────────────────────────────────────

import os  # noqa: E402
import stat  # noqa: E402


def _read_only(folder):
    folder.chmod(stat.S_IRUSR | stat.S_IXUSR)


def _writable(folder):
    folder.chmod(stat.S_IRWXU)


@pytest.mark.requires_chmod_denial
def test_r1_1_a_leftover_that_cannot_be_removed_stays_recorded_for_the_next_start(world):
    part = died_while_receiving(world, 3, part=b"four", reservation=False)
    sql(world, "UPDATE upload_items SET state = 'cancelled', cancel_requested = 1 WHERE item_uuid = ?",
        (world.items[3],))
    folder = item_dir(world, world.items[3])
    _read_only(folder)
    try:
        with world.start():
            pass
        assert item(world, 3)["part_path"] == str(part) and part.exists()
    finally:
        _writable(folder)

    with world.start():
        pass

    assert item(world, 3)["part_path"] is None and not part.exists()


@pytest.mark.requires_chmod_denial
def test_r1_1_a_dead_partial_that_cannot_be_removed_fails_the_item_and_stays_recorded(world):
    part = died_while_receiving(world, 1, part=CONTENTS[1][:5])
    folder = item_dir(world, world.items[1])
    _read_only(folder)
    try:
        with world.start():
            pass
        row = item(world, 1)
        assert (row["state"], row["error_code"], row["part_path"]) == (
            "failed", "upload_cleanup_failed", str(part),
        )
    finally:
        _writable(folder)

    with world.start():
        pass

    assert item(world, 1)["part_path"] is None and not part.exists()


@pytest.mark.requires_chmod_denial
def test_r1_5_an_unreadable_source_is_not_trusted_and_does_not_stall_the_row(world):
    died_while_receiving(world, 0, part=None, source=CONTENTS[0])
    source = item_dir(world, world.items[0]) / "source"
    os.chmod(source, 0)

    with world.start():
        pass

    row = item(world, 0)
    assert (row["state"], row["error_code"], row["source_path"]) == (
        "allocated", "upload_interrupted", None,
    )
    assert not source.exists()
    assert reservations(world) == []


# ── the reconcile alone (no other start-up step runs) ───────────────────────

def reconcile(server):
    """``reconcile_upload_receipts`` by itself, as a new boot's first start-up
    step runs it: the janitor and the reservation reconcile do not run."""
    from app.database import Database, DatabaseContext
    from app.services.upload_receipt import reconcile_upload_receipts
    from tests.schema_fixtures import INIT_SQL

    database = Database(DatabaseContext(database_path=Path(server.db_path), init_sql_path=INIT_SQL))
    return reconcile_upload_receipts(database, server.root, boot_id="boot-of-this-start")


def test_a_dead_transfers_source_that_cannot_be_removed_keeps_the_item_and_its_quota_row(world, monkeypatch):
    """The part goes, but the fixed-name source, which is not the allocated
    bytes, cannot be removed: the item is not returned to ``allocated``; it
    fails with its part path kept, and its ``upload_receive`` row stays."""
    from app.services.upload_receipt import ReceiptFiles

    part = died_while_receiving(world, 2, part=b"xy", source=b"not the allocated bytes")
    source = item_dir(world, world.items[2]) / "source"
    real = ReceiptFiles.remove

    def refuse_source(self, path):
        if Path(path) == source:
            raise PermissionError("busy")
        return real(self, path)

    monkeypatch.setattr(ReceiptFiles, "remove", refuse_source)

    reconcile(world)

    row = item(world, 2)
    assert (row["state"], row["error_code"], row["part_path"]) == (
        "failed", "upload_cleanup_failed", str(part),
    )
    assert not part.exists() and source.exists()
    assert reservations(world) == [("upload_receive", world.items[2], len(CONTENTS[2]), DEAD)]
