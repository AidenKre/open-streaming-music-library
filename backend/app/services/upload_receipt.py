"""Streamed upload byte receipt (Phase 7 spec §5 "Byte receipt"): the
in-process transfer slots, and the receipt of one item's content with its one
terminal handler."""

import asyncio
import errno
import hashlib
import logging
import os
import threading
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, AsyncIterator, Awaitable, Callable

import anyio
from anyio import to_thread

from app.core.operator_log import operator_logger
from app.core.bounded_body import BodyTooLarge, capped_chunks
from app.core.durable_fs import fsync_dir
from app.core.upload_states import ENDED_STATES, SOURCE_GIVEN_BACK_STATES
from app.services import job_runtime
from app.services.path_sanitize import assert_within
from app.services.storage_ledger import (
    UPLOAD_RECEIVE,
    UPLOAD_SOURCE,
    InsufficientStorage,
    StagedQuota,
    StorageLedger,
)
from app.services.upload_errors import (
    UploadError,
    upload_cleanup_failed,
    upload_digest_mismatch,
    upload_disk_full,
    upload_incomplete,
    upload_write_failed,
    upload_interrupted,
    upload_idle_timeout,
    upload_item_cancelled,
    upload_slots_busy,
    upload_transfer_in_progress,
    upload_length_mismatch,
    upload_item_not_found,
    upload_item_not_receivable,
    upload_storage_refused,
    upload_too_large,
)

logger = logging.getLogger(__name__)

CHUNK_SIZE = 1024 * 1024
IDLE_TIMEOUT_S = 30
PROGRESS_INTERVAL_S = 1.0
BUSY_RETRY_AFTER_S = 5

job_runtime.register_job_table(
    "upload_items",
    key_columns=("owner_id", "item_uuid"),
    state_column="state",
    terminal_states=ENDED_STATES,
)


class TransferSlot:
    def __init__(self, slots: "TransferSlots", owner_id):
        self._slots = slots
        self.owner_id = owner_id
        self._released = False

    def release(self) -> bool:
        """Give the slot back; True only the first time."""
        return self._slots._release(self)


class TransferSlots:
    """At most ``total`` receiving transfers at once, and with ``per_user`` set
    at most that many for one owner; taking one never waits. Thread-safe (one
    lock) because requests may run on different event loops."""

    def __init__(self, total: int, per_user: int | None = None):
        self._total = total
        self._per_user = per_user
        self._held = 0
        self._by_owner: dict = {}
        self._lock = threading.Lock()

    def try_acquire(self, owner_id) -> TransferSlot | None:
        with self._lock:
            if self._held >= self._total:
                return None
            if self._per_user is not None and self._by_owner.get(owner_id, 0) >= self._per_user:
                return None
            self._held += 1
            self._by_owner[owner_id] = self._by_owner.get(owner_id, 0) + 1
            return TransferSlot(self, owner_id)

    def in_use(self) -> int:
        with self._lock:
            return self._held

    def _release(self, slot: TransferSlot) -> bool:
        with self._lock:
            if slot._released:
                return False
            slot._released = True
            self._held -= 1
            left = self._by_owner[slot.owner_id] - 1
            if left:
                self._by_owner[slot.owner_id] = left
            else:
                del self._by_owner[slot.owner_id]
            return True


class ReceiptFiles:
    """The one place the receipt touches the filesystem; every method blocks,
    so callers run them in a worker thread."""

    def make_dir(self, path: Path) -> None:
        path.mkdir(parents=True, exist_ok=True, mode=0o700)

    def open_part(self, path: Path):
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        return os.fdopen(fd, "wb")

    def write_block(self, handle, block: bytes) -> None:
        handle.write(block)

    def sync_close(self, handle) -> None:
        try:
            handle.flush()
            os.fsync(handle.fileno())
        finally:
            handle.close()

    def close(self, handle) -> None:
        handle.close()

    def rename(self, source: Path, target: Path) -> None:
        os.replace(source, target)

    def sync_dir(self, path: Path) -> None:
        """Best effort: not every platform can open a directory."""
        fsync_dir(path)

    def remove(self, path: Path) -> None:
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass


def remove_verified(files: ReceiptFiles, path: Path) -> bool:
    """Remove ``path`` and report whether it is gone (missing counts as gone). A
    removal that raises is logged by type only; only the file's absence counts."""
    try:
        files.remove(path)
    except Exception as exc:
        logger.warning("upload file removal failed (%s)", type(exc).__name__)
    try:
        os.lstat(path)
    except FileNotFoundError:
        return True
    except OSError:
        return False
    return False


def remove_then_release(
    files: ReceiptFiles, path: Path, release: Callable[[], Any], *,
    within: Path | None = None, remove: Callable[[ReceiptFiles, Path], bool] | None = None,
    between: Callable[[], None] | None = None,
) -> Any:
    """Give a staged file back, in this order: check that ``path`` lies inside
    ``within`` (when given; ``ValueError`` otherwise: nothing removed, nothing
    released), remove it verifiably, and only once it is gone call
    ``release()``, the database write that forgets the path and its quota row.
    A file that is still there is never released, so its bytes stay counted.

    ``remove`` defaults to this module's ``remove_verified``, looked up at the
    call; a caller passes its own module's name for it, so a test that replaces
    that name there still reaches the call. ``between`` (a crash seam) runs after
    the removal attempt, whatever its outcome, and before the release. Returns
    ``None`` while the file is still there, else what ``release()`` returned.
    Raises what the check, the seam or the release raise; each caller keeps its
    own handling and log line."""
    if within is not None:
        assert_within(path, within)
    gone = (remove or remove_verified)(files, path)
    if between is not None:
        between()
    if not gone:
        return None
    return release()


@dataclass
class ReceiptRuntime:
    ledger: StorageLedger
    slots: TransferSlots
    tokens: job_runtime.CancelTokens
    uploads_root: Path
    boot_id: str
    files: ReceiptFiles = field(default_factory=ReceiptFiles)
    sleep: Callable[[float], Awaitable[None]] = anyio.sleep
    monotonic: Callable[[], float] = time.monotonic
    chunk_size: int = CHUNK_SIZE
    idle_timeout_s: float = IDLE_TIMEOUT_S
    progress_interval_s: float = PROGRESS_INTERVAL_S


class ClientGone(Exception):
    """The client disconnected before the body ended (the route adapts its
    framework's signal to this)."""


@dataclass(frozen=True)
class Outcome:
    """How an uncommitted receipt ends: the item's next state and error, which
    are also the HTTP answer, so the two cannot drift."""

    to_state: str
    error: UploadError


INTERRUPTED = Outcome("allocated", upload_interrupted())
# DELETE already moved the row to cancelled; the receipt only cleans up.
CANCELLED = Outcome("cancelled", upload_item_cancelled())
IDLE = Outcome("allocated", upload_idle_timeout())


def _classify(exc: Exception) -> Outcome | None:
    """The one place an exception becomes an outcome; None = not ours (re-raised)."""
    if isinstance(exc, BodyTooLarge):
        # More than was allocated: the allocation cannot take these bytes.
        return Outcome("failed", upload_too_large())
    if isinstance(exc, ClientGone):
        return INTERRUPTED
    if isinstance(exc, OSError):
        if exc.errno in (errno.ENOSPC, errno.EDQUOT):
            return Outcome("allocated", upload_disk_full())
        return Outcome("allocated", upload_write_failed())
    return None


def _safe_uuid(value: str) -> str:
    if str(uuid.UUID(value)) != value:
        raise ValueError("not a canonical uuid")
    return value


def owner_dir(uploads_root: Path, owner_id) -> Path:
    """``<uploads root>/<owner>``: the only place an owner's staged files live.
    A recorded path is trusted only inside its own owner's folder."""
    if not isinstance(owner_id, int) or isinstance(owner_id, bool) or owner_id <= 0:
        raise ValueError("owner_id must be a positive int")
    return uploads_root / str(owner_id)


def _item_dir(uploads_root: Path, owner_id, row: dict) -> Path:
    """``<uploads root>/<owner>/<batch>/<item>`` from the owner id and a row's
    own ids, never from the client's filename. Item ids are per owner, so the
    owner is part of the path."""
    folder = (
        owner_dir(uploads_root, owner_id)
        / _safe_uuid(row["batch_uuid"]) / _safe_uuid(row["item_uuid"])
    )
    assert_within(folder, uploads_root)
    return folder


def discard_child_files(files, uploads_root: Path, owner_id, child_row: dict) -> None:
    """Remove one archive child's staged files (fixed names only, folder from its ids)."""
    folder = _item_dir(uploads_root, owner_id, child_row)
    for name in ("source.part", "source"):
        remove_verified(files, folder / name)


async def _current_item(library, item_uuid: str) -> dict | None:
    return await to_thread.run_sync(library.get_upload_item, item_uuid)


async def _shielded(function, *args, **kwargs):
    """Run a blocking call to completion even if this task is cancelled, so
    its result (a claim, a reservation, a commit) is never lost."""
    with anyio.CancelScope(shield=True):
        return await to_thread.run_sync(lambda: function(*args, **kwargs))


_END = object()


async def _watched(
    stream: AsyncIterator[bytes],
    token: job_runtime.CancelToken,
    sleep: Callable[[float], Awaitable[None]],
    idle_timeout_s: float,
):
    """``stream``'s chunks, each read raced against the cancel token and an
    idle timeout (restarted for every read). The token fires from another
    thread, so it is bridged into this loop. A fired token (even one fired
    before the first read) ends the transfer as cancelled, and wins over an
    idle timeout that is ready at the same time; the losing sides of every
    race are cancelled, so no task is left behind."""
    loop = asyncio.get_running_loop()
    cancelled = anyio.Event()

    def fire() -> None:
        try:
            loop.call_soon_threadsafe(cancelled.set)
        except RuntimeError:  # this loop is gone: nobody is reading any more
            pass

    token.on_cancel(fire)
    chunks = stream.__aiter__()
    while True:
        # A next chunk that is already there never suspends the read, so the
        # race below could not see a fired token: look before every read.
        if token.cancelled or cancelled.is_set():
            raise _Ended(CANCELLED)
        box: list = []
        failure: Exception | None = None
        async with anyio.create_task_group() as tg:

            async def watch() -> None:
                await cancelled.wait()
                box.append(_Ended(CANCELLED))
                tg.cancel_scope.cancel()

            async def idle() -> None:
                await sleep(idle_timeout_s)
                box.append(_Ended(CANCELLED if cancelled.is_set() else IDLE))
                tg.cancel_scope.cancel()

            tg.start_soon(watch)
            tg.start_soon(idle)
            try:
                box.append(await chunks.__anext__())
            except StopAsyncIteration:
                box.append(_END)
            except Exception as exc:  # re-raised below, outside the group
                failure = exc
            tg.cancel_scope.cancel()
        if failure is not None:
            raise failure
        item = box[0]
        if isinstance(item, _Ended):
            raise item
        if item is _END:
            return
        yield item


def _hash_and_write(files: ReceiptFiles, handle, hasher, block: bytes) -> None:
    hasher.update(block)
    files.write_block(handle, block)


class _Ended(Exception):
    """The body ended in a known way that is not a success."""

    def __init__(self, outcome: Outcome):
        self.outcome = outcome


class _Receipt:
    """What one transfer acquired, and the one terminal handler that gives it
    all back exactly once."""

    def __init__(self, runtime: ReceiptRuntime, library, item_uuid: str, now: int):
        self.runtime = runtime
        self.library = library
        self.item_uuid = item_uuid
        self.now = now
        self.start = None
        self.slot: TransferSlot | None = None
        self.reservation_id: int | None = None
        self.claimed = False
        self.part: Path | None = None
        self.source: Path | None = None
        self.source_created = False
        self.handle: Any = None
        self.token_key = None
        self.committed = False
        self.outcome = INTERRUPTED
        self._finished = False

    def stamp(self) -> int:
        """Row time: the request's wall clock plus the monotonic time elapsed
        since the claim."""
        if self.start is None:
            return self.now
        return self.now + int(self.runtime.monotonic() - self.start)

    async def _step(self, name: str, function, *args, **kwargs) -> None:
        """One guarded sub-step of finish: a failure is logged by type only."""
        try:
            await to_thread.run_sync(lambda: function(*args, **kwargs))
        except Exception as exc:
            logger.warning("upload receipt cleanup step %s failed (%s)", name, type(exc).__name__)

    async def _removed(self, name: str, path: Path) -> bool:
        """Remove one owned file; True only when it is verifiably gone."""
        try:
            return await to_thread.run_sync(remove_verified, self.runtime.files, path)
        except Exception as exc:
            logger.warning("upload receipt cleanup step %s failed (%s)", name, type(exc).__name__)
            return False

    async def finish(self) -> None:
        """Run once, from a ``finally``, shielded from cancellation."""
        if self._finished:
            return
        self._finished = True
        rt = self.runtime
        with anyio.CancelScope(shield=True):
            # First: once the end write makes the item claimable again, a new
            # transfer must not find this one's (ended) token.
            if self.token_key is not None:
                await self._step("discard_token", rt.tokens.discard, self.token_key)
            if self.handle is not None:
                await self._step("close", rt.files.close, self.handle)
                self.handle = None
            # A leftover that cannot be removed stays recorded and counted.
            cleaned = True
            if self.part is not None:
                cleaned = await self._removed("remove_part", self.part)
            if self.source_created and not self.committed:
                cleaned = await self._removed("remove_source", self.source) and cleaned
            end = self.outcome
            if not cleaned:
                end = Outcome("failed", upload_cleanup_failed())
            if self.claimed and not self.committed:
                await self._step(
                    "end",
                    self.library.end_upload_receipt,
                    self.item_uuid,
                    boot_id=rt.boot_id,
                    part_path=str(self.part),
                    to_state=end.to_state,
                    error_code=end.error.code,
                    error_message=end.error.message,
                    error_retryable=end.error.retryable,
                    now=self.stamp(),
                    keep_part=not cleaned,
                )
            if self.reservation_id is not None and not self.committed and cleaned:
                await self._step("release_reservation", rt.ledger.release, self.reservation_id)
            if self.slot is not None:
                await self._step("release_slot", self.slot.release)


# States after a complete receipt: the same bytes sent again are only verified.
COMPLETED_STATES = frozenset(
    {
        "validating",
        "review_ready",
        "committing",
        "imported",
        "duplicate",
        "duplicate_conflict",
        "expanded",
    }
)


async def _read_blocks(stream, token, runtime: ReceiptRuntime, expected_bytes: int, sink) -> None:
    """The one body reader: chunks (watched for cancel and idle, capped at the
    allocated size) re-cut into blocks of ``runtime.chunk_size`` and handed to
    ``sink``. The write path and the verify-only path differ only in the sink."""
    buffer = bytearray()
    size = runtime.chunk_size
    async for chunk in capped_chunks(
        _watched(stream, token, runtime.sleep, runtime.idle_timeout_s), expected_bytes
    ):
        buffer += chunk
        while len(buffer) >= size:
            block = bytes(buffer[:size])
            del buffer[:size]
            await sink(block)
    if buffer:
        await sink(bytes(buffer))


def _error_for(receipt: "_Receipt", exc: Exception) -> UploadError | None:
    """The error that answers ``exc`` (recording its outcome on the receipt), or
    None when it is not ours: a refusal before the claim, or a bug."""
    outcome = exc.outcome if isinstance(exc, _Ended) else _classify(exc)
    if outcome is None:
        return None
    receipt.outcome = outcome
    return outcome.error


async def _verify_content(runtime, library, item_uuid, stream, row, *, now: int) -> dict:
    """Content sent again for a completed receipt: read it through the same
    reader, hash it, and answer the item's current status when it is the
    allocated content. Nothing is written, reserved or claimed."""
    receipt = _Receipt(runtime, library, item_uuid, now)
    try:
        receipt.slot = runtime.slots.try_acquire(library.owner_id)
        if receipt.slot is None:
            raise upload_slots_busy(retry_after_s=BUSY_RETRY_AFTER_S)
        hasher = hashlib.sha256()
        received = 0

        async def sink(block: bytes) -> None:
            nonlocal received
            await to_thread.run_sync(hasher.update, block)
            received += len(block)

        await _read_blocks(stream, job_runtime.CancelToken(), runtime, row["expected_bytes"], sink)
        if received != row["expected_bytes"] or hasher.hexdigest() != row["expected_sha256"]:
            raise _Ended(Outcome("allocated", upload_digest_mismatch()))
    except Exception as exc:
        error = _error_for(receipt, exc)
        if error is None:
            raise
        raise error from None
    finally:
        await receipt.finish()
    return await _current_item(library, item_uuid)


def _refusal_for_state(state: str | None) -> UploadError:
    """The refusal for an item that cannot start a receipt in ``state`` (None:
    the item is gone). The one state-to-refusal mapping, for the entry check
    and for a lost claim."""
    if state is None:
        return upload_item_not_found()
    if state == "receiving":
        return upload_transfer_in_progress()
    return upload_item_not_receivable(state)


def _check_declared_length(declared: str | None, expected: int) -> None:
    """A Content-Length, when sent, must equal the allocated size. Absent is
    fine: the actual counter is the enforcement."""
    if declared is None:
        return
    if not (declared.isascii() and declared.isdecimal()):
        raise upload_length_mismatch()
    if int(declared) > expected:
        raise upload_too_large()
    if int(declared) < expected:
        raise upload_length_mismatch()


async def _raise_if_lost(library, item_uuid: str, *, always: bool = False) -> None:
    """The transfer's durable guard failed (or is being re-checked): end it as
    cancelled if the item was cancelled, else as interrupted. Without
    ``always`` nothing is raised while the item is still receiving."""
    current = await _current_item(library, item_uuid)
    state = current["state"] if current else None
    if state == "cancelled":
        raise _Ended(CANCELLED)
    if always or state != "receiving":
        raise _Ended(INTERRUPTED)


async def receive_content(
    runtime: ReceiptRuntime,
    library,
    limits,
    item_uuid: str,
    stream: AsyncIterator[bytes],
    *,
    declared_length: str | None = None,
    now: int,
) -> dict:
    """Receive the body of one allocated item; returns the item's row (status
    after the receipt). Raises UploadError for every refusal."""
    row = await _current_item(library, item_uuid)
    if row is None:
        raise upload_item_not_found()
    if row["parent_item_uuid"] is not None:
        raise upload_item_not_receivable(row["state"])  # a child's content comes from its archive
    if row["state"] != "allocated" and row["state"] not in COMPLETED_STATES:
        raise _refusal_for_state(row["state"])
    _check_declared_length(declared_length, row["expected_bytes"])
    if row["state"] != "allocated":
        return await _verify_content(runtime, library, item_uuid, stream, row, now=now)
    return await _receive_allocated(runtime, library, limits, item_uuid, stream, row, now=now)


async def _receive_allocated(runtime, library, limits, item_uuid, stream, row, *, now: int) -> dict:
    """The receipt of an allocated item: slot, reservation, claim, streamed
    write, verification, atomic rename and commit, ending through the one
    terminal handler."""
    owner = library.owner_id
    receipt = _Receipt(runtime, library, item_uuid, now)
    try:
        receipt.slot = runtime.slots.try_acquire(owner)
        if receipt.slot is None:
            # Server-wide and per-user busy answer alike: never reveal others' transfers.
            raise upload_slots_busy(retry_after_s=BUSY_RETRY_AFTER_S)
        expected_bytes = row["expected_bytes"]
        try:
            receipt.reservation_id = await _shielded(
                runtime.ledger.reserve,
                owner_id=owner,
                purpose=UPLOAD_RECEIVE,
                nbytes=expected_bytes,
                subject_ref=item_uuid,
                quota=StagedQuota(
                    user_bytes=limits.user_staged_quota_bytes,
                    total_bytes=limits.staged_quota_bytes,
                ),
            )
        except InsufficientStorage as exc:
            raise upload_storage_refused(exc) from None

        # A server-made part name inside the row's own item dir.
        # assert_within resolves paths (filesystem calls): off the event loop.
        item_dir = await to_thread.run_sync(_item_dir, runtime.uploads_root, owner, row)
        receipt.part = item_dir / f"{uuid.uuid4()}.part"
        receipt.source = item_dir / "source"

        # The part path is recorded before the file exists.
        receipt.start = last_persisted = runtime.monotonic()
        receipt.claimed = await _shielded(
            library.begin_upload_receipt,
            item_uuid,
            boot_id=runtime.boot_id,
            part_path=str(receipt.part),
            now=now,
        )
        if not receipt.claimed:
            # Another request got there first: answer by the item's state now.
            current = await _current_item(library, item_uuid)
            raise _refusal_for_state(current["state"] if current else None)
        receipt.token_key = (owner, item_uuid)
        token = runtime.tokens.register(receipt.token_key)
        # A DELETE between the claim and the token would be missed by the token.
        await _raise_if_lost(library, item_uuid)

        files = runtime.files
        await to_thread.run_sync(files.make_dir, item_dir)
        receipt.handle = await to_thread.run_sync(files.open_part, receipt.part)

        hasher = hashlib.sha256()
        received = 0

        async def write(block: bytes) -> None:
            nonlocal received, last_persisted
            await to_thread.run_sync(_hash_and_write, files, receipt.handle, hasher, block)
            received += len(block)
            if runtime.monotonic() - last_persisted < runtime.progress_interval_s:
                return
            last_persisted = runtime.monotonic()
            held = await to_thread.run_sync(
                lambda: library.record_upload_progress(
                    item_uuid, boot_id=runtime.boot_id, part_path=str(receipt.part),
                    received_bytes=received, now=receipt.stamp(),
                )
            )
            if not held:
                await _raise_if_lost(library, item_uuid, always=True)

        await _read_blocks(stream, token, runtime, expected_bytes, write)

        if received != expected_bytes:
            raise _Ended(Outcome("allocated", upload_incomplete()))
        if hasher.hexdigest() != row["expected_sha256"]:
            raise _Ended(Outcome("failed", upload_digest_mismatch()))

        handle, receipt.handle = receipt.handle, None
        await to_thread.run_sync(files.sync_close, handle)
        await to_thread.run_sync(files.rename, receipt.part, receipt.source)
        receipt.source_created = True
        await to_thread.run_sync(files.sync_dir, item_dir)
        receipt.committed = await _shielded(
            library.complete_upload_receipt,
            item_uuid,
            boot_id=runtime.boot_id,
            part_path=str(receipt.part),
            source_path=str(receipt.source),
            received_bytes=received,
            received_sha256=hasher.hexdigest(),
            reservation_id=receipt.reservation_id,
            settled_purpose=UPLOAD_SOURCE,
            now=receipt.stamp(),
        )
        if not receipt.committed:
            await _raise_if_lost(library, item_uuid, always=True)
    except Exception as exc:
        error = _error_for(receipt, exc)
        if error is None:
            raise  # a refusal before the claim, or a bug: unchanged
        raise error from None
    finally:
        await receipt.finish()
    return await _current_item(library, item_uuid)


# ── startup reconcile (spec §5 "On process restart reconcile receiving rows") ──


def _file_matches(path: Path, expected_bytes: int, expected_sha256: str) -> bool:
    """True only for a regular file of exactly the allocated length and digest,
    re-hashed in fixed blocks (a filename is never trusted)."""
    if not path.is_file() or path.stat().st_size != expected_bytes:
        return False
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        while block := handle.read(CHUNK_SIZE):
            digest.update(block)
    return digest.hexdigest() == expected_sha256


def reconcile_upload_receipts(
    database, uploads_root: Path, *, boot_id: str, files: ReceiptFiles | None = None
) -> int:
    """Startup, before any transfer: settle or release what dead transfers left.

    A receiving row of another boot advances to validating when its complete
    source exists with the allocated length and digest, else its partials are
    removed and it returns to allocated. A cancelled row's leftovers are
    removed. Every received file keeps its quota row only while its item still
    holds the file. Idempotent; one bad row never stops the rest; nothing
    outside an owner's own folder is touched. Returns how many changes were made."""
    files = files or ReceiptFiles()
    uploads_root = Path(uploads_root)
    now = int(time.time())
    advanced = returned = cleared = released = 0

    def remove_owned(recorded, owner) -> bool:
        """True when nothing owned remains at ``recorded``. A path outside the
        owner's folder is never touched, and is not ours to keep recorded."""
        if not recorded:
            return True
        path = Path(recorded)
        try:
            assert_within(path, owner_dir(uploads_root, owner))
        except Exception:
            return True
        return remove_verified(files, path)

    def return_dead(owner, item) -> bool:
        """Receiving -> allocated with ``upload_interrupted``; its in-flight quota
        row goes. Only once nothing of the transfer is left on disk."""
        error = upload_interrupted()
        return database.return_dead_upload_receipt(
            owner_id=owner, item_uuid=item, boot_id=boot_id,
            receive_purpose=UPLOAD_RECEIVE, error_code=error.code,
            error_message=error.message, now=now,
        )

    for row in database.list_upload_receipts_to_reconcile(boot_id=boot_id):
        try:
            folder = _item_dir(uploads_root, row["owner_id"], row)
            source = folder / "source"
            owner, item = row["owner_id"], row["item_uuid"]
            if row["state"] != "receiving":
                gone = remove_owned(row["part_path"], row["owner_id"])
                if row["source_path"] is None:
                    gone = remove_verified(files, source) and gone
                if gone:
                    database.clear_upload_part(owner_id=owner, item_uuid=item)
                    cleared += 1
                continue
            try:
                complete = _file_matches(source, row["expected_bytes"], row["expected_sha256"])
            except Exception as exc:
                # An unreadable source is not a trusted one; the row must not stall.
                logger.warning("upload source check failed (%s)", type(exc).__name__)
                complete = False
            part_gone = remove_owned(row["part_path"], row["owner_id"])
            if complete:
                advanced += database.advance_dead_upload_receipt(
                    owner_id=owner, item_uuid=item, boot_id=boot_id, source_path=str(source),
                    received_bytes=row["expected_bytes"], received_sha256=row["expected_sha256"],
                    receive_purpose=UPLOAD_RECEIVE, settled_purpose=UPLOAD_SOURCE, now=now,
                    keep_part=not part_gone,
                )
            elif part_gone and (back := remove_then_release(
                    files, source, lambda: return_dead(owner, item))) is not None:
                returned += back
            else:
                error = upload_cleanup_failed()
                database.fail_dead_upload_receipt(
                    owner_id=owner, item_uuid=item, boot_id=boot_id,
                    error_code=error.code, error_message=error.message, now=now,
                )
        except Exception as exc:
            logger.warning("upload receipt reconcile of one row failed (%s)", type(exc).__name__)

    for reservation in database.list_upload_source_reservations(purpose=UPLOAD_SOURCE):
        try:
            source_path = reservation["source_path"]
            if reservation["state"] in SOURCE_GIVEN_BACK_STATES and source_path is not None:
                # An ended item that still records its source (a removal failed):
                # the bytes stay counted until the file is verifiably gone.
                try:
                    os.lstat(source_path)
                    keep = True
                except FileNotFoundError:
                    keep = False
                except OSError:
                    keep = True  # cannot be inspected: stays counted
            else:
                keep = (
                    reservation["state"] is not None
                    and reservation["state"] not in SOURCE_GIVEN_BACK_STATES
                    and source_path is not None
                )
                if keep:
                    assert_within(Path(source_path), owner_dir(uploads_root, reservation["owner_id"]))
                    keep = Path(source_path).is_file()
        except Exception:
            keep = False
        if not keep:
            released += bool(database.release_storage(reservation["id"]))

    total = advanced + returned + cleared + released
    if total:
        operator_logger.info(
            "upload receipts reconciled: %d advanced, %d returned, %d cleared, %d reservations released",
            advanced, returned, cleared, released,
        )
    return total
