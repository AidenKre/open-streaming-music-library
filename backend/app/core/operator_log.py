"""The one logger for lines an operator must see at the default log level.

App loggers have no level or handler, so their INFO lines are dropped by
default. uvicorn configures "uvicorn.error" at INFO with a handler, so the
startup lines that matter (schema upgrade, identity reconcile summary, a
missing fpcalc) go there. Never put a path, secret or token in such a line.
"""

import logging

operator_logger = logging.getLogger("uvicorn.error")
