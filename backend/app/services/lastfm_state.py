"""The Last.fm server state: ``off``, ``running`` or ``stopped``, held in memory."""

import threading
import time
from enum import StrEnum

from app.core.operator_log import operator_logger
from app.services.lastfm_config import (
    LastfmConfig,
    LastfmInvalid,
    LastfmOff,
    resolve_lastfm_config,
)


def wall_ms() -> int:
    return time.time_ns() // 1_000_000


class LastfmService(StrEnum):
    OFF = "off"
    RUNNING = "running"
    STOPPED = "stopped"


class LastfmState:
    def __init__(self, service: LastfmService, config: LastfmConfig | None):
        self._service = service
        self._config = config
        self._lock = threading.Lock()

    @property
    def service(self) -> LastfmService:
        return self._service

    @property
    def config(self) -> LastfmConfig | None:
        return self._config

    @property
    def is_running(self) -> bool:
        return self._service is LastfmService.RUNNING

    def stop(self, cause: str) -> bool:
        """Move running to stopped and log the cause once at ERROR; True if it moved.

        The cause is a fixed text: it must never contain a secret, a URL or
        Last.fm reply text.
        """
        with self._lock:
            if self._service is not LastfmService.RUNNING:
                return False
            self._service = LastfmService.STOPPED
        operator_logger.error("Last.fm scrobbling is stopped: %s", cause)
        return True

    def __repr__(self) -> str:
        return f"LastfmState({self._service.value})"


def start_lastfm(settings) -> LastfmState:
    result = resolve_lastfm_config(settings)
    if isinstance(result, LastfmOff):
        if result.switch_unparseable:
            operator_logger.error(
                "LASTFM_ENABLED is not true or false; Last.fm scrobbling is off"
            )
        return LastfmState(LastfmService.OFF, None)
    if isinstance(result, LastfmInvalid):
        operator_logger.error(
            "Last.fm scrobbling is stopped: %s %s", result.setting, result.problem
        )
        return LastfmState(LastfmService.STOPPED, None)
    if result.insecure_api_url:
        operator_logger.warning(
            "OSML_INSECURE_LASTFM_API_URL is set: Last.fm requests go to a test "
            "simulator, not to Last.fm"
        )
    if result.app_name_ignored:
        operator_logger.warning(
            "LASTFM_APP_NAME is invalid (more than 100 characters, or a control, "
            "format or line/paragraph separator character) and is ignored; the "
            "consent screen does not name the application"
        )
    return LastfmState(LastfmService.RUNNING, result)
