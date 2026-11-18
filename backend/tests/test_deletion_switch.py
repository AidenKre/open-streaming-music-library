"""Phase 8A.1 (8-U01, spec §3, SC-18, SC-22): with ``LIBRARY_DELETE_ENABLED``
off, deletion preview and job creation answer 403 ``library_delete_disabled``
(SC-22, not retryable) before any catalog or file access and before the body
is read. Authentication still comes first (401). With the switch on, the
request passes the switch and reaches the route."""

import pytest

DELETE_ROUTES = ["/tracks/deletions/preview", "/tracks/deletions"]
# The auth middleware's own session lookup is the only database access the
# request may make before the switch answers.
AUTH_LOOKUP = {"get_live_session"}


class SpyDatabase:
    """Records every attribute of the real Database the request touches."""

    def __init__(self, real):
        self._real = real
        self.touched = []

    def __getattr__(self, name):
        self.touched.append(name)
        return getattr(self._real, name)


@pytest.fixture
def spy_database():
    """``spy_database(client)`` swaps the app's Database for a spy (after the
    client logged in) and returns the spy."""
    swapped = []

    def _install(client):
        spy = SpyDatabase(client.app.state.database)
        swapped.append((client.app.state, spy._real))
        client.app.state.database = spy
        return spy

    yield _install
    for state, real in swapped:
        state.database = real


def _assert_disabled(response):
    assert response.status_code == 403, response.text
    detail = response.json()["detail"]
    assert set(detail) == {"error", "message", "retryable"}
    assert detail["error"] == "library_delete_disabled"
    assert detail["retryable"] is False
    assert isinstance(detail["message"], str) and detail["message"]


@pytest.mark.parametrize("path", DELETE_ROUTES)
def test_switch_off_answers_403_before_any_database_access(app_client, spy_database, path):
    spy = spy_database(app_client)

    response = app_client.post(path, json={"targets": []})

    _assert_disabled(response)
    assert set(spy.touched) <= AUTH_LOOKUP, spy.touched


@pytest.mark.parametrize("path", DELETE_ROUTES)
def test_switch_off_answers_403_before_the_body_is_read(app_client, path):
    # Malformed and oversized bodies would otherwise give 422/413.
    assert app_client.post(path, content=b"{not json").status_code == 403
    _assert_disabled(app_client.post(path, content=b"x" * (2 * 1024 * 1024)))


@pytest.mark.parametrize("path", DELETE_ROUTES)
def test_authentication_still_comes_first(app_client, path):
    app_client.headers.pop("Authorization")

    response = app_client.post(path, json={"targets": []})

    assert response.status_code == 401
    assert response.json()["detail"]["error"] == "auth_required"


@pytest.mark.parametrize("path", DELETE_ROUTES)
def test_switch_on_passes_the_switch_and_reaches_the_route(open_app_client, spy_database, path):
    with open_app_client(env={"LIBRARY_DELETE_ENABLED": "true"}) as client:
        spy = spy_database(client)
        response = client.post(path, json={"targets": []})

    assert response.status_code != 403, response.text
    # The route resolves the caller's library: the spy sees access past the
    # auth lookup, so the 403 test above would see it too.
    assert "get_user" in spy.touched
