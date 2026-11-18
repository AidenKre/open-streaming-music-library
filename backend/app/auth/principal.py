"""The request principal (spec §5.3 "What handlers see")."""

from dataclasses import dataclass

from fastapi import HTTPException, Request

from app.core.api_errors import api_error


@dataclass(frozen=True)
class Principal:
    user_id: int
    is_admin: bool
    is_master_admin: bool
    session_hash: str


_AUTH_MESSAGES = {
    "auth_required": "Authentication is required.",
    "invalid_token": "The session token is not valid.",
}


def auth_error(code: str) -> HTTPException:
    """The one 401 envelope for a missing or invalid credential."""
    return api_error(401, code, _AUTH_MESSAGES[code], retryable=False)


def current_principal(request: Request) -> Principal:
    state = request.scope.get("state") or {}
    principal = state.get("principal")
    if not isinstance(principal, Principal):
        raise auth_error("auth_required")
    return principal
