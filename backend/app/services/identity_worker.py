"""Phase 6.5 (SC-25): the audio-identity maintenance worker (spec §6.4).

``process_one()`` is one synchronous step: take the next queued row, stat()
the master, compute the pending layers and write them with a compare-and-set
(generation, master path, second equal stat(), no edit_journal row). A row
whose exact layer is settled but whose ``match_state`` is pending gets a match
step instead: find its duplicates and store the candidate pairs.
"""

from __future__ import annotations

import itertools
import logging
import os
import sqlite3
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Optional

from app import config
from app.core.operator_log import operator_logger
from app.database.database import ANY_OWNER
from app.services import audio_identity
from app.services.audio_identity import (
    AudioIdentity,
    ExactAudioHash,
    REASON_INTERNAL_ERROR,
    REASON_KILLED,
    REASON_TOOL_MISSING,
    ExactUnavailable,
    FingerprintUnavailable,
    fingerprint_to_columns,
    identity_to_columns,
)
from app.services.duplicate_detection import (
    MatcherParams,
    classifier_version,
    matcher_version as _matcher_version_of,
)
from app.services.fingerprinter import RawFingerprint, classify as classify_print
from app.services.ffmpeg_runner import FfmpegProcessRegistry
from app.services.identity_wakeup import IdentityWakeup
from app.services.worker_thread import WorkerThread

logger = logging.getLogger(__name__)

IDLE_POLL_S = 60.0
JOIN_TIMEOUT_S = 10.0
BACKOFF_S = (60, 3600, 86400)
MAX_ATTEMPTS = len(BACKOFF_S) + 1  # 1 min, 1 h and 1 day waits, then failed on the 4th failure
BUSY_RETRY_S = 5.0
TOOL_MISSING_RETRY_S = 300.0

_Stat = tuple[int, int, int]
_stat = audio_identity.stat_snapshot
_FP_SETTLED = frozenset({"pending", "unavailable"})
_MAX_DEFERRED = 256


def default_matcher_version() -> str:
    """The matcher version for the current settings (read at call time)."""
    return _matcher_version_of(MatcherParams.from_settings(config.settings))


@dataclass(frozen=True)
class StepResult:
    outcome: str
    uuid_id: Optional[str] = None
    delay_s: float = 0.0  # how long the loop waits before the next step


class AudioIdentityWorker(WorkerThread):
    thread_name = "audio-identity-worker"
    join_timeout_s = JOIN_TIMEOUT_S

    def __init__(
        self,
        database,
        *,
        wakeup: IdentityWakeup,
        registry: FfmpegProcessRegistry,
        clock: Callable[[], float] = time.time,
        compute_exact=audio_identity.compute_exact,
        tool_versions=None,
        idle_poll_s: float = IDLE_POLL_S,
        matcher_version: Optional[str] = None,
        fingerprinter=None,
        journal_finisher: Optional[Callable[[], Any]] = None,
    ):
        self.database = database
        super().__init__(kill_registry=registry)
        self.wakeup = wakeup
        self.registry = registry
        self._clock = clock
        self._compute_exact = compute_exact
        self._fingerprinter = fingerprinter
        self._journal_finisher = journal_finisher
        self._params = MatcherParams.from_settings(config.settings)  # classification thresholds
        self._tool_versions = tool_versions or (
            lambda: audio_identity.tool_versions(fingerprinter=self._fingerprinter)
        )
        self._idle_poll_s = idle_poll_s
        self._matcher_version = matcher_version or default_matcher_version()
        self._layer: Optional[str] = None  # which layer the step in flight is on
        # Rows set aside in memory: uuid -> generation it is set aside at, and
        # until when. A generation bump or the expiry lifts it.
        self._deferred: dict[str, int] = {}
        self._deferred_until: dict[str, float] = {}
        self._job_ids = itertools.count(1)
        self._tool_paused = False
        self._fp_paused_until = 0.0
        self._fp_tool_paused = False
        # What the step in flight knows, for recording an unexpected failure.
        self._uuid: Optional[str] = None
        self._subject: Optional[dict] = None
        self._stat1: Optional[_Stat] = None
        self._stat_known = False

    def _wait(self, timeout):
        self.wakeup.wait(timeout)

    def _signal(self):
        self.wakeup.notify()

    def run_step(self):
        result = self.process_one()
        return result.delay_s if result.delay_s > 0 else None

    def process_one(self) -> StepResult:
        """One step; never raises an Exception."""
        self._uuid = self._subject = self._stat1 = None
        self._stat_known = False
        self._layer = None
        try:
            return self._step()
        except Exception as e:  # noqa: BLE001 - the loop must survive anything
            return self._after_exception(e)

    def _step(self) -> StepResult:
        db = self.database
        now = int(self._clock())
        for expired in [u for u, t in self._deferred_until.items() if t <= now]:
            self._undefer(expired)
        uuid_id = db.next_identity_work(
            now, skip=self._deferred, owner_id=ANY_OWNER, fingerprint=self._fingerprint_enabled(now)
        )
        if uuid_id is None:
            if self._journal_finisher is not None:
                try:
                    self._journal_finisher()
                except Exception as e:  # noqa: BLE001 - idling must survive it
                    logger.warning("journal finisher failed: %s", type(e).__name__)
            return StepResult("idle", delay_s=self._idle_poll_s)
        self._uuid = uuid_id
        subject = db.get_identity_subject(uuid_id, owner_id=ANY_OWNER)
        if subject is None:
            return StepResult("vanished", uuid_id)
        self._subject = subject
        layer = self._work_layer(subject, now)
        if layer == "exact":
            return self._exact_step(subject, now)
        if layer == "fingerprint":
            return self._fingerprint_step(subject, now)
        if layer == "match":
            self._layer = "match"
            result = self._match(subject, now)
            if result.outcome == "discarded":
                # An unexplained refusal must not hot-loop; a generation bump retries now.
                current = db.get_identity_subject(uuid_id, owner_id=ANY_OWNER)
                if current is not None and current["generation"] == subject["generation"]:
                    self._defer(uuid_id, subject["generation"], now + BACKOFF_S[0])
            return result
        # Queued but nothing is due for this worker: set it aside, never spin.
        self._defer(uuid_id, subject["generation"], now + BACKOFF_S[0])
        return StepResult("discarded", uuid_id, delay_s=0)

    def _work_layer(self, subject: dict, now: int) -> Optional[str]:
        """The one layer a step works on for this row (exact, fingerprint, match),
        or None when nothing is due for this worker."""
        if subject["exact_state"] == "pending":
            return "exact"
        if (
            self._fingerprint_enabled(now)
            and subject["fp_state"] == "pending"
            and subject["exact_state"] in ("current", "unsupported")
            and (subject["next_attempt_at"] is None or subject["next_attempt_at"] <= now)
        ):
            return "fingerprint"
        if subject["match_state"] == "pending":
            return "match"
        return None

    def _fingerprint_enabled(self, now: int) -> bool:
        return self._fingerprinter is not None and now >= self._fp_paused_until

    def _exact_step(self, subject: dict, now: int) -> StepResult:
        uuid_id = subject["uuid_id"]
        self._layer = "exact"
        path = subject["file_path"]
        stat1 = self._stat1 = _stat(path)
        self._stat_known = True

        exact = self._compute_exact_layer(subject, path)
        if isinstance(exact, ExactUnavailable) and exact.state == "failed":
            return self._handle_failure(subject, exact, now)
        values = self._exact_values(subject, exact, stat1, now)
        self._tool_paused = False
        if self._write(subject, values):
            self._undefer(uuid_id)
            return StepResult("written", uuid_id)
        return StepResult("discarded", uuid_id)

    def _match(self, subject: dict, now: int) -> StepResult:
        """Find and store the subject's duplicate pairs (spec 6.4 matching)."""
        uuid_id, owner = subject["uuid_id"], subject["owner_id"]
        if subject["exact_state"] == "current":
            exact = ExactAudioHash(
                subject["exact_kind"], subject["exact_digest"],
                subject["sample_rate_hz"], subject["channels"], subject["bits_per_sample"],
            )
        else:
            exact = ExactUnavailable(subject["exact_state"], None)
        fingerprint = None
        if subject["fp_state"] == "current":
            fingerprint = self.database.get_identity_fingerprint(uuid_id, owner_id=owner)
        identity = AudioIdentity(exact=exact, tool_versions=None, computed_at=now, fingerprint=fingerprint)
        report = self.database.find_duplicates_for_track(uuid_id, identity, owner_id=owner)
        if self.database.store_duplicate_candidates(
            uuid_id, generation=subject["generation"], exact_state=subject["exact_state"],
            fp_state=subject["fp_state"], matches=report.matches,
            matcher_version=self._matcher_version, now=now, owner_id=owner,
        ):
            self._undefer(uuid_id)
            return StepResult("matched", uuid_id)
        return StepResult("discarded", uuid_id)

    def _undefer(self, uuid_id: str) -> None:
        self._deferred.pop(uuid_id, None)
        self._deferred_until.pop(uuid_id, None)

    def _defer(self, uuid_id: str, generation: int, until: float) -> None:
        """Set a row aside (bounded; the oldest entry goes first when full)."""
        if uuid_id not in self._deferred and len(self._deferred) >= _MAX_DEFERRED:
            self._undefer(next(iter(self._deferred)))
        self._deferred[uuid_id] = generation
        self._deferred_until[uuid_id] = until

    def _write(self, subject: dict, values: dict[str, Any], fingerprint: Optional[dict] = None) -> bool:
        """The CAS write. A refusal while the master's stat moved (bytes changing
        before any generation bump) sets the row aside for BACKOFF_S[0]."""
        written = self._write_cas(subject, values, fingerprint)
        if not written and _stat(subject["file_path"]) != self._stat1:
            self._defer(subject["uuid_id"], subject["generation"], self._clock() + BACKOFF_S[0])
        return written

    def _write_cas(self, subject: dict, values: dict[str, Any], fingerprint: Optional[dict] = None) -> bool:
        path, stat1 = subject["file_path"], self._stat1
        return self.database.update_identity_if_unchanged(
            subject["uuid_id"],
            generation=subject["generation"],
            file_path=path,
            values=values,
            verify=lambda: _stat(path) == stat1,
            owner_id=subject["owner_id"],
            fingerprint=fingerprint,
        )

    def _compute_exact_layer(self, subject: dict, path: str):
        job_id = ("identity", next(self._job_ids))
        self._current_job = job_id
        try:
            if self._stop.is_set():  # a stop between the loop check and here must not be lost
                return ExactUnavailable("failed", REASON_KILLED)
            return self._compute_exact(
                Path(path), subject["codec"], registry=self.registry,
                job_id=job_id, low_priority=True,
            )
        finally:
            self._current_job = None
            self.registry.forget(job_id)

    def _exact_values(self, subject: dict, exact, stat1: Optional[_Stat], now: int) -> dict[str, Any]:
        values = identity_to_columns(
            AudioIdentity(exact=exact, tool_versions=self._tool_versions(), computed_at=now)
        )
        if stat1 is not None:
            values.update(zip(("stat_size", "stat_mtime_ns", "stat_inode"), stat1))
        values.update(attempts=0, next_attempt_at=None, failure_reason=None)
        values.update(self._fp_after_exact(subject, exact.digest if isinstance(exact, ExactAudioHash) else None))
        return values

    def _fp_after_exact(self, subject: dict, digest: Optional[str]) -> dict[str, Any]:
        """The one rule for the fingerprint after an exact result: keep it only when
        the kept digest and the new digest are both known and equal. Without that
        proof (``digest`` None: unsupported or finally failed; or a changed digest)
        a settled print goes back to pending; pending and unavailable stay. A
        ``failed`` print is not a stored print: a successful exact compute retries it."""
        old, fp_state = subject["exact_digest"], subject["fp_state"]
        if digest is not None and old == digest and fp_state != "failed":
            return {}
        if digest is not None and old is not None and old != digest and fp_state != "pending":
            logger.warning(
                "audio identity anomaly: digest changed for %s while the fingerprint was kept",
                subject["uuid_id"],
            )
        return {} if fp_state in _FP_SETTLED else {"fp_state": "pending"}

    @staticmethod
    def _attempt_values(attempts: int, reason: str, now: int) -> dict[str, Any]:
        """Count one failed attempt: back off, or fail the layer after MAX_ATTEMPTS."""
        n = attempts + 1
        if n >= MAX_ATTEMPTS:
            return {"state": "failed", "attempts": n, "next_attempt_at": None, "failure_reason": reason}
        return {"state": "pending", "attempts": n, "next_attempt_at": now + BACKOFF_S[n - 1],
                "failure_reason": reason}

    def _record_attempt(self, subject: dict, reason: str, now: int, layer: str = "exact") -> StepResult:
        """Count an attempt through the same CAS; if a writer raced it, change nothing.
        ``layer`` picks the state it moves: exact_state, or the fingerprint's
        (a final failure is written through ``fingerprint=`` and drops the blob)."""
        attempt = self._attempt_values(subject["attempts"], reason, now)
        state = attempt.pop("state")
        attempt["tool_versions"] = self._tool_versions()  # so an unchanged tool never revives it
        fingerprint = None
        if layer == "exact":
            attempt["exact_state"] = state
            if state == "failed":
                if self._fingerprinter is not None and subject["fp_state"] != "unavailable":
                    # The file cannot be read, so the print fails with it (no fpcalc run).
                    fingerprint = self._failed_fingerprint()
                elif subject["fp_state"] != "failed":
                    # The final failure proves nothing about the audio: a stored print
                    # goes back to pending. A failed one stays (pending would strand it).
                    attempt.update(self._fp_after_exact(subject, None))
        elif state == "failed":
            fingerprint = self._failed_fingerprint()
        if self._write(subject, attempt, fingerprint=fingerprint):
            return StepResult("failed", subject["uuid_id"])
        return StepResult("discarded", subject["uuid_id"])

    def _failed_fingerprint(self) -> dict[str, Any]:
        """The final-failure fingerprint write: state failed with the algorithm, no blob."""
        fingerprint = dict.fromkeys(audio_identity.FINGERPRINT_COLUMNS)
        fingerprint.update(fp_state="failed", fp_algorithm=self._fingerprinter.algorithm)
        return fingerprint

    def _handle_failure(self, subject: dict, exact: ExactUnavailable, now: int) -> StepResult:
        reason, uuid_id = exact.reason, subject["uuid_id"]
        if reason == REASON_KILLED and (self._stop.is_set() or self.registry.closed):
            return StepResult("stopped", uuid_id)
        if reason == REASON_TOOL_MISSING:
            if not self._tool_paused:
                self._tool_paused = True
                logger.warning("audio identity paused: tool (ffmpeg/ffprobe) cannot run; retrying later")
            return StepResult("tool_missing", uuid_id, TOOL_MISSING_RETRY_S)
        return self._record_attempt(subject, reason, now)

    @staticmethod
    def _is_busy(e: Exception) -> bool:
        return isinstance(e, sqlite3.OperationalError) and any(
            word in str(e).lower() for word in ("locked", "busy")
        )

    def _after_exception(self, e: Exception) -> StepResult:
        uuid_id = self._uuid
        if self._is_busy(e):
            logger.info("audio identity worker: database busy; retrying later")
            return StepResult("busy", uuid_id, BUSY_RETRY_S)
        if uuid_id is None:
            logger.warning("audio identity worker: queue read failed: %s", type(e).__name__)
            return StepResult("error", None, BUSY_RETRY_S)
        logger.warning("audio identity worker: step failed for %s: %s", uuid_id, type(e).__name__)
        subject = self._subject
        layer = self._layer
        if layer == "match" and subject is not None:
            # A match failure is not an exact-layer attempt: set the row aside.
            self._defer(uuid_id, subject["generation"], self._clock() + BACKOFF_S[0])
            return StepResult("error", uuid_id, BUSY_RETRY_S)
        try:
            if subject is None:
                subject = self.database.get_identity_subject(uuid_id, owner_id=ANY_OWNER)
                if subject is None:
                    return StepResult("vanished", uuid_id)
            if layer is None:  # failed before the layer was known: decide as _step would
                layer = self._work_layer(subject, int(self._clock()))
                if layer not in ("exact", "fingerprint"):  # match work or nothing: no attempt
                    self._defer(uuid_id, subject["generation"], self._clock() + BACKOFF_S[0])
                    return StepResult("error", uuid_id, BUSY_RETRY_S)
            if not self._stat_known:
                self._stat1 = _stat(subject["file_path"])
            return self._record_attempt(subject, REASON_INTERNAL_ERROR, int(self._clock()), layer=layer)
        except Exception as e2:  # noqa: BLE001
            if self._is_busy(e2):
                return StepResult("busy", uuid_id, BUSY_RETRY_S)
            if subject is None:
                return StepResult("error", uuid_id, BUSY_RETRY_S)
            logger.warning("audio identity worker: setting %s aside: %s", uuid_id, type(e2).__name__)
            self._defer(uuid_id, subject["generation"], self._clock() + BACKOFF_S[0])
            return StepResult("error", uuid_id, BUSY_RETRY_S)

    def _fingerprint_step(self, subject: dict, now: int) -> StepResult:
        """Compute and store the pending fingerprint layer (one layer per step).
        The CAS writes no stat_* or computed_at: those describe the exact compute."""
        uuid_id, path = subject["uuid_id"], subject["file_path"]
        self._layer = "fingerprint"
        self._stat1 = _stat(path)
        self._stat_known = True
        job_id = ("identity", next(self._job_ids))
        self._current_job = job_id
        try:
            if self._stop.is_set():  # a stop between the loop check and here must not be lost
                result = FingerprintUnavailable(REASON_KILLED)
            else:
                result = audio_identity.compute_fingerprint(
                    Path(path), self._fingerprinter, params=self._params,
                    known_duration_s=subject["duration"], registry=self.registry,
                    job_id=job_id, low_priority=True,
                )
        finally:
            self._current_job = None
            self.registry.forget(job_id)
        if isinstance(result, FingerprintUnavailable):
            return self._fingerprint_failure(subject, result.reason, now)
        values = {"attempts": 0, "next_attempt_at": None, "failure_reason": None,
                  "tool_versions": self._tool_versions()}
        if self._write(subject, values, fingerprint=fingerprint_to_columns(result)):
            self._fp_tool_paused = False
            self._undefer(uuid_id)
            return StepResult("written", uuid_id)
        return StepResult("discarded", uuid_id)

    def _fingerprint_failure(self, subject: dict, reason: str, now: int) -> StepResult:
        """A fingerprint that could not be computed this time."""
        uuid_id = subject["uuid_id"]
        if reason == REASON_KILLED and (self._stop.is_set() or self.registry.closed):
            return StepResult("stopped", uuid_id)
        if reason == REASON_TOOL_MISSING:
            # Not an attempt: pause fingerprint work only; exact work and matching go on.
            self._fp_paused_until = now + TOOL_MISSING_RETRY_S
            if not self._fp_tool_paused:
                self._fp_tool_paused = True
                logger.warning("audio identity: fingerprinting paused: a tool (fpcalc or ffmpeg) cannot run; retrying later")
            return StepResult("tool_missing", uuid_id, delay_s=0)
        return self._record_attempt(subject, reason, now, layer="fingerprint")


def reconcile_audio_identity(
    database,
    *,
    tool_versions: Optional[str],
    fingerprinter_present: bool,
    batch_size: int = 500,
    matcher_version: Optional[str] = None,
    fingerprint_algorithm: Optional[str] = None,
    classifier_params: Optional[MatcherParams] = None,
) -> None:
    """Startup reconcile (spec §6.4): idempotent and non-fatal. Inserts missing
    rows, sets fingerprint availability and re-queues prints of another
    algorithm, retries failed rows after a tool-version change, and retries
    master_missing rows whose master is back. When ``matcher_version`` is given
    and differs from the stored one, every row is re-queued for matching (no
    decoding); None leaves matching alone. When ``classifier_params`` is given,
    stored prints are reclassified if the item or diversity minimum changed, with
    or without a fingerprinter (matching re-runs only for rows whose class
    changed). Each part runs on its own."""
    inserted = reset = revived = requeued = availability = realgorithm = reclassified = rule_requeued = 0
    try:
        inserted = database.insert_missing_identity_rows(
            fingerprinter_present=fingerprinter_present, owner_id=ANY_OWNER)
    except Exception as e:  # noqa: BLE001
        logger.warning("identity reconcile: inserting missing rows failed: %s", type(e).__name__)
    try:
        availability = database.set_fingerprint_availability(
            fingerprinter_present, algorithm=fingerprint_algorithm if fingerprinter_present else None,
            owner_id=ANY_OWNER)
    except Exception as e:  # noqa: BLE001
        logger.warning("identity reconcile: fingerprint availability failed: %s", type(e).__name__)
    if fingerprinter_present and fingerprint_algorithm is not None:
        try:
            realgorithm = database.requeue_fingerprint_algorithm(fingerprint_algorithm, owner_id=ANY_OWNER)
        except Exception as e:  # noqa: BLE001
            logger.warning("identity reconcile: re-queueing fingerprints failed: %s", type(e).__name__)
    if classifier_params is not None:
        try:
            # Without a fingerprinter stored prints are still matched, so they are
            # reclassified too (any algorithm; too_short waits as 'unavailable').
            reclassified = database.reclassify_fingerprints(
                classifier_version(classifier_params),
                fingerprint_algorithm if fingerprinter_present else None,
                lambda items: classify_print(RawFingerprint(items, None), classifier_params),
                owner_id=ANY_OWNER, fingerprinter_present=fingerprinter_present)
        except Exception as e:  # noqa: BLE001
            logger.warning("identity reconcile: reclassifying prints failed: %s", type(e).__name__)
    if tool_versions is not None:  # a missing tool is not a version change
        try:
            reset = database.reset_failed_identity_rows(
                tool_versions, owner_id=ANY_OWNER, fingerprint=fingerprinter_present)
        except Exception as e:  # noqa: BLE001
            logger.warning("identity reconcile: resetting failed rows failed: %s", type(e).__name__)
    if fingerprinter_present:
        try:
            rule_requeued = database.requeue_unknown_duration_prints(
                audio_identity.FINGERPRINT_DURATION_RULE, owner_id=ANY_OWNER)
        except Exception as e:  # noqa: BLE001
            logger.warning("identity reconcile: re-queueing duration_unknown prints failed: %s", type(e).__name__)
    if matcher_version is not None:
        try:
            requeued = database.requeue_matching(matcher_version, owner_id=ANY_OWNER)
        except Exception as e:  # noqa: BLE001
            logger.warning("identity reconcile: re-queueing matching failed: %s", type(e).__name__)
    try:
        back = [
            uuid_id
            for uuid_id, file_path in database.list_master_missing_identity(
                owner_id=ANY_OWNER, fingerprint=fingerprinter_present)
            if Path(file_path).is_file()
        ]
        for i in range(0, len(back), batch_size):
            revived += database.reset_master_missing_identity(
                back[i:i + batch_size], owner_id=ANY_OWNER, fingerprint=fingerprinter_present)
    except Exception as e:  # noqa: BLE001
        logger.warning("identity reconcile: master_missing sweep failed: %s", type(e).__name__)
    operator_logger.info(
        "identity reconcile: %d rows inserted, %d fingerprint availability changes, "
        "%d prints re-queued for a new algorithm, %d failed rows reset, %d missing masters back, "
        "%d rows re-queued for matching, %d prints reclassified, "
        "%d prints re-queued for the new duration rule",
        inserted, availability, realgorithm, reset, revived, requeued, reclassified, rule_requeued,
    )
