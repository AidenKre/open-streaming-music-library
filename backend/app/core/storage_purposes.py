"""The names of the storage ledger's purposes (``storage_reservations.purpose``).

A leaf: it imports nothing from the app, so the database names a purpose at
its top. What each purpose means for the quotas (staged, on disk, gated) is
registered in ``app/services/storage_ledger.py``, which also offers these
names to its importers.
"""

CONVERSION = "conversion"
UPLOAD_RECEIVE = "upload_receive"
UPLOAD_SOURCE = "upload_source"
UPLOAD_WORK_RESERVE = "upload_work_reserve"
UPLOAD_WORK = "upload_work"
UPLOAD_EXPAND = "upload_expand"
IMPORT_UNPACK = "import_unpack"
