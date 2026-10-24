"""Master-type conversion orchestration (Phase 2).

Reuses Phase 1's shared crash-safety machinery end to end: the per-uuid
``TrackLocks`` lock, the ``edit_journal`` table (via a third ``"convert"``
intent handled in ``track_editor._reconcile_one``), and the existing
``EncoderCoordinator`` thread pool (via ``PRIORITY_CONVERSION``). No new job
scheduler, no new lock registry, no new staging directory.

No API routes call into this yet -- ``ConversionOrchestrator`` is exercised
directly (by tests, and later by step 3's ``POST/DELETE /jobs`` routes).
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
from app.services.encoded_cache import EncodedCache
from app.services.encoder_coordinator import EncoderCoordinator
from app.services.ffmpeg_runner import FfmpegProcessRegistry
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
    SUPPORTED_TARGET_CODECS,
    SourceAudioParams,
    transcode,
)


class MasterNotFound(Exception):
    """The track exists but its master file is missing on disk -- unlike
    Phase 1's PATCH, conversion has no DB-only fallback."""


class NoOpConversion(Exception):
    """Hard-blocked: lossless source and target are the same codec (e.g.
    flac -> flac). Lossy same-codec (e.g. mp3 -> mp3 at a new bitrate) is
    warn-only and NOT raised here -- that's a frontend concern."""


class InsufficientDiskSpace(Exception):
    """Not enough free space on the staging filesystem for the worst-case
    coexistence of old + temp + new during a conversion."""


class ConversionFailed(Exception):
    """The pipeline itself failed (transcode, tag-bake, verify, or a
    cancellation arriving mid-run) -- distinct from a rejected enqueue()."""


class ConversionJobStatus(enum.Enum):
    QUEUED = "queued"
    RUNNING = "running"
    DONE = "done"
    FAILED = "failed"
    CANCELLED = "cancelled"


def _probe_source_params(source: Path) -> Optional[SourceAudioParams]:
    """Read the source's raw ffprobe stream dict for the fields
    build_track_metadata doesn't expose (sample_fmt/bits_per_raw_sample) --
    mirrored onto the ffmpeg command so a lossless target doesn't silently
    pick up ffmpeg's own defaults instead of the source's actual format."""
    raw = ffprobe_for_metadata(source)
    if raw is None:
        return None
    for raw_stream in raw.get("streams", []):
        stream = {k.lower(): v for k, v in raw_stream.items()}
        if stream.get("codec_type") != "audio":
            continue
        return SourceAudioParams(
            sample_fmt=stream.get("sample_fmt"),
            bits_per_raw_sample=(
                int(stream["bits_per_raw_sample"])
                if str(stream.get("bits_per_raw_sample", "")).isdigit()
                else None
            ),
            sample_rate_hz=(
                int(stream["sample_rate"]) if str(stream.get("sample_rate", "")).isdigit() else None
            ),
            channels=stream.get("channels"),
        )
    return None


def _probe_intrinsic_fields(path: Path, target_codec: str) -> tuple[str, float, int, int]:
    """Re-probe a converted file to get the codec/bitrate/sample_rate/channels
    that actually landed, so stored values match ingestion exactly. FLAC (and
    other lossless codecs) typically omit stream-level bit_rate -- fall back
    to format.bit_rate, which ffprobe derives from container size/duration."""
    raw = ffprobe_for_metadata(path)
    if raw is None:
        raise ConversionFailed(f"post-conversion probe of {path} failed")
    metadata = build_track_metadata(raw)
    if metadata is None or metadata.codec != target_codec:
        raise ConversionFailed(
            f"post-conversion probe codec mismatch: expected {target_codec}, "
            f"got {metadata.codec if metadata else None}"
        )
    bitrate_kbps = metadata.bitrate_kbps
    if is_lossless(target_codec) and bitrate_kbps == 0.0:
        fmt_bitrate = raw.get("format", {}).get("bit_rate")
        try:
            if fmt_bitrate is not None:
                bitrate_kbps = float(fmt_bitrate) / 1000.0
        except (TypeError, ValueError):
            pass
    return metadata.codec, bitrate_kbps, metadata.sample_rate_hz, metadata.channels


def _check_disk_space(source: Path, staging_dir: Path, target_codec: str) -> None:
    """Conservative preflight: a lossy->lossless conversion can multiply file
    size, and old + temp(s) + new briefly coexist on disk. No existing
    disk-space helper anywhere in the codebase -- this is new."""
    try:
        source_size = source.stat().st_size
    except OSError:
        source_size = 0
    multiplier = 3 if is_lossless(target_codec) else 1.5
    required = int(source_size * multiplier)
    free = shutil.disk_usage(staging_dir).free
    if free < required:
        raise InsufficientDiskSpace(
            f"need ~{required} bytes free in {staging_dir}, have {free}"
        )


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
        """
        track = self.database.get_track_by_uuid(uuid_id)
        if track is None:
            raise TrackNotFound(uuid_id)
        if base_revision is None or base_revision != track.revision:
            raise RevisionConflict(uuid_id, base_revision, track.revision)

        source = Path(track.file_path)
        if not source.exists():
            raise MasterNotFound(uuid_id)

        if target_codec not in SUPPORTED_TARGET_CODECS or target_codec not in self.available_encoders:
            raise ValueError(f"unsupported or unavailable target codec: {target_codec}")
        if is_lossy(target_codec) and target_bitrate_kbps is None:
            raise ValueError(f"{target_codec} requires a target bitrate")

        source_codec = track.metadata.codec
        if (
            source_codec is not None
            and is_lossless(source_codec)
            and is_lossless(target_codec)
            and source_codec == target_codec
        ):
            raise NoOpConversion(uuid_id)

        self.staging_dir.mkdir(parents=True, exist_ok=True)
        _check_disk_space(source, self.staging_dir, target_codec)

        job_id = self.database.insert_conversion_job(
            uuid_id, target_codec, CODEC_TO_EXT[target_codec], target_bitrate_kbps
        )
        self.encoder_coordinator.submit_conversion(self._run_job, job_id)
        return job_id

    def cancel(self, job_id: int) -> bool:
        """Cancel a queued or running job. Queued jobs the pool hasn't
        started yet are handled by _run_job_inner's own first step losing the
        queued->running race. Running jobs additionally get their ffmpeg
        subprocess killed -- best-effort: a cancel arriving in the narrow
        window between two pipeline steps (not inside an ffmpeg call) can't
        interrupt anything, but the job's terminal status is never clobbered
        back to done (see complete_conversion_job's conditional update)."""
        cancelled = self.database.mark_conversion_job_cancelled(job_id)
        self._registry.kill(job_id)
        return cancelled

    def _run_job(self, job_id: int) -> None:
        # Mandatory outer catch: EncoderCoordinator's pool silently discards
        # any exception a submitted function raises, so nothing upstream of
        # this would ever learn the job failed.
        try:
            self._run_job_inner(job_id)
        except Exception as e:
            self.database.mark_conversion_job_failed(job_id, str(e))

    def _run_job_inner(self, job_id: int) -> None:
        if not self.database.mark_conversion_job_running(job_id):
            return  # lost the queued->running race to a cancel

        job = self.database.get_conversion_job(job_id)
        uuid_id = job["uuid_id"]
        target_codec = job["target_codec"]
        target_bitrate = job["target_bitrate"]

        with self.track_locks.lock(uuid_id):
            track = self.database.get_track_by_uuid(uuid_id)
            if track is None or not Path(track.file_path).exists():
                raise MasterNotFound(uuid_id)
            source = Path(track.file_path)
            dest = source.with_suffix("." + CODEC_TO_EXT[target_codec])

            self.staging_dir.mkdir(parents=True, exist_ok=True)
            transcoded_temp = self.staging_dir / f"{uuid_id}.convert{dest.suffix}"
            tagged_temp = self.staging_dir / f"{uuid_id}.tagged{dest.suffix}"

            # Bit-depth/sample-format mirroring only makes sense for a
            # lossless target -- lossy encoders (native aac, libmp3lame) have
            # their own fixed internal PCM format and reject an explicit
            # -sample_fmt override of the source's (e.g. aac requires fltp;
            # forcing a FLAC source's s16 makes the encoder fail to open).
            source_params = _probe_source_params(source) if is_lossless(target_codec) else None
            result = transcode(
                source, transcoded_temp, target_codec, target_bitrate,
                source_params=source_params, strip_video=False,
                registry=self._registry, job_id=job_id,
            )
            if not result.ok:
                transcoded_temp.unlink(missing_ok=True)
                raise ConversionFailed(result.stderr or "transcode failed")

            self._raise_if_cancelled(job_id)

            # Bake every editable tag from the CURRENT DB metadata, not a
            # patch subset -- transcode() only carried over whatever tags
            # were physically in the (possibly stale, DB-only-edited) source.
            fields = {col: getattr(track.metadata, col) for col in EDITABLE_METADATA_COLUMNS}
            try:
                write_metadata_tags(
                    transcoded_temp, tagged_temp, build_ffmpeg_tags(fields),
                    registry=self._registry, job_id=job_id,
                )
            except TagWriteError as e:
                raise ConversionFailed(str(e)) from e
            finally:
                transcoded_temp.unlink(missing_ok=True)

            self._raise_if_cancelled(job_id)

            codec, bitrate_kbps, sample_rate_hz, channels = _probe_intrinsic_fields(
                tagged_temp, target_codec
            )

            try:
                entry = self.database.insert_journal_entry(
                    "convert", uuid_id,
                    old_path=str(source),
                    new_path=str(dest) if dest != source else None,
                    temp_path=str(tagged_temp),
                )
            except BaseException:
                tagged_temp.unlink(missing_ok=True)  # nothing journaled yet
                raise

            if dest != source:
                if not move_file(file_path=tagged_temp, destination_path=dest):
                    self.database.delete_journal_entry(entry)
                    tagged_temp.unlink(missing_ok=True)
                    raise ConversionFailed(f"could not place converted master at {dest}")
                try:
                    self.database.complete_conversion_job(
                        job_id, uuid_id, codec, bitrate_kbps, sample_rate_hz, channels,
                        file_path=str(dest),
                    )
                except BaseException:
                    # DB did not commit -> revert: drop the new copy, keep the old master.
                    dest.unlink(missing_ok=True)
                    prune_empty_dirs(dest.parent, self.music_library_dir)
                    self.database.delete_journal_entry(entry)
                    raise
                # Committed: DB now points at `dest`; the old master is redundant.
                source.unlink(missing_ok=True)
                prune_empty_dirs(source.parent, self.music_library_dir)
            else:
                # Commit the DB first; a crash before the replace leaves
                # file=old-codec/DB=new-codec, closed by reconcile_journal's
                # "convert" branch (mirrors _inplace's same-path safety).
                self.database.complete_conversion_job(
                    job_id, uuid_id, codec, bitrate_kbps, sample_rate_hz, channels,
                    file_path=None,
                )
                os.replace(tagged_temp, dest)

            self.database.delete_journal_entry(entry)

            self.cache.remove_all_for_uuid(uuid_id)
            if self.default_cache is not None:
                self.default_cache.remove_all_for_uuid(uuid_id)

    def _raise_if_cancelled(self, job_id: int) -> None:
        job = self.database.get_conversion_job(job_id)
        if job is not None and job["status"] == "cancelled":
            raise ConversionFailed("cancelled")


def reconcile_conversion_jobs(database: Database) -> None:
    """Startup pass, separate from reconcile_journal: no worker thread
    survives a process restart, so any conversion_jobs row still 'running'
    is orphaned -- flip it to failed. Independent of journal reconciliation
    (a crash before the journal was even written leaves no journal row at
    all, but the job is still stuck running)."""
    for job in database.list_running_conversion_jobs():
        database.mark_conversion_job_failed(job["id"], "interrupted by restart")
