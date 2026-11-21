"""Closed vocabularies of deletion jobs.

A leaf: it imports nothing from the app, so the database, the job runtime and
the models can all name these lists.
"""

# The states in which a deletion job item has ended (``deletion_job_items.status``).
DELETION_ITEM_TERMINAL_STATES = ("deleted", "already_deleted", "conflict", "busy", "failed")

# Closed vocabularies of the deletion job read model (plan O12): nothing outside
# these lists is ever echoed to a client.
ITEM_ERROR_CODES = (
    "not_found", "conflict", "busy", "path_rejected", "rename", "recovery_required",
    "internal_error",
)
ITEM_DETAIL_CODES = ("master_missing", "storage_cleanup_pending")
