"""Per-owner ingest pipeline (spec §6.3)."""

import threading
from pathlib import Path
from typing import Callable

from app.database import ANY_OWNER
from app.library import Library, library_root
from app.services import audio_identity
from app.services.ffmpeg_runner import FfmpegProcessRegistry
from app.services.import_archive import ArchiveUnpacker, ImportArchiveLimits, default_limits
from app.services.ingestion import Ingestor, IngestorContext
from app.services.organizer import Organizer, OrganizerContext
from app.services.storage_ledger import StorageLedger


def make_pipeline(
    user,
    *,
    database,
    cover_art_manager,
    music_library_dir,
    workspace_root,
    on_track_added: Callable[[str, int], None] | None = None,
    on_imported: Callable[[str, int, Path, tuple | None], None] | None = None,
    stop_event: threading.Event | None = None,
    fingerprinter_present: bool = False,
    identity_signal=None,
    identity_registry: FfmpegProcessRegistry | None = None,
    archive_ledger: StorageLedger | None = None,
    archive_limits: Callable[[], ImportArchiveLimits] | None = None,
) -> tuple[Organizer, Ingestor]:
    """Build the owner's Organizer and Ingestor: files land under the owner's
    root, tracks are added as the owner, and archives unpack under
    workspace/u<user_id>/ (numeric, so it cannot clash with stem directories),
    reserved on ``archive_ledger`` and checked against ``archive_limits``
    (import_archive_limits of the settings; default: of their defaults)."""
    root = library_root(music_library_dir, user)
    library = Library(database, user["id"], root=root)

    def add_to_database(track):
        added = library.add_track(track, fingerprinter_present=fingerprinter_present)
        if added:
            # After add_track's transaction has committed (U04).
            if identity_signal is not None:
                identity_signal.notify()
            if on_track_added is not None:
                on_track_added(track.uuid_id, user["id"])
        return added

    def compute_identity(path, codec_hint):
        job_id = object()  # unique per call: concurrent ingests never share a kill flag
        try:
            return audio_identity.compute_identity(
                path, codec_hint, registry=identity_registry, job_id=job_id
            )
        finally:
            if identity_registry is not None:
                identity_registry.forget(job_id)

    organizer_hook = None
    if on_imported is not None:

        def organizer_hook(track, signature):
            on_imported(track.uuid_id, user["id"], Path(track.file_path), signature)

    organizer = Organizer(
        ctx=OrganizerContext(
            music_library_dir=root,
            should_organize_files=True,
            should_copy_files=False,
            add_to_database=add_to_database,
            add_cover_art=cover_art_manager.add_album_art_with_status,
            release_cover_art=cover_art_manager.release_if_unreferenced,
            on_imported=organizer_hook,
            compute_identity=compute_identity,
            should_stop=stop_event.is_set if stop_event is not None else None,
            probe_registry=identity_registry,
            folder_tracks=lambda folder: database.track_identities_in_folder(
                str(folder), owner_id=ANY_OWNER
            ),
        )
    )
    workspace = workspace_root / f"u{user['id']}"
    workspace.mkdir(parents=True, exist_ok=True)
    ingestor = Ingestor(
        ctx=IngestorContext(
            workspace_dir=workspace,
            organize_function=organizer.organize,
            archives=ArchiveUnpacker(owner_id=user["id"], ledger=archive_ledger,
                                     limits=archive_limits or default_limits),
            probe_registry=identity_registry,
            **({"should_stop": stop_event.is_set} if stop_event is not None else {}),
        )
    )
    return organizer, ingestor
