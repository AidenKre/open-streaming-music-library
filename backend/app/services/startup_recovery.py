"""SC-16e startup recovery registry.

Steps run once each, in list order, before serving: after the database,
CoverArtManager and both encoded caches exist, and before any worker starts.
Each step is idempotent. A step is non-fatal by default: its failure is logged
and later steps still run. A step marked ``fatal`` aborts startup instead.
"""

import logging
from dataclasses import dataclass
from typing import Callable, Sequence

from app.core.operator_log import operator_logger

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class StartupStep:
    name: str
    fn: Callable[[], None]
    fatal: bool = False


def run_startup_recovery(steps: Sequence[StartupStep]) -> None:
    names = [step.name for step in steps]
    if len(set(names)) != len(names):
        raise ValueError("duplicate startup recovery step name")
    for step in steps:
        try:
            step.fn()
        except Exception as exc:
            # Type name only: exception messages can carry a library path.
            level = logging.ERROR if step.fatal else logging.WARNING
            operator_logger.log(
                level, "startup recovery step %s failed: %s", step.name, type(exc).__name__
            )
            logger.debug("startup recovery step %s failed", step.name, exc_info=True)
            if step.fatal:
                raise
