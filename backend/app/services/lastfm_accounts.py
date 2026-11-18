"""The caller's Last.fm link: status, connect, complete, disconnect (spec §7.4)."""

import threading
import unicodedata
import urllib.parse
import uuid

from app.services.lastfm_client import AnswerKind, LastfmClient
from app.models.lastfm import BindOutcome, EnableOutcome
from app.services.lastfm_crypto import CredentialUndecryptable, decrypt, encrypt
from app.services.lastfm_errors import (
    lastfm_account_mismatch,
    lastfm_approval_expired,
    lastfm_connection_changed,
    lastfm_not_connected,
    lastfm_reconnect_required,
    LastfmError,
    lastfm_disabled,
    lastfm_not_authorized_yet,
    lastfm_stopped,
    lastfm_too_soon,
    lastfm_unavailable,
)
from app.services.lastfm_gate import GateBusy, GateStopped, LastfmGate
from app.services.lastfm_now_playing import NowPlayingNotices
from app.services.lastfm_state import LastfmService, wall_ms
from app.services.user_cooldown import UserCooldown

DAY_MS = 86_400_000
KEPT_DAYS = 30
GATE_WAIT_S = 10.0
CONNECT_COOLDOWN_S = 30
TOKEN_LIFETIME_MS = 600_000
ACCOUNT_NAME_MAX = 64
TOKEN_MAX = 256
AUTHORIZATION_URL = "https://www.last.fm/api/auth/"


def lastfm_available(state) -> bool:
    """The capability block's ``available`` (spec §7.2): Last.fm is configured, i.e.
    ``LASTFM_ENABLED`` is true and the configuration is valid. Stays true through a
    run-time stop (opt-in still works, listens still queue); whether requests go out
    right now is ``state.service``, shown by the status route."""
    return state.service is not LastfmService.OFF and state.config is not None


def authorization_url(api_key: str, token: str) -> str:
    query = urllib.parse.urlencode(
        [("api_key", api_key), ("token", token)], quote_via=urllib.parse.quote
    )
    return f"{AUTHORIZATION_URL}?{query}"


def _usable_account_name(name) -> bool:
    return (
        isinstance(name, str)
        and 0 < len(name) <= ACCOUNT_NAME_MAX
        and not any(unicodedata.category(c) in ("Cc", "Cs", "Cf", "Zl", "Zp") for c in name)
    )


def _connected_state(row) -> str:
    return "enabled" if row["opted_in"] else "connected_disabled"


def _plausible_credential(value) -> bool:
    return (
        isinstance(value, str)
        and 0 < len(value) <= TOKEN_MAX
        and all("!" <= c <= "~" for c in value)
    )


class LastfmAccounts:
    def __init__(self, state, *, client, gate, cooldown, now_ms, notices):
        self.state = state
        self.client = client
        self.gate = gate
        self.cooldown = cooldown
        self.now_ms = now_ms
        self.notices = notices
        self._lock = threading.Lock()
        self._disconnects: dict = {}  # owner -> disconnects so far
        self._completing: set = set()  # owners with a complete in flight

    def status(self, library) -> dict:
        now = self.now_ms()
        row = library.get_lastfm_connection()
        summary = library.get_lastfm_outbox_summary(now - KEPT_DAYS * DAY_MS)
        has_key = row is not None and row["session_key_enc"] is not None
        expires = row["pending_token_expires_at"] if row is not None else None
        live_token = (
            row is not None
            and row["pending_token_enc"] is not None
            and expires is not None
            and expires > now
        )
        if has_key:
            state = _connected_state(row)
        else:
            state = "awaiting_authorization" if live_token else "not_connected"
        return {
            "service": self.state.service.value,
            "state": state,
            "needs_reconnect": row["needs_reconnect"] if has_key else None,
            "account_name": row["account_name"] if has_key else None,
            "connection_id": row["connection_id"] if has_key else None,
            "approval_expires_at": expires if live_token else None,
            "counts": summary["counts"],
            "recent_problems": [
                {
                    "artist": p["artist"],
                    "track": p["track"],
                    "listened_at": p["listened_at_s"] * 1000,
                    "status": p["status"],
                    "code": p["code"],
                }
                for p in summary["recent_problems"]
            ],
            "last_success_at": summary["last_success_at"],
            "app_name": self.state.config.app_name if self.state.config is not None else None,
        }

    def _require_running(self) -> None:
        if self.state.service is LastfmService.OFF:
            raise lastfm_disabled()
        if not self.state.is_running:
            raise lastfm_stopped()

    def _send(self, call, still_valid=None):
        """Runs call() inside the gate and returns its answer; raises only when the
        gate refused, so nothing was sent. When still_valid() is false once the gate
        is entered, nothing is sent and None is returned."""
        try:
            with self.gate.enter(max_wait_s=GATE_WAIT_S) as slot:
                if still_valid is not None and not still_valid():
                    return None
                answer = call()
                slot.record(answer.answer)
        except GateStopped:
            raise lastfm_stopped() from None
        except GateBusy:
            raise lastfm_unavailable() from None
        return answer

    def connect(self, library) -> dict:
        self._require_running()
        owner = library.owner_id
        retry_after_s, undo = self.cooldown.claim(owner, "connect", CONNECT_COOLDOWN_S)
        if retry_after_s is not None:
            raise lastfm_too_soon(retry_after_s=retry_after_s)
        with self._lock:
            disconnects = self._disconnects.get(owner, 0)
        try:
            answer = self._send(self.client.get_token)
        except LastfmError:
            self.cooldown.release(owner, "connect", undo)
            raise
        if answer.answer.kind is AnswerKind.STOP:
            raise lastfm_stopped()
        if answer.answer.kind is not AnswerKind.OK or not _plausible_credential(answer.token):
            raise lastfm_unavailable()
        config = self.state.config
        now = self.now_ms()
        expires_at = now + TOKEN_LIFETIME_MS
        token_enc = encrypt(config.credential_key.get_secret_value(), answer.token)
        with self._lock:
            if self._disconnects.get(owner, 0) != disconnects:
                raise lastfm_approval_expired()
            library.store_lastfm_pending_token(token_enc, expires_at, now)
        return {
            "authorization_url": authorization_url(
                config.api_key.get_secret_value(), answer.token
            ),
            "expires_at": expires_at,
        }

    def complete(self, library) -> dict:
        self._require_running()
        owner = library.owner_id
        retry_after_s, undo = self.cooldown.claim(owner, "complete", self.gate.gap_s)
        if retry_after_s is not None:
            raise lastfm_too_soon(retry_after_s=retry_after_s)
        with self._lock:
            if owner in self._completing:
                self.cooldown.release(owner, "complete", undo)
                raise lastfm_unavailable()
            self._completing.add(owner)
        try:
            return self._complete(library, undo)
        finally:
            with self._lock:
                self._completing.discard(owner)

    def _complete(self, library, undo) -> dict:
        now = self.now_ms()
        row = library.get_lastfm_connection()
        token_enc = row["pending_token_enc"] if row is not None else None
        if token_enc is None:
            raise lastfm_approval_expired()
        if row["pending_token_expires_at"] <= now:
            library.clear_lastfm_pending_token(token_enc, now)
            raise lastfm_approval_expired()
        key = self.state.config.credential_key.get_secret_value()
        try:
            token = decrypt(key, token_enc)
        except CredentialUndecryptable:
            library.clear_lastfm_pending_token(token_enc, now)
            raise lastfm_approval_expired() from None
        def pending_token_unchanged() -> bool:
            current = library.get_lastfm_connection()
            return current is not None and current["pending_token_enc"] == token_enc

        try:
            answer = self._send(lambda: self.client.get_session(token), pending_token_unchanged)
        except LastfmError:
            self.cooldown.release(library.owner_id, "complete", undo)
            raise
        if answer is None:  # a disconnect or a newer connect during the gate wait
            raise lastfm_approval_expired()
        kind, code = answer.answer.kind, answer.answer.error_code
        if kind is AnswerKind.STOP:
            raise lastfm_stopped()
        if kind is AnswerKind.REJECTED and code == 14:
            raise lastfm_not_authorized_yet()
        if kind is AnswerKind.REJECTED and code in (15, 4):
            library.clear_lastfm_pending_token(token_enc, now)
            raise lastfm_approval_expired()
        name, session_key = answer.account_name, answer.session_key
        if kind is not AnswerKind.OK or not _usable_account_name(name) or not _plausible_credential(session_key):
            raise lastfm_unavailable()
        result = library.bind_lastfm_session(
            token_enc,
            account_name=name,
            session_key_enc=encrypt(key, session_key),
            new_connection_id=str(uuid.uuid4()),
            now=now,
        )
        if result.outcome is BindOutcome.BOUND:
            state = "connected_disabled"
        elif result.outcome is BindOutcome.REBOUND:
            # A disconnect right after the bind leaves no row: answer from the row read before.
            state = _connected_state(library.get_lastfm_connection() or row)
        elif result.outcome is BindOutcome.ACCOUNT_MISMATCH:
            raise lastfm_account_mismatch(
                stored_account=result.stored_account, approved_account=name
            )
        else:
            raise lastfm_approval_expired()
        return {"connection_id": result.connection_id, "account_name": name, "state": state}

    def enable(self, library, connection_id) -> dict:
        if self.state.service is LastfmService.OFF:
            raise lastfm_disabled()
        outcome = library.enable_lastfm_scrobbling(connection_id, self.now_ms())
        if outcome is EnableOutcome.NOT_CONNECTED:
            raise lastfm_not_connected()
        if outcome is EnableOutcome.CONNECTION_CHANGED:
            raise lastfm_connection_changed()
        if outcome is EnableOutcome.RECONNECT_REQUIRED:
            raise lastfm_reconnect_required()
        return {"connection_id": connection_id, "state": "enabled"}

    def now_playing(self, library, track_uuid) -> None:
        if self.state.service is LastfmService.OFF:
            raise lastfm_disabled()
        if not self.state.is_running:
            return
        if self.notices.attached:
            self.notices.put(library.owner_id, track_uuid)

    def disconnect(self, library) -> None:
        owner = library.owner_id
        with self._lock:
            library.disconnect_lastfm()
            self._disconnects[owner] = self._disconnects.get(owner, 0) + 1
        self.notices.drop(owner)


def build_lastfm_accounts(state) -> LastfmAccounts:
    config = state.config
    client = gate = None
    if config is not None:
        client = LastfmClient(config)
        gate = LastfmGate(state, gap_s=config.min_request_gap_s)
    return LastfmAccounts(
        state,
        client=client,
        gate=gate,
        cooldown=UserCooldown(),
        now_ms=wall_ms,
        notices=NowPlayingNotices(),
    )
