"""Phase M.0b inventory (SC-28 rule 3, spec §4.2, review M-U05).

- Every public ``Database`` method is classified. Owned methods take a
  required keyword-only ``owner_id`` (omitting it is a ``TypeError``), and a
  ``Library`` exposes exactly the owned set.
- ``ANY_OWNER`` appears only at the documented by-UUID worker sites.

A method added later must be classified here; an unclassified one fails.
"""

import ast
import inspect
from pathlib import Path

import pytest

from app.database import ANY_OWNER
from app.database.database import Database
from app.library import Library
from app.models import Track, TrackMetaData
from app.models.history import HistoryEvent

APP_DIR = Path(__file__).resolve().parents[1] / "app"

# Owned data: tracks, edits, delete, changes, tombstones, artists, albums,
# search, counts, history, jobs, journal, user settings (spec §4.2).
OWNED = {
    "add_track",
    "insert_conversion_job",
    "insert_journal_entry",
    "insert_history_events",
    "seed_user_setting",
    "get_tracks",
    "get_tracks_count",
    "get_track_by_uuid",
    "apply_track_metadata_edit",
    "get_track_file_path",
    # Journal recovery: is a path some track's master (ANY_OWNER from recovery).
    "track_path_in_use",
    # U05-B-01: the tracks (and stored exact hashes) whose master lies in one
    # library folder; the import's name-clash test (ANY_OWNER from make_pipeline).
    "track_identities_in_folder",
    # The admin tool's library check: the master paths of one owner's live tracks.
    "live_track_paths",
    "get_all_track_uuids",
    "get_changes",
    "get_artists",
    "get_artists_count",
    "get_albums",
    "get_albums_count",
    "get_search_results",
    "get_history_changes",
    "get_conversion_job",
    "list_conversion_jobs_with_status",
    "list_conversion_jobs",
    "mark_conversion_job_running",
    "mark_conversion_job_failed",
    "mark_conversion_job_cancelled",
    "complete_conversion_job",
    # A same-file conversion whose final swap was refused is taken back.
    "undo_inplace_conversion",
    # U06-B-06: a same-file conversion whose swap the next start finished or ended.
    "settle_swapped_conversion_job",
    "bump_track_revision",
    "refresh_track_audio_properties",
    "list_journal_entries",
    "has_journal_entry_for_uuid",
    "delete_journal_entry",
    "get_tracks_missing_cover_art",
    "update_track_cover_art_id",
    "get_user_setting",
    "set_user_setting",
    "filter_owned_track_uuids",
    "owns_cover_art",
    "get_owned_cover_art",  # U04-B-03: the /cover_art lookup, behind owns_cover_art
    "mark_audio_identity_stale",
    "write_conversion_identity",
    "get_audio_identity",
    # 6.5A.3: the candidate-store API for Phase 8 and L08 (no endpoint).
    "set_duplicate_candidate_status",
    "get_identity_coverage_summary",
    # 8A.4: the duplicates API's reads (spec §4).
    "list_duplicate_candidates",
    "count_duplicate_candidates",
    # 8A.3a: the reader-side pending-deletion predicate (open_track_source).
    "is_pending_deletion",
    # 7A.1d: the upload API (spec §4), reached only through the caller's Library.
    "allocate_upload_batch",
    "get_upload_batch",
    "list_upload_items",
    "get_upload_item",
    "list_upload_batches",
    # 7A.2b: the streamed receipt.
    "begin_upload_receipt",
    "complete_upload_receipt",
    "end_upload_receipt",
    "record_upload_progress",
    "cancel_upload_item",
    # 7A.2c: a cancel gives a validated source back.
    "get_upload_item_source_path",
    "release_removed_upload_source",
    "retry_upload_item",
    "accept_upload_commit",
    "resolve_upload_duplicate",
    "get_upload_preview",
    # 8A.2b: the deletion preview, jobs and receipts API (spec §4).
    "get_deletion_preview_facts",
    "create_deletion_job",
    "get_deletion_job",
    "list_deletion_jobs",
    # 9D.1b: the Last.fm connection and outbox rows behind the routes (spec §7.3, §7.4).
    "get_lastfm_connection",
    "store_lastfm_pending_token",
    "clear_lastfm_pending_token",
    "bind_lastfm_session",
    "enable_lastfm_scrobbling",
    "disconnect_lastfm",
    "get_lastfm_outbox_summary",
}

# Owned methods a Library does not offer: no request and no service acting for
# one owner calls them. Start-up recovery does, on the Database, naming the
# owner of the row it settles (``journal_settle``: a same-file conversion whose
# swap the start finished).
OWNED_NOT_ON_A_LIBRARY = {"bump_track_revision"}

# Server-wide: no owner (spec §4.2 "Server-wide methods") plus the users table.
SERVER_WIDE = {
    "initialize",
    "require_current_schema",
    "get_master_admin",
    "create_master_admin",
    "rename_user",
    "set_password_hash",
    "get_live_session",
    "get_live_session_by_media_hash",
    "revoke_auth_session",
    "register_user",
    "get_user_by_username_key",
    "start_login_session",
    "set_password_hash_and_revoke_sessions",
    "get_user",
    "get_library_folders",
    "list_user_folders",  # M.2a: the import dispatcher and startup scans
    "get_deleting_user_ids",  # review r1 m-R1-09: startup workers skip them
    "get_cover_art_by_id",
    "get_cover_art_by_sha256",
    "get_cover_arts_by_phash_prefix",
    "insert_cover_art",
    "get_server_instance_id",
    "get_setting",
    "read_setting",
    "set_setting",
    # The durable point: a checkpoint and flush of the whole database file, reading
    # and returning no rows of any owner. Callers: the deletion executor's flush and
    # janitor pass, the moving edit and conversion writers, their runtime finish,
    # and startup journal recovery (sign-off OPEN-6.5-05, decision D12).
    "make_durable",
    # The server's one idle connection, opened at
    # start-up and closed at shutdown. They read and return no rows of any owner.
    "hold_open",
    "close",
}

# Global cover-art release (SC-16h): deletes a cover_arts row only when no
# owner's trackmetadata references it, so it takes ``owner_id=ANY_OWNER`` and
# nothing else. Its one caller is ``CoverArtManager.release_if_unreferenced``.
COVER_ART_RELEASE = {"delete_cover_art"}

# The offline admin CLI (M.2b, spec §6.4): user-lifecycle operations keyed by
# the user id, spanning that user's rows by design. Only ``app/cli.py`` and the
# user-delete service call them; no route does.
USER_ADMIN = {
    "list_users",
    "set_user_disabled",
    "mark_user_deleting",
    "purge_user_rows",
    "list_user_track_uuids_for_delete",
    "get_cover_art_file_paths",
    "delete_user_row",
}

# The audio-identity worker (6.5A.2d, SC-25/SC-28 rule 3): its queue and
# subject reads span owners (``owner_id=ANY_OWNER`` only); its CAS write
# names the owner it read from the row (a real id, never ANY_OWNER).
IDENTITY_WORKER = {
    "next_identity_work",
    "get_identity_subject",
    "update_identity_if_unchanged",
    # 6.5A.3: the matching step's candidate-store write (names the row's owner).
    "store_duplicate_candidates",
    "find_duplicates_for_track",
    # 6.5B.2b: the matching step's read of the subject's stored print (the row's owner).
    "get_identity_fingerprint",
}

# The startup identity reconcile (6.5A.2d, spec §6.4): server-wide
# maintenance over every owner's identity rows, like the journal reconcile,
# so it takes ``owner_id=ANY_OWNER`` only.
IDENTITY_RECONCILE = {
    "insert_missing_identity_rows",
    "reset_failed_identity_rows",
    "list_master_missing_identity",
    "reset_master_missing_identity",
    # 6.5A.3: the startup matcher_version re-match.
    "requeue_matching",
    # The startup reclassification of stored prints after a class-setting change.
    "reclassify_fingerprints",
    # 6.5B.1b: the fingerprint transitions (tool appears/disappears, new algorithm).
    "set_fingerprint_availability",
    "requeue_fingerprint_algorithm",
    # 6-5-L-03 live fix: prints that gave up for an unknown duration, once per duration rule.
    "requeue_unknown_duration_prints",
}

# The SC-16g storage ledger (7A.2a): free space and the staged quota are
# server-wide, so a reservation reads every owner's reserved bytes; the new
# row names a real owner, and a release is by the ledger's own id.
STORAGE_LEDGER = {
    "reserve_storage",
    "release_storage",
    "storage_totals",
    # The startup reconcile: releases every lease of another (dead) boot id.
    "release_storage_leases_except",
    # 7A.2b: a received upload's row becomes a durable on-disk row.
    "settle_storage",
}

# The startup upload-receipt reconcile (7A.2b, spec §5 "On process restart
# reconcile receiving rows"): server-wide maintenance over every owner's dead
# receipts and received files' quota rows; each write names the owner it read
# from the row. Only ``reconcile_upload_receipts`` calls them; no route does.
UPLOAD_RECEIPT_RECONCILE = {
    "list_upload_receipts_to_reconcile",
    "advance_dead_upload_receipt",
    "return_dead_upload_receipt",
    "clear_upload_part",
    "list_upload_source_reservations",
    "fail_dead_upload_receipt",
}

# 7A.2c: the one validation worker (spec §5 "Duplicate check"), server-wide
# like the identity worker: it claims any owner's validating item by boot id
# and every write names the owner read from the claimed row.
UPLOAD_VALIDATION_WORKER = {
    "claim_upload_validation",
    "finish_upload_validation",
    "fail_upload_validation",
    "release_upload_validation_lease",
    "reconcile_upload_validation",
    # 7A.2d: the ZIP expansion run by the same worker (owner from the claimed row).
    "upload_child_usage",
    "ensure_upload_manifest",
    "finish_upload_expansion",
    "list_upload_children",
    # 7A.2d review r1: the ZIP startup cleanup (server-wide, owner from each row).
    "list_expanded_upload_archives",
    "list_ended_upload_children",
}

# 7A.3a: the commit worker, server-wide like the validation worker: it claims
# any owner's accepted commit by boot id; every write names the claimed owner.
UPLOAD_COMMIT_WORKER = {
    "claim_upload_commit",
    "prepare_upload_commit",
    "release_upload_commit_lease",
    "record_upload_commit_art",
    "fail_upload_commit",
    "upload_commit_preflight",
    "mark_upload_commit_moved",
    "publish_upload_commit",
    "record_upload_commit_conflict",
    "release_upload_work",
    "fail_upload_publish",
    "record_upload_publish_art",
    # 7A.3c: the startup journal step (server-wide, owner from each row).
    "list_upload_commit_journals_to_resume",
    "list_finished_upload_commit_journals",
    "delete_finished_upload_commit_journal",
    # 7A.3c: the expiry janitor (server-wide lists; each write names the row's owner).
    "list_expirable_upload_items",
    "expire_upload_item",
    "list_ended_upload_items",
    "count_live_upload_items",
    # 7A.3c: 30-day retention (server-wide candidates; the prune names the owner).
    "list_upload_batches_for_retention",
    "prune_upload_batch",
    # 7A.3c: startup adoption of unjournaled commit art (7A.3a review #2).
    "adopt_upload_commit_art",
    # A commit re-run keeps its earlier art while another commit's journal names it.
    "upload_commit_art_named_elsewhere",
}

# 9D.1b: the offline operator purge (spec §7.11): every user's Last.fm rows at
# once, by design. Only ``app/cli.py`` (``lastfm purge``) calls it; no route does.
LASTFM_PURGE = {"purge_lastfm_data"}

# 9D.2b: the one scrobble sender (spec §7.8). Its due scan spans every owner
# by design (it decides whom to serve); every later read and write of a user's
# connection and rows names the owner read from that scan.
LASTFM_SENDER = {
    "list_due_lastfm_owners",
    "read_lastfm_batch",
    "settle_lastfm_rows",
    # The retention pass (spec §7.3, §7.8 step 1): server-wide by design.
    "prune_lastfm_outbox",
    # Answer rules (§7.9): each names the owner read from the due scan.
    "count_lastfm_try",
    "mark_lastfm_alone",
    "mark_lastfm_needs_reconnect",
    # 9D.2c: Now Playing re-reads the notice's owner and track inside the gate
    # (spec §7.10); it names the owner the notice was put for.
    "read_lastfm_now_playing",
}

# 8A.3c: the deletion worker, server-wide like the upload workers: it claims
# any owner's pending item by boot id; every later read and write names the
# owner read from the claimed row.
DELETION_WORKER = {
    "claim_next_deletion_item",
    "finish_deletion_item",
    "read_deletion_target",
    "begin_track_deletion",
    "mark_deletion_moved",
    "commit_track_deletion",
    "finish_deletion_cleanup",
    "clear_deletion_journal",
    # Fix round 1 (8-R1-01): the release rule reads the item's own journal
    # row and requeues the item, both by the claimed row's owner.
    "get_deletion_journal",
    "release_deletion_item",
    # OPEN-8-01 B (signoff-8-deletion-recovery): the executor's per-job flush
    # asks whether the claimed item's job (by the claimed row's owner) still
    # has a pending item; its one caller is DeletionExecutor.execute.
    "deletion_job_has_pending_items",
}

# 8A.3d: deletion startup recovery, job reclaim and the quarantine janitor
# (SC-16e): server-wide maintenance over every owner's deletion rows; every
# write names the owner read from the row.
DELETION_RECOVERY = {
    "reclaim_deletion_items",
    "list_deletion_journals",
    "mark_deletion_recovery_required",
}

# Spec §4.2: the only places that may skip the owner predicate, as
# (path under app/, enclosing function). The encoder's owner lookup arrives
# in M.2a. The M.2b CLI and user delete need none: they act on one user's id.
ANY_OWNER_SITES: set[tuple[str, str]] = {
    # 8A.3a (was main.py _resolve_track_source_path / _resolve_track_owner):
    # the background encoder's by-UUID read (prefetch owner, warm source),
    # answered only for a live track; the owner decides only the write tier.
    ("services/track_source.py", "_live_track_any_owner"),
    # The conversion worker: one by-id read of its job; the rest of the run
    # uses that job's owner.
    ("services/conversion.py", "ConversionOrchestrator._run_job"),
    ("services/conversion.py", "ConversionOrchestrator.resume_queued"),
    ("services/conversion.py", "reconcile_conversion_jobs"),
    ("services/journal_settle.py", "reconcile_journal"),
    # The idle identity worker finishing journal rows kept after a failed mark.
    ("services/journal_recovery.py", "finish_kept_journal_rows"),
    # Journal recovery: a master of any owner at new_path is not the row's own copy.
    ("services/journal_recovery.py", "_reconcile_relocate"),
    # Startup settle (sign-off OPEN-6.5-05): another track's master (any owner) is
    # never deleted, adopted or hashed; a leftover becomes a track only at a path
    # no track of any owner uses.
    ("services/journal_settle.py", "_Row.claimed"),
    ("services/journal_settle.py", "_Row._organizer"),
    # U06-B-06: a same-file conversion's swap never overwrites a file another track
    # (of any owner) names.
    ("services/journal_recovery.py", "_reconcile_inplace"),
    # The startup convert-journal eviction.
    ("main.py", "_interrupted_conversion_uuids"),
    ("services/cover_art_manager.py", "CoverArtManager.backfill_cover_art"),
    ("services/cover_art_manager.py", "CoverArtManager.release_if_unreferenced"),
    # 6.5A.2d: the identity worker's queue read and by-uuid subject read; its
    # CAS write names the owner read from the row.
    ("services/identity_worker.py", "AudioIdentityWorker._step"),
    ("services/identity_worker.py", "AudioIdentityWorker._after_exception"),
    ("services/identity_worker.py", "reconcile_audio_identity"),
    # U05-B-01: the import's name-clash test reads every owner's tracks in the
    # destination folder (like the publish move's master check below).
    ("services/pipeline.py", "make_pipeline"),
    # 7A.3b: the publish move refuses a final path that is any owner's master (D38).
    ("services/upload_publish.py", "UploadPublisher._move"),
    # 7A.3b: a conflict loser removes its own final file only when no track of any owner uses it.
    ("services/upload_publish.py", "UploadPublisher._remove_own_final"),
    # 7A.3c: a placed final file is removed only when no track of any owner names it.
    ("services/upload_recovery.py", "_remove_placed_final"),
    # Pre-merge B1-01: a deletion never moves or unlinks a file that another
    # track's row (of any owner) names; only the catalog entry goes.
    ("services/deletion_worker.py", "DeletionExecutor._delete_live"),
    # Pre-merge B1-01: a tag edit's move and a conversion to another file type
    # never give a track a path that another track's row (of any owner) names.
    ("services/master_replace.py", "move_to_new_path"),
    ("services/conversion.py", "ConversionOrchestrator._named_by_another_track"),
}


def _public_methods() -> set[str]:
    return {
        name
        for name, member in inspect.getmembers(Database)
        if not name.startswith("_") and callable(member)
    }


def test_every_public_database_method_is_classified():
    groups = [OWNED, SERVER_WIDE, COVER_ART_RELEASE, USER_ADMIN, IDENTITY_WORKER, IDENTITY_RECONCILE,
              STORAGE_LEDGER, UPLOAD_RECEIPT_RECONCILE, UPLOAD_VALIDATION_WORKER, UPLOAD_COMMIT_WORKER,
              LASTFM_PURGE, LASTFM_SENDER, DELETION_WORKER, DELETION_RECOVERY]
    assert sum(len(g) for g in groups) == len(set().union(*groups)), "overlapping groups"
    assert _public_methods() == set().union(*groups)


@pytest.mark.parametrize("name", sorted(OWNED))
def test_an_owned_method_takes_a_required_keyword_only_owner(name):
    parameter = inspect.signature(getattr(Database, name)).parameters["owner_id"]

    assert parameter.kind is inspect.Parameter.KEYWORD_ONLY
    assert parameter.default is inspect.Parameter.empty


@pytest.mark.parametrize("name", sorted(OWNED))
def test_calling_an_owned_method_without_an_owner_is_a_type_error(db, name):
    method = getattr(Database, name)
    required = [
        p for p in inspect.signature(method).parameters.values()
        if p.name != "self"
        and p.kind is inspect.Parameter.POSITIONAL_OR_KEYWORD
        and p.default is inspect.Parameter.empty
    ]

    with pytest.raises(TypeError, match="owner_id"):
        method(db, *[None] * len(required))


def test_a_library_exposes_exactly_the_owned_methods(db):
    """All of them but the ones named in ``OWNED_NOT_ON_A_LIBRARY``."""
    library = Library(db, db.owner_id)

    assert OWNED_NOT_ON_A_LIBRARY <= OWNED
    for name in OWNED - OWNED_NOT_ON_A_LIBRARY:
        assert callable(getattr(library, name)), name
    for name in (_public_methods() - OWNED) | OWNED_NOT_ON_A_LIBRARY:
        with pytest.raises(AttributeError):
            getattr(library, name)


def test_the_librarys_allow_list_names_only_methods_the_database_has():
    """A name left on the list after its method is gone would hide that."""
    from app.library import OWNED_METHODS

    assert OWNED_METHODS == OWNED - OWNED_NOT_ON_A_LIBRARY


def _track():
    return Track(
        file_path="/music/a.flac",
        metadata=TrackMetaData(title="a", artist="b", album="c", codec="flac", duration=1.0),
    )


def _event():
    return HistoryEvent(
        event_uuid="00000000-0000-4000-8000-000000000001",
        kind="listen",
        entity_type="track",
        entity_ref="t",
        occurred_at=1,
        seconds_played=1.0,
        track_length=2.0,
    )


@pytest.mark.parametrize(
    "call",
    [
        lambda db, owner: Database.add_track(db, _track(), owner_id=owner),
        lambda db, owner: Database.insert_conversion_job(
            db, "u", "aac", "m4a", 192, owner_id=owner
        ),
        lambda db, owner: Database.insert_journal_entry(db, "inplace", "u", owner_id=owner),
        lambda db, owner: Database.insert_history_events(db, [_event()], owner_id=owner),
        lambda db, owner: Database.seed_user_setting(db, owner_id=owner, key="k", value="v"),
    ],
    ids=["add_track", "insert_conversion_job", "insert_journal_entry",
         "insert_history_events", "seed_user_setting"],
)
@pytest.mark.parametrize("owner", [ANY_OWNER, None, True, "1"])
def test_an_owned_insert_needs_a_real_owner(db, call, owner):
    with pytest.raises(TypeError):
        call(db, owner)


@pytest.mark.parametrize(
    "call",
    [
        lambda db: Database.mark_conversion_job_running(db, 1, owner_id=ANY_OWNER),
        lambda db: Database.mark_conversion_job_failed(db, 1, "x", owner_id=ANY_OWNER),
        lambda db: Database.mark_conversion_job_cancelled(db, 1, owner_id=ANY_OWNER),
        lambda db: Database.complete_conversion_job(
            db, 1, "u", "aac", 1.0, 1, 1, owner_id=ANY_OWNER
        ),
        lambda db: Database.undo_inplace_conversion(
            db, 1, "u", 1, "x", codec="aac", bitrate_kbps=1.0, sample_rate_hz=1, channels=1,
            owner_id=ANY_OWNER,
        ),
        lambda db: Database.settle_swapped_conversion_job(db, 1, "u", owner_id=ANY_OWNER),
        lambda db: Database.bump_track_revision(db, "u", owner_id=ANY_OWNER),
        lambda db: Database.apply_track_metadata_edit(db, "u", {}, 1, owner_id=ANY_OWNER),
        lambda db: Database.update_track_cover_art_id(db, "u", 1, owner_id=ANY_OWNER),
        lambda db: Database.delete_journal_entry(db, 1, owner_id=ANY_OWNER),
        lambda db: Database.set_user_setting(db, "k", "v", owner_id=ANY_OWNER),
        lambda db: Database.refresh_track_audio_properties(
            db, "u", codec="flac", bitrate_kbps=1.0, sample_rate_hz=1, channels=1,
            duration=1.0, owner_id=ANY_OWNER,
        ),
    ],
    ids=["mark_running", "mark_failed", "mark_cancelled", "complete_job", "undo_swap", "settle_swap", "bump_revision", "edit",
         "update_cover_art", "delete_journal_entry", "set_user_setting",
         "refresh_audio"],
)
def test_an_owned_write_never_accepts_any_owner(db, call):
    """ANY_OWNER is for by-id reads in workers only; every write names its owner."""
    with pytest.raises(TypeError):
        call(db)


# Where ANY_OWNER is defined (the owner checks) and where the Database class
# applies it: not call sites.
OWNER_CHECK_FILES = {
    "core/owner.py",
    "database/database.py",
    "database/core.py",
    "database/schema.py",
    "database/users.py",
    "database/lastfm.py",
    "database/storage.py",
    "database/history.py",
    "database/uploads.py",
    "database/identity.py",
    "database/cover_art.py",
    "database/tracks.py",
    "database/deletion.py",
    "database/browse.py",
}


def _any_owner_sites() -> set[tuple[str, str]]:
    sites = set()
    for path in sorted(APP_DIR.rglob("*.py")):
        relative = path.relative_to(APP_DIR).as_posix()
        if relative in OWNER_CHECK_FILES or relative.endswith("__init__.py"):
            continue  # the definition, the class that applies it, a re-export
        tree = ast.parse(path.read_text())

        def visit(node, scope):
            for child in ast.iter_child_nodes(node):
                if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                    visit(child, f"{scope}.{child.name}" if scope else child.name)
                elif (
                    (isinstance(child, ast.Name) and child.id == "ANY_OWNER")
                    or (isinstance(child, ast.Attribute) and child.attr == "ANY_OWNER")
                ):
                    sites.add((relative, scope or "<module>"))
                elif isinstance(child, ast.alias) and child.name == "ANY_OWNER":
                    # An import under another name would hide later uses.
                    assert child.asname in (None, "ANY_OWNER"), (relative, child.asname)
                else:
                    visit(child, scope)

        visit(tree, "")
    return sites


def test_any_owner_appears_only_at_the_documented_sites():
    assert _any_owner_sites() == ANY_OWNER_SITES


# Where the Database itself is taken out of a Library (``unbound_database``:
# every owner's rows are within its reach), as (path under app/, enclosing
# function). Only the file operations that must look beyond the owner; never a
# route, and never a helper a route could hand its Library to for owned data.
UNBOUND_DATABASE_SITES: set[tuple[str, str]] = {
    # Where the property is defined.
    ("library.py", "Library.unbound_database"),
    # Runtime recovery of the track's kept journal rows: each row names its owner.
    ("services/journal_recovery.py", "finish_track_journal_rows"),
    # Whether a kept row of the track waits for the next start (its job, by the row's owner).
    ("services/journal_recovery.py", "swap_waits_for_start"),
    # The move of a master: no path another track's row (of any owner) names; the durable points.
    ("services/master_replace.py", "move_to_new_path"),
    ("services/master_replace.py", "settle_old_master"),
}


def _attribute_sites(*names: str) -> set[tuple[str, str]]:
    """Every (path under app/, enclosing function) that reads an attribute
    called one of ``names``, or mentions one in a ``getattr``-style string."""
    sites = set()
    for path in sorted(APP_DIR.rglob("*.py")):
        relative = path.relative_to(APP_DIR).as_posix()

        def visit(node, scope):
            for child in ast.iter_child_nodes(node):
                if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                    if isinstance(child, ast.FunctionDef) and child.name in names:
                        sites.add((relative, f"{scope}.{child.name}" if scope else child.name))
                    visit(child, f"{scope}.{child.name}" if scope else child.name)
                    continue
                if (isinstance(child, ast.Attribute) and child.attr in names) or (
                    isinstance(child, ast.Constant) and child.value in names
                ):
                    sites.add((relative, scope or "<module>"))
                visit(child, scope)

        visit(ast.parse(path.read_text()), "")
    return sites


def test_the_unbound_database_is_taken_from_a_library_only_at_the_documented_sites():
    """A Library binds every call to its owner; ``unbound_database`` is the one
    way around that. The route guard below reads only an endpoint's own source,
    so a helper could hand a request's Library on: this test reads every module
    of the server instead."""
    assert _attribute_sites("unbound_database") == UNBOUND_DATABASE_SITES


def test_nothing_outside_the_library_reads_its_private_database():
    assert {site for site in _attribute_sites("_db") if site[0] != "library.py"} == set()


# Routes that may read the raw Database: only server-wide facts.
# register, login: the users and auth_sessions tables (server-wide, spec §5.2),
# never owned data. logout, me (M.1b): the caller's own auth_sessions row and
# users row (server-wide), never owned data. (get_app_info reads the server
# identity cached at start-up, app.state.server_instance_id.)
DATABASE_ROUTES = {"register", "login", "logout", "me"}


def test_no_route_reaches_the_database_directly(configure_app):
    """SC-28 rule 3: "No endpoint calls owned Database methods directly." Every
    route reaches owned data through its ``Library``; the raw ``Database`` is
    read only by the routes listed above, for server-wide facts."""
    app = configure_app().app
    endpoints = {
        route.endpoint.__name__: route.endpoint
        for route in app.routes
        if getattr(route, "endpoint", None) is not None
        and getattr(route.endpoint, "__module__", "").startswith("app.")
    }
    assert {"get_tracks", "post_history", "get_jobs"} <= set(endpoints)

    reaching = {
        name for name, endpoint in endpoints.items()
        if "state.database" in inspect.getsource(endpoint)
    }

    assert reaching == DATABASE_ROUTES
