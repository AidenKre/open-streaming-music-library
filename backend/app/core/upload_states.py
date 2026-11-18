"""Named sets of upload item states (``upload_items.state``). A leaf: imports
nothing from the app. Each set is checked against the schema's list of
allowed states (``tests/test_upload_states.py``); SQL binds the members as
placeholders, never as text."""

# Ended: no transfer, worker or import acts on the item again (the job
# registry's terminal states; the janitor's and retention's "ended").
ENDED_STATES: tuple[str, ...] = ("imported", "duplicate", "expanded", "expired", "cancelled")

# Ended states in which an item that still records a staged source gives it
# back: the janitor removes the file, and the start-up reconcile keeps its
# quota row only while the file is still on disk.
SOURCE_GIVEN_BACK_STATES: tuple[str, ...] = ("cancelled", "expired", "imported", "duplicate", "expanded")

# The states in which a removed staged source may be released
# (``Database.release_removed_upload_source``).
SOURCE_RELEASE_STATES: tuple[str, ...] = (
    "cancelled", "failed", "expanded", "imported", "duplicate", "expired",
)
