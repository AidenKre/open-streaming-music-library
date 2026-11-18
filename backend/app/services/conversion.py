"""Master-type conversion orchestration (Phase 2).

Reuses Phase 1's shared crash-safety machinery end to end: the per-uuid
``TrackLocks`` lock, the ``edit_journal`` table (via a third ``"convert"``
intent handled in ``track_editor._reconcile_one``), and the existing
``EncoderCoordinator`` thread pool (via ``PRIORITY_CONVERSION``). No new job
scheduler, no new lock registry, no new staging directory.
"""

import enum
import logging
import os
import time
from dataclasses import dataclass, field, replace
from pathlib import Path
from typing import Any, Callable, FrozenSet, Optional

from app.core.durable_fs import fsync_file
from app.core.media_types import CODEC_TO_EXT, is_lossless, is_lossy
from app.library import Library, library_root
from app.database import ANY_OWNER
from app.database.database import (
    Database,
    EDITABLE_METADATA_COLUMNS,
    RevisionConflict,
    TrackNotFound,
)
from app.models.track import Track
from app.services import audio_identity
from app.services.audio_identity import AudioIdentity, ExactAudioHash
from app.services.encoded_cache import EncodedCache
from app.services.encoder_coordinator import EncoderCoordinator
from app.services.ffmpeg_runner import FfmpegProcessRegistry, kill_orphaned_ffmpeg
from app.services.metadata import (
    TagWriteError,
    build_ffmpeg_tags,
    build_track_metadata,
    ffprobe_for_metadata,
    write_metadata_tags,
)
from app.services.organizer import flush_move, move_back, move_file, prune_empty_dirs
from app.services.path_sanitize import PathEscapesRoot, assert_within
from app.services.storage_ledger import CONVERSION, InsufficientStorage, StorageLedger
from app.services.track_locks import TrackLocks
from app.services.transcoder import (
    QUALITY_BITRATES_KBPS,
    SUPPORTED_TARGET_CODECS,
    SourceAudioParams,
    transcode,
)

LOSSY_BITRATE_PRESETS_KBPS: FrozenSet[int] = frozenset(QUALITY_BITRATES_KBPS.values())

TRACK_CHANGED_ERROR = "track changed since the conversion was requested"
AUDIO_CHECK_STOPPED_ERROR = (
    "Conversion stopped before its audio check finished, so the original was kept."
)
AUDIO_UNREADABLE_ERROR = (
    "Conversion stopped: the converted audio could not be read back, "
    "so the original was kept."
)
AUDIO_MISMATCH_ERROR = (
    "Conversion stopped: the converted audio did not match the original, "
    "so the original was kept (conversion_audio_mismatch)."
)
AUDIO_UNVERIFIED_ERROR = (
    "Conversion stopped: the converted audio could not be verified against "
    "the original, so the original was kept."
)
SOURCE_DAMAGED_ERROR = (
    "Conversion stopped: the original has damaged audio, so it was not converted."
)
# U06-B-06: the same-file swap failed twice; the next start puts the file in place.
SWAP_PENDING_ERROR = (
    "The converted file could not replace the original. The server finishes it at its next start."
)
SWAP_RETRY_PAUSE_S = 1.0
# A lossy target whose codec the track already has, at a preset no lower than the
# stored bitrate (less this tolerance: encoders land near, not on, their preset),
# would only lose quality: re-encoding cannot add what the file lacks.
SAME_FORMAT_BITRATE_TOLERANCE_KBPS = 8.0
ALREADY_IN_FORMAT_ERROR = "The track is already in this format at this bitrate or higher"

_INT_SAMPLE_FMT_BITS = {"u8": 8, "u8p": 8, "s16": 16, "s16p": 16, "s32": 32, "s32p": 32}


logger = logging.getLogger(__name__)


class MasterNotFound(Exception):
    """The track exists but its master file is missing on disk -- unlike
    Phase 1's PATCH, conversion has no DB-only fallback."""


class NoOpConversion(Exception):
    """Hard-blocked: lossless source and target are the same codec (e.g.
    flac -> flac). Lossy same-codec (e.g. mp3 -> mp3 at a new bitrate) is
    warn-only and NOT raised here -- that's a frontend concern."""


# Not enough free space for the converted file's temporaries (the storage
# ledger's refusal; its message carries numbers, never a path).
InsufficientDiskSpace = InsufficientStorage


class TargetPathTaken(Exception):
    """The converted master's path (same stem, new extension) is already
    occupied by a different file."""


class PendingRecovery(Exception):
    """An earlier destructive step on this track (a journal row) is still
    awaiting reconcile; converting now could clobber or orphan it."""


class ConversionFailed(Exception):
    """The pipeline itself failed (transcode, tag-bake, verify, or a
    cancellation arriving mid-run) -- distinct from a rejected enqueue()."""


class ConversionJobStatus(enum.Enum):
    QUEUED = "queued"
    RUNNING = "running"
    DONE = "done"
    FAILED = "failed"
    CANCELLED = "cancelled"


def _audio_stream_count(raw: Optional[dict]) -> int:
    return sum(
        1 for st in (raw or {}).get("streams", [])
        if {k.lower(): v for k, v in st.items()}.get("codec_type") == "audio"
    )


def _source_params_from_probe(
    raw: Optional[dict], source_codec: Optional[str]
) -> Optional[SourceAudioParams]:
    """Source rate/channels/bit depth to mirror onto a lossless target.
    A lossy source has no meaningful bit depth -- it decodes to float -- so
    it gets 16-bit, the standard for a lossless copy of lossy audio."""
    if raw is None:
        return None
    for raw_stream in raw.get("streams", []):
        stream = {k.lower(): v for k, v in raw_stream.items()}
        if stream.get("codec_type") != "audio":
            continue
        raw_bits = str(stream.get("bits_per_raw_sample", ""))
        if source_codec is not None and is_lossy(source_codec):
            bits: Optional[int] = 16
        elif raw_bits.isdigit() and int(raw_bits) > 0:
            bits = int(raw_bits)
        else:
            bits = _INT_SAMPLE_FMT_BITS.get(str(stream.get("sample_fmt", "")))
        sample_rate = str(stream.get("sample_rate", ""))
        channels = stream.get("channels")
        return SourceAudioParams(
            bits_per_sample=bits,
            sample_rate_hz=int(sample_rate) if sample_rate.isdigit() else None,
            channels=channels if isinstance(channels, int) and channels > 0 else None,
        )
    return None


def _probe_intrinsic_fields(
    path: Path, target_codec: str
) -> tuple[str, Optional[float], Optional[int], Optional[int]]:
    """Re-probe a converted file to get the codec/bitrate/sample_rate/channels
    that actually landed, using the same builder as ingestion so stored
    values match it exactly (including its format.bit_rate fallback for
    FLAC, which has no stream-level bit_rate)."""
    raw = ffprobe_for_metadata(path)
    if raw is None:
        logger.warning("post-conversion probe of %s failed", path)
        raise ConversionFailed("post-conversion probe failed")
    metadata = build_track_metadata(raw)
    if metadata is None or metadata.codec != target_codec:
        raise ConversionFailed(
            f"post-conversion probe codec mismatch: expected {target_codec}, "
            f"got {metadata.codec if metadata else None}"
        )
    return metadata.codec, metadata.bitrate_kbps, metadata.sample_rate_hz, metadata.channels


def _estimate_output_bytes(track: Track, source_size: int, target_codec: str,
                           target_bitrate_kbps: Optional[int]) -> int:
    meta = track.metadata
    duration = meta.duration or 0.0
    if is_lossy(target_codec) and target_bitrate_kbps and duration > 0:
        return int(duration * target_bitrate_kbps * 1000 / 8)
    if meta.codec is not None and is_lossless(meta.codec):
        return source_size  # lossless -> lossless: roughly the same size
    if duration > 0 and meta.sample_rate_hz and meta.channels:
        return int(duration * meta.sample_rate_hz * meta.channels * 2)  # 16-bit PCM bound
    return source_size * 10


def _reservation_bytes(track: Track, source: Path, target_codec: str,
                       target_bitrate_kbps: Optional[int]) -> int:
    """Peak usage is the transcoded temp + the tag-baked temp side by side
    (the final move is a same-filesystem rename, the old master already
    exists), so reserve ~2x the estimated output plus headroom."""
    try:
        source_size = source.stat().st_size
    except OSError:
        source_size = 0
    estimate = _estimate_output_bytes(track, source_size, target_codec, target_bitrate_kbps)
    return int(estimate * 2.2) + 16 * 1024 * 1024


def _resolve_dest(source: Path, target_codec: str) -> Path:
    """The converted master's path: same stem, the target's extension. When
    that names the source itself (same extension, or one differing only in
    case on a case-insensitive filesystem) the source path is returned, and
    the conversion replaces the master in place. Raises ``TargetPathTaken``
    if the path belongs to a different file -- checked before transcoding,
    and never left for ``move_file``/reconcile to trip over."""
    dest = source.with_suffix("." + CODEC_TO_EXT[target_codec])
    if dest == source:
        return source
    if dest.exists():
        if os.path.samefile(dest, source):
            return source
        raise TargetPathTaken(str(dest))
    return dest


def _validate_request(track: Track, target_codec: str, target_bitrate_kbps: Optional[int],
                      available_encoders: FrozenSet[str]) -> None:
    if target_codec not in SUPPORTED_TARGET_CODECS or target_codec not in available_encoders:
        raise ValueError(f"unsupported or unavailable target codec: {target_codec}")
    if is_lossy(target_codec):
        if target_bitrate_kbps not in LOSSY_BITRATE_PRESETS_KBPS:
            raise ValueError(
                f"{target_codec} requires a target bitrate of one of "
                f"{sorted(LOSSY_BITRATE_PRESETS_KBPS, reverse=True)}"
            )
    elif target_bitrate_kbps is not None:
        raise ValueError(f"{target_codec} is lossless and takes no target bitrate")

    source_codec = track.metadata.codec
    source_bitrate = track.metadata.bitrate_kbps
    if (
        is_lossy(target_codec)
        and source_codec == target_codec
        and source_bitrate is not None
        and target_bitrate_kbps >= source_bitrate - SAME_FORMAT_BITRATE_TOLERANCE_KBPS
    ):
        # U06-B-06: re-encoding a lossy file into its own codec at the same or a
        # higher bitrate only loses quality (e.g. a Retry after the next start
        # finished the swap; ffmpeg's AAC can land far below its preset).
        raise ValueError(ALREADY_IN_FORMAT_ERROR)
    if (
        source_codec is not None
        and is_lossless(source_codec)
        and is_lossless(target_codec)
        and source_codec == target_codec
    ):
        raise NoOpConversion(track.uuid_id)


@dataclass(frozen=True)
class _SourceSide:
    """The source half of the lossless audio check: its exact hash, the identity
    generation it was taken under, whether the hash came from storage (rather
    than being computed in this job), and the file and codec it describes."""

    exact: Any
    generation: Optional[int]
    stored: bool
    path: Path
    codec: str


@dataclass
class ConversionOrchestrator:
    database: Database
    music_library_dir: Path
    staging_dir: Path
    track_locks: TrackLocks
    encoder_coordinator: EncoderCoordinator
    cache: EncodedCache
    default_cache: Optional[EncodedCache]
    available_encoders: FrozenSet[str]
    storage_ledger: StorageLedger
    identity_signal: Optional[Any] = None
    compute_identity: Callable[..., AudioIdentity] = field(default=audio_identity.compute_identity)
    check_strict_decode: Callable[..., Optional[str]] = field(
        default=audio_identity.check_strict_decode
    )
    # U06-B-06: the pause before the one retry of a failed same-file swap.
    swap_retry_pause: Callable[[], None] = field(
        default=lambda: time.sleep(SWAP_RETRY_PAUSE_S)
    )
    _registry: FfmpegProcessRegistry = field(default_factory=FfmpegProcessRegistry)

    def enqueue(
        self,
        library: Library,
        uuid_id: str,
        target_codec: str,
        target_bitrate_kbps: Optional[int],
        base_revision: Optional[int],
    ) -> int:
        """Validate everything synchronously and persist a queued job, then
        schedule the worker. All input validation happens here -- the
        scheduler's worker loop silently swallows any exception a submitted
        function raises, so nothing may rely on it to surface a bad request.
        Raises ``ConversionJobActive`` if the track already has one queued or
        running (a double-tap, or a retry of a timed-out-but-landed POST,
        must not re-encode an already-converted master).
        """
        # TODO(bulk-jobs): accept a set/album/artist selector and mint one job
        # per track under a shared batch_id (best-effort, per-job independent).
        # Uploads are not a job type: they live under /tracks/uploads (Phase 7).
        track = library.get_track_by_uuid(uuid_id)
        if track is None:
            raise TrackNotFound(uuid_id)
        if base_revision is None or base_revision != track.revision:
            raise RevisionConflict(uuid_id, base_revision, track.revision)

        source = Path(track.file_path)
        if not source.exists():
            raise MasterNotFound(uuid_id)

        # Before the request's own checks: while an earlier file operation (e.g.
        # a same-file swap the next start finishes, U06-B-06) is kept, the track's
        # stored format may not be its file's yet.
        if library.has_journal_entry_for_uuid(uuid_id):
            raise PendingRecovery(uuid_id)
        _validate_request(track, target_codec, target_bitrate_kbps, self.available_encoders)
        _resolve_dest(source, target_codec)

        self.staging_dir.mkdir(parents=True, exist_ok=True)
        # Read-only: a queued job holds nothing; the run reserves.
        self.storage_ledger.check(
            owner_id=library.owner_id, purpose=CONVERSION,
            nbytes=_reservation_bytes(track, source, target_codec, target_bitrate_kbps),
        )

        job_id = library.insert_conversion_job(
            uuid_id, target_codec, CODEC_TO_EXT[target_codec], target_bitrate_kbps,
            base_revision=base_revision,
        )
        self.encoder_coordinator.submit_conversion(self._run_job, job_id)
        return job_id

    def resume_queued(self) -> None:
        """Startup: resubmit jobs still ``queued`` (the in-memory pool queue
        doesn't survive a restart). Each re-validates when it starts."""
        deleting = self.database.get_deleting_user_ids()
        for job in self.database.list_conversion_jobs_with_status(
            "queued", owner_id=ANY_OWNER
        ):
            if job["owner_id"] in deleting:
                continue
            self.encoder_coordinator.submit_conversion(self._run_job, job["id"])

    def cancel(self, library: Library, job_id: int) -> bool:
        """Cancel a queued or running job. A queued job loses its
        queued->running race in _run_job_inner; a running one has its ffmpeg
        killed (and any later ffmpeg step killed on start). Whatever step it
        is in, its result can no longer commit -- complete_conversion_job is
        conditioned on the job still being 'running' -- so a successful
        cancel always leaves the original master in place."""
        cancelled = library.mark_conversion_job_cancelled(job_id)
        if cancelled:
            self._registry.kill(job_id)
        return cancelled

    def shutdown(self) -> None:
        self._registry.close()

    @staticmethod
    def _job_error_text(e: Exception) -> str:
        """The text a client reads in ``GET /jobs``: curated for the named
        failures, never an arbitrary exception's text (it may name a path)."""
        if isinstance(e, (ConversionFailed, PendingRecovery)):
            return str(e) or type(e).__name__
        if isinstance(e, InsufficientDiskSpace):
            return e.message  # numbers only, no path
        if isinstance(e, PathEscapesRoot):
            return "the master or its destination is outside the owner's library"
        if isinstance(e, MasterNotFound):
            return "master file not found"
        logger.warning("conversion job failed: %s: %s", type(e).__name__, e)
        return f"conversion failed ({type(e).__name__})"

    def _run_job(self, job_id: int) -> None:
        # Mandatory outer catch: EncoderCoordinator's pool silently discards
        # any exception a submitted function raises, so nothing upstream of
        # this would ever learn the job failed.
        try:
            # The one by-id read without an owner: the job row names its owner,
            # and everything after runs as that owner.
            job = self.database.get_conversion_job(job_id, owner_id=ANY_OWNER)
            if job is None:
                return
            library = Library(self.database, job["owner_id"])
            try:
                self._run_job_inner(library, job_id)
            except Exception as e:
                library.mark_conversion_job_failed(job_id, self._job_error_text(e))
        finally:
            self._registry.forget(job_id)

    def _run_job_inner(self, library: Library, job_id: int) -> None:
        if self._registry.closed:
            return  # shutting down: the job stays queued; resume_queued resubmits it at the next start
        if not library.mark_conversion_job_running(job_id):
            return  # lost the queued->running race to a cancel

        job = library.get_conversion_job(job_id)
        uuid_id = job["uuid_id"]
        target_codec = job["target_codec"]
        target_bitrate = job["target_bitrate"]

        track = library.get_track_by_uuid(uuid_id)
        if track is None or not Path(track.file_path).exists():
            raise MasterNotFound(uuid_id)
        # A queued job can sit behind other work (or a restart) while the
        # track moves on; every check enqueue() made is redone against it.
        if job["base_revision"] is not None and track.revision != job["base_revision"]:
            raise ConversionFailed(TRACK_CHANGED_ERROR)
        try:
            _validate_request(track, target_codec, target_bitrate, self.available_encoders)
        except ValueError as e:
            raise ConversionFailed(str(e)) from e
        source = Path(track.file_path)
        dest = _resolve_dest(source, target_codec)
        # Owner's root; a missing user row raises here and fails the job.
        root = library_root(
            self.music_library_dir, self.database.get_user(library.owner_id)
        )
        assert_within(source, root)
        assert_within(dest, root)
        if library.has_journal_entry_for_uuid(uuid_id):
            raise PendingRecovery(f"{uuid_id} has an unfinished file operation awaiting recovery")
        self.staging_dir.mkdir(parents=True, exist_ok=True)
        reservation = self.storage_ledger.reserve(
            owner_id=library.owner_id, purpose=CONVERSION,
            nbytes=_reservation_bytes(track, source, target_codec, target_bitrate),
            subject_ref=str(job_id),
        )

        # Job-scoped names: a later job for the same track can never touch
        # (and unlink) a temp an earlier job's journal row still owns.
        ext = "." + CODEC_TO_EXT[target_codec]
        transcoded_temp = self.staging_dir / f"{uuid_id}.{job_id}.convert{ext}"
        tagged_temp = self.staging_dir / f"{uuid_id}.{job_id}.tagged{ext}"
        journal_owns_temp = False
        committed = False
        try:
            # Transcode + tag-bake run WITHOUT the per-uuid lock: they take
            # minutes for a large lossless file, and a PATCH meanwhile must
            # not block on it. The lock is taken for the FS+commit window
            # below, where the revision re-check catches any edit that landed
            # in between (the tags baked here would then be stale).
            raw_probe = ffprobe_for_metadata(source) if is_lossless(target_codec) else None
            source_params = _source_params_from_probe(raw_probe, track.metadata.codec)
            # Source side of the audio check: hashes the bytes the transcoder reads.
            source_side = self._source_exact(
                library, uuid_id, source, track, target_codec, job_id, raw_probe
            )
            result = transcode(
                source, transcoded_temp, target_codec, target_bitrate,
                source_params=source_params, strip_video=False,
                registry=self._registry, job_id=job_id,
            )
            self._raise_if_cancelled(library, job_id)
            if not result.ok:
                logger.warning("transcode failed: %s", result.stderr)
                raise ConversionFailed("transcode failed")

            # Bake every editable tag from the CURRENT DB metadata --
            # transcode() only carried over whatever tags were physically in
            # the (possibly stale, DB-only-edited) source. NULL columns are
            # omitted, not cleared: as in Phase 1's master write, the DB can't
            # tell "cleared" from "never captured" (e.g. a vinyl "A1" track
            # number ffprobe couldn't parse).
            fields = {
                col: value for col in EDITABLE_METADATA_COLUMNS
                if (value := getattr(track.metadata, col)) is not None
            }
            try:
                write_metadata_tags(
                    transcoded_temp, tagged_temp, build_ffmpeg_tags(fields),
                    registry=self._registry, job_id=job_id,
                )
            except TagWriteError as e:
                self._raise_if_cancelled(library, job_id)
                logger.warning("tag write failed: %s", e)
                raise ConversionFailed("tag write failed") from e
            transcoded_temp.unlink(missing_ok=True)
            self._raise_if_cancelled(library, job_id)

            codec, bitrate_kbps, sample_rate_hz, channels = _probe_intrinsic_fields(
                tagged_temp, target_codec
            )
            # Never raises: a failure is a 'failed' value the writer stores as pending.
            identity = self.compute_identity(
                tagged_temp, target_codec, registry=self._registry, job_id=job_id
            )
            self._raise_if_cancelled(library, job_id)
            audio_unchanged, source_side = self._verify_lossless(
                library, uuid_id, job_id, source_side, identity
            )

            try:
                fsync_file(tagged_temp)
            except OSError as e:
                raise ConversionFailed("could not write the converted file to disk") from e

            with self.track_locks.lock(uuid_id):
                current = library.get_track_by_uuid(uuid_id)
                if (
                    current is None
                    or current.revision != track.revision
                    or current.file_path != track.file_path
                ):
                    raise ConversionFailed(TRACK_CHANGED_ERROR)
                if source_side is not None and self._generation(library, uuid_id) != source_side.generation:
                    raise ConversionFailed(TRACK_CHANGED_ERROR)
                self._raise_if_cancelled(library, job_id)

                if dest != source:
                    entry = library.insert_journal_entry(
                        "convert", uuid_id,
                        old_path=str(source), new_path=str(dest),
                        temp_path=str(tagged_temp),
                    )
                    if not move_file(file_path=tagged_temp, destination_path=dest):
                        # While the row exists the staged temp is its evidence
                        # that the move never happened; drop it only after the
                        # row is gone.
                        journal_owns_temp = True
                        library.delete_journal_entry(entry)
                        journal_owns_temp = False
                        logger.warning("could not place converted master at %s", dest)
                        raise ConversionFailed("could not place the converted master")
                    flush_move(dest, tagged_temp, root)
                    try:
                        library.complete_conversion_job(
                            job_id, uuid_id, codec, bitrate_kbps, sample_rate_hz, channels,
                            file_path=str(dest),
                            identity=identity, audio_unchanged=audio_unchanged,
                            stat=audio_identity.stat_snapshot(dest),
                        )
                    except BaseException:
                        # DB did not commit (incl. cancelled in the meantime) ->
                        # revert: put the new copy back in staging and keep the
                        # old master. The staged temp stays while the row does,
                        # showing recovery that the move was undone.
                        if not move_back(dest, tagged_temp):
                            dest.unlink(missing_ok=True)
                        prune_empty_dirs(dest.parent, root)
                        journal_owns_temp = True
                        library.delete_journal_entry(entry)
                        journal_owns_temp = False
                        raise
                    committed = True
                    self._evict(uuid_id)
                    # Committed: DB now points at `dest`; the old master is redundant.
                    source.unlink(missing_ok=True)
                    prune_empty_dirs(source.parent, root)
                    library.delete_journal_entry(entry)
                    self._notify_identity()
                else:
                    # The journal row commits WITH the DB update, so "row
                    # exists" means "DB advanced" -- exactly what
                    # _reconcile_inplace assumes when it redoes a pending
                    # replace after a crash. From here the journal owns the temp.
                    _, entry = library.complete_conversion_job(
                        job_id, uuid_id, codec, bitrate_kbps, sample_rate_hz, channels,
                        file_path=None, inplace_journal=(str(source), str(tagged_temp)),
                    )
                    committed = True
                    journal_owns_temp = True
                    try:
                        os.replace(tagged_temp, source)
                    except OSError:
                        self.swap_retry_pause()
                        try:
                            os.replace(tagged_temp, source)
                        except OSError as e:
                            # The row and the staged file are kept: the next start
                            # puts the file in place and marks the job done.
                            library.mark_conversion_job_failed(
                                job_id, SWAP_PENDING_ERROR, after_commit=True
                            )
                            logger.warning(
                                "conversion of %s: the converted file could not replace"
                                " the original (%s); kept for the next start",
                                uuid_id, type(e).__name__,
                            )
                            return
                        # The old bytes were served under the committed revision
                        # during the pause: clients must see the change.
                        library.bump_track_revision(uuid_id)
                    flush_move(source, tagged_temp)
                    self._evict(uuid_id)
                    try:
                        library.write_conversion_identity(
                            uuid_id, identity, audio_unchanged=audio_unchanged,
                            stat=audio_identity.stat_snapshot(source),
                        )
                    except Exception as e:
                        # The job stays done; the kept journal row lets the identity
                        # worker (when idle) or startup recovery mark the identity
                        # stale ('conversion').
                        logger.warning(
                            "conversion identity write failed for %s: %s",
                            uuid_id, type(e).__name__,
                        )
                        return
                    library.delete_journal_entry(entry)
                    self._notify_identity()
        finally:
            # The reservation is held until the temps are gone and eviction is
            # done, and released exactly once whatever happens in between.
            try:
                transcoded_temp.unlink(missing_ok=True)
                if not journal_owns_temp:
                    tagged_temp.unlink(missing_ok=True)
                if committed:
                    # Covers an exception after the commit; a hard crash there is
                    # covered by startup evicting every uuid with a convert
                    # journal row (eviction always precedes the row's deletion).
                    self._evict(uuid_id)
            finally:
                self._release(reservation)

    def _release(self, reservation: int) -> None:
        try:
            self.storage_ledger.release(reservation)
        except Exception as e:
            # Keep the job's own outcome; the row is left for startup reconcile.
            logger.warning("conversion storage release failed (%s)", type(e).__name__)

    @staticmethod
    def _generation(library: Library, uuid_id: str) -> Optional[int]:
        row = library.get_audio_identity(uuid_id)
        return row["generation"] if row is not None else None

    @staticmethod
    def _skip_check(uuid_id: str, reason: str) -> None:
        logger.info("conversion audio check skipped for %s: %s", uuid_id, reason)

    def _source_exact(
        self, library: Library, uuid_id: str, source: Path, track: Track,
        target_codec: str, job_id: int, raw_probe: Optional[dict],
    ) -> Optional[_SourceSide]:
        """§6.3 source side, taken before the transcode, or None when the check
        cannot apply (logged). Where it applies, the original is first decoded
        strictly: damaged audio refuses the conversion. Uses the stored digest
        when it is current (and records that it did), else computes it in this job."""
        codec = track.metadata.codec
        if not is_lossless(target_codec):
            self._skip_check(uuid_id, "lossy target")
            return None
        if codec is not None and is_lossy(codec):
            self._skip_check(uuid_id, "lossy source")
            return None
        if codec in audio_identity.FLOAT_PCM_CODECS:
            self._skip_check(uuid_id, "float source")
            return None
        if codec is None or not is_lossless(codec):
            self._skip_check(uuid_id, "unknown source codec")
            return None
        if raw_probe is None:
            logger.warning("conversion audio check unavailable for %s: %s", uuid_id, "probe_error")
            return None
        if _audio_stream_count(raw_probe) > 1:
            # The transcoder may not pick the stream the hash reads (0:a:0).
            self._skip_check(uuid_id, "multiple audio streams")
            return None
        self._check_source_decodes(library, uuid_id, source, job_id, codec)
        row = library.get_audio_identity(uuid_id)
        generation = row["generation"] if row is not None else None
        if (
            row is not None and row["exact_state"] == "current"
            and row["exact_kind"] == audio_identity.KIND_PCM
        ):
            stored = True
            exact = ExactAudioHash(
                row["exact_kind"], row["exact_digest"], row["sample_rate_hz"],
                row["channels"], row["bits_per_sample"],
            )
        else:
            stored = False
            exact = self.compute_identity(
                source, codec, registry=self._registry, job_id=job_id
            ).exact
        return _SourceSide(exact, generation, stored, source, codec)

    def _check_source_decodes(
        self, library: Library, uuid_id: str, source: Path, job_id: int, codec: str,
    ) -> None:
        """Strict decode of the original (OPEN-6.5-06): damaged audio fails the
        job, a killed decode stops it, any other failure only logs (the hash
        check still runs). A FLAC that fails it is decoded once more without a
        recognised trailing tag or padding (ffmpeg reads FLAC to the end of the
        file); that second result is the verdict when it is one (a pass, damaged
        or killed), else the first stands."""
        reason = self.check_strict_decode(
            source, registry=self._registry, job_id=job_id, low_priority=True
        )
        if reason == audio_identity.REASON_DECODE_ERROR and codec == "flac":
            end = audio_identity.audio_end_without_trailer(source)
            if end is not None:
                logger.info("strict decode retried without a trailing tag for %s", uuid_id)
                retry = self.check_strict_decode(
                    source, registry=self._registry, job_id=job_id, low_priority=True,
                    audio_end=end,
                )
                if retry in (
                    None, audio_identity.REASON_DECODE_ERROR, audio_identity.REASON_KILLED
                ):
                    reason = retry
                else:
                    # No verdict from the retry: the first one (damaged) stands.
                    logger.info(
                        "strict decode retry for %s gave no verdict: %s", uuid_id, retry
                    )
        if reason is None:
            return
        if reason == audio_identity.REASON_DECODE_ERROR:
            raise ConversionFailed(SOURCE_DAMAGED_ERROR)
        if reason == audio_identity.REASON_KILLED:
            self._raise_if_cancelled(library, job_id)
            raise ConversionFailed(AUDIO_CHECK_STOPPED_ERROR)
        logger.warning(
            "conversion audio check unavailable for %s: %s", uuid_id, f"strict decode {reason}"
        )

    def _verify_lossless(
        self, library: Library, uuid_id: str, job_id: int,
        source_side: Optional[_SourceSide], identity: AudioIdentity,
    ) -> tuple[bool, Optional[_SourceSide]]:
        """§6.3 check: ``(audio_unchanged, source_side)``. ``audio_unchanged`` is
        True when the PCM digest is unchanged (fingerprint kept), False when the
        check does not apply or cannot run. Raises ``ConversionFailed`` on a
        killed check, a source change or a digest mismatch.

        A stored source hash that disagrees with the converted audio in any way
        (digest or sample rate/channels) is not trusted yet: the source is hashed
        once more and the decision is made on the fresh hash. If it differs from
        the stored one, the identity row is marked stale (the stored hash did not
        describe this file) and the worker is woken; the returned source side then
        carries the new generation. Then, with different parameters the check is
        skipped (a real parameter change), with the same digest it passes, and
        otherwise it fails. A re-hash that cannot run (and was
        not killed) leaves the mismatch unexplained: the identity row is marked
        stale so it is recomputed, and the job fails as unverified. When the
        source digest was unusable from the start, nothing was compared and the
        check is simply unavailable. A hash computed in this job is trusted: a
        parameter change skips the check and a digest mismatch fails at once."""
        if source_side is None:
            return False, None
        source_hash, generation = source_side.exact, source_side.generation
        temp_hash = identity.exact
        for exact in (source_hash, temp_hash):
            if not isinstance(exact, ExactAudioHash):
                reason = "unsupported" if exact.state == "unsupported" else exact.reason
                if reason == audio_identity.REASON_KILLED:
                    self._raise_if_cancelled(library, job_id)
                    raise ConversionFailed(AUDIO_CHECK_STOPPED_ERROR)
        if (
            not isinstance(temp_hash, ExactAudioHash)
            and getattr(temp_hash, "reason", None) in (
                audio_identity.REASON_DECODE_ERROR,
                audio_identity.REASON_PROBE_ERROR,
                audio_identity.REASON_OUTPUT_ERROR,
            )
        ):
            raise ConversionFailed(AUDIO_UNREADABLE_ERROR)
        for exact in (source_hash, temp_hash):
            if not isinstance(exact, ExactAudioHash):
                reason = "unsupported" if exact.state == "unsupported" else exact.reason
                logger.warning("conversion audio check unavailable for %s: %s", uuid_id, reason)
                return False, source_side
        if not source_side.stored:
            if not self._same_parameters(source_hash, temp_hash):
                self._skip_check(uuid_id, "parameter change")
                return False, source_side
            if self._generation(library, uuid_id) != generation:
                raise ConversionFailed(TRACK_CHANGED_ERROR)
            if audio_identity.exact_match(source_hash, temp_hash):
                return True, source_side
            raise ConversionFailed(AUDIO_MISMATCH_ERROR)
        if self._generation(library, uuid_id) != generation:
            raise ConversionFailed(TRACK_CHANGED_ERROR)
        if self._same_parameters(source_hash, temp_hash) and audio_identity.exact_match(
            source_hash, temp_hash
        ):
            return True, source_side
        fresh = self.compute_identity(
            source_side.path, source_side.codec, registry=self._registry, job_id=job_id
        ).exact
        if not isinstance(fresh, ExactAudioHash):
            if getattr(fresh, "reason", None) == audio_identity.REASON_KILLED:
                self._raise_if_cancelled(library, job_id)
                raise ConversionFailed(AUDIO_CHECK_STOPPED_ERROR)
            # The stored digest disagreed with the converted audio and nothing
            # clears that: mark the stored identity stale so it is recomputed,
            # and fail so the original is kept.
            logger.warning("conversion audio check unavailable for %s: %s", uuid_id, fresh.reason)
            self._mark_identity_stale(library, uuid_id, generation)
            raise ConversionFailed(AUDIO_UNVERIFIED_ERROR)
        if (
            fresh.digest != source_hash.digest
            or fresh.sample_rate_hz != source_hash.sample_rate_hz
            or fresh.channels != source_hash.channels
        ):
            # Another writer's bump during the re-hash is a track change, never
            # absorbed: the mark must be the only bump (generation + 1).
            self._mark_identity_stale(library, uuid_id, generation)
            expected = generation + 1
            if self._generation(library, uuid_id) != expected:
                raise ConversionFailed(TRACK_CHANGED_ERROR)
            source_side = replace(source_side, generation=expected)
        if not self._same_parameters(fresh, temp_hash):
            self._skip_check(uuid_id, "parameter change")
            return False, source_side
        if audio_identity.exact_match(fresh, temp_hash):
            return True, source_side
        raise ConversionFailed(AUDIO_MISMATCH_ERROR)

    @staticmethod
    def _same_parameters(source: ExactAudioHash, converted: ExactAudioHash) -> bool:
        return (
            source.sample_rate_hz is not None and source.channels is not None
            and source.sample_rate_hz == converted.sample_rate_hz
            and source.channels == converted.channels
        )

    def _mark_identity_stale(self, library: Library, uuid_id: str, generation: int) -> None:
        if self._generation(library, uuid_id) != generation:
            raise ConversionFailed(TRACK_CHANGED_ERROR)
        library.mark_audio_identity_stale(uuid_id, "settle")
        self._notify_identity()

    def _notify_identity(self) -> None:
        if self.identity_signal is not None:
            self.identity_signal.notify()

    def _evict(self, uuid_id: str) -> None:
        # Lazy re-warm: the next stream re-encodes from the new master.
        evict_converted_track_caches(uuid_id, self.cache, self.default_cache)

    def _raise_if_cancelled(self, library: Library, job_id: int) -> None:
        job = library.get_conversion_job(job_id)
        if job is not None and job["status"] == "cancelled":
            raise ConversionFailed("cancelled")


def evict_converted_track_caches(
    uuid_id: str, cache: EncodedCache, default_cache: Optional[EncodedCache]
) -> None:
    cache.remove_all_for_uuid(uuid_id)
    if default_cache is not None:
        default_cache.remove_all_for_uuid(uuid_id)


def reconcile_conversion_jobs(database: Database, staging_dir: Path) -> None:
    """Startup pass, run AFTER reconcile_journal: no worker thread survives
    a process restart, so any conversion_jobs row still 'running' is
    orphaned -- flip it to failed (the master is untouched: conversion only
    writes temps until its commit, which also marks the job done). Then kill
    any ffmpeg a hard-killed predecessor left writing into staging, and
    sweep every staged temp (conversion or master edit) that no journal row
    owns any more (a crash before the commit leaves them behind)."""
    for job in database.list_conversion_jobs_with_status(
        "running", owner_id=ANY_OWNER
    ):
        database.mark_conversion_job_failed(
            job["id"], "interrupted by restart", owner_id=job["owner_id"]
        )
    owned = {e["temp_path"] for e in database.list_journal_entries(owner_id=ANY_OWNER) if e["temp_path"]}
    if not staging_dir.is_dir():
        return
    # A hard-killed server leaves its conversion ffmpeg running (each has its
    # own session), still writing a temp the sweep below deletes. No ffmpeg
    # of this process exists yet, so anything writing here is an orphan.
    kill_orphaned_ffmpeg(staging_dir)
    for path in staging_dir.iterdir():
        if (
            ".convert." in path.name or ".tagged." in path.name or ".edit." in path.name
        ) and str(path) not in owned:
            path.unlink(missing_ok=True)
