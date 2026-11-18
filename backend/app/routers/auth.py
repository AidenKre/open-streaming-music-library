from fastapi import APIRouter, Depends, Request, Response
from pydantic import ValidationError

from app.auth import accounts
from app.auth.principal import Principal, auth_error, current_principal
from app.auth.passwords import AuthBusy, WeakPassword
from app.auth.sessions import revoke_session_hash
from app.auth.signup_policy import SignupDisabled, UserLimitReached
from app.core.api_errors import api_error
from app.core.bounded_body import bounded_body, validation_error_422
from app.database.database import UsernameTaken
from app.services.import_folders import prepare_signup_import_folder
from app.models.auth import AuthResponse, AuthUser, Credentials, MeResponse

router = APIRouter(prefix="/auth")

# exception -> (status, code, message, retryable); messages are fixed text.
_REFUSALS = {
    accounts.InvalidUsername: (422, "invalid_username", "That username is not allowed.", False),
    WeakPassword: (422, "weak_password", "The password must be 8-1024 characters.", False),
    UsernameTaken: (409, "username_taken", "That username is already taken.", False),
    SignupDisabled: (403, "signup_disabled", "Signup is disabled.", False),
    UserLimitReached: (403, "user_limit_reached", "The user limit has been reached.", False),
    accounts.InvalidCredentials: (401, "invalid_credentials", "Wrong username or password.", False),
    AuthBusy: (503, "auth_busy", "The server is busy. Try again shortly.", True),
}


def _refusal(exc: Exception):
    status, code, message, retryable = next(
        refusal for kind, refusal in _REFUSALS.items() if isinstance(exc, kind)
    )
    return api_error(status, code, message, retryable=retryable)


def _credentials(raw: bytes) -> Credentials:
    try:
        return Credentials.model_validate_json(raw)
    except ValidationError as exc:
        raise validation_error_422(exc) from None


def _auth_user(user) -> AuthUser:
    return AuthUser(
        id=user.id,
        username=user.username,
        is_admin=user.is_admin,
        is_master_admin=user.is_master_admin,
    )


def _auth_response(database, result: accounts.AuthResult) -> AuthResponse:
    return AuthResponse(
        token=result.tokens.token,
        media_token=result.tokens.media_token,
        server_instance_id=database.get_server_instance_id(),
        user=_auth_user(result.user),
    )


def _run(database, settings, raw: bytes, action, after=None) -> AuthResponse:
    credentials = _credentials(raw)
    try:
        result = action(database, settings, credentials.username, credentials.password)
    except tuple(_REFUSALS) as exc:
        raise _refusal(exc) from None
    if after is not None:
        after(result)
    return _auth_response(database, result)


@router.post("/register", status_code=201, response_model=AuthResponse)
def register(request: Request, raw: bytes = Depends(bounded_body(16 * 1024))):
    database = request.app.state.database
    state = request.app.state

    def prepare_import_folder(result: accounts.AuthResult) -> None:
        prepare_signup_import_folder(
            state.settings.user_import_dir,
            result.folder_choice,
            state.user_file_watcher,
        )

    return _run(
        database, state.settings, raw, accounts.register, prepare_import_folder
    )


@router.post("/login", response_model=AuthResponse)
def login(request: Request, raw: bytes = Depends(bounded_body(16 * 1024))):
    database = request.app.state.database
    return _run(database, request.app.state.settings, raw, accounts.login)


@router.post("/logout", status_code=204)
def logout(request: Request, principal: Principal = Depends(current_principal)):
    revoke_session_hash(request.app.state.database, principal.session_hash)
    return Response(status_code=204)


@router.get("/me", response_model=MeResponse)
def me(request: Request, principal: Principal = Depends(current_principal)):
    database = request.app.state.database
    row = database.get_user(principal.user_id)
    if row is None:
        raise auth_error("auth_required")
    return MeResponse(
        user=_auth_user(accounts.account_user(row)),
        server_instance_id=database.get_server_instance_id(),
    )
