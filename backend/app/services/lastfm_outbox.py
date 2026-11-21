"""The ``lastfm_scrobble_outbox`` history subscriber (spec §7.7, SC-23).

Runs inside the history write transaction, so it uses only the connection it is given.
"""

import math

from app.core.operator_log import operator_logger
from app.database.database import Database
from app.services.history_hooks import register_history_hook, unregister_history_hook
from app.services.lastfm_rules import lastfm_track_fields, long_enough_to_scrobble
from app.services.lastfm_state import LastfmService, wall_ms

HOOK_NAME = "lastfm_scrobble_outbox"
MAX_FUTURE_MS = 86_400_000


class ScrobbleOutbox:
    def __init__(self, now_ms):
        self.now_ms = now_ms

    def __call__(self, conn, new_events) -> None:
        # Never raises: a raise would roll back the whole batch's rows (spec §7.7).
        for event in new_events:
            event_uuid = event.get("event_uuid")
            try:
                self._queue_one(conn, event)
            except Exception as exc:
                operator_logger.error(
                    "Last.fm: could not queue the listen %s (%s)",
                    event_uuid,
                    type(exc).__name__,
                )

    def _queue_one(self, conn, event) -> None:
        owner = event["owner_id"]
        if not Database._lastfm_scrobbling_on_in(conn, owner_id=owner):
            return
        if event["kind"] != "play" or event["entity_type"] != "track":
            return
        now = self.now_ms()
        if event["occurred_at"] - now > MAX_FUTURE_MS:
            return
        if not long_enough_to_scrobble(event["seconds_played"], event["track_length"]):
            return
        fields = Database._lastfm_track_fields_in(
            conn, event["entity_ref"], owner_id=owner
        )
        if fields is None:
            return
        sendable = lastfm_track_fields(fields)
        if sendable is None:
            return
        payload = {
            "artist": sendable["artist"],
            "track": sendable["track"],
            "timestamp": event["occurred_at"] // 1000,
        }
        for key in ("album", "albumArtist"):
            if key in sendable:
                payload[key] = sendable[key]
        if event["track_length"] is not None:
            payload["duration"] = math.ceil(event["track_length"])
        Database._queue_scrobble_in(
            conn,
            owner_id=owner,
            event_uuid=event["event_uuid"],
            payload=payload,
            listened_at_s=event["occurred_at"] // 1000,
            now=now,
        )


def uninstall_scrobble_outbox() -> None:
    try:
        unregister_history_hook(HOOK_NAME)
    except KeyError:
        pass


def install_scrobble_outbox(state, *, now_ms=wall_ms) -> None:
    """Register the subscriber when ``state.service`` is not ``off``; remove it otherwise."""
    if state.service is LastfmService.OFF:
        uninstall_scrobble_outbox()
    else:
        register_history_hook(HOOK_NAME, ScrobbleOutbox(now_ms))
