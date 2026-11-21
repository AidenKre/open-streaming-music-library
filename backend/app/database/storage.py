"""The storage reservation ledger's rows.

One part of ``Database`` (``app/database/database.py``). It imports the shared
core and never another part.
"""

from dataclasses import dataclass

from app.core.owner import _require_owner
from app.database.core import DatabaseCore


@dataclass(frozen=True)
class StorageTotals:
    """Bytes held by the storage ledger: all rows, staged purposes, and one owner's staged."""

    reserved: int
    staged: int
    user_staged: int


class StoragePart(DatabaseCore):
    """The ``storage_reservations`` rows behind ``StorageLedger``: admit and
    reserve, totals, settle, release."""

    @staticmethod
    def _storage_totals_in(conn, owner_id: int, quota_purposes, on_disk_purposes) -> StorageTotals:
        """``reserved`` leaves out on-disk purposes: their bytes are already off the free count."""

        def in_list(column, purposes):
            return f"{column} IN ({','.join('?' * len(purposes))})" if purposes else "0"

        quota = tuple(quota_purposes)
        on_disk = tuple(on_disk_purposes)
        in_staged = in_list("purpose", quota)
        row = conn.execute(
            f"SELECT COALESCE(SUM(CASE WHEN {in_list('purpose', on_disk)} THEN 0 ELSE bytes END), 0),"
            f" COALESCE(SUM(CASE WHEN {in_staged} THEN bytes ELSE 0 END), 0),"
            f" COALESCE(SUM(CASE WHEN {in_staged} AND owner_id = ? THEN bytes ELSE 0 END), 0)"
            " FROM storage_reservations",
            (*on_disk, *quota, *quota, owner_id),
        ).fetchone()
        return StorageTotals(reserved=row[0], staged=row[1], user_staged=row[2])

    def reserve_storage(
        self,
        *,
        owner_id,
        purpose,
        nbytes,
        subject_ref,
        lease_boot_id,
        quota_purposes,
        on_disk_purposes,
        admit,
    ) -> int:
        """Admit and insert one reservation inside a single write transaction.

        ``admit(totals)`` runs under the write lock and raises to refuse; a
        refusal rolls back, so no row is stored.
        """
        owner = _require_owner(owner_id)
        with self._connection(commit=True, immediate=True) as conn:
            admit(self._storage_totals_in(conn, owner, quota_purposes, on_disk_purposes))
            cursor = conn.execute(
                "INSERT INTO storage_reservations"
                " (owner_id, purpose, subject_ref, bytes, lease_boot_id, created_at)"
                " VALUES (?, ?, ?, ?, ?, unixepoch())",
                (owner, purpose, subject_ref, nbytes, lease_boot_id),
            )
            return cursor.lastrowid

    def storage_totals(self, *, owner_id, quota_purposes, on_disk_purposes) -> StorageTotals:
        owner = _require_owner(owner_id)
        with self._connection() as conn:
            return self._storage_totals_in(conn, owner, quota_purposes, on_disk_purposes)

    def settle_storage(self, reservation_id: int, *, purpose: str) -> bool:
        with self._connection(commit=True, immediate=True) as conn:
            return self._settle_storage_in(conn, reservation_id, purpose=purpose)

    def release_storage_leases_except(self, boot_id: str) -> int:
        """Delete reservations leased by any boot other than ``boot_id``; unleased rows stay."""
        with self._connection(commit=True) as conn:
            cursor = conn.execute(
                "DELETE FROM storage_reservations"
                " WHERE lease_boot_id IS NOT NULL AND lease_boot_id <> ?",
                (boot_id,),
            )
            return cursor.rowcount

    def release_storage(self, reservation_id: int) -> bool:
        with self._connection(commit=True) as conn:
            cursor = conn.execute(
                "DELETE FROM storage_reservations WHERE id = ?", (reservation_id,)
            )
            return cursor.rowcount > 0
