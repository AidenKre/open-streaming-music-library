"""A recording rig for the deletion executor (refactor piece BE-DEL).

It runs the real ``DeletionExecutor`` on the two-user fixture library of
``deletion_world`` and writes down, in order, everything the executor does for
a target:

- every call it makes on the database, with its arguments and its answer;
- the track lock it takes and gives back;
- the path judgements the worker and the recovery verdict ask for
  (``check_master_path``, ``is_journaled_file``, ``quarantine_state``,
  ``put_back_file``, ``quarantine_trusted``), with their arguments and
  answers; what ``put_back_file`` judges inside itself is not written down,
  only the file operations it makes and its answer;
- the real file operations, at the ``os`` module, whichever helper makes them:
  ``replace``, ``rename``, ``link``, ``unlink``, ``rmdir``, ``mkdir`` and the
  flush of a folder (an ``os.fsync`` of a descriptor ``os.open`` returned);
- the cache evictions and the cover-art release;
- the executor's test seams, and every log line of the deletion modules, the
  file helpers and the operator logger.

Paths are written relative to the music folder; the track's uuid, the
operation uuid and the journaled file identity are written as ``<uuid>``,
``<op>`` and ``<identity>``, and the three keyword arguments that name the
target (owner, operation, uuid) together as ``<key>``. A fault is injected where the test says: an
answer or an error for one database call, an error or an extra action around
one file operation, an action at a seam.

The lines are compared with a list written out in the test, so a value that
reaches the wrong argument, an operation on the wrong path or a changed order
shows as a changed line.
"""

import errno
import logging
import os
from pathlib import Path

from app.services import deletion_recovery, deletion_worker
from app.services.deletion_recovery import DeletionJanitor
from app.services.deletion_worker import DeletionExecutor, DeletionWorker
from tests.deletion_world import (
    BOOT,
    NOW,
    SpyCache,
    World,
    accept_job,
    add_master,
    files_under,
    item,
    journal,
    path_of,
    revision,
)

_JUDGEMENTS = ("check_master_path", "is_journaled_file", "quarantine_state", "put_back_file")
_RECORDED_OS = ("replace", "rename", "link", "unlink", "rmdir", "mkdir")
# file_ops logs under the organizer's name and master_paths does not log; both
# are listed so that a line logged under either name later shows in the lists.
_LOGGERS = (
    "app.services.deletion_worker",
    "app.services.deletion_recovery",
    "app.services.master_paths",
    "app.services.organizer",
    "app.services.file_ops",
    "uvicorn.error",
)


class _Fault:
    """One injected fault: on the ``on_call``-th matching call (and the
    ``times - 1`` after it) raise ``error`` or give ``answer`` instead of the
    real call; with ``after`` the real call runs first. ``then`` (file
    operations only) runs when the fault fires: before its error, or after
    the real call when it has none."""

    def __init__(self, *, error=None, answer=None, has_answer=False, when=None, on_call=1,
                 times=1, after=False, then=None):
        self.error, self.answer, self.has_answer = error, answer, has_answer
        self.when, self.on_call, self.times = when, on_call, times
        self.after, self.then = after, then
        self.seen = 0

    def hits(self, args, kwargs) -> bool:
        if self.when is not None and not self.when(*args, **kwargs):
            return False
        self.seen += 1
        return self.on_call <= self.seen < self.on_call + self.times


class _RecordingLock:
    def __init__(self, real, rig, uuid_id):
        self._real, self._rig, self._uuid = real, rig, uuid_id

    def acquire(self, *args, **kwargs):
        line = self._rig.begin(f"lock({self._rig.show(self._uuid)}).acquire({self._rig.args(args, kwargs)})")
        return self._rig.end(line, self._real.acquire(*args, **kwargs))

    def release(self):
        self._rig.begin(f"lock({self._rig.show(self._uuid)}).release()")
        return self._real.release()


class _RecordingLocks:
    def __init__(self, real, rig):
        self._real, self._rig = real, rig

    def lock_for(self, uuid_id):
        return _RecordingLock(self._real.lock_for(uuid_id), self._rig, uuid_id)


class _RecordingCache(SpyCache):
    def __init__(self, rig, label):
        super().__init__()
        self._rig, self._label = rig, label

    def remove_all_for_uuid(self, uuid_id):
        line = self._rig.begin(f"{self._label}.remove_all_for_uuid({self._rig.show(uuid_id)})")
        try:
            return super().remove_all_for_uuid(uuid_id)
        except Exception as exc:
            self._rig.failed(line, exc)
            raise


class _RecordingCoverArt:
    def __init__(self, real, rig):
        self._real, self._rig = real, rig

    def release_if_unreferenced(self, cover_art_id):
        line = self._rig.begin(f"cover_art.release_if_unreferenced({cover_art_id})")
        return self._rig.end(line, self._real.release_if_unreferenced(cover_art_id))


class _RecordingDatabase:
    """Every method call is written down; anything else is passed through."""

    def __init__(self, real, rig):
        self._real, self._rig = real, rig

    def __getattr__(self, name):
        target = getattr(self._real, name)
        if not callable(target):
            return target
        return self._rig.recorded(f"db.{name}", target, self._rig.faults.get(("db", name), ()))


class _LogLines(logging.Handler):
    def __init__(self, rig):
        super().__init__(level=logging.DEBUG)
        self._rig = rig

    def emit(self, record):
        name = record.name.removeprefix("app.services.")
        self._rig.begin(f"log {record.levelname} {name}: {self._rig.text(record.getMessage())}")


class DeletionRig:
    """See the module docstring. Build the tracks and jobs first (``job``),
    then ``start`` the recording, inject faults, ``step`` the worker and
    compare with ``expect``."""

    def __init__(self, world: World, monkeypatch):
        self.world = world
        self._monkeypatch = monkeypatch
        self.lines: list[str] = []
        self.faults: dict[tuple[str, str], list[_Fault]] = {}
        self._names: dict[str, str] = {}
        self._identities: dict[tuple, str] = {}
        self._seams: dict[str, list] = {}
        self._fds: dict[int, str] = {}
        self._tracks: list[tuple[str, str, int, str]] = []  # uuid, rel, owner, operation
        self._undo: list = []
        self._inside_put_back = 0
        self._roots = []
        for root, label in ((world.music, ""), (world.tmp, "<tmp>/")):
            for spelling in dict.fromkeys((os.path.realpath(root), str(root))):
                self._roots.append((spelling, label))
        self.database = _RecordingDatabase(world.db, self)
        self.locks = _RecordingLocks(world.locks, self)
        self.cache = _RecordingCache(self, "cache")
        self.default_cache = _RecordingCache(self, "default_cache")
        self.cover_art = _RecordingCoverArt(world.cover_art, self)
        self.executor = None
        self.worker = None
        self._started = False

    # ── building the world (not recorded) ─────────────────────────────────

    def job(self, *rels, owner=None, delta=0, **track):
        """One job over a new track per ``rel`` (default one track); returns
        the uuids. The first track of the rig is ``<uuid>`` and its job
        ``<op>``; later ones are numbered from 2."""
        assert not self._started, "build the world before start()"
        rels = rels or ("A/Album/a.flac",)
        owner = self.world.owner if owner is None else owner
        targets, added = [], []
        for rel in rels:
            uuid_id = add_master(self.world, rel, owner=owner, **track)
            n = len(self._tracks) + len(added) + 1
            self._names[uuid_id] = "<uuid>" if n == 1 else f"<uuid{n}>"
            added.append((uuid_id, rel, owner))
            master = path_of(self.world, uuid_id)
            if os.path.lexists(master):
                st = os.lstat(master)
                label = "identity" if n == 1 else f"identity{n}"
                self._identities[(st.st_dev, st.st_ino, st.st_size)] = f"<{label}>"
            targets.append((uuid_id, revision(self.world, uuid_id) + delta))
        op = accept_job(self.world, *targets, owner=owner)
        ops = sum(1 for placeholder in self._names.values() if placeholder.startswith("<op"))
        self._names[op] = "<op>" if ops == 0 else f"<op{ops + 1}>"
        self._tracks += [(*one, op) for one in added]
        self.op = getattr(self, "op", op)
        return [uuid_id for uuid_id, _ in targets]

    @property
    def uuid(self) -> str:
        return self._tracks[0][0]

    @property
    def master(self) -> Path:
        _uuid_id, rel, owner, _op = self._tracks[0]
        return self.world.root(owner) / rel

    @property
    def quarantine(self) -> Path:
        uuid_id, rel, owner, op = self._tracks[0]
        return self.world.music / ".deleting" / str(owner) / op / f"{uuid_id}{Path(rel).suffix}"

    # ── recording ─────────────────────────────────────────────────────────

    def start(self, **executor_overrides):
        """Install the recording and build the executor and its worker."""
        assert not self._started
        self._started = True
        patch = self._monkeypatch
        for module, label in ((deletion_worker, "worker"), (deletion_recovery, "recovery")):
            for name in _JUDGEMENTS:
                patch.setattr(module, name, self._judgement(f"{label}.{name}", getattr(module, name)))
        patch.setattr(deletion_recovery, "quarantine_trusted", self.recorded(
            "recovery.quarantine_trusted", deletion_recovery.quarantine_trusted))
        for name in _RECORDED_OS:
            patch.setattr(os, name, self._os_call(name, getattr(os, name)))
        for name in ("stat", "lstat"):
            patch.setattr(os, name, self._os_fault_only(name, getattr(os, name)))
        self._patch_flushes(patch)
        handler = _LogLines(self)
        for name in _LOGGERS:
            logger = logging.getLogger(name)
            self._undo.append((logger, logger.level, handler))
            logger.setLevel(logging.DEBUG)
            logger.addHandler(handler)
        kwargs = dict(
            music_library_dir=self.world.music,
            track_locks=self.locks,
            cover_art=self.cover_art,
            cache=self.cache,
            default_cache=self.default_cache,
            boot_id=BOOT,
            lock_timeout_s=0,
            clock=lambda: NOW + 5,
            seam=self._seam,
        )
        kwargs.update(executor_overrides)
        self.executor = DeletionExecutor(self.database, **kwargs)
        self.worker = DeletionWorker(self.executor, idle_poll_s=0)
        return self

    def close(self) -> None:
        """Give the loggers back their level and take the recorder off them."""
        while self._undo:
            logger, level, handler = self._undo.pop()
            logger.removeHandler(handler)
            logger.setLevel(level)

    def step(self, times: int = 1):
        """Run worker steps; each writes its outcome ("done", "idle", "error")."""
        for _ in range(times):
            line = self.begin("step")
            self.end(line, self.worker.process_one())

    def janitor_pass(self):
        """The worker's periodic pass over committed journals."""
        line = self.begin("janitor.retry_cleanups")
        janitor = DeletionJanitor(
            self.database, executor=self.executor, music_library_dir=self.world.music)
        self.end(line, janitor.retry_cleanups())

    def begin(self, text: str) -> int:
        self.lines.append(text)
        return len(self.lines) - 1

    def end(self, line: int, result):
        self.lines[line] += f" -> {self.show(result)}"
        return result

    def failed(self, line: int, exc: BaseException) -> None:
        self.lines[line] += f" raises {self._error_name(exc)}"

    def recorded(self, label, target, faults=()):
        """``target`` wrapped so each call is one line: its arguments, then
        its answer or the error it raised."""

        def call(*args, **kwargs):
            line = self.begin(f"{label}({self.args(args, kwargs)})")
            fault = next((f for f in faults if f.hits(args, kwargs)), None)
            try:
                if fault is not None and not fault.after:
                    if fault.error is not None:
                        raise fault.error
                    return self.end(line, fault.answer)
                result = target(*args, **kwargs)
                if fault is not None and fault.error is not None:
                    raise fault.error
            except BaseException as exc:
                self.failed(line, exc)
                raise
            return self.end(line, result)

        return call

    def _judgement(self, label, target):
        """A recorded path judgement; one asked for from inside
        ``put_back_file`` is let through unrecorded."""
        recorded = self.recorded(label, target)
        is_put_back = label.endswith(".put_back_file")

        def call(*args, **kwargs):
            if self._inside_put_back:
                return target(*args, **kwargs)
            if not is_put_back:
                return recorded(*args, **kwargs)
            self._inside_put_back += 1
            try:
                return recorded(*args, **kwargs)
            finally:
                self._inside_put_back -= 1

        return call

    # ── faults ────────────────────────────────────────────────────────────

    def db_fault(self, name, error=None, **how):
        """Make database method ``name`` raise ``error`` (or, with
        ``answer=``, return that) on its first call; see ``_Fault``."""
        if "answer" in how:
            how["has_answer"] = True
        self.faults.setdefault(("db", name), []).append(_Fault(error=error, **how))

    def os_fault(self, name, error=None, *, path=None, **how):
        """Make ``os.<name>`` raise ``error`` when its first path is ``path``
        (any path when None); ``then=`` runs when that happens (after the
        real call when there is no error). ``stat`` and ``lstat`` are not
        written down; they only take faults."""
        if path is not None:
            target = os.fspath(path)
            how["when"] = lambda first, *a, **k: self._path_of(first) == target
        self.faults.setdefault(("os", name), []).append(_Fault(error=error, **how))

    def at(self, seam: str, action) -> None:
        """Run ``action()`` when the executor reaches ``seam``."""
        self._seams.setdefault(seam, []).append(action)

    # ── end state ─────────────────────────────────────────────────────────

    def end_state(self):
        """Write the end state of every track of the rig: its item, its
        journal stage, and the files under the music folder."""
        for uuid_id, _rel, owner, op in self._tracks:
            it = item(self.world, op, uuid_id, owner)
            row = journal(self.world, uuid_id)
            self.begin(
                f"end {self.show(uuid_id)}: item={it['status']}/{it['error']} lease={it['lease']}"
                f" details={self.show(it['details'])} journal={row['stage'] if row else None}"
            )
        self.begin(f"end files: {self.show(sorted(files_under(self.world.music)))}")

    def outcome(self) -> tuple:
        """(status, error code) of the first track's item."""
        uuid_id, _rel, owner, op = self._tracks[0]
        it = item(self.world, op, uuid_id, owner)
        return it["status"], it["error"]

    def count(self, start: str) -> int:
        """How many recorded lines start with ``start``."""
        return sum(1 for line in self.lines if line.startswith(start))

    def expect(self, *parts: str) -> None:
        """The recorded lines, followed by the end state, are exactly the
        lines of ``parts`` (blank lines and indentation aside)."""
        self.end_state()
        wanted = [line.strip() for part in parts for line in part.splitlines() if line.strip()]
        assert self.lines == wanted

    # ── writing values down ───────────────────────────────────────────────

    def text(self, value: str) -> str:
        for root, label in self._roots:
            value = value.replace(root + "/", label)
            if value == root:
                value = label.rstrip("/") or "<music>"
        for literal, placeholder in self._names.items():
            value = value.replace(literal, placeholder)
        return value

    def show(self, value) -> str:
        if isinstance(value, BaseException):
            return type(value).__name__
        if isinstance(value, os.stat_result):
            return "<stat>"
        if isinstance(value, (str, os.PathLike)):
            return self.text(os.fspath(value))
        if isinstance(value, tuple):
            if value in self._identities:
                return self._identities[value]
            return "(" + ", ".join(self.show(v) for v in value) + ")"
        if isinstance(value, list):
            return "[" + ", ".join(self.show(v) for v in value) + "]"
        if isinstance(value, dict):
            if "library_folder" in value:
                return f"<user {value['library_folder']}>"
            if "state" in value:
                return f"<{value['state']}>"
            if "stage" in value:
                return f"<journal {value['stage']}>"
            if "quarantine_path" in value:
                return "<journal-like row>"
            if {"owner_id", "operation_uuid", "uuid_id"} <= set(value):
                return f"<item {self.show(value['uuid_id'])}>"
            return "<dict>"
        if callable(value):
            return "<function>"
        return repr(value)

    def args(self, args, kwargs) -> str:
        shown = [self.show(a) for a in args]
        kwargs = dict(kwargs)
        # The three values that name one target of the rig are written as <key>.
        triple = tuple(kwargs.get(name) for name in ("uuid_id", "owner_id", "operation_uuid"))
        for n, (uuid_id, _rel, owner, op) in enumerate(self._tracks, start=1):
            if triple == (uuid_id, owner, op):
                shown.append("<key>" if n == 1 else f"<key{n}>")
                for name in ("uuid_id", "owner_id", "operation_uuid"):
                    del kwargs[name]
        shown += [f"{key}={self.show(kwargs[key])}" for key in sorted(kwargs)]
        return ", ".join(shown)

    @staticmethod
    def _error_name(exc: BaseException) -> str:
        if isinstance(exc, OSError) and exc.errno in errno.errorcode:
            return f"{type(exc).__name__}({errno.errorcode[exc.errno]})"
        return type(exc).__name__

    # ── the os module ─────────────────────────────────────────────────────

    @staticmethod
    def _path_of(value) -> str | None:
        return os.fspath(value) if isinstance(value, (str, os.PathLike)) else None

    def _ours(self, *paths) -> bool:
        tmp = [root for root, _label in self._roots]
        return any(
            p is not None and any(p == root or p.startswith(root + "/") for root in tmp)
            for p in map(self._path_of, paths)
        )

    def _os_call(self, name, real):
        two_paths = name in ("replace", "rename", "link")

        def call(*args, **kwargs):
            paths = args[: 2 if two_paths else 1]
            if not self._ours(*paths):
                return real(*args, **kwargs)
            shown = " -> ".join(self.show(p) for p in paths) if two_paths else self.show(paths[0])
            line = self.begin(f"os.{name} {shown}")
            fault = next((f for f in self.faults.get(("os", name), ()) if f.hits(args, kwargs)), None)
            try:
                if fault is not None and fault.error is not None and not fault.after:
                    if fault.then is not None:
                        fault.then()
                    raise fault.error
                result = real(*args, **kwargs)
                if fault is not None and fault.then is not None:
                    fault.then()
                if fault is not None and fault.error is not None:
                    raise fault.error
            except BaseException as exc:
                if name == "mkdir":
                    del self.lines[line:]  # only the folders really made are written down
                else:
                    self.failed(line, exc)
                raise
            return result

        return call

    def _os_fault_only(self, name, real):
        def call(*args, **kwargs):
            for fault in self.faults.get(("os", name), ()):
                if fault.hits(args, kwargs):
                    raise fault.error
            return real(*args, **kwargs)

        return call

    def _patch_flushes(self, patch) -> None:
        real_open, real_close, real_fsync = os.open, os.close, os.fsync

        def open_(path, *args, **kwargs):
            fd = real_open(path, *args, **kwargs)
            name = self._path_of(path)
            if name is not None:
                self._fds[fd] = name
            else:
                self._fds.pop(fd, None)
            return fd

        def close(fd):
            self._fds.pop(fd, None)
            return real_close(fd)

        def fsync(fd):
            path = self._fds.get(fd)
            if path is None or not self._ours(path):
                return real_fsync(fd)
            line = self.begin(f"os.fsync {self.show(path)}")
            fault = next((f for f in self.faults.get(("os", "fsync"), ()) if f.hits((path,), {})), None)
            try:
                if fault is not None:
                    raise fault.error
                return real_fsync(fd)
            except BaseException as exc:
                self.failed(line, exc)
                raise

        patch.setattr(os, "open", open_)
        patch.setattr(os, "close", close)
        patch.setattr(os, "fsync", fsync)

    def _seam(self, name: str) -> None:
        self.begin(f"seam {name}")
        for action in self._seams.get(name, ()):
            action()
