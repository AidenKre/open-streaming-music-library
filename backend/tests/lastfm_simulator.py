"""A Last.fm simulator for the deferred live gate (spec §7.14 "End to end").

Run it from ``backend/`` with made-up credentials, then point the backend's
``OSML_INSECURE_LASTFM_API_URL`` at the URL it prints::

    SIMULATOR_API_KEY=... SIMULATOR_API_SECRET=... uv run python -m tests.lastfm_simulator --port 8765

It binds loopback addresses only. Last.fm calls are ``POST /2.0/``. Control:

    POST /control/approve        token, account   approve a token for a simulated account
    POST /control/revoke         account          that account's session keys stop working (error 9)
    POST /control/fail           code and/or http_status   force the next answer to fail
    POST /control/reject-title   title            a scrobble request with this title is refused (error 6)
    GET  /control/requests       JSON list of every recorded request form
    GET  /control/scrobbles      JSON dict: account -> accepted scrobbles

Standard library plus httpx only; it has its own signature check and never imports the app's client.
"""

import argparse
import hashlib
import ipaddress
import json
import os
import re
import secrets
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qsl
from xml.sax.saxutils import escape

import httpx

_ERRORS = {3: "Invalid method", 4: "Authentication failed", 6: "Invalid parameters", 9: "Invalid session key",
           10: "Invalid API key", 13: "Invalid method signature", 14: "Unauthorized token", 15: "Token expired"}
_ROW_FIELDS = ("artist", "track", "timestamp", "album", "albumArtist", "duration")
_INDEXED = re.compile(r"^([A-Za-z]+)\[(\d+)\]$")


def _failed(code: int, status: int = 200, text: str | None = None) -> tuple[int, bytes]:
    text = text or _ERRORS.get(code, "Error")
    return status, f'<lfm status="failed"><error code="{code}">{escape(text)}</error></lfm>'.encode()


def _ok(inner: str) -> tuple[int, bytes]:
    return 200, f'<lfm status="ok">{inner}</lfm>'.encode()


class Simulator:
    def __init__(self, api_key: str, api_secret: str, *, clock=time.time):
        self._key, self._secret, self._clock = api_key, api_secret, clock
        self._lock = threading.Lock()
        self.requests: list[dict[str, str]] = []
        self.scrobbles: dict[str, list[dict[str, str]]] = {}
        self._tokens: dict[str, str | None] = {}  # token -> approving account (None until approved)
        self._sessions: dict[str, str] = {}  # session key -> account
        self._revoked: set[str] = set()
        self._forced: list[tuple[int | None, int | None]] = []
        self._rejected_titles: set[str] = set()

    # --- control -------------------------------------------------------------
    def approve(self, token: str, account: str) -> None:
        with self._lock:
            self._tokens[token] = account

    def revoke(self, account: str) -> None:
        with self._lock:
            self._revoked.add(account)

    def fail_next(self, *, code: int | None = None, http_status: int | None = None) -> None:
        with self._lock:
            self._forced.append((code, http_status))

    def reject_title(self, title: str) -> None:
        with self._lock:
            self._rejected_titles.add(title)

    def handle_control(self, method: str, path: str, body: bytes) -> tuple[int, bytes]:
        form = dict(parse_qsl(body.decode("utf-8"), keep_blank_values=True))
        try:
            if (method, path) == ("POST", "/control/approve"):
                self.approve(form["token"], form["account"])
            elif (method, path) == ("POST", "/control/revoke"):
                self.revoke(form["account"])
            elif (method, path) == ("POST", "/control/fail"):
                self.fail_next(
                    code=int(form["code"]) if form.get("code") else None,
                    http_status=int(form["http_status"]) if form.get("http_status") else None,
                )
            elif (method, path) == ("POST", "/control/reject-title"):
                self.reject_title(form["title"])
            elif (method, path) == ("GET", "/control/requests"):
                with self._lock:
                    return 200, json.dumps(self.requests).encode()
            elif (method, path) == ("GET", "/control/scrobbles"):
                with self._lock:
                    return 200, json.dumps(self.scrobbles).encode()
            else:
                return 404, b"not found"
        except (KeyError, ValueError):
            return 400, b"bad control request"
        return 200, b"ok"

    # --- the Last.fm API -----------------------------------------------------
    def _signature(self, form: dict[str, str]) -> str:
        pairs = sorted((k.encode(), v.encode()) for k, v in form.items() if k != "api_sig")
        return hashlib.md5(b"".join(k + v for k, v in pairs) + self._secret.encode()).hexdigest()  # noqa: S324

    def handle(self, form: list[tuple[str, str]]) -> tuple[int, bytes]:
        params = dict(form)
        with self._lock:
            self.requests.append(params)
            if self._forced:
                code, status = self._forced.pop(0)
                if status is not None:
                    return status, b"<html>simulated outage</html>"
                return _failed(code or 11)
            method = params.get("method")
            if method not in ("auth.getToken", "auth.getSession", "track.scrobble", "track.updateNowPlaying"):
                return _failed(3)
            if params.get("api_key") != self._key:
                return _failed(10, 403)
            if not secrets.compare_digest(params.get("api_sig", "").encode(), self._signature(params).encode()):
                return _failed(13)
            if method == "auth.getToken":
                token = secrets.token_hex(16)
                self._tokens[token] = None
                return _ok(f"<token>{token}</token>")
            if method == "auth.getSession":
                return self._get_session(params.get("token", ""))
            account = self._sessions.get(params.get("sk", ""))
            if account is None or account in self._revoked:
                return _failed(9)
            if method == "track.updateNowPlaying":
                return self._now_playing(params)
            return self._scrobble(account, params)

    def _get_session(self, token: str) -> tuple[int, bytes]:
        if token not in self._tokens:
            return _failed(15)
        account = self._tokens[token]
        if account is None:
            return _failed(14)
        del self._tokens[token]
        key = secrets.token_hex(16)
        self._sessions[key] = account
        return _ok(f"<session><name>{escape(account)}</name><key>{key}</key><subscriber>0</subscriber></session>")

    @staticmethod
    def _echo(source: dict[str, str]) -> str:
        return "".join(
            f'<{t} corrected="0">{escape(source.get(t, ""))}</{t}>' for t in ("track", "artist", "album", "albumArtist")
        )

    def _now_playing(self, params: dict[str, str]) -> tuple[int, bytes]:
        code = 1 if params.get("artist") == "Unknown Artist" else 0
        return _ok(f'<nowplaying>{self._echo(params)}<ignoredMessage code="{code}"></ignoredMessage></nowplaying>')

    def _scrobble(self, account: str, params: dict[str, str]) -> tuple[int, bytes]:
        indexed: dict[int, dict[str, str]] = {}
        for name, value in params.items():
            match = _INDEXED.match(name)
            if match and match.group(1) in _ROW_FIELDS:
                indexed.setdefault(int(match.group(2)), {})[match.group(1)] = value
        rows = [indexed[i] for i in sorted(indexed)]
        if not rows or len(rows) > 50 or any(r.get("track") in self._rejected_titles for r in rows):
            return _failed(6)
        now = self._clock()
        accepted, results = 0, []
        for row in rows:
            try:
                stamp = int(row.get("timestamp", ""))
            except ValueError:
                return _failed(6)
            if row.get("artist") == "Unknown Artist":
                code = 1
            elif stamp < now - 14 * 86400:
                code = 3
            elif stamp > now + 86400:
                code = 4
            else:
                code = 0
            if code == 0:
                accepted += 1
                self.scrobbles.setdefault(account, []).append({k: row[k] for k in _ROW_FIELDS if k in row})
            results.append(
                f'<scrobble>{self._echo(row)}<timestamp>{stamp}</timestamp>'
                f'<ignoredMessage code="{code}"></ignoredMessage></scrobble>'
            )
        return _ok(f'<scrobbles accepted="{accepted}" ignored="{len(rows) - accepted}">{"".join(results)}</scrobbles>')

    def transport(self) -> httpx.MockTransport:
        def respond(request: httpx.Request) -> httpx.Response:
            form = parse_qsl(request.content.decode("utf-8"), keep_blank_values=True)
            status, body = self.handle(form)
            return httpx.Response(status, content=body, headers={"Content-Type": "text/xml; charset=utf-8"})

        return httpx.MockTransport(respond)


def loopback_host(host: str) -> str:
    try:
        ok = ipaddress.ip_address(host).is_loopback
    except ValueError:
        ok = False
    if not ok:
        raise ValueError("the simulator binds loopback IP addresses only")
    return host


_HOST_HEADER = re.compile(r"(?:(?P<v4>[0-9.]+)|\[(?P<v6>[0-9A-Fa-f:.]+)\])(?::[0-9]{1,5})?")


def host_header_allowed(header: str | None) -> bool:
    """True only for a Host header naming a loopback IP literal (a DNS-rebinding defence)."""
    match = _HOST_HEADER.fullmatch(header or "")
    if match is None:
        return False
    try:
        return ipaddress.ip_address(match.group("v4") or match.group("v6")).is_loopback
    except ValueError:
        return False


def make_server(simulator, host: str = "127.0.0.1", port: int = 0) -> ThreadingHTTPServer:
    loopback_host(host)

    class Handler(BaseHTTPRequestHandler):
        def _serve(self, method: str) -> None:
            if not host_header_allowed(self.headers.get("Host")):
                self.send_error(403, "Host not allowed")
                return
            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(length) if length else b""
            path = self.path.split("?", 1)[0]
            if path.startswith("/control/"):
                status, reply = simulator.handle_control(method, path, body)
            elif method == "POST":
                status, reply = simulator.handle(parse_qsl(body.decode("utf-8", "replace"), keep_blank_values=True))
            else:
                status, reply = 404, b"not found"
            self.send_response(status)
            self.send_header("Content-Type", "text/xml; charset=utf-8")
            self.send_header("Content-Length", str(len(reply)))
            self.end_headers()
            self.wfile.write(reply)

        def do_POST(self) -> None:  # noqa: N802
            self._serve("POST")

        def do_GET(self) -> None:  # noqa: N802
            self._serve("GET")

        def log_message(self, *args) -> None:
            pass

    class Server(ThreadingHTTPServer):
        address_family = socket.AF_INET6 if ":" in host else socket.AF_INET
        daemon_threads = True

    return Server((host, port), Handler)


def main(argv=None) -> None:
    parser = argparse.ArgumentParser(description="Last.fm simulator for the OSML live gate")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args(argv)
    key, secret = os.environ.get("SIMULATOR_API_KEY"), os.environ.get("SIMULATOR_API_SECRET")
    if not key or not secret:
        sys.exit("set SIMULATOR_API_KEY and SIMULATOR_API_SECRET (made-up values)")
    try:
        loopback_host(args.host)
    except ValueError as exc:
        sys.exit(str(exc))
    server = make_server(Simulator(key, secret), args.host, args.port)
    host = f"[{args.host}]" if ":" in args.host else args.host
    print(f"OSML_INSECURE_LASTFM_API_URL=http://{host}:{server.server_address[1]}/2.0/", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
