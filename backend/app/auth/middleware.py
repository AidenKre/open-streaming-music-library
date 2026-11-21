"""The auth boundary (spec §5.3): a pure ASGI middleware, registered outermost."""

from urllib.parse import parse_qs

from starlette.responses import JSONResponse, PlainTextResponse
from starlette.routing import Match
from starlette.types import Scope

from app.auth.principal import Principal, auth_error
from app.auth.sessions import (
    LiveSession,
    lookup_media_session,
    lookup_session,
)

MEDIA_ROUTE_NAMES = frozenset({"stream_track", "preview_upload_item"})
INSTANCE_HEADER = b"x-server-instance-id"
PUBLIC_PATHS = frozenset({"/", "/app/info", "/auth/login", "/auth/register"})


def get_route_path(scope: Scope) -> str:
    # Mirrors Starlette's get_route_path so path matching is identical to the router's.
    path: str = scope["path"]
    root_path = scope.get("root_path", "")
    if not root_path:
        return path
    if not path.startswith(root_path):
        return path
    if path == root_path:
        return ""
    if path[len(root_path)] == "/":
        return path[len(root_path) :]
    return path


def _bearer_token(header: str) -> str | None:
    scheme, space, token = header.partition(" ")
    if scheme.lower() != "bearer" or not space or not token:
        return None
    return token


def _is_media_request(scope) -> bool:
    if scope["type"] != "http" or scope["method"] != "GET":
        return False
    # The router serves the first fully matching route; only that one counts.
    for route in scope["app"].router.routes:
        if route.matches(scope)[0] == Match.FULL:
            return getattr(route, "name", None) in MEDIA_ROUTE_NAMES
    return False


def _media_token(scope) -> str | None:
    query = parse_qs(scope["query_string"].decode("latin-1"), keep_blank_values=True)
    values = query.get("access_token")
    return values[0] if values else None


async def _authenticate(scope) -> tuple[LiveSession | None, str | None]:
    """Return (session, None) or (None, error_code) for the request."""
    database = scope["app"].state.database
    for name, value in scope["headers"]:
        if name == b"authorization":
            token = _bearer_token(value.decode("latin-1"))
            if token is None:
                return None, "invalid_token"
            session = await lookup_session(database, token)
            return session, (None if session else "invalid_token")
    if _is_media_request(scope):
        media_token = _media_token(scope)
        if media_token is not None:
            session = await lookup_media_session(database, media_token)
            return session, (None if session else "invalid_token")
    return None, "auth_required"


async def _reject(code, scope, receive, send):
    if scope["type"] == "websocket":
        await send({"type": "websocket.close", "code": 1008})
        return
    exc = auth_error(code)
    response = JSONResponse(
        {"detail": exc.detail},
        status_code=exc.status_code,
        headers={"WWW-Authenticate": "Bearer"},
    )
    await response(scope, receive, send)


class AuthMiddleware:
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] not in ("http", "websocket"):
            await self.app(scope, receive, send)
            return
        if scope["type"] == "http":
            await self._call_stamped(scope, receive, send)
            return
        await self._dispatch(scope, receive, send)

    async def _call_stamped(self, scope, receive, send):
        """Stamp the server instance id on every HTTP response (SC-01 rule 6)."""
        instance_id = getattr(scope["app"].state, "server_instance_id", None)
        started = False

        async def stamped_send(message):
            nonlocal started
            if message["type"] == "http.response.start":
                started = True
                if instance_id is not None:
                    headers = list(message.get("headers", []))
                    headers.append((INSTANCE_HEADER, instance_id.encode("latin-1")))
                    message = {**message, "headers": headers}
            await send(message)

        try:
            await self._dispatch(scope, receive, stamped_send)
        except Exception:
            # ServerErrorMiddleware sits outside this one; answer as it would,
            # but stamped, then re-raise so the error still reaches the server.
            if not started:
                await PlainTextResponse("Internal Server Error", status_code=500)(
                    scope, receive, stamped_send
                )
            raise

    async def _dispatch(self, scope, receive, send):
        if get_route_path(scope) in PUBLIC_PATHS:
            await self.app(scope, receive, send)
            return

        session, error = await _authenticate(scope)
        if error is not None:
            await _reject(error, scope, receive, send)
            return

        principal = Principal(
            user_id=session.user_id,
            is_admin=session.is_admin,
            is_master_admin=session.is_master_admin,
            session_hash=session.session_hash,
        )
        scope = {
            **scope,
            "state": {
                **scope.get("state", {}),
                "principal": principal,
                "library_folder": session.library_folder,
            },
        }
        await self.app(scope, receive, send)
