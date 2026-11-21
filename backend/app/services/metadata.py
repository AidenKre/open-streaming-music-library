import json
import logging
import math
from contextlib import contextmanager
from contextvars import ContextVar
from pathlib import Path
from typing import Optional

from app.core.operator_log import operator_logger
from app.models.edit_fields import EDIT_FIELD_SPECS
from app.models.track_meta_data import TrackMetaData
from app.services import audio_identity
from app.services.media_input import ffmpeg_input_args
from app.services.ffmpeg_runner import (
    CaptureOverflow,
    CaptureTimeout,
    NO_OPTIONS,
    FfmpegError,
    FfmpegProcessRegistry,
    ToolOptions,
    describe_tool_error,
    run_capture,
    run_ffmpeg,
    scaled_timeout,
)

logger = logging.getLogger(__name__)

# stdout bounds for the probes: the metadata JSON can carry large tags; the
# bitrate and quick-check probes print a few bytes.
METADATA_PROBE_MAX_STDOUT_BYTES = 16 * 1024 * 1024
SHORT_PROBE_MAX_STDOUT_BYTES = 64 * 1024
# One embedded picture; more than this is not a cover.
COVER_ART_MAX_BYTES = 16 * 1024 * 1024

# DB column -> ffmpeg metadata key, for the columns whose tag name differs —
# derived from the single field-spec table.
_FFMPEG_TAG_KEY = {
    spec.key: spec.ffmpeg_key for spec in EDIT_FIELD_SPECS if spec.ffmpeg_key
}


class TagWriteError(Exception):
    """Raised when writing tags to a master file fails (ffmpeg non-zero exit,
    timeout, or the re-probe verification did not confirm the change)."""


def build_ffmpeg_tags(fields: dict) -> dict[str, Optional[str]]:
    """Map DB columns to ffmpeg metadata keys for the columns present in
    ``fields``: a present ``None`` clears the tag, an absent column leaves the
    file's tag untouched (the caller decides which columns to reconcile).
    ``year``/``date`` both target the file's ``date`` tag — an explicit
    ``date`` wins, else ``year``. Shared by the PATCH tag-reconcile path and
    Phase 2's conversion tag-baking (which reconciles every editable column,
    not just the ones a PATCH touched)."""
    tags: dict[str, Optional[str]] = {}
    for col in ("title", "artist", "album", "album_artist", "genre"):
        if col in fields:
            tags[col] = fields[col]
    for col in ("track_number", "disc_number"):
        if col in fields:
            v = fields[col]
            tags[_FFMPEG_TAG_KEY[col]] = str(v) if v is not None else None
    if "date" in fields:
        tags["date"] = fields["date"]
    elif "year" in fields:
        v = fields["year"]
        tags["date"] = str(v) if v is not None else None
    return tags


def is_wav(file_path: Path) -> bool:
    """WAV master tagging is out of scope in Phase 1 (RIFF tag support is too
    lossy), so the orchestration degrades a ``db_and_master`` WAV edit to
    DB-only. Keyed off the extension — cheap and good enough for the gate."""
    return file_path.suffix.lower() == ".wav"


def write_metadata_tags(
    source: Path,
    dest: Path,
    tags: dict[str, str | None],
    *,
    options: ToolOptions = NO_OPTIONS,
) -> None:
    """Copy ``source`` to ``dest`` with ``tags`` applied, audio bytes untouched.

    ``tags`` maps ffmpeg metadata keys to values; ``None`` (or "") clears the
    tag. Uses ``-map 0 -c copy -map_metadata 0`` so every stream — including the
    attached-pic cover-art stream — and all unedited tags are preserved; only
    the named tags are overwritten. Because the audio bytes are unchanged, the
    ``(uuid, quality)``-keyed encoded cache stays valid across an edit. Verifies
    by re-probing ``dest`` and raises ``TagWriteError`` on any failure.
    ``options.registry``/``options.job_id`` (both required together) allow a
    conversion job's tag-baking pass to be cancelled — see
    ``FfmpegProcessRegistry``; ``options.input_format`` forces an upload's demuxer.
    """
    cmd = [
        "ffmpeg",
        "-hide_banner",
        "-loglevel", "error",
        "-y",
        *ffmpeg_input_args(options.input_format),
        "-i", str(source),
        "-map", "0",
        "-c", "copy",
        "-map_metadata", "0",
    ]
    for key, value in tags.items():
        cmd += ["-metadata", f"{key}={value if value is not None else ''}"]
    cmd.append(str(dest))

    try:
        run_ffmpeg(
            cmd, dest, timeout=scaled_timeout(source),
            options=options,
        )
    except FfmpegError as e:
        # The category only: ffmpeg's text names the file and the tag values.
        logger.warning("tag write failed: %s", describe_tool_error(e))
        raise TagWriteError("tag write failed") from e

    # Verify the output is still a probe-able audio file (catches a silently
    # corrupt remux). Field-level verification is intentionally light — ffmpeg
    # normalizes some tag spellings, so we confirm probe-ability, not equality.
    if ffprobe_for_metadata(dest, options.input_format) is None:
        dest.unlink(missing_ok=True)
        raise TagWriteError("re-probe of written file failed")

# TODO: Handle non printable characters in metadata (remember the UniBe@t thingy where there were windows /r/n invisible characters...)
# TODO: possible search database to see if artist/album already exists? and match capitalization? might be confusing...


class ProbeUnavailable(RuntimeError):
    """ffprobe could not answer now (missing, cannot start, timed out, killed,
    or an answer that could not be read)."""


_raise_if_unavailable: ContextVar[bool] = ContextVar("raise_if_unavailable", default=False)


@contextmanager
def probe_unavailable_raises():
    """Within this block ffprobe_for_metadata (so get_track_metadata) raises
    ProbeUnavailable when ffprobe cannot start, instead of returning None:
    environmental, not the file's own refusal."""
    token = _raise_if_unavailable.set(True)
    try:
        yield
    finally:
        _raise_if_unavailable.reset(token)


_probe_registry: ContextVar[Optional[FfmpegProcessRegistry]] = ContextVar("probe_registry", default=None)


@contextmanager
def probes_killed_by(registry: Optional[FfmpegProcessRegistry]):
    """Within this block ffprobe_for_metadata and the ingest quick check run
    their process registered in ``registry`` (None: none), so closing it at
    shutdown ends a probe without waiting out the bound."""
    token = _probe_registry.set(registry)
    try:
        yield
    finally:
        _probe_registry.reset(token)


@contextmanager
def probe_registration():
    """The ``ToolOptions`` for one probe's ``run_capture``: the registry set by
    ``probes_killed_by`` under a fresh job id, forgotten afterwards; no
    options outside such a block."""
    registry = _probe_registry.get()
    if registry is None:
        yield NO_OPTIONS
        return
    job_id = object()  # unique per call: concurrent probes never share a kill flag
    try:
        yield ToolOptions(registry=registry, job_id=job_id)
    finally:
        registry.forget(job_id)


def probe_timeout(timeout: Optional[float]) -> float:
    """The bound for one probe: ``timeout``, else the shared probe bound
    (read at call time)."""
    return audio_identity.PROBE_TIMEOUT_S if timeout is None else timeout


def _probe_unavailable(message: str, cause: Optional[BaseException] = None) -> None:
    """Unreadable for now (environmental): raises inside
    probe_unavailable_raises, else None."""
    if _raise_if_unavailable.get():
        raise ProbeUnavailable(message) from cause
    return None


def get_track_metadata(file_path: Path, timeout: Optional[float] = None) -> TrackMetaData | None:
    json_data = ffprobe_for_metadata(file_path, timeout=timeout)
    if json_data is None:
        return None
    metadata = build_track_metadata(json_data)
    if metadata is None:
        return None
    if metadata.is_empty():
        return None
    return metadata


def get_audio_bitrate_kbps(path: Path, timeout: Optional[float] = None) -> int | None:
    """Return the audio stream's bitrate in kbps, or None on failure.

    Issues a targeted ffprobe query for only the bit_rate field — lighter than
    the full metadata probe. Returns None when ffprobe is unavailable, times
    out (bounded by ``timeout``, default the shared probe bound), the file has
    no audio stream, or the value cannot be parsed. Callers should treat None
    as "unknown" and proceed conservatively (e.g. allow transcoding).
    """
    try:
        result = run_capture(
            [
                "ffprobe",
                "-v", "quiet",
                "-select_streams", "a:0",
                "-show_entries", "stream=bit_rate",
                "-of", "default=noprint_wrappers=1:nokey=1",
                str(path),
            ],
            timeout_s=probe_timeout(timeout),
            max_stdout_bytes=SHORT_PROBE_MAX_STDOUT_BYTES,
        )
    except (FfmpegError, OSError):
        return None
    if result.returncode != 0:
        return None

    raw = result.stdout.decode("utf-8", errors="replace").strip()
    if not raw or raw == "N/A":
        return None
    try:
        return int(raw) // 1000
    except ValueError:
        return None


def ffprobe_for_metadata(
    file_path: Path, input_format: str | None = None, timeout: Optional[float] = None
) -> dict | None:
    """ffprobe's JSON for ``file_path``, or None. Bounded by ``timeout``
    (default the shared probe bound). A tool that cannot start, a time-out, a
    kill by any signal, an overflowing or garbled answer is unreadable for now
    (ProbeUnavailable inside probe_unavailable_raises, else None): startup
    recovery treats only a refusal as the file's own answer, so nothing it
    cannot prove reads as one. Any other non-zero exit is the file's own
    answer (None)."""
    try:
        with probe_registration() as registration:
            completed_process = run_capture(
                [
                    "ffprobe",
                    "-v",
                    "error",
                    "-hide_banner",
                    "-show_streams",
                    "-show_format",
                    "-of",
                    "json",
                    *ffmpeg_input_args(input_format),
                    str(file_path),
                ],
                timeout_s=probe_timeout(timeout),
                max_stdout_bytes=METADATA_PROBE_MAX_STDOUT_BYTES,
                options=registration,
            )
    except CaptureOverflow as e:
        return _probe_unavailable("ffprobe answered too much", e)
    except CaptureTimeout as e:
        return _probe_unavailable("ffprobe timed out", e)
    except FfmpegError as e:  # not found, or cannot start
        if isinstance(e.__cause__, FileNotFoundError):
            operator_logger.warning("ffprobe not found")
        return _probe_unavailable(str(e), e)
    except OSError as e:  # setting up the pipes failed (e.g. EMFILE): cannot run now
        return _probe_unavailable(f"ffprobe cannot run: {e.strerror or type(e).__name__}", e)

    if completed_process.returncode < 0:
        # Killed by a signal (a stop, the OOM killer, a crash): says nothing
        # about the file. Startup recovery's content rule (D1) deletes a
        # leftover only on a refusal, so this must read as unknown there.
        return _probe_unavailable("ffprobe was killed")
    if completed_process.returncode != 0:
        return None

    try:
        return json.loads(completed_process.stdout.decode("utf-8", errors="replace") or "{}")
    except json.JSONDecodeError as e:
        return _probe_unavailable("ffprobe answered garbage", e)


def build_track_metadata(json_data: dict) -> TrackMetaData | None:
    raw_format_tags = json_data.get("format", {}).get("tags", {})
    format_tags = {k.lower(): v for k, v in raw_format_tags.items()}
    streams = json_data.get("streams", {})

    audio_stream = None
    has_album_art = False

    for raw_stream in streams:
        stream = {k.lower(): v for k, v in raw_stream.items()}
        stream_type = stream.get("codec_type")
        if stream_type == "audio":
            audio_stream = stream
            continue

        if stream.get("disposition", {}).get("attached_pic") == 1:
            has_album_art = True
            continue

    if audio_stream is None:
        return None

    metadata = TrackMetaData()

    codec = audio_stream.get("codec_name", None)
    if codec:
        codec = str(codec)

    metadata.codec = codec
    metadata.duration = _parse_float(audio_stream.get("duration"))
    # FLAC (and some other containers) carry no stream-level bit_rate; fall
    # back to format.bit_rate, which ffprobe derives from file size/duration
    # (so it includes embedded art -- a small overstatement beats not
    # knowing). Neither reported -> None ("unknown"), never a made-up 0.
    stream_bitrate = _bitrate_kbps(audio_stream.get("bit_rate"))
    metadata.bitrate_kbps = (
        stream_bitrate if stream_bitrate is not None
        else _bitrate_kbps(json_data.get("format", {}).get("bit_rate"))
    )
    metadata.sample_rate_hz = _parse_int(audio_stream.get("sample_rate"))
    metadata.channels = _parse_int(audio_stream.get("channels"))

    metadata.has_album_art = has_album_art

    if metadata.is_empty():
        return None

    metadata.title = format_tags.get("title")
    metadata.artist = format_tags.get("artist")
    metadata.album = format_tags.get("album")
    metadata.album_artist = format_tags.get("album_artist")
    date_val = format_tags.get("date") if "date" in format_tags else None
    metadata.date = date_val
    metadata.year = _parse_year(date_val)

    metadata.genre = format_tags.get("genre")
    metadata.track_number = (
        _parse_track_number(format_tags.get("track"))
        if "track" in format_tags
        else None
    )
    metadata.disc_number = (
        _parse_track_number(format_tags.get("disc")) if "disc" in format_tags else None
    )

    return metadata


def extract_cover_art_bytes(file_path: Path, input_format: str | None = None) -> bytes | None:
    """Extract embedded cover art from an audio file using ffmpeg."""
    try:
        with probe_registration() as registration:
            result = run_capture(
                [
                    "ffmpeg",
                    *ffmpeg_input_args(input_format),
                    "-i", str(file_path),
                    "-an",
                    "-vcodec", "copy",
                    "-frames:v", "1",
                    "-f", "image2pipe",
                    "-",
                ],
                timeout_s=30,
                max_stdout_bytes=COVER_ART_MAX_BYTES,
                options=registration,
            )
    except CaptureOverflow:
        logger.warning(
            "embedded cover art not used: the picture is larger than %d bytes", COVER_ART_MAX_BYTES
        )
        return None
    except (FfmpegError, OSError):
        return None

    if result.returncode != 0 or not result.stdout:
        return None

    return result.stdout


def _parse_float(value: object) -> float | None:
    try:
        parsed = float(value)  # type: ignore[arg-type]
    except (TypeError, ValueError, OverflowError):
        return None
    return parsed if math.isfinite(parsed) else None


def _parse_int(value: object) -> int | None:
    try:
        return int(value)  # type: ignore[arg-type]
    except (TypeError, ValueError, OverflowError):
        return None


def _bitrate_kbps(bit_rate: object) -> float | None:
    """ffprobe's bit_rate (bits/s, usually a string; may be missing or "N/A")
    in kbps, or None when it isn't reported or can't be parsed."""
    try:
        value = float(bit_rate)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return None
    return value / 1000.0 if value >= 0 else None


def _parse_year(date_val: object) -> int | None:
    """
    Best-effort year extraction from ffprobe date tags.
    Common values: "2021", "2021-06-01", sometimes numeric.
    """
    if date_val is None:
        return None
    if isinstance(date_val, int):
        return date_val
    if not isinstance(date_val, str):
        return None
    if not date_val.strip():
        return None
    try:
        return int(date_val.split("-")[0])
    except (ValueError, TypeError):
        return None


def _parse_track_number(track_val: object) -> int | None:
    """
    Best-effort parsing from ffprobe track tags.
    Common values: "1", "1/12", sometimes numeric.
    """
    if track_val is None:
        return None
    if isinstance(track_val, int):
        return track_val
    if not isinstance(track_val, str):
        return None
    if not track_val.strip():
        return None
    try:
        return int(track_val.split("/")[0])
    except (ValueError, TypeError):
        return None
