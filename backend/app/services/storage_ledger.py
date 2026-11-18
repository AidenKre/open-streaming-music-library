"""SC-16g storage reservation ledger (7A.2a).

A reservation is admitted only while the library filesystem's free space,
minus every live reservation, minus the configured floor, still covers it.
Free space is read inside the database's write transaction. Unknown free
space is refused. Errors carry a stable code and numbers, never a path.

A purpose may be *on disk*: its bytes already exist on the filesystem, so they
count toward the staged quotas (if the purpose is staged) but are not
subtracted from free space a second time. ``settle`` turns a live reservation
into such a durable, unleased row once its bytes have landed.

A staged purpose is *quota gated* by default: its admission is checked against
the staged quotas. A purpose can be counted in the staged totals without being
gated (``quota_gated=False``); it is then admitted against the free-disk floor
only.
"""

import logging
from dataclasses import dataclass
import shutil

from app.core.operator_log import operator_logger
from app.database.database import StorageTotals, _require_owner

logger = logging.getLogger(__name__)

CONVERSION = "conversion"
UPLOAD_RECEIVE = "upload_receive"
UPLOAD_SOURCE = "upload_source"
UPLOAD_WORK_RESERVE = "upload_work_reserve"
UPLOAD_WORK = "upload_work"
UPLOAD_EXPAND = "upload_expand"
IMPORT_UNPACK = "import_unpack"


@dataclass(frozen=True)
class _Purpose:
    staged_quota: bool
    on_disk: bool
    quota_gated: bool


_PURPOSES: dict[str, _Purpose] = {}


def register_purpose(name, *, staged_quota: bool = False, on_disk: bool = False,
                     quota_gated=None) -> None:
    if not isinstance(name, str) or not name:
        raise ValueError("purpose name must be a non-empty str")
    if not isinstance(staged_quota, bool):
        raise ValueError("staged_quota must be a bool")
    if not isinstance(on_disk, bool):
        raise ValueError("on_disk must be a bool")
    if quota_gated is None:
        quota_gated = staged_quota
    if not isinstance(quota_gated, bool):
        raise ValueError("quota_gated must be a bool")
    if quota_gated and not staged_quota:
        raise ValueError("quota_gated needs staged_quota")
    purpose = _Purpose(staged_quota, on_disk, quota_gated)
    if _PURPOSES.setdefault(name, purpose) != purpose:
        raise ValueError(f"purpose {name!r} is already registered differently")


register_purpose(CONVERSION, staged_quota=False)
register_purpose(UPLOAD_RECEIVE, staged_quota=True)
register_purpose(UPLOAD_SOURCE, staged_quota=True, on_disk=True)
# Counted, not gated: a commit converts bytes the quota already accepted (the
# source) and releases the source when it publishes, so the quota never refuses it.
register_purpose(UPLOAD_WORK_RESERVE, staged_quota=True, quota_gated=False)
register_purpose(UPLOAD_WORK, staged_quota=True, on_disk=True)
register_purpose(UPLOAD_EXPAND, staged_quota=True)
# Free-disk floor only: an import-folder file is never refused for a user's storage limit.
register_purpose(IMPORT_UNPACK, staged_quota=False)


@dataclass(frozen=True)
class StagedQuota:
    user_bytes: int
    total_bytes: int


class InsufficientStorage(Exception):
    def __init__(self, code, message, *, needed, available, limit=None):
        super().__init__(message)
        self.code = code
        self.message = message
        self.needed = needed
        self.available = available
        self.limit = limit


class StorageLedger:
    def __init__(self, database, *, path, floor_bytes, boot_id, disk_usage=shutil.disk_usage):
        if not isinstance(boot_id, str) or not boot_id:
            # A NULL lease would look durable and never be reconciled.
            raise ValueError("boot_id must be a non-empty str")
        self._database = database
        self._path = path
        self._floor = floor_bytes
        self._boot_id = boot_id
        self._disk_usage = disk_usage

    def _validate(self, owner_id, purpose, nbytes):
        _require_owner(owner_id)
        if purpose not in _PURPOSES:
            raise ValueError("storage purpose is not registered")
        if isinstance(nbytes, bool) or not isinstance(nbytes, int):
            raise TypeError("nbytes must be an int")
        if nbytes < 0:
            raise ValueError("nbytes must be >= 0")

    def _effective_quota(self, owner_id, purpose, nbytes, quota):
        """Validate, then return the quota that applies (None for a non-staged purpose)."""
        self._validate(owner_id, purpose, nbytes)
        if not _PURPOSES[purpose].staged_quota:
            return None
        if not isinstance(quota, StagedQuota):
            raise ValueError("a staged-quota purpose needs a StagedQuota")
        return quota if _PURPOSES[purpose].quota_gated else None

    def _quota_purposes(self):
        return tuple(name for name, p in _PURPOSES.items() if p.staged_quota)

    def _on_disk_purposes(self):
        return tuple(name for name, p in _PURPOSES.items() if p.on_disk)

    def _admitter(self, nbytes, quota=None):
        def admit(totals: StorageTotals) -> None:
            if quota is not None:
                # Only the caller's own numbers, and the shared total, are ever reported.
                for code, used, limit, noun in (
                    ("user_staged_quota_exceeded", totals.user_staged, quota.user_bytes, "Your"),
                    ("staged_quota_exceeded", totals.staged, quota.total_bytes, "The server's"),
                ):
                    if used + nbytes > limit:
                        left = max(0, limit - used)
                        raise InsufficientStorage(
                            code,
                            f"{noun} staged upload quota is exceeded: {nbytes} bytes needed, "
                            f"{left} available of {limit}.",
                            needed=nbytes,
                            available=left,
                            limit=limit,
                        )
            try:
                free = self._disk_usage(self._path).free
            except OSError as exc:
                logger.warning("storage free space unreadable (%s)", type(exc).__name__)
                raise InsufficientStorage(
                    "free_space_unknown",
                    "Free disk space could not be determined.",
                    needed=nbytes,
                    available=None,
                ) from None
            headroom = free - totals.reserved - self._floor
            available = max(0, headroom)
            # Below the floor nothing is admitted, not even an empty reservation.
            if headroom < 0 or nbytes > available:
                raise InsufficientStorage(
                    "insufficient_storage",
                    f"Not enough free disk space: {nbytes} bytes needed.",
                    needed=nbytes,
                    available=available,
                )

        return admit

    def reserve(self, *, owner_id, purpose, nbytes, subject_ref=None, quota=None) -> int:
        quota = self._effective_quota(owner_id, purpose, nbytes, quota)
        return self._database.reserve_storage(
            owner_id=owner_id,
            purpose=purpose,
            nbytes=nbytes,
            subject_ref=subject_ref,
            lease_boot_id=self._boot_id,
            quota_purposes=self._quota_purposes(),
            on_disk_purposes=self._on_disk_purposes(),
            admit=self._admitter(nbytes, quota),
        )

    def check(self, *, owner_id, purpose, nbytes, quota=None) -> None:
        quota = self._effective_quota(owner_id, purpose, nbytes, quota)
        totals = self._database.storage_totals(
            owner_id=owner_id,
            quota_purposes=self._quota_purposes(),
            on_disk_purposes=self._on_disk_purposes(),
        )
        self._admitter(nbytes, quota)(totals)

    def settle(self, reservation_id, *, purpose) -> bool:
        """Turn a reservation into a durable row of the on-disk ``purpose`` (no lease)."""
        if not _PURPOSES.get(purpose, _Purpose(False, False, False)).on_disk:
            raise ValueError("settle needs a registered on-disk purpose")
        return self._database.settle_storage(reservation_id, purpose=purpose)

    def release(self, reservation_id) -> bool:
        return self._database.release_storage(reservation_id)

    def reconcile(self) -> int:
        """Startup: release every reservation leased by a previous server run."""
        released = self._database.release_storage_leases_except(self._boot_id)
        if released:
            operator_logger.info(
                "released %d storage reservations of a previous server run", released
            )
        return released
