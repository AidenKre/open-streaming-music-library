import functools
import logging
import threading
import time
from uuid import uuid4
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI

from app.auth.passwords import prepare_dummy_hash
from app.bootstrap import bootstrap_master_admin
from app.config import ENV_FILE, settings
from app.services.lastfm_accounts import build_lastfm_accounts
from app.services.lastfm_outbox import (
    install_scrobble_outbox,
    uninstall_scrobble_outbox,
)
from app.services.lastfm_sender import ScrobbleSender
from app.services.lastfm_state import start_lastfm
from app.auth.middleware import AuthMiddleware
from app.core.access_log import install_access_log_redaction
from app.library import Library, library_root
from app.core.instance_lock import InstanceLockHeld, acquire_instance_lock
from app.core.operator_log import operator_logger
from app.core.internal_dirs import STAGING, UPLOADS, ensure_internal_dirs, is_or_inside as _is_or_inside
from app.services.user_delete import (
    RECORDED_ROOT_KEYS,
    DeletePaths,
    resume_user_deletes,
)
from app.database import (
    ANY_OWNER,
    Database,
    DatabaseContext,
    server_database,
)
from app.models import Track
from app.services.upload_limits import effective_upload_limits
from app.routers.auth import router as auth_router
from app.routers.catalog import router as catalog_router
from app.routers.streaming import router as streaming_router
from app.routers.app_info import router as app_info_router
from app.routers.tracks import router as tracks_router
from app.routers.jobs import router as jobs_router
from app.routers.history import router as history_router
from app.routers.lastfm import router as lastfm_router
from app.routers.deletions import router as deletions_router
from app.routers.duplicates import router as duplicates_router
from app.routers.uploads import router as uploads_router
from app.services.job_runtime import CancelTokens
from app.services.storage_ledger import StagedQuota, StorageLedger
from app.services import deletion_recovery
from app.services import upload_commit, upload_janitor, upload_publish, upload_recovery
from app.services import upload_receipt as upload_receipts
from app.services import upload_validation, upload_zip
from app.services import filesystem_check
from app.services.upload_receipt import ReceiptRuntime, TransferSlots
from app.services.track_edit import WriteMode
from app.services.conversion import (
    ConversionOrchestrator,
    reconcile_conversion_jobs,
)
from app.services.track_editor import (
    PendingOldMasters,
    TrackEditor,
    finish_kept_journal_rows,
    reconcile_journal,
)
from app.services.import_folders import (
    ImportDispatcher,
    ensure_user_import_folders,
)
from app.services.import_archive import import_archive_limits, sweep_workspace, upload_only_settings_notice
from app.services.ingestion import IMPORTED_DIR_NAME
from app.services.deletion_worker import DeletionExecutor, DeletionWorker
from app.services.encoded_cache import evict_track_caches
from app.services.pipeline import make_pipeline
from app.services.track_locks import TrackLocks
from app.services import (
    CoverArtContext,
    CoverArtManager,
    EncodedCache,
    EncodedCacheContext,
    EncoderCoordinator,
    FileWatcher,
    probe_available_encoders,
)
from app.services.ffmpeg_runner import FfmpegProcessRegistry, kill_orphaned_ffmpeg
from app.services import audio_identity
from app.services.track_source import (
    live_source_path,
    live_track_owner,
)
from app.services.fingerprinter import detect_fingerprinter
from app.services.startup_recovery import StartupStep, run_startup_recovery
from app.services.file_watcher import stop_watchers
from app.services.identity_worker import (
    JOIN_TIMEOUT_S as IDENTITY_JOIN_TIMEOUT_S,
    AudioIdentityWorker,
    default_matcher_version,
    reconcile_audio_identity,
)
from app.services.duplicate_detection import MatcherParams
from app.services.identity_wakeup import IdentityWakeup
from app.services.settle_check import SettleCheck, make_settle_refresh
from app.services.transcoder import resolve_default_quality


@asynccontextmanager
async def lifespan(_app: FastAPI):
    startup_event()
    try:
        yield
    finally:
        shutdown_event()


# The POSIX instance lock (taken in startup_event) lets one process own the data folder; run with --workers 1.
app = FastAPI(lifespan=lifespan)
app.include_router(uploads_router)
app.include_router(deletions_router)
app.include_router(duplicates_router)
app.include_router(history_router)
app.include_router(auth_router)
app.include_router(lastfm_router)
app.include_router(catalog_router)
app.include_router(streaming_router)
app.include_router(app_info_router)
app.include_router(tracks_router)
app.include_router(jobs_router)
# Spec §5.3: the auth boundary is the outermost user middleware. Starlette
# wraps the last-added middleware outermost, so add any future middleware
# before this line.
app.add_middleware(AuthMiddleware)


def _interrupted_conversion_uuids(database: Database) -> set[str]:
    return {
        e["uuid_id"]
        for e in database.list_journal_entries(owner_id=ANY_OWNER)
        if e["intent"] == "convert"
    }


def _startup_recovery_steps(
    *,
    database: Database,
    staging_dir: Path,
    identity_signal: IdentityWakeup,
    encoded_cache: EncodedCache,
    default_cache: EncodedCache,
    matcher_version: str | None,
    fingerprinter,
    storage_ledger,
    uploads_root: Path,
    boot_id: str,
    cover_art,
    track_locks,
) -> list[StartupStep]:
    # A convert journal row outliving a crash means its commit may have landed
    # without the encoded caches being evicted. Read the rows before journal
    # recovery runs; the conversion step evicts for every row read, whether
    # recovery finished it or kept it.
    interrupted_conversion_uuids = _interrupted_conversion_uuids(database)

    def edit_journal() -> None:
        # Finish/revert any edit interrupted by a crash before serving requests.
        reconcile_journal(
            database, settings.music_library_dir, identity_signal=identity_signal,
            cover_art=cover_art,
        )

    def conversion_jobs() -> None:
        # Journal recovery keeps a convert row it cannot prove: evict for every
        # convert row read before recovery ran, whether it finished or kept the
        # row, even if the reconcile raises; otherwise a later start could never
        # evict the rows it finished.
        try:
            # No worker thread survives a restart -- any conversion job still
            # "running" is orphaned; independent of the journal pass above.
            reconcile_conversion_jobs(database, staging_dir)
        finally:
            for uuid_id in interrupted_conversion_uuids:
                evict_track_caches(uuid_id, encoded_cache, default_cache)

    def audio_identity_reconcile() -> None:
        reconcile_audio_identity(
            database,
            matcher_version=matcher_version,
            tool_versions=audio_identity.tool_versions(fingerprinter=fingerprinter),
            fingerprinter_present=fingerprinter is not None,
            fingerprint_algorithm=(
                fingerprinter.algorithm if fingerprinter is not None else None
            ),
            classifier_params=MatcherParams.from_settings(settings),
        )

    def upload_commit_reconcile() -> None:
        # Built here, not from the worker's wiring: recovery must run even with
        # the commit worker off.
        upload_recovery.reconcile_upload_commits(
            database,
            publisher=upload_publish.UploadPublisher(
                database,
                uploads_root=uploads_root,
                music_library_dir=settings.music_library_dir.resolve(),
                cover_art=cover_art,
                identity_signal=identity_signal,
                fingerprinter_present=fingerprinter is not None,
                copy_floor_bytes=settings.storage_free_space_floor_bytes,
            ),
            uploads_root=uploads_root,
            music_library_dir=settings.music_library_dir.resolve(),
            cover_art=cover_art,
        )

    def upload_janitor_once() -> None:
        # No worker runs yet, so a finished journal cannot be in use: no grace.
        upload_janitor.UploadJanitor(
            database,
            uploads_root=uploads_root,
            music_library_dir=settings.music_library_dir.resolve(),
            cover_art=cover_art,
            clock=time.time,
            expiry_s=settings.upload_stage_expiry_s,
            retention_s=settings.upload_retention_s,
            journal_grace_s=0,
        ).run_once()

    def upload_receipt_reconcile() -> None:
        upload_receipts.reconcile_upload_receipts(database, uploads_root, boot_id=boot_id)

    def upload_validation_reconcile() -> None:
        try:
            upload_validation.reconcile_upload_validation(database, boot_id=boot_id)
        finally:
            upload_zip.reconcile_expanded_archives(database, uploads_root)

    # Unresolved, like the deletion worker's executor: journal quarantine paths
    # are compared as strings built from this root.
    deletion_journal, deletion_jobs, deletion_janitor = deletion_recovery.startup_steps(
        database,
        music_library_dir=settings.music_library_dir,
        track_locks=track_locks,
        cover_art=cover_art,
        cache=encoded_cache,
        default_cache=default_cache,
        boot_id=boot_id,
    )

    # Fatal: a failure escaping any of these aborted startup before the
    # registry existed; kept.
    return [
        StartupStep("edit journal", edit_journal, fatal=True),
        StartupStep("conversion jobs", conversion_jobs, fatal=True),
        StartupStep("audio identity", audio_identity_reconcile, fatal=True),
        # Prepared/moved commit journals resume before receipts and job reclaim.
        # Non-fatal: the worker claims only committing journals, so a skipped
        # journal is just left for the next start.
        StartupStep("upload commit journal", upload_commit_reconcile),
        # SC-16e, O4 non-fatal: a failure leaves the journal, so the track stays
        # hidden and mutators keep refusing it.
        deletion_journal,
        # Receipts settle or release their rows first (non-fatal: a failure leaves
        # rows as they were).
        StartupStep("upload receipts", upload_receipt_reconcile),
        # Then items a dead process was validating go back to the queue.
        StartupStep("upload validation", upload_validation_reconcile),
        # SC-16e, O4 non-fatal: unreclaimed items wait for the next start.
        deletion_jobs,
        # After job reclaim (the conversion step fails jobs left running), before
        # any janitor. Non-fatal: a failure only leaves orphaned reservations
        # counted, which makes admission more conservative, never less.
        StartupStep("storage reservations", storage_ledger.reconcile),
        # Last. Non-fatal: a skipped pass only leaves stages for the next pass.
        StartupStep("upload janitor", upload_janitor_once),
        # SC-16e, O4 non-fatal: a failed pass leaves the journal for the next one.
        deletion_janitor,
    ]


def _assert_dirs_non_overlapping(
    import_dir: Path,
    user_import_dir: Path,
    library_dir: Path,
    app_data_dir: Path,
) -> None:
    """Fail startup if any two of import_dir, user_import_dir and
    music_library_dir are the same or one is nested in the other — otherwise
    edit staging (under the library) or another tree's files could be
    re-ingested by an import watcher — or if app_data_dir is, or is inside,
    one of them (its caches would be ingested, or adopted as a user folder).
    Other trees inside the data dir are allowed."""
    trees = [
        ("import_dir", import_dir),
        ("user_import_dir", user_import_dir),
        ("music_library_dir", library_dir),
    ]
    pairs = [
        (name_a, a, name_b, b)
        for i, (name_a, a) in enumerate(trees)
        for name_b, b in trees[i + 1:]
        if _is_or_inside(a, b) or _is_or_inside(b, a)
    ]
    pairs += [
        ("app_data_dir", app_data_dir, name, tree)
        for name, tree in trees
        if _is_or_inside(app_data_dir, tree)
    ]
    for name_a, a, name_b, b in pairs:
        raise RuntimeError(
            f"{name_a} ({a.resolve()}) and {name_b} ({b.resolve()}) must not overlap"
        )


def startup_event():
    install_access_log_redaction()
    # Set app.state classes to be None
    app.state.database = None
    app.state.server_instance_id = None
    app.state.admin_user_id = None
    app.state.admin_library = None
    app.state.cover_art_manager = None
    app.state.organizer = None
    app.state.ingestor = None
    app.state.file_watcher = None
    app.state.user_file_watcher = None
    app.state.encoded_cache = None
    app.state.default_cache = None
    app.state.encoder_coordinator = None
    for worker, registry in _BACKGROUND_WORKERS:
        setattr(app.state, worker, None)
        if registry is not None:
            setattr(app.state, registry, None)
    app.state.fingerprinter = None
    app.state.boot_id = None
    app.state.storage_ledger = None
    app.state.import_unpack_ledger = None
    app.state.upload_cancel_tokens = None
    app.state.upload_receipt = None
    # The teardown reads these: a failed start-up never acts on an earlier start's objects.
    app.state.import_stop = None
    app.state.settle_check = None
    app.state.identity_registry = None
    app.state.conversion_orchestrator = None
    # Per-uuid track lock. Built once here so the paths that serialize on one
    # track (metadata edits, conversions, deletions and the deletion start-up
    # recovery, the settle check, finishing kept journal rows) share the
    # identical instance.
    app.state.track_locks = TrackLocks()
    app.state.settings = settings
    # 9D: a wrong Last.fm setting leaves it off or stopped, never stops startup.
    app.state.lastfm = start_lastfm(settings)
    app.state.lastfm_accounts = None

    settings.app_data_dir.mkdir(parents=True, exist_ok=True)
    try:
        app.state.instance_lock = acquire_instance_lock(settings.app_data_dir)
    except InstanceLockHeld as exc:
        operator_logger.error(
            "Startup refused: another instance holds osml.lock in the data folder; "
            "run with --workers 1"
        )
        raise
    # SC-16d: identifies this process's job leases; any other boot id on a lease
    # is a dead process (the flock guarantees one process).
    app.state.boot_id = str(uuid4())
    try:
        # Only after the lock is ours (a second server opens no client), and inside
        # the try so a failure building it releases the lock.
        app.state.lastfm_accounts = build_lastfm_accounts(app.state.lastfm)
        _startup_locked()
    except BaseException:
        try:
            _teardown(app.state)
        except Exception as e:  # the start-up error stays the one raised
            logger.warning("stopping after a failed start-up failed: %s", type(e).__name__)
        raise
    # Registered only once startup succeeded: a failed start-up's teardown has no hook to remove.
    install_scrobble_outbox(app.state.lastfm)


logger = logging.getLogger(__name__)

# How long shutdown waits for running imports before keeping the instance lock.
WATCHER_STOP_TIMEOUT_S = 30.0


def _startup_locked():
    settings.music_library_dir.mkdir(parents=True, exist_ok=True)
    settings.import_dir.mkdir(parents=True, exist_ok=True)

    # The watchers ingest anything dropped in import_dir / user_import_dir; edit
    # staging lives under music_library_dir. If any two of these trees
    # overlapped, a staged temp could be re-ingested as a new track. Fail fast
    # rather than corrupt the library.
    _assert_dirs_non_overlapping(
        settings.import_dir,
        settings.user_import_dir,
        settings.music_library_dir,
        settings.app_data_dir,
    )
    internal_dirs = ensure_internal_dirs(
        settings.music_library_dir,
        import_trees=(
            ("IMPORT_DIR", settings.import_dir),
            ("USER_IMPORT_DIR", settings.user_import_dir),
        ),
    )
    # No ffmpeg of this process exists yet, so any ffmpeg writing into an
    # internal dir is an orphan. One listing of the processes for all of them,
    # and the only one of a start: the sweep of staged files
    # (reconcile_conversion_jobs) relies on it having run.
    kill_orphaned_ffmpeg(*internal_dirs)

    operator_logger.info("app data dir: %s", settings.app_data_dir)

    # Set up database
    database = server_database(settings.app_data_dir)
    uploads_root = settings.music_library_dir.resolve() / UPLOADS
    database.context.database_path.parent.mkdir(parents=True, exist_ok=True)
    if database.initialize() is not True:
        raise RuntimeError("Database initialization failed")
    app.state.server_instance_id = database.get_server_instance_id()
    app.state.admin_user_id = bootstrap_master_admin(
        database, settings, env_file=Path(ENV_FILE)
    )
    for key in RECORDED_ROOT_KEYS:
        database.set_setting(key, str(Path(getattr(settings, key)).resolve()))
    resume_user_deletes(database, DeletePaths.from_settings(settings))
    # Build the dummy hash now so the first unknown-user login is not slower.
    prepare_dummy_hash(settings)
    if settings.osml_insecure_fast_password_hashing:
        operator_logger.warning(
            "OSML_INSECURE_FAST_PASSWORD_HASHING is on: passwords are hashed with "
            "weak settings meant only for tests, so anyone with a copy of the "
            "database can guess them far more easily. Turn it off on a real "
            "server; each password is then hashed again with the normal settings "
            "at its user's next sign-in."
        )
    app.state.admin_library = Library(
        database,
        app.state.admin_user_id,
        root=library_root(
            settings.music_library_dir, database.get_user(app.state.admin_user_id)
        ),
    )
    app.state.database = database
    # One idle connection for the life of the process, so no call's close is the
    # last one (each would checkpoint the write-ahead log). Opened only once
    # app.state.database is set, because the teardown closes what that name holds.
    database.hold_open()
    # Post-commit wake-up for the audio-identity writers, and the registry that
    # lets shutdown kill the ingest hashes.
    app.state.identity_wakeup = IdentityWakeup()
    app.state.identity_registry = FfmpegProcessRegistry()

    # Master-file edit orchestration. Staging lives under the library so a
    # staged temp is on the same filesystem as its destination (atomic
    # os.replace / rename) yet off the watched import tree.
    staging_dir = settings.music_library_dir / STAGING
    staging_dir.mkdir(parents=True, exist_ok=True)
    app.state.storage_ledger = StorageLedger(
        database,
        path=settings.music_library_dir,
        floor_bytes=settings.storage_free_space_floor_bytes,
        boot_id=app.state.boot_id,
    )
    # One token registry for the upload receipt, the validation worker and the
    # cancel route (DELETE).
    app.state.upload_cancel_tokens = CancelTokens()
    app.state.upload_receipt = ReceiptRuntime(
        ledger=app.state.storage_ledger,
        slots=TransferSlots(
            total=effective_upload_limits(settings).receives,
            per_user=effective_upload_limits(settings).receives_per_user,
        ),
        tokens=app.state.upload_cancel_tokens,
        uploads_root=uploads_root,
        boot_id=app.state.boot_id,
    )
    # Old masters kept after a failed durable point; every runtime journal finisher
    # (edit, conversion, idle pass) shares this one registry.
    app.state.pending_old_masters = PendingOldMasters()
    app.state.track_editor = TrackEditor(
        music_library_dir=settings.music_library_dir,
        staging_dir=staging_dir,
        identity_signal=app.state.identity_wakeup,
        pending_old_masters=app.state.pending_old_masters,
    )
    # Independent of the worker flag; a missing tool gives None versions.
    matcher_version = default_matcher_version()
    # Detected once per startup (spec 4.1); the pipeline factory below reads it.
    app.state.fingerprinter = fingerprinter = detect_fingerprinter(settings)

    # Set up cover art manager
    cover_art_dir = settings.app_data_dir / "cover_art"
    cover_art_dir.mkdir(parents=True, exist_ok=True)
    cover_art_context = CoverArtContext(
        cover_art_dir=cover_art_dir, database=database
    )
    cover_art_manager = CoverArtManager(ctx=cover_art_context)
    app.state.cover_art_manager = cover_art_manager

    # Set up the encoded-track cache + coordinator used by the streaming endpoint.
    encoded_cache_dir = settings.app_data_dir / "encoded_cache"
    encoded_cache_dir.mkdir(parents=True, exist_ok=True)
    max_cache_bytes = int(settings.encoded_cache_size_gb * 1024 * 1024 * 1024)
    encoded_cache = EncodedCache(
        ctx=EncodedCacheContext(
            cache_dir=encoded_cache_dir,
            max_size_bytes=max_cache_bytes,
        )
    )
    # Unlimited cache for the server's default streaming quality — these files
    # are never evicted by on-demand traffic.
    default_cache_dir = settings.app_data_dir / "default_cache"
    default_cache_dir.mkdir(parents=True, exist_ok=True)
    default_cache = EncodedCache(
        ctx=EncodedCacheContext(
            cache_dir=default_cache_dir,
            max_size_bytes=0,  # unlimited
        )
    )
    default_quality = resolve_default_quality(
        app.state.admin_library.get_user_setting("default_streaming_quality"),
        settings.default_streaming_quality,
    )

    app.state.encoded_cache = encoded_cache
    app.state.default_cache = default_cache

    # SC-16e: recovery runs before any worker starts.
    run_startup_recovery(
        _startup_recovery_steps(
            database=database,
            staging_dir=staging_dir,
            identity_signal=app.state.identity_wakeup,
            encoded_cache=encoded_cache,
            default_cache=default_cache,
            matcher_version=matcher_version,
            fingerprinter=fingerprinter,
            storage_ledger=app.state.storage_ledger,
            uploads_root=uploads_root,
            boot_id=app.state.boot_id,
            cover_art=app.state.cover_art_manager,
            track_locks=app.state.track_locks,
        )
    )

    # Once per start: warn when a library root cannot take hard links (never fatal).
    upload_publish.probe_library_links(
        database,
        uploads_root=uploads_root,
        music_library_dir=settings.music_library_dir,
    )

    # Backfill cover_art_id for tracks ingested before cover art support;
    # after recovery, which may fix the track files it reads.
    cover_art_manager.backfill_cover_art()

    encoder_coordinator = EncoderCoordinator(
        cache=encoded_cache,
        source_lookup=lambda uuid_id: live_source_path(database, uuid_id),
        workers=max(1, settings.encoded_cache_prefetch_workers),
        default_cache=default_cache,
        default_quality=default_quality,
        all_uuids_fn=app.state.admin_library.get_all_track_uuids,
        admin_owner_id=app.state.admin_user_id,
        owner_lookup=lambda uuid_id: live_track_owner(database, uuid_id),
    )
    app.state.encoder_coordinator = encoder_coordinator
    encoder_coordinator.startup()

    # One-time probe of which ffmpeg encoders this build actually has
    # (libmp3lame/alac are build-dependent). Both /app/info's advertised
    # targets and POST /jobs' enqueue guard read it: advertised == accepted.
    app.state.available_encoders = probe_available_encoders()

    # Master-type conversion orchestration (Phase 2). Shares the staging dir
    # and per-uuid TrackLocks with the metadata edit path (``patch_track``),
    # and the streaming encoder pool -- no new subsystems.
    app.state.conversion_orchestrator = ConversionOrchestrator(
        database=database,
        music_library_dir=settings.music_library_dir,
        staging_dir=staging_dir,
        track_locks=app.state.track_locks,
        encoder_coordinator=encoder_coordinator,
        cache=encoded_cache,
        default_cache=default_cache,
        available_encoders=app.state.available_encoders,
        storage_ledger=app.state.storage_ledger,
        identity_signal=app.state.identity_wakeup,
        pending_old_masters=app.state.pending_old_masters,
    )
    app.state.conversion_orchestrator.resume_queued()

    settings.user_import_dir.mkdir(parents=True, exist_ok=True)
    ensure_user_import_folders(settings.user_import_dir, database.list_user_folders())
    # With the hard-link probe's startup checks: warn when a folder is on
    # another filesystem than the music library (never fatal).
    try:
        filesystem_check.warn_other_filesystems(
            database,
            music_library_dir=settings.music_library_dir,
            import_dir=settings.import_dir,
            user_import_dir=settings.user_import_dir,
        )
    except Exception as e:
        logger.warning("filesystem check failed: %s", type(e).__name__)

    # Import-folder archives unpack here (sign-off DEV-7-14 point 1). After the
    # recovery (the ledger reconcile released a dead run's reservations), before
    # any import runs: remove the dead run's unpack folders. The path must exist,
    # or the ledger reads its free space as unknown.
    workspace_root = settings.app_data_dir / "workspace"
    workspace_root.mkdir(parents=True, exist_ok=True)
    sweep_workspace(workspace_root)
    upload_only_settings_notice(settings)  # upload limits that no longer reach import folders
    # The unpack folders live on the data disk, so admission reads that disk;
    # reservations on the library disk are subtracted too (conservative).
    app.state.import_unpack_ledger = StorageLedger(
        database,
        path=workspace_root,
        floor_bytes=settings.storage_free_space_floor_bytes,
        boot_id=app.state.boot_id,
    )

    if settings.enable_file_watcher:
        # One flag stops both watchers' waits and every ingestor's next member.
        import_stop = app.state.import_stop = threading.Event()
        app.state.settle_check = settle_check = SettleCheck(
            refresh=make_settle_refresh(
                database=database,
                track_locks=app.state.track_locks,
                cache=encoded_cache,
                default_cache=default_cache,
                encoder_coordinator=encoder_coordinator,
                identity_signal=app.state.identity_wakeup,
            ),
            stop_event=import_stop,
        )
        settle_check.start()
        pipeline_factory = functools.partial(
            make_pipeline,
            database=database,
            cover_art_manager=cover_art_manager,
            music_library_dir=settings.music_library_dir,
            workspace_root=workspace_root,
            archive_ledger=app.state.import_unpack_ledger,
            archive_limits=lambda: import_archive_limits(settings),
            on_track_added=encoder_coordinator.warm_imported,
            on_imported=settle_check.schedule,
            stop_event=import_stop,
            identity_signal=app.state.identity_wakeup,
            identity_registry=app.state.identity_registry,
            fingerprinter_present=app.state.fingerprinter is not None,
        )
        dispatcher = ImportDispatcher(
            user_import_dir=settings.user_import_dir,
            database=database,
            make_pipeline=pipeline_factory,
        )
        # The dispatcher is the single place per-owner pipelines are built
        # and cached; IMPORT_DIR feeds the master admin's.
        organizer, ingestor = dispatcher.pipeline_for(
            database.get_user(app.state.admin_user_id)
        )
        app.state.organizer = organizer
        app.state.ingestor = ingestor

        file_watcher = FileWatcher(
            import_dir=settings.import_dir,
            on_file=functools.partial(
                app.state.ingestor.ingest_file,
                imported_dir=settings.import_dir / IMPORTED_DIR_NAME,
            ),
            stop_event=import_stop,
        )
        user_file_watcher = FileWatcher(
            import_dir=settings.user_import_dir,
            on_file=dispatcher.dispatch,
            stop_event=import_stop,
        )

        # Watchers start first, then the scans (after the reconciles), so a
        # file created in between is seen by one of them; _submit_new dedupes.
        app.state.file_watcher = file_watcher
        app.state.user_file_watcher = user_file_watcher
        file_watcher.start_file_watcher()
        user_file_watcher.start_file_watcher()
        file_watcher.scan_existing()
        user_file_watcher.scan_existing()

    # Own kill registry (never the identity one); assigned before start() so a
    # failing start is cleaned up by startup_event.
    if settings.enable_upload_validation_worker:
        app.state.upload_validation_registry = FfmpegProcessRegistry()
        validation = upload_validation.UploadValidationWorker(
            database,
            uploads_root=uploads_root,
            boot_id=app.state.boot_id,
            tokens=app.state.upload_cancel_tokens,
            registry=app.state.upload_validation_registry,
            fingerprinter=app.state.fingerprinter,
            zip_handler=upload_zip.ZipExpander(
                database,
                uploads_root=uploads_root,
                boot_id=app.state.boot_id,
                ledger=app.state.storage_ledger,
                limits=lambda: effective_upload_limits(settings),
            ),
        )
        app.state.upload_validation_worker = validation
        validation.start()

    if settings.enable_upload_commit_worker:
        limits = effective_upload_limits(settings)
        app.state.upload_commit_registry = FfmpegProcessRegistry()
        commit = upload_commit.UploadCommitWorker(
            database,
            uploads_root=uploads_root,
            music_library_dir=settings.music_library_dir.resolve(),
            boot_id=app.state.boot_id,
            ledger=app.state.storage_ledger,
            quota=StagedQuota(
                user_bytes=limits.user_staged_quota_bytes, total_bytes=limits.staged_quota_bytes),
            cover_art=app.state.cover_art_manager,
            registry=app.state.upload_commit_registry,
            after_prepared=upload_publish.UploadPublisher(
                database,
                uploads_root=uploads_root,
                music_library_dir=settings.music_library_dir.resolve(),
                cover_art=app.state.cover_art_manager,
                identity_signal=app.state.identity_wakeup,
                fingerprinter_present=app.state.fingerprinter is not None,
                copy_floor_bytes=settings.storage_free_space_floor_bytes,
            ),
        )
        app.state.upload_commit_worker = commit
        commit.start()

    if settings.enable_upload_janitor:
        # Assigned before start() so a failing start is cleaned up by startup_event.
        janitor_thread = upload_janitor.UploadJanitorThread(
            upload_janitor.UploadJanitor(
                database,
                uploads_root=uploads_root,
                music_library_dir=settings.music_library_dir.resolve(),
                cover_art=app.state.cover_art_manager,
                expiry_s=settings.upload_stage_expiry_s,
                retention_s=settings.upload_retention_s,
            ),
            interval_s=settings.upload_janitor_interval_s,
        )
        app.state.upload_janitor_thread = janitor_thread
        janitor_thread.start()

    if settings.enable_deletion_worker:
        # Assigned before start() so a failing start is cleaned up by startup_event.
        deletion_executor = DeletionExecutor(
            database,
            # Unresolved: the path check accepts stored masters under the
            # configured root or under its real path.
            music_library_dir=settings.music_library_dir,
            track_locks=app.state.track_locks,
            cover_art=app.state.cover_art_manager,
            cache=app.state.encoded_cache,
            default_cache=app.state.default_cache,
            boot_id=app.state.boot_id,
            pending_old_masters=app.state.pending_old_masters,
            identity_signal=app.state.identity_wakeup,
        )
        deletion_worker = DeletionWorker(
            deletion_executor,
            idle_poll_s=5.0,
            janitor=deletion_recovery.DeletionJanitor(
                database,
                executor=deletion_executor,
                music_library_dir=settings.music_library_dir,
            ),
            janitor_interval_s=settings.deletion_janitor_interval_s,
        )
        app.state.deletion_worker = deletion_worker
        deletion_worker.start()

    # Last, and outside the watcher block: it needs its own stop flag because
    # import_stop does not exist when the watcher is off. Assigned before
    # start() so a failing start is cleaned up by startup_event.
    if settings.enable_identity_worker:
        worker = AudioIdentityWorker(
            database,
            wakeup=app.state.identity_wakeup,
            registry=app.state.identity_registry,
            matcher_version=matcher_version,
            fingerprinter=app.state.fingerprinter,
            journal_finisher=functools.partial(
                finish_kept_journal_rows,
                database, settings.music_library_dir, app.state.track_locks,
                identity_signal=app.state.identity_wakeup,
                reported=set(),  # each failing row is logged once per process
                pending_old_masters=app.state.pending_old_masters,
            ),
        )
        app.state.identity_worker = worker
        worker.start()

    # The Last.fm sender: only while Last.fm is running, on the one gate and
    # client the accounts service owns. Assigned before start() like the others.
    accounts = app.state.lastfm_accounts
    if (
        app.state.lastfm.is_running
        and settings.enable_lastfm_sender
        and accounts is not None
        and accounts.gate is not None
    ):
        sender = ScrobbleSender(
            database,
            app.state.lastfm,
            client=accounts.client,
            gate=accounts.gate,
            notices=accounts.notices,
            settle_delay_s=app.state.lastfm.config.settle_delay_s,
        )
        app.state.lastfm_sender = sender
        sender.start()


# The one list of background worker threads, in stop order: each worker's state
# name with the state name of the kill registry it owns (None when it owns
# none). Start-up sets these names to None; the teardown, used by shutdown and
# by a failed start-up, stops exactly these, and the instance lock is kept
# while any of them is alive. A new worker adds one line here.
_BACKGROUND_WORKERS: tuple[tuple[str, str | None], ...] = (
    ("lastfm_sender", None),
    ("deletion_worker", None),
    ("upload_janitor_thread", None),
    ("upload_commit_worker", "upload_commit_registry"),
    ("upload_validation_worker", "upload_validation_registry"),
    # Its registry is shared with imports: the teardown closes it with them.
    ("identity_worker", None),
)


def _background_workers(state) -> list[tuple[object, object]]:
    """The workers of ``_BACKGROUND_WORKERS`` that exist, in stop order, each
    with its kill registry (None when it owns none)."""
    entries = (
        (getattr(state, worker, None), getattr(state, registry, None) if registry else None)
        for worker, registry in _BACKGROUND_WORKERS
    )
    return [(worker, registry) for worker, registry in entries if worker is not None]


def _request_stop(workers) -> None:
    """Ask every worker to stop, then close its own kill registry (stop first, so
    a killed process reads as a stop, not a failure)."""
    for worker, registry in workers:
        try:
            worker.request_stop()
        except Exception as e:
            logger.warning("background worker stop request failed: %s", type(e).__name__)
        if registry is not None:
            try:
                registry.close()
            except Exception as e:
                logger.warning("background worker stop request failed: %s", type(e).__name__)


def _join(workers) -> None:
    # IDENTITY_JOIN_TIMEOUT_S is one deadline for all workers, not a bound each.
    # Every worker was asked to stop before the first join begins, so each has
    # the whole deadline to end whatever the join order: a later join that gets
    # a remaining timeout of 0 is still a worker that had its full time. Do not
    # give each join its own bound again. A worker still running at the
    # deadline is left running: shutdown goes on and the instance lock is kept
    # until it ends.
    deadline = time.monotonic() + IDENTITY_JOIN_TIMEOUT_S
    for worker, _ in workers:
        try:
            worker.join(timeout=max(0.0, deadline - time.monotonic()))
        except Exception as e:
            logger.warning("background worker join failed: %s", type(e).__name__)


def _still_running(workers) -> set:
    return {worker.done for worker, _ in workers if worker.is_alive()}


def _release_instance_lock(instance_lock, not_done: set) -> None:
    if not_done:
        _release_lock_when_done(instance_lock, not_done)  # never while one lives
    else:
        instance_lock.release()


def _close_lastfm_client(client) -> None:
    """Closes the given Last.fm client; a failure never propagates."""
    try:
        client.close()
    except Exception as e:
        logger.warning("Last.fm client close failed: %s", type(e).__name__)


def _close_lastfm_client_when_sender_ends(state) -> None:
    """Shutdown's rule, also used by a failed start-up: while the sender still
    runs, a request may be in flight, so the client closes when the sender ends;
    otherwise it closes now. A failure of the direct close propagates. The
    client is the one ``state`` holds now, never one a later start builds."""
    client = getattr(getattr(state, "lastfm_accounts", None), "client", None)
    if client is None:
        return
    sender = getattr(state, "lastfm_sender", None)
    if sender is not None and sender.is_alive():
        sender.done.add_done_callback(lambda _: _close_lastfm_client(client))
    else:
        client.close()


def _teardown(state, *, before_lock_release=None):
    """Stops everything a start-up started, in one fixed order; used by shutdown
    and by a failed start-up. A step that raises skips no later step: its error
    is kept, a later step's error is logged by type, and the first error is
    raised once everything was asked to stop. ``before_lock_release`` runs even
    when a step raised."""
    workers = _background_workers(state)
    leftover_imports: set = set()
    errors: list[Exception] = []

    def step(fn, *args, **kwargs):
        try:
            return fn(*args, **kwargs)
        except Exception as e:  # the rest still stops; the first error is raised at the end
            if errors:
                logger.warning("stop step failed: %s", type(e).__name__)
            errors.append(e)
            return None

    try:
        # The encoder pool is asked to stop first (its stop markers sort ahead of
        # the backlog, and the call does not wait), so nothing only queued starts
        # while the server waits for the watchers and workers; a warm or prefetch
        # resumes at the next start and a queued conversion stays queued.
        coordinator = getattr(state, "encoder_coordinator", None)
        if coordinator:
            step(coordinator.shutdown)
        watchers = [
            w
            for w in (
                getattr(state, "file_watcher", None),
                getattr(state, "user_file_watcher", None),
            )
            if w
        ]
        # Order matters: set the import stop flag, ask every worker to stop (each
        # closes its own registry), then close the identity registry. Closing the
        # registry kills every running hash (one that starts later is killed on
        # arrival), so shutdown never waits out a long hash; an import's killed
        # hash is stored pending and the import still lands. A worker is told to
        # stop before the kill so its killed hash reads as a stop, not as a
        # failed attempt.
        import_stop = getattr(state, "import_stop", None)
        if import_stop is not None:
            step(import_stop.set)
        _request_stop(workers)
        identity_registry = getattr(state, "identity_registry", None)
        if identity_registry is not None:
            step(identity_registry.close)
        leftover_imports = set(step(stop_watchers, watchers, WATCHER_STOP_TIMEOUT_S) or ())
        settle_check = getattr(state, "settle_check", None)
        if settle_check is not None:
            step(settle_check.join, timeout=2)  # the shared stop flag ended it
        _join(workers)
        # Closing the conversion registry kills a running conversion's ffmpeg (it
        # runs in its own session and would outlive this process) and kills on
        # arrival one that starts later; the job's own thread then marks that job
        # failed (if the process ends first, the next startup fails the row left
        # 'running'), and a job that was only queued stays queued for the next start.
        orchestrator = getattr(state, "conversion_orchestrator", None)
        if orchestrator:
            step(orchestrator.shutdown)
        step(_close_lastfm_client_when_sender_ends, state)
        # Last of the stop steps, after everything that was asked to stop, so this
        # close is the last one and checkpoints the write-ahead log; a worker that
        # outlived its join only makes a later close the last.
        database = getattr(state, "database", None)
        if database is not None:
            step(database.close)
        if errors:
            raise errors[0]  # reported once everything was asked to stop
    finally:
        try:
            if before_lock_release is not None:
                before_lock_release()
        finally:
            instance_lock = getattr(state, "instance_lock", None)
            if instance_lock is not None:
                # Kept while an import or any worker still runs; released after the last.
                _release_instance_lock(instance_lock, leftover_imports | _still_running(workers))


def shutdown_event():
    # The history hook is removed even when a shutdown step raised. The global
    # is read here, when shutdown runs.
    _teardown(app.state, before_lock_release=uninstall_scrobble_outbox)


def _release_lock_when_done(instance_lock, futures: set) -> None:
    """Keep the lock while imports or workers outlive the shutdown
    bound; release it once the last of them ends."""
    logger.warning(
        "keeping the instance lock until %d task(s) still running finish",
        len(futures),
    )
    remaining = len(futures)
    guard = threading.Lock()

    def one_done(_future) -> None:
        nonlocal remaining
        with guard:
            remaining -= 1
            last = remaining == 0
        if last:
            instance_lock.release()

    for future in futures:
        future.add_done_callback(one_done)


@app.get("/")
def read_root():
    return {"message": "Healthy"}
