"""The one background worker thread lifecycle.

A worker is one daemon thread that runs ``run_step`` over and over until it is
stopped. This module owns everything around the step; a subclass owns only
what one step does.

What a subclass supplies
  * ``thread_name``: the thread's name and the name used in log messages.
  * ``run_step()``: one step. It returns ``None`` to run the next step at once,
    or a number of seconds (0 included) to wait before the next step.
  * optionally ``_first_wait_s()``: seconds to wait before the very first step
    (default ``None``: no wait; a periodic worker returns its interval).
  * optionally ``_wait(timeout)`` and ``_signal()``: how a wait is made and how
    it is ended early, for a worker that has its own wake-up object. The
    defaults use one ``threading.Event`` and always clear it after a wait.

Wake-up and stop
  ``wake()`` ends the current wait so the next step runs at once.
  ``request_stop()`` sets the stop flag and signals, so a wait ends and the
  loop leaves without another step; it never interrupts plain Python work in a
  step, which finishes first (``stop`` then reports False until the thread has
  ended, or after its timeout). ``start`` may be called once; ``join`` and
  ``stop`` return True once the thread has ended or was never started.
  ``done`` is a Future resolved when the thread has ended (or by join/stop of a
  worker that never started).

A stop during a process step
  A step that runs an external process wraps it in ``_process_step(fn, ...,
  job_id=...)``, which publishes the job id and passes it on to ``fn`` as the
  keyword ``job_id``. ``request_stop`` then sets
  ``_stop_hit_step`` (the step's result is not to be trusted) and, when a
  ``kill_registry`` was given, calls ``kill_registry.kill(job_id)``.

What is logged
  An exception that escapes the loop is logged once at ERROR as the thread name
  and the exception type name only (never the message, which can hold paths);
  the thread ends and ``done`` resolves. Nothing else is logged here.
"""

import logging
import threading
from concurrent.futures import Future

log = logging.getLogger(__name__)

_DEFAULT = object()


class WorkerThread:
    thread_name = "worker"
    join_timeout_s = 5.0

    def __init__(self, *, kill_registry=None):
        self._stop = threading.Event()
        self._wake = threading.Event()
        self._thread = None
        self._current_job = None
        self._stop_hit_step = False
        self._kill_registry = kill_registry
        self.done = Future()  # resolved when the thread has ended (or was never started)

    def run_step(self):
        """One step: None for the next step at once, else seconds to wait first."""
        raise NotImplementedError

    def _first_wait_s(self):
        return None

    def _wait(self, timeout):
        self._wake.wait(timeout)
        self._wake.clear()

    def _signal(self):
        self._wake.set()

    def wake(self):
        self._signal()

    def request_stop(self):
        """Stop soon: end the wait and kill the process step in flight."""
        self._stop.set()
        self._signal()
        job_id = self._current_job
        if job_id is not None:
            self._stop_hit_step = True  # a process step was in flight: its result is not trusted
            if self._kill_registry is not None:
                self._kill_registry.kill(job_id)

    def start(self):
        if self._thread is not None:
            raise RuntimeError(f"{self.thread_name} is already started")
        self._thread = threading.Thread(target=self._thread_main, name=self.thread_name, daemon=True)
        try:
            self._thread.start()
        except BaseException:
            self._thread = None  # never started: stop/join resolve `done`
            raise

    def _run_loop(self):
        wait_s = self._first_wait_s()
        while not self._stop.is_set():
            if wait_s is not None:
                self._wait(wait_s)
                if self._stop.is_set():
                    break
            wait_s = self.run_step()

    def _thread_main(self):
        try:
            self._run_loop()
        except Exception as e:
            log.error("%s stopped unexpectedly: %s", self.thread_name, type(e).__name__)
        finally:
            if not self.done.done():
                self.done.set_result(None)

    def is_alive(self):
        return self._thread is not None and self._thread.is_alive()

    def join(self, timeout=None):
        """True once the thread has ended (or never started)."""
        if self._thread is None:
            if not self.done.done():
                self.done.set_result(None)
            return True
        self._thread.join(timeout)
        return not self._thread.is_alive()

    def stop(self, timeout=_DEFAULT):
        self.request_stop()
        return self.join(self.join_timeout_s if timeout is _DEFAULT else timeout)

    def _process_step(self, fn, *args, job_id, **kwargs):
        """Run one process step with its job id published, so a stop can kill it.
        ``fn`` gets the job id as the keyword ``job_id``."""
        self._current_job = job_id
        try:
            return fn(*args, job_id=job_id, **kwargs)
        finally:
            self._current_job = None


class PollingWorkerThread(WorkerThread):
    """Runs ``process_one`` back to back; waits ``idle_poll_s`` after an idle or error."""

    IDLE_OUTCOMES = ("idle", "error")

    def __init__(self, *, idle_poll_s, kill_registry=None):
        super().__init__(kill_registry=kill_registry)
        self._idle_poll_s = idle_poll_s

    def process_one(self):
        raise NotImplementedError

    def run_step(self):
        return self._idle_poll_s if self.process_one() in self.IDLE_OUTCOMES else None
