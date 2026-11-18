"""Phase M.1b (M-U12, spec §5.3 "Placement"): the real app's boundary wiring.

The auth middleware is registered outermost: it is the first user middleware
and sits directly inside Starlette's ``ServerErrorMiddleware``, so it runs
before ``ExceptionMiddleware``, routing, dependencies and any body read.
"""

from fastapi.testclient import TestClient
from starlette.middleware.errors import ServerErrorMiddleware
from starlette.middleware.exceptions import ExceptionMiddleware

from app.auth.middleware import AuthMiddleware
from tests.conftest import TEST_ADMIN_PASSWORD, TEST_ADMIN_USERNAME, log_in


def test_the_auth_middleware_is_the_outermost_user_middleware(configure_app):
    app = configure_app().app

    assert app.user_middleware[0].cls is AuthMiddleware
    assert [m.cls for m in app.user_middleware].count(AuthMiddleware) == 1


def test_the_built_stack_runs_auth_before_exception_handling(app_client):
    stack = app_client.app.middleware_stack

    assert isinstance(stack, ServerErrorMiddleware)
    assert isinstance(stack.app, AuthMiddleware)
    inner = stack.app.app
    while not isinstance(inner, ExceptionMiddleware):
        assert not isinstance(inner, AuthMiddleware)
        inner = inner.app


def test_the_real_app_refuses_a_private_route_without_a_token(configure_app):
    main = configure_app()
    with TestClient(main.app) as client:
        response = client.get("/tracks")

    assert response.status_code == 401
    assert response.json()["detail"]["error"] == "auth_required"


def test_the_shared_fixture_is_logged_in_as_the_master_admin(app_client):
    assert app_client.headers["Authorization"].startswith("Bearer ")
    assert app_client.get("/tracks").status_code == 200


def test_log_in_returns_the_login_response(app_client):
    body = log_in(app_client, TEST_ADMIN_USERNAME, TEST_ADMIN_PASSWORD)

    assert set(body) == {"token", "media_token", "server_instance_id", "user"}
    assert body["user"]["id"] == app_client.app.state.admin_user_id
