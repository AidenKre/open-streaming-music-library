"""The Last.fm scrobble sender (spec §7.8, §7.9): one background thread on the
shared worker base that sends each due user's pending outbox rows through the
gate and applies Last.fm's answers to the rows that are still pending."""

import json

from app.services.lastfm_client import AnswerKind, RowRefused, check_scrobble_row
from app.core.operator_log import operator_logger
from app.models.lastfm import RESULT_INVALID_ROW
from app.services.lastfm_crypto import CredentialUndecryptable, decrypt
from app.services.lastfm_gate import GateBusy, GateCancelled, GateStopped
from app.services.lastfm_now_playing import now_playing_track
from app.services.lastfm_state import wall_ms
from app.services.worker_thread import WorkerThread

PASS_INTERVAL_S = 15
BATCH_MAX = 50
MAX_TRIES = 10
RETAIN_DONE_S = 30 * 86_400
MAX_AGE_S = 14 * 86_400
MAX_REJECTED_IN_A_ROW = 10


def _code_text(code) -> str:
    """A Last.fm code as stored text: an int 0-999 as decimal, anything else "unknown"."""
    if isinstance(code, int) and not isinstance(code, bool) and 0 <= code <= 999:
        return str(code)
    return "unknown"


class ScrobbleSender(WorkerThread):
    thread_name = "lastfm-sender"

    def __init__(
        self,
        database,
        state,
        *,
        client,
        gate,
        notices,
        settle_delay_s,
        now_ms=wall_ms,
    ):
        super().__init__()
        self.notices = notices
        notices.attach(self.wake)
        self._database = database
        self._state = state
        self._client = client
        self._gate = gate
        self._settle_delay_s = settle_delay_s
        self._now_ms = now_ms
        self._serves = 0
        self._rejected_in_a_row = 0
        self._served: dict[int, int] = {}  # owner id -> serve counter (least recent first)
        # answered scrobble outcomes whose write failed (not the reconnect mark), per owner, retried oldest first; memory only
        self._unrecorded: dict[int, list] = {}

    def _record(self, owner: int, write) -> None:
        """Runs a write that records a known answer. A failed write is kept and retried at
        the start of the next pass: an answered row is never resent."""
        try:
            write()
        except Exception as exc:  # class only, never the message
            operator_logger.warning(
                "Last.fm sender could not record an answer, will retry: %s", type(exc).__name__
            )
            self._unrecorded.setdefault(owner, []).append(write)

    def _retry_unrecorded(self) -> None:
        for owner in list(self._unrecorded):
            writes = self._unrecorded[owner]
            while writes:
                try:
                    writes[0]()
                except Exception as exc:
                    operator_logger.warning(
                        "Last.fm sender could not record an answer, will retry: %s", type(exc).__name__
                    )
                    break
                writes.pop(0)
            if not writes:
                del self._unrecorded[owner]

    def _needs_reconnect_undecryptable(self, connection_id, session_key_enc, owner: int) -> None:
        self._database.mark_lastfm_needs_reconnect(
            connection_id, session_key_enc, self._now_ms(), owner_id=owner
        )
        operator_logger.warning(
            "Last.fm: a stored session key cannot be decrypted; that user must reconnect"
        )

    def _session_key(self, stored, owner: int) -> str | None:
        """The session key of ``stored`` (a read holding connection_id and
        session_key_enc), or None when it cannot be decrypted: the connection is
        then marked for reconnect."""
        try:
            return decrypt(
                self._state.config.credential_key.get_secret_value(), stored["session_key_enc"]
            )
        except CredentialUndecryptable:
            self._needs_reconnect_undecryptable(
                stored["connection_id"], stored["session_key_enc"], owner
            )
            return None

    def _needs_reconnect_answered(self, connection_id, session_key_enc, owner: int) -> None:
        self._database.mark_lastfm_needs_reconnect(
            connection_id, session_key_enc, self._now_ms(), owner_id=owner
        )

    def run_pass(self) -> bool:
        """One pass: retention, then waiting Now Playing notices, then every due user once
        (least recently served first) with another Now Playing round after each. True when
        at least one request went out."""
        self._retry_unrecorded()
        now_ms = self._now_ms()
        self._database.prune_lastfm_outbox(
            now_ms, keep_done_ms=RETAIN_DONE_S * 1000, max_age_s=MAX_AGE_S,
            skip_owners=tuple(self._unrecorded),
        )
        if not self._state.is_running:
            self.notices.clear()
            return False
        sent_any, ended = self._now_playing_round()
        if ended:
            return sent_any
        owners = self._database.list_due_lastfm_owners(
            listened_by_s=now_ms // 1000, queued_by=now_ms - self._settle_delay_s * 1000
        )
        owners.sort(key=lambda owner: (self._served.get(owner, 0), owner))
        for owner in owners:
            if owner in self._unrecorded:
                continue
            self._serves += 1
            self._served[owner] = self._serves  # before the gate: a failing owner goes to the back
            try:
                if self._serve(owner):
                    sent_any = True
            except (GateStopped, GateCancelled):
                break
            except Exception as exc:  # one user's failure never ends the pass or starves the rest
                operator_logger.error("Last.fm sender could not serve a user: %s", type(exc).__name__)
            # a notice that arrived while this user was served goes out before the next scrobble
            round_sent, ended = self._now_playing_round()
            sent_any = sent_any or round_sent
            if ended:
                break
        return sent_any

    def _now_playing_round(self) -> tuple[bool, bool]:
        """Sends each notice waiting now (oldest first) or discards it. Returns (sent any,
        the pass is over because the gate stopped or the sender was cancelled)."""
        sent_any = False
        for notice in self.notices.waiting():
            remaining = self.notices.remaining_s(notice)
            try:
                if self._send_notice(notice, remaining):
                    sent_any = True
            except GateBusy:
                self.notices.discard(notice)
            except (GateStopped, GateCancelled):
                return sent_any, True
            except Exception as exc:  # never the message: it could carry track fields
                operator_logger.error(
                    "Last.fm sender could not send a Now Playing notice: %s", type(exc).__name__
                )
                self.notices.discard(notice)
        return sent_any, False

    def _send_notice(self, notice, remaining: float) -> bool:
        owner = notice.owner_id
        with self._gate.enter(max_wait_s=remaining, cancel=self._stop) as slot:
            if not self.notices.claim(notice):
                return False
            target = self._database.read_lastfm_now_playing(
                owner_id=owner, track_uuid=notice.track_uuid
            )
            if target is None:
                return False
            track = now_playing_track(target["track"])
            if track is None:
                return False
            key = self._session_key(target, owner)
            if key is None:
                return False
            answer = self._client.update_now_playing(key, track)
            slot.record(answer)
            if answer.kind is AnswerKind.RECONNECT:
                self._needs_reconnect_answered(target["connection_id"], target["session_key_enc"], owner)
            return True

    def _serve(self, owner: int) -> bool:
        """One request for one owner: gate first, then read, then send at once."""
        with self._gate.enter(cancel=self._stop) as slot:
            now_ms = self._now_ms()
            batch = self._database.read_lastfm_batch(
                owner_id=owner,
                listened_by_s=now_ms // 1000,
                listened_since_s=now_ms // 1000 - MAX_AGE_S,
                limit=BATCH_MAX,
            )
            if batch is None:
                return False
            key = self._session_key(batch, owner)
            if key is None:
                return False
            uuids, rows, refused = [], [], []
            for event_uuid, payload in batch["rows"]:
                try:
                    row = json.loads(payload)
                    if not isinstance(row, dict):
                        raise RowRefused("a scrobble row is not an object")
                    check_scrobble_row(row)
                except (ValueError, RecursionError):  # RowRefused, JSON decode errors, deep nesting
                    refused.append((event_uuid, "failed", RESULT_INVALID_ROW))
                    continue
                uuids.append(event_uuid)
                rows.append(row)
            if refused:
                self._record(owner, self._settle_write(owner, refused))
            if not rows:
                return False
            result = self._client.scrobble(key, rows)
            slot.record(result.answer)
            if result.answer.kind is AnswerKind.OK:
                self._rejected_in_a_row = 0
                self._settle_ok(owner, uuids, result.rows)
            elif result.answer.kind is AnswerKind.RECONNECT:
                self._needs_reconnect_answered(batch["connection_id"], batch["session_key_enc"], owner)
            elif result.answer.kind is AnswerKind.REJECTED:
                self._settle_rejected(owner, uuids, result.answer.error_code)
            elif result.answer.kind is AnswerKind.TRY_LATER and not result.answer.connect_failed:
                self._database.count_lastfm_try(uuids, self._now_ms(), max_tries=MAX_TRIES, owner_id=owner)
            return True

    def _settle_write(self, owner: int, results):
        now = self._now_ms()  # the time of the answer, kept with the write
        return lambda: self._database.settle_lastfm_rows(results, now, owner_id=owner)

    def _settle_ok(self, owner: int, uuids, outcomes) -> None:
        results = []
        for event_uuid, outcome in zip(uuids, outcomes):
            if outcome.status == "ignored":
                code = _code_text(outcome.code)
            elif outcome.status == "dropped":
                code = outcome.code  # RESULT_NO_ANSWER: the reply did not mention the row
            else:
                code = None
            results.append((event_uuid, outcome.status, code))
        self._record(owner, self._settle_write(owner, results))

    def _settle_rejected(self, owner: int, uuids, error_code) -> None:
        self._rejected_in_a_row += 1  # once per rejected request, whether or not the write lands
        if len(uuids) > 1:
            self._record(
                owner, lambda: self._database.mark_lastfm_alone(uuids, owner_id=owner)
            )
        else:
            self._record(
                owner, self._settle_write(owner, [(uuids[0], "failed", _code_text(error_code))])
            )
        if self._rejected_in_a_row >= MAX_REJECTED_IN_A_ROW:
            self._state.stop("ten track.scrobble requests in a row were rejected")

    def _run_loop(self):
        """A clean stop retries the kept writes once; if that fails they are lost with this
        process (logged at ERROR) and those rows are sent again after the restart. A crash
        may also resend (spec §7.13)."""
        try:
            super()._run_loop()
        finally:
            try:
                self._retry_unrecorded()
            except Exception as exc:  # class only, never the message
                operator_logger.warning(
                    "Last.fm sender could not record an answer at stop: %s", type(exc).__name__
                )
            if self._unrecorded:
                operator_logger.error(
                    "Last.fm sender stopped with %d answer(s) it could not record; some"
                    " listens may be sent to Last.fm again after the restart",
                    sum(len(writes) for writes in self._unrecorded.values()),
                )

    def run_step(self):
        try:
            return None if self.run_pass() else PASS_INTERVAL_S
        except Exception as exc:  # a pass never ends the thread; class only, never the message
            operator_logger.error("Last.fm sender pass failed: %s", type(exc).__name__)
            return PASS_INTERVAL_S

    def request_stop(self):
        super().request_stop()
        self._gate.wake()  # setting the cancel event alone does not wake a gate waiter
