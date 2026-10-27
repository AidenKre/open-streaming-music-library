"""Master-type conversion orchestration (Phase 2).

Reuses Phase 1's shared crash-safety machinery end to end: the per-uuid
``TrackLocks`` lock, the ``edit_journal`` table (via a third ``"convert"``
intent handled in ``track_editor._reconcile_one``), and the existing
``EncoderCoordinator`` thread pool (via ``PRIORITY_CONVERSION``). No new job
scheduler, no new lock registry, no new staging directory.
"""

import enum
import os
import shutil
from dataclasses import dataclass, field
from pathlib import Path
from typing import FrozenSet, Optional

from app.core.media_types import CODEC_TO_EXT, is_lossless, is_lossy
from app.database.database import (
    Database,
    EDITABLE_METADATA_COLUMNS,
    RevisionConflict,
    TrackNotFound,
)
from app.models.track import Track
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
from app.services.organizer import move_file, prune_empty_dirs
from app.services.track_locks import TrackLocks
from app.services.transcoder import (
    QUALITY_BITRATES_KBPS,
    SUPPORTED_TARGET_CODECS,
    SourceAudioParams,
    transcode,
)

LOSSY_BITRATE_PRESETS_KBPS: FrozenSet[int] = frozenset(QUALITY_BITRATES_KBPS.values())

TRACK_CHANGED_ERROR = "track changed since the conversion was requested"

_INT_SAMPLE_FMT_BITS = {"u8": 8, "u8p": 8, "s16": 16, "s16p": 16, "s32": 32, "s32p": 32}


class MasterNotFound(Exception):
    """The track exists but its master file is missing on disk -- unlike
    Phase 1's PATCH, conversion has no DB-only fallback."""


class NoOpConversion(Exception):
    """Hard-blocked: lossless source and target are the same codec (e.g.
    flac -> flac). Lossy same-codec (e.g. mp3 -> mp3 at a new bitrate) is
    warn-only and NOT raised here -- that's a frontend concern."""


class InsufficientDiskSpace(Exception):
    """Not enough free space on the staging filesystem for the converted
    file's temporaries."""


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


def _probe_source_params(source: Path, source_codec: Optional[str]) -> Optional[SourceAudioParams]:
    """Source rate/channels/bit depth to mirror onto a lossless target.
    A lossy source has no meaningful bit depth -- it decodes to float -- so
    it gets 16-bit, the standard for a lossless copy of lossy audio."""
    raw = ffprobe_for_metadata(source)
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
) -> tuple[str, Optional[float], int, int]:
    """Re-probe a converted file to get the codec/bitrate/sample_rate/channels
    that actually landed, using the same builder as ingestion so stored
    values match it exactly (including its format.bit_rate fallback for
    FLAC, which has no stream-level bit_rate)."""
    raw = ffprobe_for_metadata(path)
    if raw is None:
        raise ConversionFailed(f"post-conversion probe of {path} failed")
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


def _check_disk_space(track: Track, source: Path, staging_dir: Path, target_codec: str,
                      target_bitrate_kbps: Optional[int]) -> None:
    """Peak usage is the transcoded temp + the tag-baked temp side by side
    (the final move is a same-filesystem rename, the old master already
    exists), so require ~2x the estimated output plus headroom."""
    try:
        source_size = source.stat().st_size
    except OSError:
        source_size = 0
    estimate = _estimate_output_bytes(track, source_size, target_codec, target_bitrate_kbps)
    required = int(estimate * 2.2) + 16 * 1024 * 1024
    free = shutil.disk_usage(staging_dir).free
    if free < required:
        raise InsufficientDiskSpace(
            f"need ~{required} bytes free in {staging_dir}, have {free}"
        )


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
    if (
        source_codec is not None
        and is_lossless(source_codec)
        and is_lossless(target_codec)
        and source_codec == target_codec
    ):
        raise NoOpConversion(track.uuid_id)


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
    _registry: FfmpegProcessRegistry = field(default_factory=FfmpegProcessRegistry)

    def enqueue(
        self,
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
        track = self.database.get_track_by_uuid(uuid_id)
        if track is None:
            raise TrackNotFound(uuid_id)
        if base_revision is None or base_revision != track.revision:
            raise RevisionConflict(uuid_id, base_revision, track.revision)

        source = Path(track.file_path)
        if not source.exists():
            raise MasterNotFound(uuid_id)

        _validate_request(track, target_codec, target_bitrate_kbps, self.available_encoders)
        _resolve_dest(source, target_codec)
        if self.database.has_journal_entry_for_uuid(uuid_id):
            raise PendingRecovery(uuid_id)

        self.staging_dir.mkdir(parents=True, exist_ok=True)
        _check_disk_space(track, source, self.staging_dir, target_codec, target_bitrate_kbps)

        job_id = self.database.insert_conversion_job(
            uuid_id, target_codec, CODEC_TO_EXT[target_codec], target_bitrate_kbps,
            base_revision=base_revision,
        )
        self.encoder_coordinator.submit_conversion(self._run_job, job_id)
        return job_id

    def resume_queued(self) -> None:
        """Startup: resubmit jobs still ``queued`` (the in-memory pool queue
        doesn't survive a restart). Each re-validates when it starts."""
        for job in self.database.list_conversion_jobs_with_status("queued"):
            self.encoder_coordinator.submit_conversion(self._run_job, job["id"])

    def cancel(self, job_id: int) -> bool:
        """Cancel a queued or running job. A queued job loses its
        queued->running race in _run_job_inner; a running one has its ffmpeg
        killed (and any later ffmpeg step killed on start). Whatever step it
        is in, its result can no longer commit -- complete_conversion_job is
        conditioned on the job still being 'running' -- so a successful
        cancel always leaves the original master in place."""
        cancelled = self.database.mark_conversion_job_cancelled(job_id)
        if cancelled:
            self._registry.kill(job_id)
        return cancelled

    def shutdown(self) -> None:
        self._registry.kill_all()

    def _run_job(self, job_id: int) -> None:
        # Mandatory outer catch: EncoderCoordinator's pool silently discards
        # any exception a submitted function raises, so nothing upstream of
        # this would ever learn the job failed.
        try:
            self._run_job_inner(job_id)
        except Exception as e:
            self.database.mark_conversion_job_failed(job_id, str(e) or type(e).__name__)
        finally:
            self._registry.forget(job_id)

    def _run_job_inner(self, job_id: int) -> None:
        if not self.database.mark_conversion_job_running(job_id):
            return  # lost the queued->running race to a cancel

        job = self.database.get_conversion_job(job_id)
        uuid_id = job["uuid_id"]
        target_codec = job["target_codec"]
        target_bitrate = job["target_bitrate"]

        track = self.database.get_track_by_uuid(uuid_id)
        if track is None or not Path(track.file_path).exists():
            raise MasterNotFound(uuid_id)
        # A queued job can sit behind other work (or a restart) while the
        # track moves on; every check enqueue() made is redone against it.
        if job["base_revision"] is not None and track.revision != job["base_revision"]:
            raise ConversionFailed(TRACK_CHANGED_ERROR)
        _validate_request(track, target_codec, target_bitrate, self.available_encoders)
        source = Path(track.file_path)
        dest = _resolve_dest(source, target_codec)
        if self.database.has_journal_entry_for_uuid(uuid_id):
            raise PendingRecovery(f"{uuid_id} has an unfinished file operation awaiting recovery")
        self.staging_dir.mkdir(parents=True, exist_ok=True)
        _check_disk_space(track, source, self.staging_dir, target_codec, target_bitrate)

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
            source_params = (
                _probe_source_params(source, track.metadata.codec)
                if is_lossless(target_codec) else None
            )
            result = transcode(
                source, transcoded_temp, target_codec, target_bitrate,
                source_params=source_params, strip_video=False,
                registry=self._registry, job_id=job_id,
            )
            self._raise_if_cancelled(job_id)
            if not result.ok:
                raise ConversionFailed(result.stderr or "transcode failed")

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
                self._raise_if_cancelled(job_id)
                raise ConversionFailed(str(e)) from e
            transcoded_temp.unlink(missing_ok=True)
            self._raise_if_cancelled(job_id)

            codec, bitrate_kbps, sample_rate_hz, channels = _probe_intrinsic_fields(
                tagged_temp, target_codec
            )

            with self.track_locks.lock(uuid_id):
                current = self.database.get_track_by_uuid(uuid_id)
                if (
                    current is None
                    or current.revision != track.revision
                    or current.file_path != track.file_path
                ):
                    raise ConversionFailed(TRACK_CHANGED_ERROR)
                self._raise_if_cancelled(job_id)

                if dest != source:
                    entry = self.database.insert_journal_entry(
                        "convert", uuid_id,
                        old_path=str(source), new_path=str(dest),
                        temp_path=str(tagged_temp),
                    )
                    if not move_file(file_path=tagged_temp, destination_path=dest):
                        self.database.delete_journal_entry(entry)
                        raise ConversionFailed(f"could not place converted master at {dest}")
                    try:
                        self.database.complete_conversion_job(
                            job_id, uuid_id, codec, bitrate_kbps, sample_rate_hz, channels,
                            file_path=str(dest),
                        )
                    except BaseException:
                        # DB did not commit (incl. cancelled in the meantime) ->
                        # revert: drop the new copy, keep the old master.
                        dest.unlink(missing_ok=True)
                        prune_empty_dirs(dest.parent, self.music_library_dir)
                        self.database.delete_journal_entry(entry)
                        raise
                    committed = True
                    self._evict(uuid_id)
                    # Committed: DB now points at `dest`; the old master is redundant.
                    source.unlink(missing_ok=True)
                    prune_empty_dirs(source.parent, self.music_library_dir)
                    self.database.delete_journal_entry(entry)
                else:
                    # The journal row commits WITH the DB update, so "row
                    # exists" means "DB advanced" -- exactly what
                    # _reconcile_inplace assumes when it redoes a pending
                    # replace after a crash. From here the journal owns the temp.
                    _, entry = self.database.complete_conversion_job(
                        job_id, uuid_id, codec, bitrate_kbps, sample_rate_hz, channels,
                        file_path=None, inplace_journal=(str(source), str(tagged_temp)),
                    )
                    committed = True
                    journal_owns_temp = True
                    os.replace(tagged_temp, source)
                    self._evict(uuid_id)
                    self.database.delete_journal_entry(entry)
        finally:
            transcoded_temp.unlink(missing_ok=True)
            if not journal_owns_temp:
                tagged_temp.unlink(missing_ok=True)
            if committed:
                # Covers an exception after the commit; a hard crash there is
                # covered by startup evicting every uuid with a convert
                # journal row (eviction always precedes the row's deletion).
                self._evict(uuid_id)

    def _evict(self, uuid_id: str) -> None:
        # Lazy re-warm: the next stream re-encodes from the new master.
        evict_converted_track_caches(uuid_id, self.cache, self.default_cache)

    def _raise_if_cancelled(self, job_id: int) -> None:
        job = self.database.get_conversion_job(job_id)
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
    sweep conversion temps no journal row owns any more (a crash before the
    commit leaves them behind)."""
    for job in database.list_conversion_jobs_with_status("running"):
        database.mark_conversion_job_failed(job["id"], "interrupted by restart")
    owned = {e["temp_path"] for e in database.list_journal_entries() if e["temp_path"]}
    if not staging_dir.is_dir():
        return
    # A hard-killed server leaves its conversion ffmpeg running (each has its
    # own session), still writing a temp the sweep below deletes. No ffmpeg
    # of this process exists yet, so anything writing here is an orphan.
    kill_orphaned_ffmpeg(staging_dir)
    for path in staging_dir.iterdir():
        if (".convert." in path.name or ".tagged." in path.name) and str(path) not in owned:
            path.unlink(missing_ok=True)
