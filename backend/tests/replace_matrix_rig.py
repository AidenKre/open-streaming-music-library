"""A rig for the "replace a track's file" crash matrix (refactor piece BE-REPLACE).

Four writers swap a track's audio file: a tag edit that moves the file (W1), a
conversion to another extension (W2), a tag edit that keeps the path (W3) and a
conversion that keeps the path (W4). The rig runs the real writer on a real
``Database`` (the product's class and schema) and real files under a temporary
music folder, stops it at a chosen step, runs the real recovery entry points and
reads the result back with plain SQL and plain file reads.

What is real: ``TrackEditor``, ``ConversionOrchestrator``, ``Database``, the file
helpers, the track locks, the storage ledger, ``reconcile_journal`` (start-up),
``reconcile_conversion_jobs``, ``finish_kept_journal_rows`` (the idle pass) and
the fence of the next edit or conversion.

What is faked, and only that: the media tools. A file's bytes are
``b"<audio>|artist=<a>;title=<t>"``; the fake tag writer, encoder, probe, hash
and recovery reader derive everything from those bytes (``AUDIO`` gives each
audio its codec, bitrate and sample rate), so "the old audio or the new audio,
never a mixture" is an exact byte comparison. The two encoded caches are
recording stand-ins (the start-up steps the rig runs list no processes: the
sweep of left-over encoder processes is main.py's own, before them). Each fake
media tool first binds
its call to the real tool's signature (``tests/tool_call_capture.py``), so it
cannot swallow an argument the real tool does not take.

Steps. Every state-changing thing the writer or recovery does is one step, named
without reference to the product module that does it, so the names survive a
move of the code:

- ``db.<method>``: a call of a ``Database`` method that writes (the rig refuses
  a method it has not classified as a read or a write);
- ``db.make_durable``: a durable point;
- ``fs.<operation> <what>``: a real file operation under the music folder, taken
  at the ``os`` module whichever helper makes it (``replace``, ``rename``,
  ``link``, ``unlink``, ``rmdir``, ``mkdir``, ``symlink``), and ``fs.flush
  <what>`` for a flush of a file or folder; paths are shown by role (``O`` the
  old master, ``N`` the new path, ``T`` the staged copy, ``dir(O)`` ...);
- ``cache.evict``, ``default_cache.evict``, ``ledger.reserve``,
  ``ledger.release``, ``signal.notify``, ``log.operator``.

A kill (``Crash``, a ``BaseException``) can be placed before any step. In "park"
mode the writer runs in its own thread and is frozen at the step: no ``finally``
and no ``except`` of the product runs, exactly as when a process dies; the test
then starts a new "process" (new ``Database`` object on the same file, new
locks, an empty remembered-old-files registry). In "raise" mode the ``Crash``
propagates through the product's own handlers and the server lives on. Ordinary
faults (an error, another answer) can be placed on any step too.

The kill is the shared ``tests.crash.Crash``.
"""

from __future__ import annotations

import atexit
import fcntl
import inspect
import logging
import os
import shutil
import sqlite3
import tempfile
import threading
from contextlib import contextmanager
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Optional

import pytest

from app.database.database import ANY_OWNER, ConversionJobActive, Database, DatabaseContext
from app.library import Library
from app.models.track import Track
from app.models.track_meta_data import TrackMetaData
from app.services import conversion as conversion_module
from app.services import audio_identity, file_ops, metadata, transcoder
from app.services import track_editor as track_editor_module
from app.services.audio_identity import AudioIdentity, ExactAudioHash
from app.services.conversion import (
    ConversionOrchestrator,
    PendingRecovery,
    reconcile_conversion_jobs,
)
from app.services.encoded_cache import evict_track_caches
from app.services.keyed_locks import KeyedLocks
from app.services.recovery_audio import PROBE_OK, PROBE_REFUSED, AudioReading
from app.services.storage_ledger import StorageLedger
from app.services.track_edit import WriteMode
from app.services.track_editor import (
    MasterWriteError,
    PendingOldMasters,
    TrackEditor,
    finish_kept_journal_rows,
    reconcile_journal,
)
from app.services.track_locks import TrackLocks
from app.services.transcoder import TranscodeResult
from tests.crash import Crash
from tests.recovery_steps import in_startup_order
from tests.schema_fixtures import INIT_SQL
from tests.tool_call_capture import bound_to
from tests.track_paths import allow_two_tracks_on_one_path, set_track_path, stale_path_rows

OPERATOR_LOGGER = "uvicorn.error"
# The start-up recovery steps of main.py this rig runs (``World.start_up``);
# the others touch nothing the matrix plants.
STARTUP_STEPS = ("edit journal", "conversion jobs", "storage reservations")


# --- the fake media ---------------------------------------------------------------------------------

# audio -> (codec, bitrate kbps, sample rate): no two alike, so a catalog that
# describes the wrong file is visible.
AUDIO = {
    "A": ("aac", 200.0, 48000),
    "F": ("flac", 900.0, 96000),
    "M3": ("mp3", 320.0, 44100),
    # The same format re-encoded: only the bitrate differs from M3, as in real
    # use, so "was the swap done" rests on the bitrate alone.
    "M1": ("mp3", 128.0, 44100),
    "B": ("aac", 96.0, 22050),  # the same owner's other track
    "S": ("aac", 64.0, 16000),  # the other user's track
    "Z": ("aac", 160.0, 24000),  # a file from somewhere else
}
_TRANSCODES = {("aac", 192): "A", ("mp3", 128): "M1"}


def master(audio: str, title: str, artist: str) -> bytes:
    """The bytes of a master file with this audio and these tags."""
    return f"{audio}|artist={artist};title={title}".encode()


def audio_of(data: bytes) -> str:
    return data.split(b"|", 1)[0].decode()


def digest_of(audio: str) -> str:
    return (audio + "-") * 8


def _hash_of(audio: str) -> ExactAudioHash:
    codec, _bitrate, rate = AUDIO[audio]
    kind = "pcm_sha256" if codec == "flac" else "packets_sha256"
    return ExactAudioHash(kind, digest_of(audio), rate, 2, None)


def _metadata_of(audio: str, title: str = "leftover", artist: str = "Art") -> TrackMetaData:
    codec, bitrate, rate = AUDIO[audio]
    return TrackMetaData(codec=codec, bitrate_kbps=bitrate, sample_rate_hz=rate, channels=2,
                         duration=2.0, title=title, artist=artist)


@bound_to(metadata.write_metadata_tags)
def fake_write_metadata_tags(source, dest, tags, **kwargs) -> None:
    """The tag writer: the source's audio, the given tags."""
    audio = audio_of(Path(source).read_bytes())
    Path(dest).write_bytes(master(audio, tags.get("title") or "?", tags.get("artist") or "?"))


@bound_to(transcoder.transcode)
def fake_transcode(source, dest, target_codec, target_bitrate, *args, **kwargs) -> TranscodeResult:
    """The encoder: other audio, no tags yet."""
    Path(dest).write_bytes(_TRANSCODES[(target_codec, target_bitrate)].encode() + b"|raw")
    return TranscodeResult(ok=True)


def fake_ffprobe(path, *args, **kwargs):
    inspect.signature(metadata.ffprobe_for_metadata).bind(path, *args, **kwargs)
    return {"fake_audio": audio_of(Path(path).read_bytes())}


def fake_build_track_metadata(raw):
    inspect.signature(metadata.build_track_metadata).bind(raw)
    return _metadata_of(raw["fake_audio"])


@bound_to(audio_identity.compute_identity)
def fake_compute_identity(path, codec_hint=None, **kwargs) -> AudioIdentity:
    return AudioIdentity(exact=_hash_of(audio_of(Path(path).read_bytes())),
                         tool_versions="fake-tools", computed_at=1_700_000_000)


def fake_read(path) -> AudioReading:
    """Start-up recovery's reader. ``X`` is a file the probe refuses."""
    audio = audio_of(Path(path).read_bytes())
    if audio == "X":
        return AudioReading(PROBE_REFUSED, None, None)
    return AudioReading(PROBE_OK, _metadata_of(audio), _hash_of(audio))


# --- the four writers -------------------------------------------------------------------------------


@dataclass(frozen=True)
class Writer:
    name: str
    kind: str  # "edit" | "convert"
    moving: bool
    old_rel: str
    new_rel: str
    old_audio: str
    new_audio: str
    old_tags: tuple  # (title, artist)
    new_tags: tuple
    fields: Optional[dict] = None  # the edit
    target: Optional[tuple] = None  # the conversion: (codec, bitrate)

    @property
    def old_bytes(self) -> bytes:
        return master(self.old_audio, *self.old_tags)

    @property
    def new_bytes(self) -> bytes:
        return master(self.new_audio, *self.new_tags)


W1 = Writer("W1", "edit", True, "owner/Old/song.m4a", "owner/New/song.m4a", "A", "A",
            ("Song", "Old"), ("Song", "New"), fields={"artist": "New"})
W2 = Writer("W2", "convert", True, "owner/Art/song.flac", "owner/Art/song.m4a", "F", "A",
            ("Song", "Art"), ("Song", "Art"), target=("aac", 192))
W3 = Writer("W3", "edit", False, "owner/Art/song.m4a", "owner/Art/song.m4a", "A", "A",
            ("Song", "Art"), ("Renamed", "Art"), fields={"title": "Renamed"})
W4 = Writer("W4", "convert", False, "owner/Art/song.mp3", "owner/Art/song.mp3", "M3", "M1",
            ("Song", "Art"), ("Song", "Art"), target=("mp3", 128))
WRITERS = {w.name: w for w in (W1, W2, W3, W4)}

# The other tracks every world holds; none of them may ever change. The other
# user's file has the target's own relative name inside another root.
BYSTANDERS = {
    "owner/Keep/other.m4a": ("B", "Other", "Keep", "owner"),
    "other/Art/song.m4a": ("S", "Song", "Art", "other"),
    "other/Old/song.m4a": ("S", "Song", "Old", "other"),
}


# --- recording, faults and kills --------------------------------------------------------------------

# Database methods that change the database (each call is a step) ...
DB_WRITES = frozenset({
    "insert_journal_entry", "delete_journal_entry", "apply_track_metadata_edit",
    "complete_conversion_job", "undo_inplace_conversion", "mark_audio_identity_stale",
    "write_conversion_identity",
    "mark_conversion_job_running", "mark_conversion_job_failed",
    "mark_conversion_job_cancelled", "settle_swapped_conversion_job", "bump_track_revision",
    "refresh_track_audio_properties", "add_track", "insert_conversion_job",
    "release_storage_leases_except", "make_durable",
})
# ... and methods that only read, or whose writes the rig records elsewhere
# (the storage ledger's rows are recorded as ledger steps).
DB_READS = frozenset({
    "get_track_by_uuid", "get_track_file_path", "is_pending_deletion", "list_journal_entries",
    "has_journal_entry_for_uuid", "get_user", "get_conversion_job", "track_path_in_use",
    "get_audio_identity", "list_conversion_jobs_with_status", "get_deleting_user_ids",
    "reserve_storage", "release_storage", "storage_totals",
})
_FS_OPERATIONS = ("replace", "rename", "link", "unlink", "remove", "rmdir", "mkdir", "symlink")
_TWO_PATHS = ("replace", "rename", "link", "symlink")


@dataclass
class Fault:
    step: str
    nth: int = 1
    times: int = 1
    # kill | raise | answer | raise_after | observe (the step is performed as
    # usual; only ``then`` runs first)
    kind: str = "kill"
    error: Optional[BaseException] = None
    answer: Any = None
    then: Optional[Callable[[], None]] = None  # runs when the fault fires
    hits: int = 0


class _Frozen:
    """One thread stopped at its kill point."""

    def __init__(self):
        self.parked = threading.Event()
        self.stopped = threading.Event()
        self.release = threading.Event()
        self.thread: Optional[threading.Thread] = None
        self.outcome: Any = None


# Steps a kill can be placed before by number (``kill_index``): the ones that
# change the disk or the database. Evictions, wake-ups and log lines change
# nothing a new process reads.
_COUNTED = ("db.", "fs.", "ledger.")


class Recorder:
    """Writes down every step and applies the faults placed on steps."""

    def __init__(self, world: "World"):
        self.world = world
        self.steps: list[str] = []  # the current phase
        self.phases: dict[str, list[str]] = {}
        self.timeline: list[str] = []  # the steps performed, over all phases, in order
        self.locked: list[bool] = []  # whether the track's lock was held at each step
        self.operator_lines: list[tuple[str, str]] = []  # (level, text) of the whole test
        self.violations: list[str] = []  # rules broken at a step, whoever swallowed what
        self.faults: list[Fault] = []
        self.kill_index: Optional[int] = None  # kill before the n-th counted step of the phase
        self.counted = 0
        self._seen: dict[str, int] = {}
        self._fds: dict[int, str] = {}
        self._freezing: Optional[_Frozen] = None
        self._frozen: list[_Frozen] = []
        self._lines_at_begin = 0
        self.last_outcome: Any = None
        self.recording = True

    # --- phases and faults ---

    def begin(self, phase: str) -> None:
        self.steps = self.phases.setdefault(phase, [])
        self.locked = []
        self._seen = {}
        self.faults = []
        self.kill_index = None
        self.counted = 0
        self._lines_at_begin = len(self.operator_lines)

    def warned(self) -> bool:
        """Whether the operator log got a warning in this phase."""
        return any(level == "WARNING" for level, _ in self.operator_lines[self._lines_at_begin:])

    def place(self, step: str, kind: str = "kill", *, nth: int = 1, times: int = 1, error=None,
              answer=None, then=None) -> Fault:
        fault = Fault(step, nth, times, kind, error, answer, then)
        self.faults.append(fault)
        return fault

    def _fault(self, step: str) -> Optional[Fault]:
        count = self._seen[step] = self._seen.get(step, 0) + 1
        if step.startswith(_COUNTED):
            self.counted += 1
            if self.kill_index == self.counted:
                return Fault(step)
        for fault in self.faults:
            if fault.step == step and fault.nth <= count < fault.nth + fault.times:
                fault.hits += 1
                return fault
        return None

    def _silent(self) -> bool:
        """Not the server's doing: a test's own change, or a thawed thread."""
        return not self.recording or threading.current_thread() in self._thawed

    def step(self, step: str, perform: Callable[[], Any] = lambda: None):
        """One step: apply its fault or perform it, and write it down."""
        if self._silent():
            return perform()
        fault = self._fault(step)
        self.locked.append(self.world.track_lock_held())
        if fault is not None and fault.then is not None:
            fault.then()
        if fault is not None and fault.kind == "kill":
            self.steps.append(f"KILL before {step}")
            frozen = self._freezing
            if frozen is not None and threading.current_thread() is frozen.thread:
                frozen.parked.set()
                frozen.stopped.set()
                frozen.release.wait()
            raise Crash()
        if fault is not None and fault.kind == "raise":
            self.steps.append(f"{step} raises {type(fault.error).__name__}")
            raise fault.error
        if fault is not None and fault.kind == "answer":
            self.steps.append(f"{step} -> {fault.answer!r}")
            return fault.answer
        try:
            result = perform()
        except BaseException as exc:
            self.steps.append(f"{step} raises {type(exc).__name__}")
            raise
        self.steps.append(step)
        self.timeline.append(step)
        if fault is not None and fault.kind == "raise_after":
            self.steps.append(f"then raises {type(fault.error).__name__}")
            raise fault.error
        return result

    # --- a process frozen at its kill point ---

    _thawed: frozenset = frozenset()

    def run_parked(self, run: Callable[[], Any]) -> bool:
        """Run ``run`` in a thread of its own until the kill placed on a step
        freezes it there: nothing of the product unwinds, as when a process
        dies. Returns False when ``run`` ended without reaching a kill."""
        frozen = _Frozen()

        def body():
            try:
                frozen.outcome = ("returned", run())
            except Crash:
                frozen.outcome = ("killed", None)
            except BaseException as exc:  # noqa: BLE001 - reported to the test
                frozen.outcome = ("raised", exc)
            finally:
                frozen.stopped.set()

        frozen.thread = threading.Thread(target=body, daemon=True)
        self._freezing = frozen
        frozen.thread.start()
        assert frozen.stopped.wait(timeout=30), "neither ended nor reached its kill point"
        self._freezing = None
        self.last_outcome = frozen.outcome
        if not frozen.parked.is_set():
            frozen.thread.join(timeout=30)
            return False
        self._frozen.append(frozen)
        return True

    def run_killed(self, run: Callable[[], Any]) -> None:
        """``run_parked``, for a kill that must be reached."""
        assert self.run_parked(run), (
            f"ended ({self.last_outcome!r}) without reaching the step of its kill "
            f"{[(f.step, f.nth) for f in self.faults]}; steps: {self.steps}")

    def thaw(self) -> None:
        """End the frozen threads (their unwinding is not recorded, not faulted)."""
        self._thawed = frozenset(f.thread for f in self._frozen)
        for frozen in self._frozen:
            frozen.release.set()
            frozen.thread.join(timeout=30)
            assert not frozen.thread.is_alive()
        self._frozen = []

    # --- the os module ---

    def _ours(self, value) -> Optional[str]:
        if not isinstance(value, (str, os.PathLike)):
            return None
        path = os.fspath(value)
        if isinstance(path, bytes):
            return None
        music = str(self.world.music)
        return path if path == music or path.startswith(music + os.sep) else None

    def install(self, patch) -> None:
        for name in _FS_OPERATIONS:
            patch.setattr(os, name, self._fs_call(name, getattr(os, name)))
        real_open, real_close, real_fsync, real_fcntl = os.open, os.close, os.fsync, fcntl.fcntl

        def open_(path, *args, **kwargs):
            fd = real_open(path, *args, **kwargs)
            ours = self._ours(path)
            if ours is not None:
                self._fds[fd] = ours
            else:
                self._fds.pop(fd, None)
            return fd

        def close(fd):
            self._fds.pop(fd, None)
            return real_close(fd)

        def fsync(fd):
            path = self._fds.get(fd)
            if path is None:
                return real_fsync(fd)
            return self.step(f"fs.flush {self.world.show(path)}")

        def fcntl_(fd, cmd, *args):
            path = self._fds.get(fd)
            if path is None or cmd != getattr(fcntl, "F_FULLFSYNC", object()):
                return real_fcntl(fd, cmd, *args)
            return self.step(f"fs.flush {self.world.show(path)}", lambda: 0)

        patch.setattr(os, "open", open_)
        patch.setattr(os, "close", close)
        patch.setattr(os, "fsync", fsync)
        patch.setattr(fcntl, "fcntl", fcntl_)
        handler = _OperatorLines(self)
        logger = logging.getLogger(OPERATOR_LOGGER)
        patch.setattr(logger, "handlers", [*logger.handlers, handler])
        patch.setattr(logger, "level", logging.INFO)
        patch.setattr(logger, "disabled", False)

    def _fs_call(self, name: str, real):
        name = "unlink" if name == "remove" else name  # one operation, two names

        def call(*args, **kwargs):
            paths = [self._ours(a) for a in args[: 2 if name in _TWO_PATHS else 1]]
            if name == "symlink":
                paths = paths[1:]
            if not any(paths) or self._silent():
                return real(*args, **kwargs)
            # Only a change is a step: "make it if it is not there", "remove it
            # if it is there" and "remove the folder if it is empty" are none
            # when there is nothing to do.
            if name == "mkdir" and os.path.lexists(args[0]):
                return real(*args, **kwargs)
            if name == "unlink" and not os.path.lexists(args[0]):
                return real(*args, **kwargs)
            if name == "rmdir" and not _empty_folder(args[0]):
                return real(*args, **kwargs)
            shown = " -> ".join(self.world.show(p) if p else "<outside>" for p in paths)

            def perform():
                self.world.judge(name, args)
                return real(*args, **kwargs)

            return self.step(f"fs.{name} {shown}", perform)

        return call


def _empty_folder(path) -> bool:
    try:
        return not os.path.islink(path) and not os.listdir(path)
    except OSError:
        return False


class _OperatorLines(logging.Handler):
    def __init__(self, recorder: Recorder):
        super().__init__(level=logging.INFO)
        self._recorder = recorder

    def emit(self, record: logging.LogRecord) -> None:
        text = record.getMessage()
        self._recorder.operator_lines.append((record.levelname, text))
        if self._recorder.recording:
            self._recorder.steps.append(f"log.operator.{record.levelname}")


class RecordingDatabase:
    """The real ``Database`` with every write a step. A method the rig has not
    classified is refused, so a new write can never go unrecorded."""

    def __init__(self, real: Database, recorder: Recorder):
        self._real, self._recorder = real, recorder

    @property
    def context(self):
        return self._real.context

    def __getattr__(self, name):
        attribute = getattr(self._real, name)
        if name.startswith("_") or not callable(attribute):
            return attribute
        if name in DB_READS:
            return attribute
        if name not in DB_WRITES:
            raise AssertionError(
                f"Database.{name} is not classified in replace_matrix_rig "
                "(add it to DB_READS or DB_WRITES)")

        def call(*args, **kwargs):
            step = f"db.{name}"
            if name == "make_durable" and kwargs.get("timeout") == 0:
                step += "(no wait)"  # asked once, without waiting for a busy database
            result = self._recorder.step(step, lambda: attribute(*args, **kwargs))
            if name == "make_durable" and result is True:
                self._recorder.world.keep_durable_image()
            return result

        return call


class RecordingCache:
    def __init__(self, recorder: Recorder, label: str):
        self._recorder, self._label = recorder, label
        self.evicted: list[str] = []

    def remove_all_for_uuid(self, uuid_id: str) -> None:
        self._recorder.step(f"{self._label}.evict", lambda: self.evicted.append(uuid_id))


class RecordingLedger:
    """The real storage ledger; a reservation taken or given back is a step."""

    def __init__(self, real: StorageLedger, recorder: Recorder):
        self._real, self._recorder = real, recorder

    def reserve(self, **kwargs) -> int:
        return self._recorder.step("ledger.reserve", lambda: self._real.reserve(**kwargs))

    def release(self, reservation_id) -> bool:
        return self._recorder.step("ledger.release", lambda: self._real.release(reservation_id))

    def check(self, **kwargs) -> None:
        return self._real.check(**kwargs)

    def reconcile(self) -> int:
        return self._real.reconcile()


class Wakeup:
    """The identity worker's wake-up. Each call writes down whether the track's
    identity row, read by a new connection, was waiting for work at that moment."""

    def __init__(self, world: "World"):
        self._world = world
        self.saw_pending: list[bool] = []

    def notify(self) -> None:
        row = self._world.identity()
        self.saw_pending.append(bool(row) and "pending" in (
            row["exact_state"], row["fp_state"], row["match_state"]))
        self._world.recorder.step("signal.notify")


class _Coordinator:
    def __init__(self):
        self.submitted: list[tuple] = []

    def submit_conversion(self, fn, *args, **kwargs):
        self.submitted.append((fn, args, kwargs))


# --- the world --------------------------------------------------------------------------------------


@dataclass
class World:
    tmp: Path
    writer: Writer
    patch: Any  # the test's monkeypatch
    music: Path = field(init=False)
    staging: Path = field(init=False)
    database_path: Path = field(init=False)
    recorder: Recorder = field(init=False)
    owner: int = 0
    other: int = 0
    uuid: str = ""
    revision0: int = 0
    counter0: int = 0
    identity0: Optional[dict] = None
    job_id: Optional[int] = None
    boots: int = 0
    _reader: Any = None  # the connection of ``reading``
    durable: dict = field(default_factory=dict)  # what ``judge`` reads (``keep_durable_image``)
    power_cuts: bool = False  # keep a whole database image at each durable point
    sweeping: bool = False  # inside the start-up sweep of staging (see ``judge``)
    bystander_uuids: dict = field(default_factory=dict)
    bystander_rows: dict = field(default_factory=dict)
    bystander_stats: dict = field(default_factory=dict)
    # One server process's objects (replaced by ``boot``).
    db: Any = None
    locks: Any = None
    pending: Any = None
    wakeup: Any = None
    cache: Any = None
    default_cache: Any = None
    ledger: Any = None
    editor: Any = None
    orchestrator: Any = None
    coordinator: Any = None

    def __post_init__(self):
        self.music = self.tmp / "music"
        self.staging = self.music / ".staging"
        self.database_path = self.tmp / "data" / "db.sqlite"
        self.recorder = Recorder(self)

    # --- paths ---

    @property
    def old(self) -> Path:
        return self.music / self.writer.old_rel

    @property
    def new(self) -> Path:
        return self.music / self.writer.new_rel

    @property
    def root(self) -> Path:
        return self.music / "owner"

    def show(self, path) -> str:
        """A path by its role."""
        path = Path(path)
        roles = {self.old: "O", self.music: "music", self.root: "root", self.staging: "staging"}
        if self.new != self.old:
            roles[self.new] = "N"
        if path in roles:
            return roles[path]
        if path.parent == self.staging:
            for mark, role in ((".edit.", "T"), (".tagged.", "T"), (".convert.", "C")):
                if mark in path.name:
                    return role
        if path == self.old.parent:
            return "dir(O)"
        if path == self.new.parent:
            return "dir(N)"
        return str(path.relative_to(self.music))

    def track_lock_held(self) -> bool:
        return self.locks is not None and self.locks.lock_for(self.uuid).locked()

    # --- plain SQL ---

    @contextmanager
    def reading(self):
        """One connection for a run of reads (a check reads a dozen rows; nothing
        of the product runs meanwhile)."""
        if self._reader is not None:
            yield
            return
        self._reader = sqlite3.connect(self.database_path)
        self._reader.row_factory = sqlite3.Row
        try:
            yield
        finally:
            self._reader.close()
            self._reader = None

    def sql(self, statement: str, params=()) -> list[dict]:
        if self._reader is not None:
            return [dict(r) for r in self._reader.execute(statement, params).fetchall()]
        conn = sqlite3.connect(self.database_path)
        conn.row_factory = sqlite3.Row
        try:
            rows = [dict(r) for r in conn.execute(statement, params).fetchall()]
            conn.commit()
            return rows
        finally:
            conn.close()

    def track(self, uuid_id: Optional[str] = None) -> Optional[dict]:
        rows = self.sql(
            "SELECT t.file_path, t.revision, t.owner_id, m.title, m.artist, m.codec, "
            "m.bitrate_kbps, m.sample_rate_hz, m.channels FROM tracks t "
            "JOIN trackmetadata m ON m.uuid_id = t.uuid_id WHERE t.uuid_id = ?",
            (uuid_id or self.uuid,))
        return rows[0] if rows else None

    def identity(self) -> Optional[dict]:
        rows = self.sql(
            "SELECT generation, exact_state, exact_digest, fp_state, match_state "
            "FROM track_audio_identity WHERE uuid_id = ?", (self.uuid,))
        return rows[0] if rows else None

    def journal(self) -> list[dict]:
        return self.sql("SELECT * FROM edit_journal ORDER BY id")

    def job(self, job_id: Optional[int] = None) -> Optional[tuple]:
        rows = self.sql("SELECT status, error_text FROM conversion_jobs WHERE id = ?",
                        (job_id or self.job_id,))
        return (rows[0]["status"], rows[0]["error_text"]) if rows else None

    def reservations(self) -> int:
        return self.sql("SELECT COUNT(*) AS n FROM storage_reservations")[0]["n"]

    # --- files ---

    def files(self) -> dict:
        """Everything under the music folder that is not a folder: relative
        path -> bytes, or ("link", target) for a symbolic link."""
        found = {}
        for path in sorted(self.music.rglob("*")):
            rel = str(path.relative_to(self.music))
            if path.is_symlink():
                found[rel] = ("link", os.readlink(path))
            elif path.is_file():
                found[rel] = path.read_bytes()
        return found

    def staged(self) -> list[Path]:
        return sorted(self.staging.iterdir()) if self.staging.is_dir() else []

    def empty_folders(self) -> list[str]:
        """The folders under the music folder that hold nothing (staging apart,
        which the server keeps)."""
        return [str(path.relative_to(self.music)) for path in sorted(self.music.rglob("*"))
                if path.is_dir() and not path.is_symlink() and path != self.staging
                and not any(path.iterdir())]

    def library(self) -> Library:
        return Library(self.db, self.owner, root=self.root)

    # --- rules checked at the moment of a file operation ---

    def judge(self, name: str, args) -> None:
        """Called just before a real file operation under the music folder. The
        rules are judged against the database as a power cut at this moment
        would leave it (the image kept at the last durable point):

        - no operation removes, replaces or moves another track's file;
        - a file appears at a free library path from staging only when a
          durable journal row owns that staged copy;
        - a file the durable catalog names as a track's file is never removed,
          and is replaced only by the same audio, or by audio the durable
          catalog already describes;
        - the staged copy of a durable in-place journal row is not removed
          while the durable catalog describes its audio and the track's file
          holds other audio (the row would be left with nothing to put in
          place: G7 after a power cut). The start-up sweep of staged copies
          that no row of the live database names is not judged by this rule:
          it takes no durable point, and what a power cut right after it
          leaves is pinned by its own test (the "staged copy lost" ending).

        The second and third rule allow the documented exception: a durable
        point that failed and said so in the operator log (decision D10).
        A broken rule is written to ``recorder.violations`` (an assertion
        raised here could be swallowed by the product's own handlers)."""
        if name in ("mkdir", "rmdir", "symlink", "link"):
            return
        violations = self.recorder.violations
        source = Path(args[0])
        victim = Path(args[1]) if name in ("replace", "rename") else source
        for path in {source, victim}:
            if str(path.relative_to(self.music)) in BYSTANDERS:
                violations.append(f"{name} touches another track's file: {self.show(path)}")
        in_staging = lambda p: self.staging in p.parents  # noqa: E731
        appears = not in_staging(victim) and not os.path.lexists(victim)
        if name != "unlink" and in_staging(source) and appears:
            owned = str(source) in self.durable["staged"]
            if not owned and not self.recorder.warned():
                violations.append(
                    f"{self.show(victim)} gets a file from staging before a durable journal row"
                    " names that staged copy")
        if name == "unlink" and in_staging(victim) and not self.sweeping:
            self._judge_staged_copy_removed(victim)
        if in_staging(victim) or not os.path.lexists(victim):
            return
        named = [r for r in self.durable["tracks"] if r["file_path"] == str(victim)]
        if not named:
            return
        if name == "unlink":
            violations.append(
                f"unlink removes {self.show(victim)}, which the durable catalog names as a "
                "track's file")
            return
        coming, going = audio_of(source.read_bytes()), audio_of(victim.read_bytes())
        described = (named[0]["codec"], named[0]["bitrate_kbps"], named[0]["sample_rate_hz"])
        if coming != going and described != AUDIO[coming] and not self.recorder.warned():
            violations.append(
                f"{self.show(victim)} is replaced by other audio before the catalog that "
                "describes it is durable")

    def _judge_staged_copy_removed(self, staged: Path) -> None:
        def audio_at(path) -> Optional[str]:
            path = Path(path)
            return audio_of(path.read_bytes()) if path.is_file() and not path.is_symlink() else None

        for row in self.durable["journal"]:
            if row["temp_path"] != str(staged) or (
                    row["new_path"] and row["new_path"] != row["old_path"]):
                continue
            coming = audio_at(staged)
            for track in self.durable["tracks"]:
                if track["uuid_id"] != row["uuid_id"] or coming not in AUDIO:
                    continue
                described = (track["codec"], track["bitrate_kbps"], track["sample_rate_hz"])
                if described == AUDIO[coming] and audio_at(track["file_path"]) != coming:
                    self.recorder.violations.append(
                        f"{self.show(staged)} is removed while the durable catalog describes its "
                        "audio and the track's file holds other audio")

    # --- what a test compares ---

    def bumps(self) -> int:
        """How many times the track's revision was bumped since the world was
        built (no other track's revision ever changes)."""
        revision = self.track()["revision"]
        return 0 if revision == self.revision0 else revision - self.counter0

    def snapshot(self) -> dict:
        """Everything a second recovery run must leave alone."""
        with self.reading():
            return self._snapshot()

    def _snapshot(self) -> dict:
        files = self.files()
        return {
            "files": files,
            "stats": {rel: (os.lstat(self.music / rel).st_ino, os.lstat(self.music / rel).st_mtime_ns)
                      for rel in files},
            "tracks": self.sql(
                "SELECT t.uuid_id, t.file_path, t.revision, m.title, m.artist, m.codec, "
                "m.bitrate_kbps, m.sample_rate_hz, m.channels, m.duration FROM tracks t "
                "JOIN trackmetadata m ON m.uuid_id = t.uuid_id ORDER BY t.id"),
            "identity": self.sql(
                "SELECT uuid_id, generation, exact_state, exact_digest, fp_state, match_state "
                "FROM track_audio_identity ORDER BY uuid_id"),
            "journal": self.journal(),
            "jobs": self.sql("SELECT id, status, error_text FROM conversion_jobs ORDER BY id"),
            "reservations": self.reservations(),
        }

    # --- one server process ---

    def boot(self) -> None:
        """The objects of a new server process on the same disk."""
        self.boots += 1
        # A new process has its own folder locks: a writer frozen inside a move
        # still holds the old ones.
        self.patch.setattr(file_ops, "_directory_locks", KeyedLocks())
        self.db = RecordingDatabase(
            Database(DatabaseContext(database_path=self.database_path, init_sql_path=INIT_SQL)),
            self.recorder)
        self.locks = TrackLocks()
        self.pending = PendingOldMasters()
        self.wakeup = Wakeup(self)
        self.cache = RecordingCache(self.recorder, "cache")
        self.default_cache = RecordingCache(self.recorder, "default_cache")
        self.ledger = RecordingLedger(
            StorageLedger(self.db, path=self.tmp, floor_bytes=0, boot_id=f"boot-{self.boots}"),
            self.recorder)
        self.editor = TrackEditor(self.music, self.staging, identity_signal=self.wakeup,
                                  pending_old_masters=self.pending)
        self.coordinator = _Coordinator()
        self.orchestrator = ConversionOrchestrator(
            database=self.db, music_library_dir=self.music, staging_dir=self.staging,
            track_locks=self.locks, encoder_coordinator=self.coordinator, cache=self.cache,
            default_cache=self.default_cache,
            available_encoders=frozenset({"aac", "alac", "flac", "mp3"}),
            storage_ledger=self.ledger, identity_signal=self.wakeup,
            pending_old_masters=self.pending, compute_identity=fake_compute_identity,
            check_strict_decode=bound_to(audio_identity.check_strict_decode)(lambda *a, **k: None),
        )

    # --- the operations ---

    def run_writer(self):
        """The operation under test, as the server runs it."""
        writer = self.writer
        if writer.kind == "edit":
            with self.locks.lock(self.uuid):  # the route holds the track's lock
                return self.editor.apply_edit(
                    self.library(), self.uuid, dict(writer.fields), self.revision0,
                    WriteMode.db_and_master)
        return self.orchestrator._run_job(self.job_id)

    def start_up(self) -> None:
        """The next start's recovery of main.py, in its order: the convert rows
        are read, the edit journal is settled, conversion jobs and staging are
        reconciled, the caches are evicted for the rows read, and reservations
        of the previous run are given back. The steps run in the order of
        ``tests.recovery_steps`` (``STARTUP_STEPS``), which
        ``tests/test_startup_recovery_order.py`` compares with main.py's."""
        self.boot()
        interrupted = {e["uuid_id"] for e in self.journal() if e["intent"] == "convert"}

        def conversion_jobs() -> None:
            self.sweeping = True
            try:
                reconcile_conversion_jobs(self.db, self.staging)
            finally:
                self.sweeping = False
                for uuid_id in sorted(interrupted):
                    evict_track_caches(uuid_id, self.cache, self.default_cache)

        steps = {
            "edit journal": lambda: reconcile_journal(
                self.db, self.music, identity_signal=self.wakeup, read_audio=fake_read),
            "conversion jobs": conversion_jobs,
            "storage reservations": self.ledger.reconcile,
        }
        assert set(steps) == set(STARTUP_STEPS)
        for name in in_startup_order(STARTUP_STEPS):
            steps[name]()

    def next_edit(self, fields: Optional[dict] = None):
        """The same track's next edit that writes the file (it finishes kept
        rows first). Returns the new revision, or the error it was refused with."""
        revision = self.track()["revision"]
        try:
            with self.locks.lock(self.uuid):
                return self.editor.apply_edit(
                    self.library(), self.uuid, fields or {"title": "Next"}, revision,
                    WriteMode.db_and_master)[0]
        except Exception as exc:  # noqa: BLE001 - the refusal is the answer
            return exc

    def next_conversion(self):
        """The same track's next conversion request (it finishes kept rows
        first). An accepted job is cancelled at once; returns "accepted" or the
        error it was refused with."""
        revision = self.track()["revision"]
        try:
            job_id = self.orchestrator.enqueue(self.library(), self.uuid, "alac", None, revision)
        except Exception as exc:  # noqa: BLE001 - the refusal is the answer
            return exc
        assert self.orchestrator.cancel(self.library(), job_id)
        return "accepted"

    def idle_pass(self) -> int:
        """The identity worker's idle pass over kept journal rows."""
        return finish_kept_journal_rows(
            self.db, self.music, self.locks, identity_signal=self.wakeup, reported=set(),
            pending_old_masters=self.pending)

    # --- what a test plants ---

    @contextmanager
    def outside(self):
        """Something other than the server changes the disk: not a step of the
        server and not judged as one."""
        was = self.recorder.recording
        self.recorder.recording = False
        try:
            yield
        finally:
            self.recorder.recording = was

    def staged_copy(self) -> Path:
        """The staged copy the one journal row names."""
        [row] = self.journal()
        return Path(row["temp_path"])

    def plant_track(self, path: Path, audio: str = "Z", owner: Optional[int] = None) -> str:
        """Another track whose file is at ``path`` (written new there), as an
        import that finished and was flushed would leave it."""
        with self.outside():
            path.unlink(missing_ok=True)
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(master(audio, "Planted", "Else"))
        track = Track(file_path=path, metadata=_metadata_of(audio, "Planted", "Else"))
        if self.db._real.track_path_in_use(str(path), owner_id=ANY_OWNER):
            # A second row naming a file a row already names: the state the
            # unique index refuses. Planted without it, to show what a writer
            # or recovery does when it meets that state.
            allow_two_tracks_on_one_path(self.database_path)
        assert self.db._real.add_track(track, owner_id=owner or self.owner)
        self.keep_durable_image()
        return track.uuid_id

    def track_naming(self, path: Path) -> list[str]:
        return [r["uuid_id"] for r in self.sql(
            "SELECT uuid_id FROM tracks WHERE file_path = ?", (str(path),))]

    # --- the database as a power cut leaves it ---

    def keep_durable_image(self) -> None:
        """Called at every successful durable point: what the database holds now
        is what a power cut would leave. ``judge`` needs three facts of it (which
        staged copies journal rows name, the rows themselves, which files tracks
        name and how they are described), kept in memory; the whole database is copied only for a
        test that will cut the power (``expect_power_cut``)."""
        with self.reading():
            self.durable = {
                "staged": {r["temp_path"] for r in self.sql("SELECT temp_path FROM edit_journal")},
                "journal": self.sql(
                    "SELECT uuid_id, old_path, new_path, temp_path FROM edit_journal"),
                "tracks": self.sql(
                    "SELECT t.uuid_id, m.codec, m.bitrate_kbps, m.sample_rate_hz, t.file_path "
                    "FROM tracks t JOIN trackmetadata m ON m.uuid_id = t.uuid_id"),
            }
            if self.power_cuts:
                target = sqlite3.connect(self.tmp / "durable.sqlite")
                try:
                    self._reader.backup(target)
                finally:
                    target.close()

    def expect_power_cut(self) -> None:
        """This test will cut the power: keep whole database images from now on."""
        self.power_cuts = True
        self.keep_durable_image()

    def power_cut(self) -> None:
        """Every transaction after the last durable point is lost; files stay."""
        assert self.power_cuts, "call expect_power_cut() before the writer runs"
        for suffix in ("", "-wal", "-shm"):
            Path(str(self.database_path) + suffix).unlink(missing_ok=True)
        shutil.copyfile(self.tmp / "durable.sqlite", self.database_path)


# The seed world of each writer, built once per test process in a folder of the
# rig's own and never changed afterwards. Every world of a test, the first of a
# process like any later one, is made the same way from it: the seed's folders
# and files are written again, its database is copied, and the music folder's
# path is rewritten. So no world depends on which worlds were built before it.
_SEEDS: dict = {}
_SEED_DIR: list = []


def _seed_folder() -> Path:
    if not _SEED_DIR:
        _SEED_DIR.append(Path(tempfile.mkdtemp(prefix="osml-replace-matrix-")))
        atexit.register(shutil.rmtree, _SEED_DIR[0], ignore_errors=True)
    return _SEED_DIR[0]


def _add_track(world: World, rel: str, audio: str, title: str, artist: str, owner: int) -> str:
    path = world.music / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(master(audio, title, artist))
    track = Track(file_path=path, metadata=_metadata_of(audio, title, artist))
    assert world.db._real.add_track(track, owner_id=owner)
    return track.uuid_id


def _build_seed(writer: Writer) -> tuple:
    """The seed world: a new database through the product's own ``initialize``
    and ``add_track``: two users, the writer's track with its identity settled,
    the three other tracks, and (a conversion) its job as the real request
    queues it. Returns the copy of its database and what a world needs of it:
    the ids, and every folder and file the seeding left under the music folder
    (the request of a conversion makes the staging folder)."""
    folder = _seed_folder() / str(len(_SEEDS))
    folder.mkdir()
    with pytest.MonkeyPatch.context() as patch:
        world = World(folder, writer, patch)
        world.music.mkdir()
        world.database_path.parent.mkdir()
        world.boot()
        assert world.db._real.initialize()
        for name in ("owner", "other"):
            world.sql(
                "INSERT INTO users (username, username_key, password_hash, library_folder, "
                "created_at) VALUES (?, ?, 'unused', ?, 0)", (name, name, name))
        users = {r["username"]: r["id"] for r in world.sql("SELECT id, username FROM users")}
        world.owner, world.other = users["owner"], users["other"]
        world.uuid = _add_track(
            world, writer.old_rel, writer.old_audio, *writer.old_tags, world.owner)
        for rel, (audio, title, artist, user) in BYSTANDERS.items():
            world.bystander_uuids[rel] = _add_track(world, rel, audio, title, artist, users[user])
        # The worker's finished state, so that a mark of the identity is visible.
        world.sql(
            "UPDATE track_audio_identity SET exact_state = 'current', exact_kind = ?, "
            "exact_digest = ?, fp_state = 'current', fp_algorithm = 'chromaprint-2', "
            "match_state = 'current', matcher_version = 'm1', priority = 1, generation = 3 "
            "WHERE uuid_id = ?",
            (_hash_of(writer.old_audio).kind, digest_of(writer.old_audio), world.uuid))
        if writer.kind == "convert":
            codec, bitrate = writer.target
            world.job_id = world.orchestrator.enqueue(
                world.library(), world.uuid, codec, bitrate, world.track()["revision"])
        seed = folder / "seed.sqlite"
        source, target = sqlite3.connect(world.database_path), sqlite3.connect(seed)
        try:
            source.backup(target)
        finally:
            target.close()
            source.close()
        entries = sorted(world.music.rglob("*"))
        facts = {
            "owner": world.owner, "other": world.other, "uuid": world.uuid,
            "bystander_uuids": dict(world.bystander_uuids), "job_id": world.job_id,
            "music": str(world.music),
            "folders": [str(p.relative_to(world.music)) for p in entries if p.is_dir()],
            "files": {str(p.relative_to(world.music)): p.read_bytes()
                      for p in entries if p.is_file()},
        }
    return seed, facts


def build_world(tmp_path: Path, monkeypatch, writer: Writer) -> World:
    """A library of two users with the writer's track in its starting state: the
    old master in place, the identity settled, and (a conversion) its job queued.
    Made from the writer's seed world, which is only read."""
    # The whole writer (its repr names every field): a variant with another old
    # file, tags or kind never gets another writer's seed. (Writer is not
    # hashable: ``fields`` is a dict.)
    key = repr(writer)
    if key not in _SEEDS:
        _SEEDS[key] = _build_seed(writer)
    seed, facts = _SEEDS[key]
    world = World(tmp_path, writer, monkeypatch)
    world.music.mkdir()
    world.database_path.parent.mkdir()
    world.boot()
    for rel in facts["folders"]:
        (world.music / rel).mkdir()
    for rel, data in facts["files"].items():
        (world.music / rel).write_bytes(data)
    shutil.copyfile(seed, world.database_path)
    for row in world.sql("SELECT uuid_id, file_path FROM tracks"):
        set_track_path(world.database_path, row["uuid_id"],
                       row["file_path"].replace(facts["music"], str(world.music)))
    world.owner, world.other, world.uuid = facts["owner"], facts["other"], facts["uuid"]
    world.bystander_uuids, world.job_id = dict(facts["bystander_uuids"]), facts["job_id"]
    world.revision0 = world.track()["revision"]
    world.counter0 = world.sql("SELECT MAX(revision) AS r FROM tracks")[0]["r"]
    world.identity0 = world.identity()

    monkeypatch.setattr(track_editor_module, "write_metadata_tags", fake_write_metadata_tags)
    monkeypatch.setattr(conversion_module, "write_metadata_tags", fake_write_metadata_tags)
    monkeypatch.setattr(conversion_module, "transcode", fake_transcode)
    monkeypatch.setattr(conversion_module, "ffprobe_for_metadata", fake_ffprobe)
    monkeypatch.setattr(conversion_module, "build_track_metadata", fake_build_track_metadata)
    for rel, uuid_id in world.bystander_uuids.items():
        world.bystander_rows[rel] = world.track(uuid_id)
        st = os.lstat(world.music / rel)
        world.bystander_stats[rel] = (st.st_ino, st.st_size, st.st_mtime_ns)
    world.keep_durable_image()
    world.recorder.install(monkeypatch)
    world.recorder.begin("writer")
    return world


# --- what a cell expects, and the checks every cell makes ---------------------------------------------

OLD = "old"  # the old file at the old path; the catalog as before
NEW = "new"  # the new file at the new path; the catalog describes it
DB_ONLY = "db_only"  # an edit: the catalog has the new tags, the file still the old ones


@dataclass(frozen=True)
class Expect:
    outcome: str
    bumps: int  # how often the track's revision was bumped
    identity: str  # "kept" as it was | "stale" marked for re-hashing | "written" by the conversion
    job: Optional[tuple] = None  # (status, error text), text ANY_TEXT for "some text"
    title: Optional[str] = None  # the title of a next edit that was applied
    extra_files: tuple = ()  # ((relative path, bytes), ...) besides the track's and the others'
    extra_bumps: bool = False  # the number of bumps is a lower bound
    detour: bool = False  # the catalog changed and changed back: bumped, though as at the start


ANY_TEXT = object()


def bystander_files() -> dict:
    return {rel: master(audio, title, artist)
            for rel, (audio, title, artist, _user) in BYSTANDERS.items()}


def check_others_untouched(world: World) -> None:
    """No file and no row of another track changed: same bytes, same file
    object (inode, size, modification time), same catalog row."""
    assert world.recorder.violations == [], world.recorder.violations
    for rel, uuid_id in world.bystander_uuids.items():
        audio, title, artist, _user = BYSTANDERS[rel]
        path = world.music / rel
        assert path.read_bytes() == master(audio, title, artist), rel
        st = os.lstat(path)
        assert (st.st_ino, st.st_size, st.st_mtime_ns) == world.bystander_stats[rel], rel
        assert world.track(uuid_id) == world.bystander_rows[rel], rel


def check_safe(world: World, *, titles=()) -> None:
    """What holds at every moment, whatever was interrupted: the track has
    exactly one master, a regular file with the old bytes or the new bytes (never
    a mixture or nothing); the catalog describes that file, or a journal row
    still promises to settle the difference; nobody else's file was touched."""
    with world.reading():
        _check_safe(world, titles)


def _check_safe(world: World, titles) -> None:
    writer = world.writer
    track = world.track()
    assert track is not None
    path = Path(track["file_path"])
    assert path in (world.old, world.new), path
    assert os.path.lexists(path) and not path.is_symlink() and path.is_file(), path
    data = path.read_bytes()
    allowed = {writer.old_bytes, writer.new_bytes}
    for title in titles:
        allowed |= {master(writer.old_audio, title, a) for a in (writer.old_tags[1], writer.new_tags[1])}
        allowed |= {master(writer.new_audio, title, a) for a in (writer.old_tags[1], writer.new_tags[1])}
    assert data in allowed, data
    described = (track["codec"], track["bitrate_kbps"], track["sample_rate_hz"])
    if described != AUDIO[audio_of(data)]:
        assert any(r["uuid_id"] == world.uuid for r in world.journal()), (
            "the catalog describes another file and no journal row is left to settle it")
    identity = world.identity()
    if identity["exact_state"] == "current" and identity != world.identity0:
        assert identity["exact_digest"] == digest_of(audio_of(data)), identity
    for level, text in world.recorder.operator_lines:
        assert str(world.tmp) not in text and "song." not in text, text
    # Wherever the writer or recovery left the track, its row's folded path is
    # the fold of its path (the unique index and the path lookups read it).
    assert stale_path_rows(world.database_path) == []
    check_others_untouched(world)


def check_evidence(world: World) -> None:
    """What a writer leaves whenever it leaves a journal row, however it was
    stopped: the staged copy, because recovery reads it as evidence.

    - G3, a moving row: while nothing is at the new path (the move did not
      happen), the staged copy exists. Recovery reads "staged copy gone" as
      "the move happened" and would treat a file that later appears at the new
      path as the operation's own.
    - G7, an in-place row: while the master still has the old bytes, the staged
      copy exists (the journal owns it; no error path deletes it)."""
    for row in world.journal():
        if row["uuid_id"] != world.uuid:
            continue
        intent = "convert" if world.writer.kind == "convert" else (
            "relocate" if world.writer.moving else "inplace")
        assert row["intent"] == intent, row["intent"]
        staged = Path(row["temp_path"])
        whole = staged.is_file() and not staged.is_symlink()
        if row["new_path"] and row["new_path"] != row["old_path"]:
            if not os.path.lexists(row["new_path"]):
                assert whole, "G3: the row is kept, the move did not happen, the staged copy is gone"
                assert staged.read_bytes() == world.writer.new_bytes, "G3: the staged copy"
        elif Path(row["old_path"]).read_bytes() == world.writer.old_bytes:
            assert whole, "G7: the row is kept, the replace did not happen, the staged copy is gone"
            assert staged.read_bytes() == world.writer.new_bytes, "G7: the staged copy"


def check_final(world: World, expect: Expect) -> None:
    """After the last recovery: the exact files under the music folder (staging
    included), the catalog row, the journal, the identity, the job, the
    reservations."""
    with world.reading():
        _check_final(world, expect)


def _check_final(world: World, expect: Expect) -> None:
    writer = world.writer
    new_file = expect.outcome == NEW
    rel = writer.new_rel if new_file else writer.old_rel
    audio = writer.new_audio if new_file else writer.old_audio
    file_title, file_artist = writer.new_tags if new_file else writer.old_tags
    title, artist = writer.old_tags if expect.outcome == OLD else writer.new_tags
    if expect.title is not None:  # the next edit wrote the catalog's tags into the file
        file_title = title = expect.title
        file_artist = artist
    files = bystander_files()
    files[rel] = master(audio, file_title, file_artist)
    files.update(dict(expect.extra_files))
    found = world.files()
    assert found == files, (found, files)
    # No folder is left behind for a file that never arrived or has gone.
    assert world.empty_folders() == [], world.empty_folders()
    codec, bitrate, rate = AUDIO[audio]
    track = world.track()
    wanted = {
        "file_path": str(world.music / rel), "revision": track["revision"], "owner_id": world.owner,
        "title": title, "artist": artist, "codec": codec, "bitrate_kbps": bitrate,
        "sample_rate_hz": rate, "channels": 2,
    }
    assert track == wanted, (track, wanted)
    assert world.journal() == [], world.journal()
    if expect.extra_bumps:
        assert world.bumps() >= expect.bumps, world.bumps()
    else:
        assert world.bumps() == expect.bumps, world.bumps()
    # The revision moved exactly when the track changed for a client.
    changed = files[rel] != writer.old_bytes or (title, artist) != writer.old_tags
    assert (world.bumps() > 0) == (changed or expect.detour), world.bumps()
    identity = world.identity()
    if expect.identity == "kept":
        assert identity == world.identity0, identity
    elif expect.identity == "stale":
        assert identity["exact_state"] == "pending" and identity["generation"] > 3, identity
    else:
        assert expect.identity == "written"
        assert identity["exact_state"] == "current" and identity["generation"] > 3, identity
        assert identity["exact_digest"] == digest_of(audio), identity
    if writer.kind == "convert":
        status, text = world.job()
        assert status == expect.job[0], (status, text)
        if expect.job[1] is ANY_TEXT:
            assert text and str(world.tmp) not in text
        else:
            assert text == expect.job[1], text
        # A job that says done has its file in place; one that does not has the old file.
        assert (status == "done") == new_file, status
        if new_file and expect.title is None:
            # G11: since the track got its new audio, both encoded caches were
            # evicted for it (an encode of the old audio must not be served).
            # (Not looked at after a next edit: its replace keeps the audio.)
            timeline = world.recorder.timeline
            became = "db.complete_conversion_job" if writer.moving else "fs.replace T -> O"
            since = timeline[len(timeline) - timeline[::-1].index(became):]
            assert "cache.evict" in since and "default_cache.evict" in since, since
    assert world.reservations() == 0, world.reservations()
    check_safe(world, titles=(expect.title,) if expect.title else ())


def check_settled(world: World, expect: Expect) -> None:
    """``check_final``, and a second start changes nothing at all. (Used where
    the next start is the cell's own subject; elsewhere ``check_final`` alone
    already says that no row, no staged file, no unfinished job and no
    reservation is left for a start to act on.)"""
    check_final(world, expect)
    before = world.snapshot()
    world.recorder.begin("second start")
    world.start_up()
    after = world.snapshot()
    assert after == before, [(k, before[k], after[k]) for k in before if before[k] != after[k]]
    again = [s for s in world.recorder.steps if s.startswith(("fs.", "db."))
             and s != "db.release_storage_leases_except"]
    assert again == [], again


# --- the running server meets what an interrupted or failed writer left -------------------------------

RUNTIME_PATHS = ("edit", "conversion", "idle")


def meet_at_runtime(world: World, path: str, held: bool, evidence: bool = True) -> tuple:
    """One runtime recovery path over the rows the writer left: the same track's
    next edit that writes the file, its next conversion request, or the idle
    pass. ``held`` says the rows must wait for the next start: then the edit and
    the request are refused and every row stays. Otherwise the edit and the
    request are accepted with no row left, and the idle pass finishes exactly
    the rows whose staged copy is gone. Returns (the rows were finished by the
    running server, a next edit was applied)."""
    rows = world.journal()
    finishable = [r for r in rows if not (r["temp_path"] and Path(r["temp_path"]).exists())]
    world.recorder.begin(f"runtime {path}")
    finished, edited = False, False
    if path == "edit":
        answer = world.next_edit()
        if held:
            assert isinstance(answer, MasterWriteError), answer
        else:
            assert isinstance(answer, int), answer
            finished = edited = True
    elif path == "conversion":
        answer = world.next_conversion()
        if held:
            assert isinstance(answer, PendingRecovery), answer
        else:
            # Accepted, unless the interrupted job itself still counts as active.
            active = world.writer.kind == "convert" and world.job()[0] in ("queued", "running")
            assert isinstance(answer, ConversionJobActive) if active else answer == "accepted", answer
            finished = True
    else:
        assert path == "idle"
        count = world.idle_pass()
        assert count == (0 if held else len(finishable)), (count, finishable)
        finished = not held and finishable == rows
        if not held:
            assert world.journal() == [r for r in rows if r not in finishable]
    if held:
        assert world.journal() == rows, world.journal()
        if evidence:  # a row that waits keeps its staged copy (unless the test took it)
            check_evidence(world)
    elif finished:
        assert world.journal() == [], world.journal()
    check_safe(world, titles=("Next",))
    # A second pass of the running server finishes nothing more and changes nothing.
    before = world.snapshot()
    left = [r for r in world.journal()
            if not (r["temp_path"] and Path(r["temp_path"]).exists())]
    assert world.idle_pass() == (0 if held else len(left)), "the second idle pass"
    if held or not left:
        after = world.snapshot()
        assert after == before, [(k, before[k], after[k]) for k in before if before[k] != after[k]]
    return finished, edited


def each_killed_start(tmp_path: Path, monkeypatch, name: str, prepare, check, safe=True) -> int:
    """The next start killed before its first step, its second, ... each time
    on a fresh world that ``prepare(world)`` brought into the same state; then a
    full start and ``check(world)``. Where the killed start stopped,
    ``check_safe`` must hold too (``safe``). Ends with the first start that
    finishes before reaching the step number. Returns how many starts were
    killed."""
    reached, index = True, 0
    while reached:
        index += 1
        folder = tmp_path / f"kill-{index}"
        folder.mkdir()
        with monkeypatch.context() as patch:
            world = build_world(folder, patch, WRITERS[name])
            try:
                prepare(world)
                world.recorder.begin("killed start")
                world.recorder.kill_index = index
                reached = world.recorder.run_parked(world.start_up)
                if reached and safe:
                    check_safe(world)
                world.recorder.begin("start")
                world.start_up()
                check(world)
            finally:
                world.recorder.thaw()
    return index - 1
