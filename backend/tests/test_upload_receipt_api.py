"""Phase 7A.2b: PUT /tracks/uploads/items/{item}/content, the streamed byte
receipt (spec §5 "Byte receipt", §4 PUT/DELETE rows; 7-U03; SC-16b/d/g, SC-22,
SC-28).

Requests are driven through ``tests.upload_stream`` so each test controls the
body's chunks, its Content-Length, stalls and disconnects."""

import hashlib
import sqlite3
import uuid
from pathlib import Path

import pytest

from tests.upload_stream import put

NOW = 1_700_000_000
DATA = b"hello, upload world"


def uid(n: int, space: int = 7) -> str:
    return str(uuid.UUID(int=(0xFEED << 96) + (space << 64) + n, version=4))


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


@pytest.fixture
def client(app_client):
    from app.routers.uploads import upload_clock

    app_client.app.dependency_overrides[upload_clock] = lambda: NOW
    return app_client


def allocate(client, *contents, headers=None, batch=None, space=7):
    """Allocate one item per content; returns (batch_uuid, [item_uuid...]).
    Item ids are unique per owner only: give another user's items their own
    ``space`` when a test reads rows of both by item id."""
    batch = batch or uid(0, space=8)
    items = [
        {"item_uuid": uid(i + 1, space=space), "filename": f"../../etc/{i}.flac", "byte_length": len(c), "sha256": sha(c)}
        for i, c in enumerate(contents)
    ]
    response = client.post(
        "/tracks/uploads", json={"batch_uuid": batch, "items": items}, headers=headers
    )
    assert response.status_code == 201, response.text
    return batch, [i["item_uuid"] for i in items]


def rows(client, sql, params=()):
    conn = sqlite3.connect(client.app.state.database.context.database_path)
    try:
        return conn.execute(sql, params).fetchall()
    finally:
        conn.close()


def item(client, item_uuid):
    [row] = rows(
        client,
        "SELECT state, received_bytes, received_sha256, part_path, source_path, lease_boot_id, "
        "cancel_requested, error_code, error_retryable FROM upload_items WHERE item_uuid = ?",
        (item_uuid,),
    )
    keys = ("state", "received_bytes", "received_sha256", "part_path", "source_path",
            "lease_boot_id", "cancel_requested", "error_code", "error_retryable")
    return dict(zip(keys, row))


def reservations(client):
    return rows(
        client,
        "SELECT owner_id, purpose, subject_ref, bytes, lease_boot_id FROM storage_reservations ORDER BY id",
    )


def uploads_root(client) -> Path:
    return Path(client.app.state.settings.music_library_dir).resolve() / ".uploads"


def files_under_uploads(client):
    root = uploads_root(client)
    return sorted(str(p.relative_to(root)) for p in root.rglob("*") if p.is_file())


def runtime(client):
    return client.app.state.upload_receipt


def assert_released(client, item_uuid):
    """Nothing of a transfer is left: no slot, no in-flight reservation, no
    partial file, no lease, no cancel token."""
    rt = runtime(client)
    assert rt.slots.in_use() == 0
    assert [r for r in reservations(client) if r[1] == "upload_receive"] == []
    assert not any(f.endswith(".part") for f in files_under_uploads(client))
    row = item(client, item_uuid)
    assert (row["part_path"], row["lease_boot_id"]) == (None, None)
    owner = client.app.state.admin_user_id
    assert rt.tokens.cancel((owner, item_uuid)) is False


def assert_error(sent, status, code, retryable):
    assert sent.status == status, sent.body
    detail = sent.json()["detail"]
    assert (detail["error"], detail["retryable"]) == (code, retryable)
    # SC-22: never a path in an error.
    assert "/" not in detail["message"] and ".uploads" not in sent.body.decode()


# ── S4: the happy path ─────────────────────────────────────────────────────

def test_a_complete_body_is_stored_as_the_items_source_and_the_item_moves_to_validating(client):
    batch, [it] = allocate(client, DATA)

    sent = put(client, it, [DATA[:5], DATA[5:12], DATA[12:]])

    assert sent.status == 200, sent.body
    body = sent.json()
    assert (body["item_uuid"], body["state"], body["received_bytes"], body["error"]) == (
        it, "validating", len(DATA), None,
    )
    # The owned source sits under .uploads/<owner>/<batch>/<item>/ (7A.2c review
    # r1 R1: per owner, since ids are per owner), named by the server.
    owner = client.app.state.admin_user_id
    assert files_under_uploads(client) == [f"{owner}/{batch}/{it}/source"]
    source = uploads_root(client) / str(owner) / batch / it / "source"
    assert source.read_bytes() == DATA
    row = item(client, it)
    assert row == {
        "state": "validating",
        "received_bytes": len(DATA),
        "received_sha256": sha(DATA),
        "part_path": None,
        "source_path": str(source),
        "lease_boot_id": None,
        "cancel_requested": 0,
        "error_code": None,
        "error_retryable": None,
    }
    # The status read agrees.
    assert client.get(f"/tracks/uploads/items/{it}").json()["state"] == "validating"


def test_a_received_file_keeps_a_durable_quota_row_and_frees_its_slot_and_token(client):
    _batch, [it] = allocate(client, DATA)

    assert put(client, it, [DATA]).status == 200

    owner = client.app.state.admin_user_id
    assert reservations(client) == [(owner, "upload_source", it, len(DATA), None)]
    assert_released(client, it)


def test_a_body_without_content_length_is_counted_and_accepted(client):
    _batch, [it] = allocate(client, DATA)

    sent = put(client, it, [DATA[:3], DATA[3:]], content_length=None)

    assert sent.status == 200, sent.body
    assert item(client, it)["state"] == "validating"


def test_the_client_filename_never_reaches_a_path(client):
    # allocate() names every file "../../etc/<n>.flac".
    batch, [it] = allocate(client, DATA)

    put(client, it, [DATA])

    owner = client.app.state.admin_user_id
    assert files_under_uploads(client) == [f"{owner}/{batch}/{it}/source"]
    assert not any("etc" in str(p) for p in uploads_root(client).parent.rglob("*"))


def test_two_items_of_one_batch_get_their_own_sources(client):
    other = b"another file"
    batch, [a, b] = allocate(client, DATA, other)

    assert put(client, b, [other]).status == 200
    assert put(client, a, [DATA]).status == 200

    owner = client.app.state.admin_user_id
    assert files_under_uploads(client) == sorted([f"{owner}/{batch}/{a}/source", f"{owner}/{batch}/{b}/source"])
    assert (uploads_root(client) / str(owner) / batch / b / "source").read_bytes() == other


# ── S4: who may send, and when ─────────────────────────────────────────────

def _second_user(client):
    from tests.auth_helpers import create_session
    from tests.conftest import bearer
    from tests.owned_database import add_test_user

    db = client.app.state.database
    sam = add_test_user(db, "sam")
    return sam, bearer(create_session(db, sam).token)


class _CountingSlots:
    """Wraps the real slots to count acquisitions."""

    def __init__(self, inner):
        self.inner, self.acquired = inner, 0

    def try_acquire(self, owner_id):
        self.acquired += 1
        return self.inner.try_acquire(owner_id)

    def in_use(self):
        return self.inner.in_use()


def test_a_foreign_item_answers_exactly_like_an_unknown_one_before_reading_or_taking_anything(client):
    sam, sam_headers = _second_user(client)
    _batch, [theirs] = allocate(client, DATA, headers=sam_headers)
    rt = runtime(client)
    rt.slots = counting = _CountingSlots(rt.slots)

    foreign = put(client, theirs, [DATA])
    unknown = put(client, uid(99), [DATA])

    assert (foreign.status, unknown.status) == (404, 404)
    assert foreign.json() == unknown.json()
    assert foreign.error == "upload_item_not_found"
    assert (foreign.reads, unknown.reads, counting.acquired) == (0, 0, 0)
    assert item(client, theirs)["state"] == "allocated"
    assert reservations(client) == []
    assert files_under_uploads(client) == []


def test_the_owner_can_still_send_after_a_foreign_attempt(client):
    sam, sam_headers = _second_user(client)
    _batch, [theirs] = allocate(client, DATA, headers=sam_headers)

    assert put(client, theirs, [DATA]).status == 404
    client.headers.update(sam_headers)
    assert put(client, theirs, [DATA]).status == 200


def _force_state(client, item_uuid, state, **extra):
    sets = ", ".join(["state = ?", *(f"{k} = ?" for k in extra)])
    conn = sqlite3.connect(client.app.state.database.context.database_path)
    try:
        with conn:
            conn.execute(
                f"UPDATE upload_items SET {sets} WHERE item_uuid = ?",
                (state, *extra.values(), item_uuid),
            )
    finally:
        conn.close()


@pytest.mark.parametrize(
    "state, extra",
    [
        ("cancelled", {}),
        ("expired", {}),
        ("failed", {"error_code": "upload_digest_mismatch"}),
    ],
)
def test_an_item_that_can_take_no_bytes_answers_409_without_reading(client, state, extra):
    _batch, [it] = allocate(client, DATA)
    _force_state(client, it, state, **extra)

    sent = put(client, it, [DATA])

    assert_error(sent, 409, "upload_item_not_receivable", False)
    assert sent.json()["detail"]["state"] == state
    assert sent.reads == 0
    assert item(client, it)["state"] == state
    assert (reservations(client), files_under_uploads(client)) == ([], [])
    assert runtime(client).slots.in_use() == 0


# ── S5: refusals before a byte is read ─────────────────────────────────────

class SpySlots:
    """Wraps the real slots; records every release call of every slot handed out."""

    def __init__(self, inner):
        self.inner = inner
        self.calls = []  # one list of release() results per slot

    def try_acquire(self, owner_id):
        slot = self.inner.try_acquire(owner_id)
        if slot is None:
            return None
        calls = []
        self.calls.append(calls)
        spy = self

        class _Slot:
            owner_id = slot.owner_id

            def release(self):
                result = slot.release()
                calls.append(result)
                return result

        return _Slot()

    def in_use(self):
        return self.inner.in_use()


def spy_slots(client):
    rt = runtime(client)
    rt.slots = spy = SpySlots(rt.slots)
    return spy


def assert_untouched(client, item_uuid, sent):
    """The answer came before any byte was read, and nothing is left behind."""
    assert sent.reads == 0
    row = item(client, item_uuid)
    assert (row["state"], row["received_bytes"], row["part_path"], row["lease_boot_id"]) == (
        "allocated", 0, None, None,
    )
    assert reservations(client) == []
    assert files_under_uploads(client) == []
    assert runtime(client).slots.in_use() == 0


@pytest.mark.parametrize(
    "declared, status, code",
    [
        (len(DATA) + 1, 413, "upload_too_large"),
        (len(DATA) * 100, 413, "upload_too_large"),
        (len(DATA) - 1, 422, "upload_length_mismatch"),
        (0, 422, "upload_length_mismatch"),
    ],
)
def test_a_declared_length_other_than_the_allocated_one_is_refused_unread(client, declared, status, code):
    _batch, [it] = allocate(client, DATA)
    slots = spy_slots(client)

    sent = put(client, it, [DATA], content_length=declared)

    assert_error(sent, status, code, False)
    assert_untouched(client, it, sent)
    assert slots.calls == []  # no slot was even taken
    # Nothing was spent: the right body still goes through.
    assert put(client, it, [DATA]).status == 200


def test_a_busy_server_answers_at_once_without_reading_and_a_freed_slot_admits(client):
    _batch, [it] = allocate(client, DATA)
    rt = runtime(client)
    held = [rt.slots.try_acquire(9001), rt.slots.try_acquire(9002)]
    assert None not in held  # the server-wide default is two

    sent = put(client, it, [DATA])

    # O4 / DEV-7-02: a busy server is a 503 with Retry-After (was 409 upload_busy).
    _assert_slots_busy(sent)
    assert item(client, it)["state"] == "allocated"
    assert reservations(client) == []
    held[0].release()
    assert put(client, it, [DATA]).status == 200
    assert rt.slots.in_use() == 1  # only the one still held by the test
    held[1].release()


def _ledger_with_disk(client, *, free=None, error=None):
    from types import SimpleNamespace

    from app.services.storage_ledger import StorageLedger

    def disk_usage(_path):
        if error is not None:
            raise error
        return SimpleNamespace(total=free, used=0, free=free)

    state = client.app.state
    return StorageLedger(
        state.database,
        path=state.settings.music_library_dir,
        floor_bytes=0,
        boot_id=state.boot_id,
        disk_usage=disk_usage,
    )


def test_too_little_free_space_is_a_retryable_507_before_reading(client):
    _batch, [it] = allocate(client, DATA)
    runtime(client).ledger = _ledger_with_disk(client, free=len(DATA) - 1)
    slots = spy_slots(client)

    sent = put(client, it, [DATA])

    assert_error(sent, 507, "insufficient_storage", True)
    detail = sent.json()["detail"]
    # Review r1 7-R1-19: only the caller's own size; the free room moves with others' uploads.
    assert detail["needed"] == len(DATA)
    assert "available" not in detail and "limit" not in detail
    assert not any(ch.isdigit() for ch in detail["message"])
    assert_untouched(client, it, sent)
    assert slots.calls == [[True]]


def test_another_users_reservation_never_changes_a_disk_refusal(client):
    """Review r1 7-R1-19 (DEV-7-10: a user learns their own numbers, never a
    server-wide one): B's answer is the same whether A holds reservations."""
    sam, _ = _second_user(client)
    _batch, [it] = allocate(client, DATA)
    runtime(client).ledger = _ledger_with_disk(client, free=len(DATA) - 1)
    alone = put(client, it, [DATA]).json()["detail"]
    conn = sqlite3.connect(client.app.state.database.context.database_path)
    try:
        with conn:  # A's transfer holds room for bytes still to come
            conn.execute("INSERT INTO storage_reservations (owner_id, purpose, subject_ref, bytes,"
                         " lease_boot_id, created_at) VALUES (?, 'upload_receive', 'theirs', 3, ?, 1)",
                         (sam, client.app.state.boot_id))
    finally:
        conn.close()

    shared = put(client, it, [DATA]).json()["detail"]

    assert alone == shared


def test_unknown_free_space_is_a_retryable_507_that_says_unknown(client):
    _batch, [it] = allocate(client, DATA)
    runtime(client).ledger = _ledger_with_disk(client, error=OSError("no statvfs"))
    slots = spy_slots(client)

    sent = put(client, it, [DATA])

    assert_error(sent, 507, "free_space_unknown", True)
    assert "available" not in sent.json()["detail"]
    assert_untouched(client, it, sent)
    assert slots.calls == [[True]]


def _staged_row(client, owner_id, nbytes, subject="elsewhere"):
    conn = sqlite3.connect(client.app.state.database.context.database_path)
    try:
        with conn:
            conn.execute(
                "INSERT INTO storage_reservations (owner_id, purpose, subject_ref, bytes, "
                "lease_boot_id, created_at) VALUES (?, 'upload_source', ?, ?, NULL, 1)",
                (owner_id, subject, nbytes),
            )
    finally:
        conn.close()


def test_a_full_personal_staged_quota_is_a_retryable_413_before_reading(client):
    from tests.test_upload_limits import EFFECTIVE_DEFAULTS

    _batch, [it] = allocate(client, DATA)
    owner = client.app.state.admin_user_id
    user_quota = EFFECTIVE_DEFAULTS["user_staged_quota_bytes"]
    _staged_row(client, owner, user_quota - len(DATA) + 1)
    slots = spy_slots(client)

    sent = put(client, it, [DATA])

    assert_error(sent, 413, "user_staged_quota_exceeded", True)
    detail = sent.json()["detail"]
    assert (detail["needed"], detail["available"], detail["limit"]) == (
        len(DATA), len(DATA) - 1, user_quota,
    )
    assert sent.reads == 0
    assert item(client, it)["state"] == "allocated"
    assert slots.calls == [[True]]
    assert runtime(client).slots.in_use() == 0


def test_a_full_server_wide_staged_quota_is_a_retryable_413_before_reading(client):
    from tests.test_upload_limits import EFFECTIVE_DEFAULTS

    sam, _sam_headers = _second_user(client)
    _batch, [it] = allocate(client, DATA)
    _staged_row(client, sam, EFFECTIVE_DEFAULTS["staged_quota_bytes"])

    sent = put(client, it, [DATA])

    assert_error(sent, 413, "staged_quota_exceeded", True)
    assert sent.reads == 0
    assert item(client, it)["state"] == "allocated"
    assert runtime(client).slots.in_use() == 0


# ── S6: every way a stream can end goes through the one terminal handler ──

import errno  # noqa: E402

import anyio  # noqa: E402

from app.services.upload_receipt import ReceiptFiles  # noqa: E402
from tests.upload_stream import DISCONNECT, Gate, content_path, request  # noqa: E402


def item_error(client, item_uuid):
    row = item(client, item_uuid)
    return row["state"], row["error_code"], row["error_retryable"]


def assert_ended_once(client, item_uuid, slots):
    """The slot went back exactly once and nothing of the transfer remains;
    the item has no received bytes and no source."""
    assert slots.calls == [[True]]
    assert_released(client, item_uuid)
    row = item(client, item_uuid)
    assert (row["received_bytes"], row["source_path"]) == (0, None)
    assert files_under_uploads(client) == []
    assert reservations(client) == []


@pytest.mark.parametrize("declared", [None, len(DATA)], ids=["no-length", "false-length"])
def test_more_bytes_than_allocated_end_the_transfer_at_once_with_413(client, declared):
    _batch, [it] = allocate(client, DATA)
    slots = spy_slots(client)

    sent = put(client, it, [DATA, b"!", b"never read"], content_length=declared)

    assert_error(sent, 413, "upload_too_large", False)
    assert sent.reads == 2  # refused on the chunk that crossed the bound
    # These bytes are not the allocated file: the allocation cannot take them.
    assert item_error(client, it) == ("failed", "upload_too_large", 0)
    assert_ended_once(client, it, slots)


@pytest.mark.parametrize("declared", [None, len(DATA)], ids=["no-length", "false-length"])
def test_a_body_that_ends_short_returns_the_item_to_allocated(client, declared):
    _batch, [it] = allocate(client, DATA)
    slots = spy_slots(client)

    sent = put(client, it, [DATA[:4], DATA[4:-1]], content_length=declared)

    assert_error(sent, 422, "upload_incomplete", True)
    assert item_error(client, it) == ("allocated", "upload_incomplete", 1)
    assert_ended_once(client, it, slots)
    # The allocation is intact: a complete resend is accepted and clears the error.
    assert put(client, it, [DATA]).status == 200
    assert item_error(client, it) == ("validating", None, None)


def test_bytes_with_another_digest_fail_the_item_with_422(client):
    _batch, [it] = allocate(client, DATA)
    slots = spy_slots(client)
    forged = bytes(reversed(DATA))

    sent = put(client, it, [forged])

    assert_error(sent, 422, "upload_digest_mismatch", False)
    assert item_error(client, it) == ("failed", "upload_digest_mismatch", 0)
    assert_ended_once(client, it, slots)
    # A failed item takes no more bytes (spec: a differing digest cannot reuse the allocation).
    assert put(client, it, [DATA]).status == 409


def test_a_client_that_disconnects_mid_body_leaves_the_item_allocated(client):
    _batch, [it] = allocate(client, DATA)
    slots = spy_slots(client)

    sent = put(client, it, [DATA[:6], DISCONNECT], content_length=len(DATA))

    assert_error(sent, 400, "upload_interrupted", True)
    assert item_error(client, it) == ("allocated", "upload_interrupted", 1)
    assert_ended_once(client, it, slots)


class FaultyFiles(ReceiptFiles):
    """Raises ``error`` at the named file step (the write seam)."""

    def __init__(self, step, error):
        self.step, self.error = step, error

    def _maybe_fail(self, name):
        if name == self.step:
            raise self.error

    def open_part(self, path):
        self._maybe_fail("open_part")
        return super().open_part(path)

    def write_block(self, handle, block):
        self._maybe_fail("write_block")
        super().write_block(handle, block)

    def sync_close(self, handle):
        self._maybe_fail("sync_close")
        super().sync_close(handle)

    def rename(self, source, target):
        self._maybe_fail("rename")
        super().rename(source, target)


@pytest.mark.parametrize("step", ["open_part", "write_block", "sync_close", "rename"])
@pytest.mark.parametrize("code", [errno.ENOSPC, errno.EDQUOT], ids=["ENOSPC", "EDQUOT"])
def test_a_full_disk_at_any_file_step_is_a_retryable_507_and_cleans_up(client, step, code):
    _batch, [it] = allocate(client, DATA)
    slots = spy_slots(client)
    runtime(client).files = FaultyFiles(step, OSError(code, "No space left on device"))

    sent = put(client, it, [DATA[:7], DATA[7:]])

    assert_error(sent, 507, "insufficient_storage", True)
    assert item_error(client, it) == ("allocated", "insufficient_storage", 1)
    assert_ended_once(client, it, slots)


def test_another_write_error_is_a_retryable_500_and_cleans_up(client):
    _batch, [it] = allocate(client, DATA)
    slots = spy_slots(client)
    runtime(client).files = FaultyFiles("write_block", OSError(errno.EIO, "I/O error"))

    sent = put(client, it, [DATA])

    assert_error(sent, 500, "upload_write_failed", True)
    assert item_error(client, it) == ("allocated", "upload_write_failed", 1)
    assert_ended_once(client, it, slots)


def test_an_unexpected_exception_still_ends_the_transfer_cleanly(client):
    _batch, [it] = allocate(client, DATA)
    slots = spy_slots(client)
    runtime(client).files = FaultyFiles("write_block", RuntimeError("bug"))

    with pytest.raises(RuntimeError):  # the server's error middleware re-raises after its 500
        put(client, it, [DATA])

    assert item_error(client, it) == ("allocated", "upload_interrupted", 1)
    assert_ended_once(client, it, slots)


def test_a_request_cancelled_by_the_server_mid_body_still_ends_cleanly(client):
    """Shutdown cancels in-flight requests: the handler is cancelled while it
    waits for the next chunk, and the terminal handler still runs to the end."""
    _batch, [it] = allocate(client, DATA)
    slots = spy_slots(client)
    gate = Gate()

    async def run():
        async with anyio.create_task_group() as tg:
            tg.start_soon(
                lambda: request(client, "PUT", content_path(it), [DATA[:5], gate, DATA[5:]],
                                content_length=len(DATA))
            )
            await gate.reached.wait()
            tg.cancel_scope.cancel()

    anyio.run(run)

    assert item_error(client, it) == ("allocated", "upload_interrupted", 1)
    assert_ended_once(client, it, slots)


# ── S7: fixed-size blocks, bounded memory, nothing blocking on the loop ───

import threading  # noqa: E402


class RecordingFiles(ReceiptFiles):
    """Records each file call's thread and every written block's size."""

    def __init__(self):
        self.threads = []
        self.blocks = []

    def _note(self, name):
        self.threads.append((name, threading.get_ident()))

    def make_dir(self, path):
        self._note("make_dir")
        super().make_dir(path)

    def open_part(self, path):
        self._note("open_part")
        return super().open_part(path)

    def write_block(self, handle, block):
        self._note("write_block")
        self.blocks.append(len(block))
        super().write_block(handle, block)

    def sync_close(self, handle):
        self._note("sync_close")
        super().sync_close(handle)

    def close(self, handle):
        self._note("close")
        super().close(handle)

    def rename(self, source, target):
        self._note("rename")
        super().rename(source, target)

    def sync_dir(self, path):
        self._note("sync_dir")
        super().sync_dir(path)

    def remove(self, path):
        self._note("remove")
        super().remove(path)


@pytest.mark.parametrize(
    "steps",
    [
        [DATA],  # one message far larger than a block
        [DATA[:1], DATA[1:2], DATA[2:15], DATA[15:]],  # tiny and large pieces
        [bytes([b]) for b in DATA],  # one byte at a time
    ],
    ids=["one-message", "mixed", "bytewise"],
)
def test_bytes_are_written_in_fixed_size_blocks_whatever_the_client_sends(client, steps):
    _batch, [it] = allocate(client, DATA)
    rt = runtime(client)
    rt.chunk_size = 4
    rt.files = files = RecordingFiles()

    sent = put(client, it, steps)

    assert sent.status == 200, sent.body
    # Every block is exactly one chunk except the last: memory per transfer is
    # bounded by the block size, however the body arrives.
    assert files.blocks == [4, 4, 4, 4, 3]
    assert (uploads_root(client) / item(client, it)["source_path"]).read_bytes() == DATA


def test_no_file_call_runs_on_the_event_loop_thread(client):
    _batch, [it] = allocate(client, DATA)
    rt = runtime(client)
    rt.chunk_size = 4
    rt.files = files = RecordingFiles()
    # The driver runs the app's event loop on this test's thread.
    loop_thread = threading.get_ident()

    assert put(client, it, [DATA[:9], DATA[9:]]).status == 200

    names = {name for name, _ in files.threads}
    assert {"make_dir", "open_part", "write_block", "sync_close", "rename", "sync_dir"} <= names
    assert [name for name, thread in files.threads if thread == loop_thread] == []


def test_the_answer_of_a_transfer_is_built_off_the_event_loop_thread(client, monkeypatch):
    """Review r1 7-R1-14: the item answer reads the stored duplicate report and
    looks up every match in SQLite; that never runs on the event loop, also
    when the same bytes are sent again for an item already past receiving."""
    from app.services import uploads as upload_rules

    _batch, [it] = allocate(client, DATA)
    built = []
    real = upload_rules.item_out

    def recording(row, library):
        built.append(threading.get_ident())
        return real(row, library)

    monkeypatch.setattr(upload_rules, "item_out", recording)
    loop_thread = threading.get_ident()  # the driver runs the loop on this thread

    assert put(client, it, [DATA]).status == 200
    assert put(client, it, [DATA]).status == 200  # a completed receipt answers its status

    assert len(built) == 2
    assert loop_thread not in built


def test_no_file_call_of_a_failed_transfer_runs_on_the_event_loop_thread(client):
    _batch, [it] = allocate(client, DATA)
    rt = runtime(client)
    rt.files = files = RecordingFiles()
    loop_thread = threading.get_ident()

    put(client, it, [bytes(reversed(DATA))])  # digest mismatch: close + remove

    names = {name for name, _ in files.threads}
    assert {"close", "remove"} <= names
    assert [name for name, thread in files.threads if thread == loop_thread] == []


# ── shared helpers for transfers that run while the test acts ──────────────

# A safety net only: a broken build fails here instead of hanging the suite.
# No test waits on wall-clock time; every wait below is on a gate or event.
HANG_GUARD_S = 10


def run_concurrently(scenario):
    """Run ``scenario()`` (async) on one event loop with the hang guard."""

    async def guarded():
        with anyio.fail_after(HANG_GUARD_S):
            return await scenario()

    return anyio.run(guarded)


async def start_put(tg, client, item_uuid, steps, results, *, content_length="auto"):
    if content_length == "auto":
        content_length = sum(len(s) for s in steps if isinstance(s, bytes))

    async def go():
        results.append(
            await request(client, "PUT", content_path(item_uuid), steps, content_length=content_length)
        )

    tg.start_soon(go)


async def thread_get(client, path):
    return await anyio.to_thread.run_sync(client.get, path)


async def thread_delete(client, path):
    return await anyio.to_thread.run_sync(client.delete, path)


# ── S8: throttled progress ─────────────────────────────────────────────────

def test_progress_is_persisted_at_most_once_per_interval_and_shows_in_the_status(client):
    _batch, [it] = allocate(client, DATA)
    rt = runtime(client)
    rt.chunk_size = 4
    rt.progress_interval_s = 1.0
    clock = [100.0]
    rt.monotonic = lambda: clock[0]
    first, second = Gate(), Gate()
    item_path = f"/tracks/uploads/items/{it}"

    async def scenario():
        results, seen = [], []
        async with anyio.create_task_group() as tg:
            await start_put(tg, client, it, [DATA[:8], first, DATA[8:16], second, DATA[16:]], results)
            await first.reached.wait()
            # 8 bytes written, but no time has passed: nothing persisted yet.
            seen.append((await thread_get(client, item_path)).json())
            clock[0] = 101.0  # one interval later
            first.open()
            await second.reached.wait()
            seen.append((await thread_get(client, item_path)).json())
            second.open()
        return results, seen

    results, seen = run_concurrently(scenario)

    assert [(s["state"], s["received_bytes"]) for s in seen[:1]] == [("receiving", 0)]
    assert seen[1]["state"] == "receiving"
    assert 8 < seen[1]["received_bytes"] <= 16
    assert results[0].status == 200
    [(progress_at,)] = rows(client, "SELECT progress_at FROM upload_items WHERE item_uuid = ?", (it,))
    # Row time = the request's wall clock plus the monotonic time elapsed.
    assert progress_at == NOW + 1




# ── S9: DELETE while receiving ──────────────────────────────────────────────

def _assert_cancelled_put(client, it, sent, slots):
    assert_error(sent, 409, "upload_item_cancelled", False)
    row = item(client, it)
    assert (row["state"], row["cancel_requested"], row["source_path"]) == ("cancelled", 1, None)
    assert slots.calls == [[True]]
    assert_released(client, it)
    assert files_under_uploads(client) == []
    assert reservations(client) == []


@pytest.mark.parametrize("where", ["before-first-chunk", "mid-body"])
def test_delete_cancels_a_stalled_transfer_at_once_without_waiting_for_it(client, where):
    _batch, [it] = allocate(client, DATA)
    slots = spy_slots(client)
    gate = Gate()  # never opened: the client stalls
    steps = [gate, DATA] if where == "before-first-chunk" else [DATA[:5], gate, DATA[5:]]

    async def scenario():
        results = []
        async with anyio.create_task_group() as tg:
            await start_put(tg, client, it, steps, results)
            await gate.reached.wait()
            deleted = await thread_delete(client, f"/tracks/uploads/items/{it}")
            # DELETE answered while the transfer is still blocked on its client.
            assert not gate.event.is_set()
        return results, deleted

    results, deleted = run_concurrently(scenario)

    assert (deleted.status_code, deleted.json()["state"]) == (200, "cancelled")
    _assert_cancelled_put(client, it, results[0], slots)


class PausingFiles(ReceiptFiles):
    """Holds the receipt (in its worker thread) right after the source rename,
    before the commit, until the test lets it go."""

    def __init__(self):
        self.paused = threading.Event()
        self.resume = threading.Event()

    def sync_dir(self, path):
        super().sync_dir(path)
        self.paused.set()
        assert self.resume.wait(HANG_GUARD_S)


def test_delete_just_after_the_last_chunk_wins_and_removes_the_source_too(client):
    _batch, [it] = allocate(client, DATA)
    slots = spy_slots(client)
    rt = runtime(client)
    rt.files = files = PausingFiles()

    async def scenario():
        results = []
        async with anyio.create_task_group() as tg:
            await start_put(tg, client, it, [DATA], results)
            await anyio.to_thread.run_sync(files.paused.wait)
            deleted = await thread_delete(client, f"/tracks/uploads/items/{it}")
            files.resume.set()
        return results, deleted

    results, deleted = run_concurrently(scenario)

    assert (deleted.status_code, deleted.json()["state"]) == (200, "cancelled")
    _assert_cancelled_put(client, it, results[0], slots)


def test_a_repeated_delete_of_a_cancelled_transfer_still_succeeds(client):
    _batch, [it] = allocate(client, DATA)
    gate = Gate()

    async def scenario():
        results = []
        async with anyio.create_task_group() as tg:
            await start_put(tg, client, it, [gate, DATA], results)
            await gate.reached.wait()
            first = await thread_delete(client, f"/tracks/uploads/items/{it}")
        second = await thread_delete(client, f"/tracks/uploads/items/{it}")
        return first, second

    first, second = run_concurrently(scenario)

    assert [(r.status_code, r.json()["state"]) for r in (first, second)] == [
        (200, "cancelled"), (200, "cancelled"),
    ]


def test_delete_cancels_a_receiving_item_whose_transfer_is_gone(client):
    """A receiving row with a dead lease (e.g. the startup reconcile could not
    run) can still be cancelled; nothing waits for a transfer that isn't there."""
    _batch, [it] = allocate(client, DATA)
    _force_state(client, it, "receiving", lease_boot_id="a-dead-boot")

    deleted = client.delete(f"/tracks/uploads/items/{it}")

    assert (deleted.status_code, deleted.json()["state"]) == (200, "cancelled")
    assert item(client, it)["cancel_requested"] == 1


def test_a_cancelled_transfer_is_seen_by_its_own_progress_write_too(client):
    """The durable flag is re-checked: if the token were missed, the next
    progress write still finds the item cancelled and ends the transfer."""
    _batch, [it] = allocate(client, DATA)
    slots = spy_slots(client)
    rt = runtime(client)
    rt.chunk_size = 4
    rt.progress_interval_s = 0.0  # persist after every block
    gate = Gate()

    async def scenario():
        results = []
        async with anyio.create_task_group() as tg:
            await start_put(tg, client, it, [DATA[:4], gate, DATA[4:]], results)
            await gate.reached.wait()
            # Cancel durably, behind the token's back.
            _force_state(client, it, "cancelled", cancel_requested=1)
            gate.open()
        return results

    results = run_concurrently(scenario)

    _assert_cancelled_put(client, it, results[0], slots)




# ── S10: the idle timeout ──────────────────────────────────────────────────

class FakeIdle:
    """Stands in for the idle sleep: records each requested bound and returns
    only when the test says the time has passed."""

    def __init__(self):
        self.asked = []
        self._elapsed = None

    @property
    def elapsed(self):
        if self._elapsed is None:
            self._elapsed = anyio.Event()
        return self._elapsed

    async def __call__(self, seconds):
        self.asked.append(seconds)
        await self.elapsed.wait()


@pytest.mark.parametrize("where", ["before-first-chunk", "mid-body"])
def test_a_client_that_sends_nothing_for_the_idle_bound_is_cut_off(client, where):
    _batch, [it] = allocate(client, DATA)
    slots = spy_slots(client)
    rt = runtime(client)
    rt.sleep = idle = FakeIdle()
    gate = Gate()  # never opened
    steps = [gate, DATA] if where == "before-first-chunk" else [DATA[:5], gate, DATA[5:]]

    async def scenario():
        results = []
        async with anyio.create_task_group() as tg:
            await start_put(tg, client, it, steps, results)
            await gate.reached.wait()
            idle.elapsed.set()  # 30 seconds pass with no chunk
        return results

    results = run_concurrently(scenario)

    assert idle.asked and set(idle.asked) == {30}
    assert_error(results[0], 408, "upload_idle_timeout", True)
    assert item_error(client, it) == ("allocated", "upload_idle_timeout", 1)
    assert_ended_once(client, it, slots)


def test_a_client_that_keeps_sending_is_never_cut_off(client):
    _batch, [it] = allocate(client, DATA)
    rt = runtime(client)
    rt.sleep = idle = FakeIdle()  # time never passes

    sent = put(client, it, [bytes([b]) for b in DATA])

    assert sent.status == 200
    assert set(idle.asked) == {30}


# ── S11 (O4 / DEV-7-02): one receiving transfer per user by default ────────

def _assert_slots_busy(sent):
    assert_error(sent, 503, "upload_slots_busy", True)
    detail = sent.json()["detail"]
    assert isinstance(detail["retry_after_s"], int) and detail["retry_after_s"] > 0
    assert sent.headers["retry-after"] == str(detail["retry_after_s"])
    assert sent.reads == 0


def test_a_user_with_a_transfer_running_waits_while_another_user_may_send(client):
    _batch, [mine] = allocate(client, DATA)
    sam, sam_headers = _second_user(client)
    _b, [theirs] = allocate(client, DATA, headers=sam_headers, batch=uid(1, space=9), space=3)
    rt = runtime(client)
    held = rt.slots.try_acquire(client.app.state.admin_user_id)  # my running transfer

    sent = put(client, mine, [DATA])

    _assert_slots_busy(sent)
    assert item(client, mine)["state"] == "allocated"
    assert reservations(client) == []
    admin_headers = dict(client.headers)
    client.headers.update(sam_headers)
    assert put(client, theirs, [DATA]).status == 200  # sam is not blocked by me
    client.headers.update(admin_headers)
    held.release()
    assert put(client, mine, [DATA]).status == 200


# ── S12: a completed receipt, and a second PUT while one runs ─────────────

def _received(client, contents=DATA):
    _batch, [it] = allocate(client, contents)
    assert put(client, it, [contents]).status == 200
    [snap] = rows(client, "SELECT * FROM upload_items WHERE item_uuid = ?", (it,))
    return it, snap


def _unchanged(client, it, snap):
    [now] = rows(client, "SELECT * FROM upload_items WHERE item_uuid = ?", (it,))
    assert now == snap
    owner = client.app.state.admin_user_id
    assert reservations(client) == [(owner, "upload_source", it, len(DATA), None)]
    assert (uploads_root(client) / item(client, it)["source_path"]).read_bytes() == DATA
    assert runtime(client).slots.in_use() == 0


def test_sending_the_same_content_again_answers_the_current_status_and_changes_nothing(client):
    it, snap = _received(client)
    slots = spy_slots(client)

    sent = put(client, it, [DATA[:3], DATA[3:]])

    assert sent.status == 200, sent.body
    assert (sent.json()["item_uuid"], sent.json()["state"]) == (it, "validating")
    _unchanged(client, it, snap)
    assert slots.calls == [[True]]
    assert files_under_uploads(client) == [str(Path(item(client, it)["source_path"]).relative_to(uploads_root(client)))]


@pytest.mark.parametrize(
    "state, extra",
    [
        ("review_ready", {}),
        ("committing", {}),
        ("duplicate_conflict", {}),
        ("imported", {"result_track_uuid": uid(50), "result_revision": 3}),
        ("duplicate", {"result_track_uuid": uid(50), "duplicate_kind": "exact"}),
    ],
)
def test_the_same_content_after_any_later_state_answers_that_state(client, state, extra):
    it, _snap = _received(client)
    _force_state(client, it, state, **extra)

    sent = put(client, it, [DATA])

    assert (sent.status, sent.json()["state"]) == (200, state)
    assert item(client, it)["state"] == state


def test_different_bytes_for_a_completed_receipt_are_a_422_and_change_nothing(client):
    it, snap = _received(client)
    slots = spy_slots(client)

    sent = put(client, it, [bytes(reversed(DATA))])

    assert_error(sent, 422, "upload_digest_mismatch", False)
    _unchanged(client, it, snap)
    assert slots.calls == [[True]]


@pytest.mark.parametrize(
    "steps, declared, status, code",
    [
        ([DATA + b"!"], None, 413, "upload_too_large"),
        ([DATA + b"!"], "auto", 413, "upload_too_large"),
        ([DATA[:-1]], None, 422, "upload_digest_mismatch"),
        ([DATA[:-1]], "auto", 422, "upload_length_mismatch"),
    ],
    ids=["long-chunked", "long-declared", "short-chunked", "short-declared"],
)
def test_another_length_for_a_completed_receipt_changes_nothing(client, steps, declared, status, code):
    it, snap = _received(client)

    sent = put(client, it, steps, content_length=declared)

    assert_error(sent, status, code, False)
    _unchanged(client, it, snap)


def test_another_user_learns_nothing_from_a_completed_receipt(client):
    it, _snap = _received(client)
    _sam, sam_headers = _second_user(client)
    client.headers.update(sam_headers)

    theirs = put(client, it, [DATA])
    unknown = put(client, uid(98), [DATA])

    assert (theirs.status, theirs.json()) == (unknown.status, unknown.json())
    assert theirs.error == "upload_item_not_found"
    assert theirs.reads == 0


def test_a_second_put_while_one_is_running_is_a_retryable_409_and_the_first_completes(client):
    _batch, [it] = allocate(client, DATA)
    gate = Gate()

    async def scenario():
        results = []
        async with anyio.create_task_group() as tg:
            await start_put(tg, client, it, [DATA[:5], gate, DATA[5:]], results)
            await gate.reached.wait()
            second = await request(client, "PUT", content_path(it), [DATA], content_length=len(DATA))
            gate.open()
        return results, second

    results, second = run_concurrently(scenario)

    assert_error(second, 409, "upload_transfer_in_progress", True)
    assert second.reads == 0
    assert results[0].status == 200
    assert item(client, it)["state"] == "validating"
    assert runtime(client).slots.in_use() == 0


# ── S14: a claim lost to a racing request answers like that request's state ──

class _RacingLedger:
    """Takes the reservation, then lets another request win the item before
    this transfer claims it (deterministic stand-in for the race)."""

    def __init__(self, inner, on_reserve):
        self.inner, self.on_reserve = inner, on_reserve
        self.released = []

    def reserve(self, **kwargs):
        rid = self.inner.reserve(**kwargs)
        self.on_reserve()
        return rid

    def release(self, reservation_id):
        self.released.append(reservation_id)
        return self.inner.release(reservation_id)


@pytest.mark.parametrize(
    "winner, status, code, retryable",
    [
        ({"state": "receiving", "lease_boot_id": "another-transfer"}, 409, "upload_transfer_in_progress", True),
        ({"state": "cancelled", "cancel_requested": 1}, 409, "upload_item_not_receivable", False),
    ],
    ids=["another-put", "a-delete"],
)
def test_a_claim_lost_to_a_racing_request_answers_its_state_and_gives_everything_back(
    client, winner, status, code, retryable
):
    _batch, [it] = allocate(client, DATA)
    slots = spy_slots(client)
    rt = runtime(client)
    winner = dict(winner)
    state = winner.pop("state")
    rt.ledger = ledger = _RacingLedger(rt.ledger, lambda: _force_state(client, it, state, **winner))

    sent = put(client, it, [DATA])

    assert_error(sent, status, code, retryable)
    assert sent.reads == 0
    assert slots.calls == [[True]]
    assert len(ledger.released) == 1
    assert reservations(client) == []
    assert files_under_uploads(client) == []
    assert item(client, it)["state"] == state


# ── review r1 ───────────────────────────────────────────────────────────────

class _RemoveFails(ReceiptFiles):
    def remove(self, path):
        raise PermissionError(errno.EACCES, "Permission denied")


def test_r1_1_a_partial_that_cannot_be_removed_stays_recorded_and_counted(client):
    """Spec §3: release a reservation only "after verified removal". A partial
    the server could not delete keeps its row and its reservation, so the next
    startup still finds and removes it."""
    _batch, [it] = allocate(client, DATA)
    slots = spy_slots(client)
    runtime(client).files = _RemoveFails()

    put(client, it, [DATA[:-1]], content_length=len(DATA))

    row = item(client, it)
    assert (row["state"], row["error_code"], row["error_retryable"]) == ("failed", "upload_cleanup_failed", 0)
    assert row["part_path"] is not None and Path(row["part_path"]).is_file()
    owner = client.app.state.admin_user_id
    assert reservations(client) == [(owner, "upload_receive", it, len(DATA), client.app.state.boot_id)]
    assert slots.calls == [[True]]
    # A failed item takes no more bytes until the leftover is cleaned up.
    assert put(client, it, [DATA]).status == 409


class _SpyTokens:
    """The real registry, remembering every token handed out."""

    def __init__(self, inner):
        self.inner, self.handed = inner, []

    def register(self, key):
        token = self.inner.register(key)
        self.handed.append(token)
        return token

    def cancel(self, key):
        return self.inner.cancel(key)

    def discard(self, key):
        return self.inner.discard(key)


def test_r1_2_a_new_transfer_never_inherits_the_token_of_one_that_just_ended(client):
    """Finding 2: once the item is claimable again, the ended transfer's token
    must already be gone, or the next transfer shares it and loses it."""
    _batch, [it] = allocate(client, DATA)
    rt = runtime(client)
    rt.tokens = tokens = _SpyTokens(rt.tokens)
    owner = client.app.state.admin_user_id
    seen = []

    def after_end():
        # The item is back to allocated here: a second transfer could claim it now.
        assert item(client, it)["state"] == "allocated"
        seen.append(tokens.register((owner, it)))
        tokens.discard((owner, it))

    rt.ledger = _RacingLedger(rt.ledger, lambda: None)
    real_release = rt.ledger.release

    def release(reservation_id):
        result = real_release(reservation_id)
        after_end()
        return result

    rt.ledger.release = release

    put(client, it, [DATA[:-1]], content_length=len(DATA))  # short body: ends allocated

    first, second = tokens.handed[0], seen[0]
    assert second is not first


class _DeletesOnFirstWrite(ReceiptFiles):
    def __init__(self, client, item_uuid):
        self.client, self.item_uuid, self.done = client, item_uuid, False

    def write_block(self, handle, block):
        super().write_block(handle, block)
        if not self.done:
            self.done = True
            response = self.client.delete(f"/tracks/uploads/items/{self.item_uuid}")
            assert response.json()["state"] == "cancelled"


def test_r1_3_a_cancel_stops_a_client_whose_next_chunk_is_already_there(client):
    """Finding 3: the token must win even when the next chunk needs no wait."""
    _batch, [it] = allocate(client, DATA)
    rt = runtime(client)
    rt.chunk_size = 1
    rt.progress_interval_s = 10**9  # the durable guard must not be what stops it
    rt.files = _DeletesOnFirstWrite(client, it)
    steps = [bytes([b]) for b in DATA]

    sent = put(client, it, steps)

    assert_error(sent, 409, "upload_item_cancelled", False)
    assert sent.reads <= 2
    assert_released(client, it)


def test_r1_6_the_items_path_is_resolved_off_the_event_loop(client, monkeypatch):
    """Finding 6: ``assert_within`` resolves paths (filesystem calls)."""
    from app.services import upload_receipt
    from app.services.path_sanitize import assert_within as real

    threads = []

    def recording(path, root):
        threads.append(threading.get_ident())
        return real(path, root)

    monkeypatch.setattr(upload_receipt, "assert_within", recording)
    _batch, [it] = allocate(client, DATA)
    loop_thread = threading.get_ident()

    assert put(client, it, [DATA]).status == 200

    assert threads and loop_thread not in threads


def test_r1_7_a_full_server_wide_quota_tells_nobody_the_other_users_totals(client):
    from tests.test_upload_limits import EFFECTIVE_DEFAULTS

    sam, _sam_headers = _second_user(client)
    _batch, [it] = allocate(client, DATA)
    _staged_row(client, sam, EFFECTIVE_DEFAULTS["staged_quota_bytes"] - 5)

    sent = put(client, it, [DATA])

    assert_error(sent, 413, "staged_quota_exceeded", True)
    detail = sent.json()["detail"]
    assert "available" not in detail and "limit" not in detail
    assert not any(ch.isdigit() for ch in detail["message"])
