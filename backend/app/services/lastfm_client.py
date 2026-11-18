"""The Last.fm client: four signed POST calls and the reading of their answers (spec §7.8, §7.9)."""

import hashlib
import re
import time
from urllib.parse import urlencode
from collections.abc import Callable, Iterable, Mapping, Sequence
from dataclasses import dataclass, field
from enum import StrEnum

import httpx
from defusedxml import DefusedXmlException
from defusedxml import ElementTree as SafeET
from xml.etree.ElementTree import Element  # noqa: S405 - type only; parsing is via defusedxml

from app.services.lastfm_config import LastfmConfig
from app.services.lastfm_log import log_exception, log_request_failure, request_secrets
from app.version import OSML_VERSION


class AnswerKind(StrEnum):
    OK = "ok"
    TRY_LATER = "try_later"
    RECONNECT = "reconnect"
    STOP = "stop"
    REJECTED = "rejected"


@dataclass(frozen=True)
class Answer:
    kind: AnswerKind
    http_status: int | None = None
    error_code: int | None = None
    connect_failed: bool = False


@dataclass(frozen=True)
class TokenAnswer:
    answer: Answer
    token: str | None = field(default=None, repr=False)


@dataclass(frozen=True)
class SessionAnswer:
    answer: Answer
    account_name: str | None = None
    session_key: str | None = field(default=None, repr=False)


class RowStatus(StrEnum):
    SENT = "sent"
    IGNORED = "ignored"
    DROPPED = "dropped"


@dataclass(frozen=True)
class RowOutcome:
    status: RowStatus
    code: int | str | None = None


@dataclass(frozen=True)
class ScrobbleAnswer:
    answer: Answer
    rows: tuple[RowOutcome, ...] | None = None


_TIMEOUT_S = 20.0
_ROW_FIELDS = frozenset({"artist", "track", "timestamp", "album", "albumArtist", "duration"})
_NOW_PLAYING_FIELDS = frozenset({"artist", "track", "album", "albumArtist", "duration"})
_MAX_ROWS = 50
_DEADLINE_S = 20.0
_MAX_REPLY_BYTES = 1024 * 1024
_ILLEGAL_XML = re.compile("[^\t\n\r\u0020-\ud7ff\ue000-\ufffd\U00010000-\U0010ffff]")
_ENCODING_DECL = re.compile(r"^\s*<\?xml[^>]*\?>")


_NUMERIC_REFERENCE = re.compile(r"&#([^;&<\s]{0,32});")


def _legal_reference(match: re.Match[str]) -> str:
    """Keep a numeric character reference only when it names an XML 1.0 Char."""
    digits = match.group(1)
    try:
        code = int(digits[1:], 16) if digits[:1] in ("x", "X") else int(digits, 10)
    except ValueError:
        return ""
    legal = code in (0x9, 0xA, 0xD) or 0x20 <= code <= 0xD7FF or 0xE000 <= code <= 0xFFFD or 0x10000 <= code <= 0x10FFFF
    return match.group(0) if legal and digits.isascii() else ""


def _parse(body: bytes) -> Element | None:
    """Parse a reply with DTDs forbidden; on any other failure, clean it up and try once more."""
    try:
        return SafeET.fromstring(body, forbid_dtd=True)
    except DefusedXmlException:
        return None
    except Exception:  # noqa: BLE001 - nothing in a reply may raise out of the client
        pass
    try:
        text = _ILLEGAL_XML.sub("", body.decode("utf-8", errors="replace"))
        text = _NUMERIC_REFERENCE.sub(_legal_reference, _ENCODING_DECL.sub("", text, count=1))
        return SafeET.fromstring(text, forbid_dtd=True)
    except Exception:  # noqa: BLE001
        return None


def _is_text(value: str) -> bool:
    """True when the value encodes as UTF-8 (no lone surrogates)."""
    try:
        value.encode("utf-8")
    except UnicodeEncodeError:
        return False
    return True


class RowRefused(ValueError):
    """A scrobble row this client will not send."""


def check_scrobble_row(row: Mapping[str, str | int]) -> None:
    """Raises RowRefused for a row with an unknown field, no timestamp, a text field that
    is not a str of valid UTF-8, or a timestamp or duration that is not an int (a bool is not)."""
    if not set(row) <= _ROW_FIELDS:
        raise RowRefused("a scrobble row has an unknown field")
    if "timestamp" not in row:
        raise RowRefused("a scrobble row has no timestamp")
    for name, value in row.items():
        if name in ("timestamp", "duration"):
            if type(value) is not int:
                raise RowRefused("a scrobble row number is not an integer")
        elif not isinstance(value, str) or not _is_text(value):
            raise RowRefused("a scrobble row value is not valid text")


def _local(tag: object) -> str:
    return tag.rsplit("}", 1)[-1].lower() if isinstance(tag, str) else ""


def _child(parent: Element, name: str) -> Element | None:
    return next((c for c in parent if _local(c.tag) == name), None)


def _child_text(parent: Element, name: str) -> str | None:
    child = _child(parent, name)
    text = (child.text or "").strip() if child is not None else ""
    return text or None


def _status(root: Element) -> str | None:
    for name, value in root.attrib.items():
        if name.lower() == "status":
            return value.strip().lower()
    return None


def _error_code(root: Element) -> int | None:
    error = _child(root, "error")
    return _int_attr(error, "code") if error is not None else None


def _kind_for_code(code: int) -> AnswerKind:
    if code in (8, 11, 16, 29):
        return AnswerKind.TRY_LATER
    if code == 9:
        return AnswerKind.RECONNECT
    if code in (10, 26):
        return AnswerKind.STOP
    return AnswerKind.REJECTED


def _as_int(value: object) -> int | None:
    try:
        return int(str(value).strip())
    except ValueError:
        return None


def _int_attr(element: Element, name: str) -> int | None:
    for key, value in element.attrib.items():
        if key.lower() == name:
            try:
                return int(value.strip())
            except ValueError:
                return None
    return None


def _row_outcomes(root: Element, rows: Sequence[Mapping[str, str | int]]) -> tuple[RowOutcome, ...] | None:
    """Per-row outcomes of an ok scrobble reply (spec §7.9); None when the totals cannot be read."""
    scrobbles = _child(root, "scrobbles")
    if scrobbles is None:
        return None
    accepted = _int_attr(scrobbles, "accepted")
    ignored = _int_attr(scrobbles, "ignored")
    if accepted is None or ignored is None:
        return None
    if accepted == len(rows) and ignored == 0:
        return tuple(RowOutcome(RowStatus.SENT) for _ in rows)
    sent_timestamps = [_as_int(row["timestamp"]) for row in rows]
    outcomes: list[RowOutcome | None] = [None] * len(rows)
    for result in scrobbles:
        if _local(result.tag) != "scrobble":
            continue
        text = _child_text(result, "timestamp")
        timestamp = _as_int(text)
        index = next((i for i, t in enumerate(sent_timestamps) if t == timestamp and outcomes[i] is None), None)
        if timestamp is None or index is None:
            continue
        message = _child(result, "ignoredmessage")
        code = _int_attr(message, "code") if message is not None else 0
        outcomes[index] = RowOutcome(RowStatus.SENT) if code == 0 else RowOutcome(RowStatus.IGNORED, code)
    return tuple(o if o is not None else RowOutcome(RowStatus.DROPPED, "no_answer") for o in outcomes)


def sign(params: Mapping[str, str], secret: str) -> str:
    """MD5 over name+value pairs sorted by UTF-8 byte order, then the secret (spec §7.8)."""
    pairs = sorted(
        ((name.encode("utf-8"), str(value).encode("utf-8")) for name, value in params.items() if name != "api_sig"),
        key=lambda pair: pair[0],
    )
    data = b"".join(name + value for name, value in pairs) + secret.encode("utf-8")
    return hashlib.md5(data).hexdigest()  # noqa: S324 - the Last.fm protocol requires MD5


class LastfmClient:
    def __init__(
        self,
        config: LastfmConfig,
        *,
        transport: httpx.BaseTransport | None = None,
        clock: Callable[[], float] = time.monotonic,
    ):
        self._config = config
        self._url = config.api_url
        self._api_key = config.api_key.get_secret_value()
        self._secret = config.api_secret.get_secret_value()
        self._clock = clock
        self._client = httpx.Client(
            transport=transport if transport is not None else httpx.HTTPTransport(verify=True, retries=0),
            follow_redirects=False,
            trust_env=False,
            timeout=_TIMEOUT_S,
        )

    def _call[T](self, params: dict[str, str], read: Callable[[Element], T | None]) -> tuple[Answer, T | None]:
        """Send one request and classify the answer (spec §7.9).

        ``read`` extracts the call's content from an ok reply; the value is None for any non-ok answer.
        Every non-ok answer is logged once, through the redaction helper.
        """
        method = params["method"]
        if not all(_is_text(name) and _is_text(value) for name, value in params.items()):
            raise ValueError("a request value is not valid text")
        body = dict(params)
        body["api_key"] = self._api_key
        body["api_sig"] = sign(body, self._secret)
        try:
            status, reply = self._post(body)
        except httpx.HTTPError as exc:
            log_exception(method, exc)
            return Answer(AnswerKind.TRY_LATER, connect_failed=isinstance(exc, (httpx.ConnectError, httpx.ConnectTimeout))), None

        def fail(answer: Answer) -> tuple[Answer, None]:
            log_request_failure(
                method,
                status=status,
                error_code=answer.error_code,
                reply=reply,
                secrets=request_secrets(self._config, body),
            )
            return answer, None

        later = Answer(AnswerKind.TRY_LATER, http_status=status)
        if status == 429 or status >= 500 or 300 <= status < 400:
            return fail(later)
        root = _parse(reply) if reply is not None else None
        if root is None or _local(root.tag) != "lfm":
            return fail(later)
        outcome = _status(root)
        if outcome == "ok" and 200 <= status < 300:
            value = read(root)
            if value is None:
                return fail(later)
            return Answer(AnswerKind.OK, http_status=status), value
        if outcome == "failed":
            code = _error_code(root)
            if code is not None:
                return fail(Answer(_kind_for_code(code), http_status=status, error_code=code))
        return fail(later)

    def _post(self, body: dict[str, str]) -> tuple[int, bytes | None]:
        """POST once; the body is None when the reply was abandoned (deadline, size cap or compression)."""
        start = self._clock()
        headers = {
            "User-Agent": f"OSML/{OSML_VERSION}",
            "Accept-Encoding": "identity",
            "Content-Type": "application/x-www-form-urlencoded; charset=utf-8",
        }
        with self._client.stream(
            "POST", self._url, content=urlencode(body, encoding="utf-8").encode("ascii"), headers=headers
        ) as response:
            status = response.status_code
            if self._clock() - start > _DEADLINE_S:
                return status, None
            if response.headers.get("content-encoding", "identity").strip().lower() not in ("", "identity"):
                return status, None
            declared = response.headers.get("content-length", "").strip()
            if re.fullmatch(r"[0-9]{1,12}", declared) and int(declared) > _MAX_REPLY_BYTES:
                return status, None
            chunks: list[bytes] = []
            total = 0
            try:
                chunk_source: Iterable[bytes] = (response.content,)  # already in memory (in-process transports)
            except httpx.ResponseNotRead:
                chunk_source = response.iter_raw()  # never iter_bytes: it would decompress
            for chunk in chunk_source:
                total += len(chunk)
                if total > _MAX_REPLY_BYTES or self._clock() - start > _DEADLINE_S:
                    return status, None
                chunks.append(chunk)
            if self._clock() - start > _DEADLINE_S:
                return status, None
            return status, b"".join(chunks)

    def get_token(self) -> TokenAnswer:
        answer, token = self._call({"method": "auth.getToken"}, lambda root: _child_text(root, "token"))
        return TokenAnswer(answer, token)

    def get_session(self, token: str) -> SessionAnswer:
        def read(root: Element) -> tuple[str, str] | None:
            session = _child(root, "session")
            name = _child_text(session, "name") if session is not None else None
            key = _child_text(session, "key") if session is not None else None
            return (name, key) if name is not None and key is not None else None

        answer, pair = self._call({"method": "auth.getSession", "token": token}, read)
        return SessionAnswer(answer, *pair) if pair is not None else SessionAnswer(answer)

    def scrobble(self, session_key: str, rows: Sequence[Mapping[str, str | int]]) -> ScrobbleAnswer:
        if not 1 <= len(rows) <= _MAX_ROWS:
            raise ValueError("a scrobble batch holds 1 to 50 rows")
        params = {"method": "track.scrobble", "sk": session_key}
        for i, row in enumerate(rows):
            check_scrobble_row(row)
            for name, value in row.items():
                params[f"{name}[{i}]"] = str(value)
        answer, outcomes = self._call(params, lambda root: _row_outcomes(root, rows))
        return ScrobbleAnswer(answer, outcomes)

    def update_now_playing(self, session_key: str, track: Mapping[str, str | int]) -> Answer:
        if not set(track) <= _NOW_PLAYING_FIELDS:
            raise ValueError("now-playing track has an unknown field")
        params = {"method": "track.updateNowPlaying", "sk": session_key}
        params.update({name: str(value) for name, value in track.items()})
        answer, _ = self._call(params, lambda root: root)
        return answer

    def close(self) -> None:
        self._client.close()
