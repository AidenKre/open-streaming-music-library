"""The bounded ZIP service for uploads (Phase 7 spec §5 "ZIP"): stdlib
``zipfile`` with streamed member reads, never ``extractall``/``extract``.
``inspect_archive`` vets every member before anything is extracted;
``copy_member`` streams one member with actual byte counters."""

import hashlib
import re
import stat
import struct
import unicodedata
import zipfile
import zlib
import errno
import logging
import time
from contextlib import nullcontext
from dataclasses import dataclass
from pathlib import Path

from app.core.media_types import ARCHIVE_EXTENSIONS, AUDIO_EXTENSIONS, OTHER_AUDIO_EXTENSIONS
from app.services import upload_errors as errors
from app.services.path_sanitize import assert_within
from app.services.storage_ledger import UPLOAD_EXPAND, UPLOAD_SOURCE, InsufficientStorage, StagedQuota
from app.services.upload_receipt import ReceiptFiles, _item_dir, discard_child_files, owner_dir, remove_verified
from app.services.upload_validation import ValidationFailed, ValidationInterrupted

log = logging.getLogger(__name__)

CENTRAL_DIRECTORY_BYTES_PER_MEMBER = 4096
_DRIVE = re.compile(r"^[A-Za-z]:")

# Read errors that can pass (an I/O error, no free file descriptor, no memory):
# they say nothing about the archive, so they are a retryable failure, never a refusal.
_TRANSIENT_READ_ERRNOS = frozenset({errno.EIO, errno.EMFILE, errno.ENFILE, errno.ENOMEM, errno.EAGAIN})


def is_transient_read_error(exc) -> bool:
    """True for an error carrying one of those errnos: an OSError, libarchive's
    ArchiveError (it carries errno too), or a BadZipFile zipfile raised over one."""
    return any(getattr(e, "errno", None) in _TRANSIENT_READ_ERRNOS
               for e in (exc, getattr(exc, "__context__", None)) if e is not None)


@dataclass(frozen=True)
class Member:
    index: int             # position in zipfile.ZipFile.infolist() (tar/RAR: entry ordinal)
    name: str              # normalized member name, e.g. "disc1/01.flac" (display + order key)
    declared_bytes: int    # ZipInfo.file_size (tar/RAR: the header's size)
    compressed_bytes: int  # ZipInfo.compress_size (tar/RAR: the archive file's size)


@dataclass(frozen=True)
class ArchivePlan:
    members: tuple[Member, ...]   # audio candidates only, in central-directory (infolist) / entry order
    skipped: int                  # non-audio regular files (ignored, counted)
    other_audio: int = 0          # of those, audio the server does not import (is_other_audio)


def inspect_archive(path, limits, *, audio_used: int = 0, expanded_used: int = 0) -> ArchivePlan:
    """``path`` is a path, or a binary file already open (it is read, not closed).
    The central directory read before parsing is bounded per allowed member:
    the limits' own bound if they carry one (import folders), else 4 KiB."""
    cap = limits.max_archive_members
    cd_bytes_per_member = getattr(limits, "central_directory_bytes_per_member",
                                  CENTRAL_DIRECTORY_BYTES_PER_MEMBER)
    try:
        with nullcontext(path) if hasattr(path, "read") else open(path, "rb") as fp:
            fp.seek(0)
            # Private helper, but it bounds ZipFile's in-memory parse of the central directory before it happens.
            endrec = zipfile._EndRecData(fp)
            if endrec is None:
                raise ValidationFailed(errors.upload_archive_invalid())
            if (endrec[zipfile._ECD_ENTRIES_TOTAL] > cap
                    or endrec[zipfile._ECD_SIZE] > cap * cd_bytes_per_member):
                raise ValidationFailed(errors.upload_archive_too_many_members())
            fp.seek(0)
            with zipfile.ZipFile(fp) as zf:
                infos = zf.infolist()
    except (zipfile.BadZipFile, zipfile.LargeZipFile, EOFError, OSError, ValueError,
            struct.error, UnicodeDecodeError) as exc:
        if is_transient_read_error(exc):
            raise ValidationFailed(errors.upload_validation_failed()) from None
        raise ValidationFailed(errors.upload_archive_invalid()) from None
    if len(infos) > cap:
        raise ValidationFailed(errors.upload_archive_too_many_members())

    seen: set[str] = set()
    candidates: list[Member] = []
    skipped = other_audio = 0
    for index, info in enumerate(infos):
        mode = info.external_attr >> 16
        kind = stat.S_IFMT(mode) if mode else 0
        is_dir = info.is_dir() or kind == stat.S_IFDIR
        name = check_member(info.filename, is_dir=is_dir, declared=info.file_size,
                            compressed=info.compress_size, limits=limits, seen=seen,
                            refused=_zip_refusal(info, kind))
        if name is None:
            if not is_dir:
                skipped += 1
                other_audio += is_other_audio(info.filename)
            continue
        candidates.append(Member(index, name, info.file_size, info.compress_size))

    check_batch_totals(candidates, limits, audio_used=audio_used, expanded_used=expanded_used)
    return ArchivePlan(tuple(candidates), skipped, other_audio)


def _zip_refusal(info, kind):
    """The ZIP-only reasons to refuse a member (an UploadError), or None."""
    if kind and kind not in (stat.S_IFREG, stat.S_IFDIR):
        return errors.upload_archive_unsafe_member()
    if info.flag_bits & 0x41:
        return errors.upload_archive_encrypted()
    if info.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED):
        return errors.upload_archive_unsupported_compression()
    return None


def check_member(name: str, *, is_dir: bool, declared: int, compressed: int | None, limits,
                 seen: set[str], refused=None) -> str | None:
    """The per-member rules every archive format shares (one inspection for
    uploads and import folders, sign-off DEV-7-14). Raises ``ValidationFailed``
    for an unsafe path, a case-insensitive duplicate (``seen`` collects the
    folded names), a nested archive, or an audio member over the size or
    ratio caps (a cap of None: no cap). Returns the normalized name of an audio candidate, or None for
    a directory or a skipped entry (the caller counts the skipped ones).

    ``refused`` is the format's own refusal for this entry (an UploadError),
    raised after the path checks so every format reports in the same order.
    ``compressed`` is None when the format has no per-entry compressed size;
    its caller then checks the ratio for the whole archive."""
    name = name.replace("\\", "/")
    parts = name.split("/")
    if name.startswith("/") or _DRIVE.match(name) or ".." in parts:
        raise ValidationFailed(errors.upload_archive_unsafe_path())
    parts = [p for p in parts if p not in ("", ".")]
    normalized = unicodedata.normalize("NFC", "/".join(parts))
    folded = normalized.casefold()
    if folded in seen:
        raise ValidationFailed(errors.upload_archive_duplicate_names())
    seen.add(folded)
    if refused is not None:
        raise ValidationFailed(refused)
    lower = name.lower()
    if any(lower.endswith(ext) for ext in ARCHIVE_EXTENSIONS):
        raise ValidationFailed(errors.upload_archive_nested())
    if is_dir:
        return None
    suffix, helper = _suffix_and_helper(parts)
    if helper or suffix not in AUDIO_EXTENSIONS:
        return None
    if limits.max_expanded_member_bytes is not None and declared > limits.max_expanded_member_bytes:
        raise ValidationFailed(errors.upload_archive_member_too_large())
    if compressed is not None and declared > limits.max_compression_ratio * max(compressed, 1):
        raise ValidationFailed(errors.upload_archive_ratio_exceeded())
    return normalized


def _suffix_and_helper(parts: list[str]) -> tuple[str, bool]:
    """The entry's lower-cased suffix, and whether it is a macOS helper
    (under ``__MACOSX/`` or named ``._*``), from its non-empty path parts."""
    base = parts[-1] if parts else ""
    suffix = "." + base.rsplit(".", 1)[1].lower() if "." in base else ""
    return suffix, bool(parts and parts[0] == "__MACOSX") or base.startswith("._")


def is_other_audio(name: str) -> bool:
    """A skipped regular entry holding audio the server does not import (not
    a macOS helper): an import-folder archive holding one is never deleted."""
    parts = [p for p in name.replace("\\", "/").split("/") if p not in ("", ".")]
    suffix, helper = _suffix_and_helper(parts)
    return not helper and suffix in OTHER_AUDIO_EXTENSIONS


def check_batch_totals(candidates, limits, *, audio_used: int = 0, expanded_used: int = 0) -> None:
    """The batch caps over an archive's audio candidates plus what the batch
    already holds: their count, then their declared bytes. A cap of None
    (import-folder archives) is no cap."""
    audio_cap, bytes_cap = limits.max_audio_items_per_batch, limits.max_expanded_bytes_per_batch
    if audio_cap is not None and audio_used + len(candidates) > audio_cap:
        raise ValidationFailed(errors.upload_archive_too_many_audio())
    if bytes_cap is not None and expanded_used + sum(m.declared_bytes for m in candidates) > bytes_cap:
        raise ValidationFailed(errors.upload_archive_expanded_too_large())


def copy_member(read, write, *, compressed_bytes: int, member_cap: int, budget_left: int,
                ratio: int, chunk_size: int, between=None) -> tuple[int, str]:
    digest = hashlib.sha256()
    total = 0
    while True:
        if between is not None:
            between()
        try:
            block = read(chunk_size)
        except (zipfile.BadZipFile, zlib.error, EOFError):
            raise ValidationFailed(errors.upload_archive_corrupt()) from None
        if not block:
            return total, digest.hexdigest()
        total += len(block)
        if total > member_cap:
            raise ValidationFailed(errors.upload_archive_member_too_large())
        if total > budget_left:
            raise ValidationFailed(errors.upload_archive_expanded_too_large())
        if total > ratio * max(compressed_bytes, 1):
            raise ValidationFailed(errors.upload_archive_ratio_exceeded())
        digest.update(block)
        write(block)


def _staging_error(exc):
    """The typed error for a failure while staging members, else ``exc`` itself."""
    if isinstance(exc, (zipfile.BadZipFile, zlib.error, EOFError)):
        return ValidationFailed(errors.upload_archive_corrupt())
    if isinstance(exc, OSError):
        full = exc.errno in (errno.ENOSPC, errno.EDQUOT)
        return ValidationFailed(errors.upload_disk_full() if full else errors.upload_write_failed())
    return exc


class ZipExpander:
    """The validation worker's zip_handler: expands a received ZIP into
    ordered child items (spec §5), one opaque staged file per audio member."""

    def __init__(self, database, *, uploads_root, boot_id, ledger, limits, files=None,
                 clock=time.time, chunk_size=1024 * 1024):
        self._database = database
        self._root = uploads_root
        self._boot_id = boot_id
        self._ledger = ledger
        self._limits = limits
        self._files = files or ReceiptFiles()
        self._clock = clock
        self._chunk_size = chunk_size

    def __call__(self, claimed, *, token, stopping) -> str:
        owner, parent = claimed["owner_id"], claimed["item_uuid"]
        if claimed["parent_item_uuid"] is not None:
            raise ValidationFailed(errors.upload_archive_nested())  # a child is never expanded
        limits = self._limits()
        reservation = None
        try:
            path = Path(claimed["source_path"])
            assert_within(path, owner_dir(self._root, owner))
            count, used = self._database.upload_child_usage(
                owner_id=owner, batch_uuid=claimed["batch_uuid"], parent_item_uuid=parent)
            plan = inspect_archive(path, limits, audio_used=count, expanded_used=used)
            try:
                reservation = self._ledger.reserve(
                    owner_id=owner, purpose=UPLOAD_EXPAND,
                    nbytes=sum(m.declared_bytes for m in plan.members), subject_ref=parent,
                    quota=StagedQuota(user_bytes=limits.user_staged_quota_bytes,
                                      total_bytes=limits.staged_quota_bytes))
            except InsufficientStorage as exc:
                raise ValidationFailed(errors.upload_storage_refused(exc)) from None
            version = claimed["review_version"]
            children = self._database.ensure_upload_manifest(
                owner_id=owner, item_uuid=parent, boot_id=self._boot_id, review_version=version,
                members=[(m.name, m.declared_bytes) for m in plan.members],
                skipped=plan.skipped, now=int(self._clock()))
            if children is None:
                return "stale"
            by_name = {m.name: m for m in plan.members}
            if {c["member_order_key"] for c in children} != set(by_name) or len(children) != len(by_name):
                raise ValidationFailed(errors.upload_validation_failed())
            staged = self._stage(path, children, by_name, owner, limits, used, token, stopping)
            published = self._database.finish_upload_expansion(
                owner_id=owner, item_uuid=parent, boot_id=self._boot_id, review_version=version,
                staged=staged, reservation_id=reservation, source_purpose=UPLOAD_SOURCE,
                now=int(self._clock()))
            if published is False:
                # The children were never published: their files must not outlive the step.
                self._discard_children(owner, children)
                return "stale"
            try:  # past the flip nothing may reach the failure handler (it would discard published files)
                # A child cancelled while it was being staged is not published; its file goes.
                self._discard_children(owner, [c for c in children if c["item_uuid"] not in published])
                if remove_verified(self._files, path):
                    self._database.release_cancelled_upload_source(
                        parent, owner_id=owner, source_path=str(path),
                        now=int(self._clock()), from_states=("expanded",))
            except Exception as e:
                log.warning("expanded archive not released: %s", type(e).__name__)
            return "expanded"
        except Exception as exc:
            if stopping() and not token.cancelled:
                # A restart reuses the manifest and overwrites the files; record nothing.
                if isinstance(exc, ValidationInterrupted):
                    raise
                raise ValidationInterrupted() from exc
            try:
                self._discard_children(
                    owner, self._database.list_upload_children(owner_id=owner, item_uuid=parent))
            except Exception as e:  # never mask the original failure
                log.warning("archive child files not discarded: %s", type(e).__name__)
            mapped = _staging_error(exc)
            if mapped is exc:
                raise
            raise mapped from None
        finally:
            if reservation is not None:
                self._ledger.release(reservation)

    def _discard_children(self, owner, children):
        for child in children:
            discard_child_files(self._files, self._root, owner, child)

    def _stage(self, path, children, by_name, owner, limits, used, token, stopping):
        def between():
            if token.cancelled or stopping():
                raise ValidationInterrupted()

        files, staged, written = self._files, [], 0
        with zipfile.ZipFile(path) as zf:
            infos = zf.infolist()
            for child in children:
                if child["state"] != "validating":
                    discard_child_files(files, self._root, owner, child)  # cancelled since the last run
                    continue
                member = by_name[child["member_order_key"]]
                folder = _item_dir(self._root, owner, child)
                files.make_dir(folder)
                part = folder / "source.part"
                files.remove(part)
                handle = files.open_part(part)
                try:
                    with zf.open(infos[member.index]) as src:
                        total, digest = copy_member(
                            src.read, lambda b: files.write_block(handle, b),
                            compressed_bytes=member.compressed_bytes,
                            member_cap=limits.max_expanded_member_bytes,
                            budget_left=limits.max_expanded_bytes_per_batch - used - written,
                            ratio=limits.max_compression_ratio, chunk_size=self._chunk_size,
                            between=between)
                    files.sync_close(handle)
                except BaseException:
                    files.close(handle)
                    raise
                files.rename(part, folder / "source")
                files.sync_dir(folder)
                written += total
                staged.append((child["item_uuid"], str(folder / "source"), total, digest))
        return staged


def reconcile_expanded_archives(database, uploads_root) -> int:
    """ZIP startup cleanup: remove leftover archives of expanded parents and
    fixed-name files of cancelled or failed children. Idempotent; a failing
    row is logged by type and skipped. Returns how many archives were released."""
    files, released = ReceiptFiles(), 0
    for row in database.list_expanded_upload_archives():
        try:
            path = Path(row["source_path"])
            assert_within(path, owner_dir(uploads_root, row["owner_id"]))
            if remove_verified(files, path) and database.release_cancelled_upload_source(
                    row["item_uuid"], owner_id=row["owner_id"], source_path=row["source_path"],
                    now=int(time.time()), from_states=("expanded",)):
                released += 1
        except Exception as e:
            log.warning("expanded archive not released: %s", type(e).__name__)
    for row in database.list_ended_upload_children():
        try:
            discard_child_files(files, uploads_root, row["owner_id"], row)
        except Exception as e:
            log.warning("ended child files not removed: %s", type(e).__name__)
    return released
