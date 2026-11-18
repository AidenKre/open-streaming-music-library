"""Keep media tokens out of uvicorn's access log (spec §5.3 "Access log")."""

import logging
import re
from urllib.parse import unquote

# A query parameter (after one or more "?" or "&") whose key we check; its
# value runs to the next "&" or whitespace.
_PARAM = re.compile(r"([?&]+)([^=&\s]*)=([^&\s]*)")


def _redact_param(match: re.Match) -> str:
    separator, key, _value = match.groups()
    if unquote(key).casefold() == "access_token":
        return f"{separator}{key}=[redacted]"
    return match.group(0)


def redact_access_token(text: str) -> str:
    return _PARAM.sub(_redact_param, text)


class AccessTokenRedactor(logging.Filter):
    def filter(self, record: logging.LogRecord) -> bool:
        if isinstance(record.msg, str):
            record.msg = redact_access_token(record.msg)
        if isinstance(record.args, tuple):
            record.args = tuple(
                redact_access_token(arg) if isinstance(arg, str) else arg
                for arg in record.args
            )
        elif isinstance(record.args, dict):
            record.args = {
                key: redact_access_token(arg) if isinstance(arg, str) else arg
                for key, arg in record.args.items()
            }
        return True


def install_access_log_redaction() -> None:
    logger = logging.getLogger("uvicorn.access")
    if not any(type(f).__name__ == "AccessTokenRedactor" for f in logger.filters):
        logger.addFilter(AccessTokenRedactor())
