"""U01-B-04: an app started by ``configure_app`` never reads a ``.env`` from the
directory the tests happen to run in.

``app.config.Settings`` reads ``.env`` relative to the working directory, and a
developer checkout may hold a real ``backend/.env`` (including external
account settings that no test may ever use). The guard plants a ``.env`` in a
temporary stand-in for such a checkout, makes it the working directory, and
starts an app through the shared fixture: no value from that file may reach
the app's settings.
"""

import pytest

UPLOAD_JANITOR_INTERVAL_DEFAULT_S = 3600


def test_a_dotenv_in_the_working_directory_never_reaches_a_test_app(
    configure_app, tmp_path_factory, monkeypatch
):
    checkout = tmp_path_factory.mktemp("developer-checkout")
    (checkout / ".env").write_text("UPLOAD_JANITOR_INTERVAL_S=7\n", encoding="utf-8")
    monkeypatch.chdir(checkout)

    main = configure_app()

    assert main.settings.upload_janitor_interval_s == UPLOAD_JANITOR_INTERVAL_DEFAULT_S


def test_lastfm_settings_in_a_dotenv_never_reach_a_test_app(
    open_app_client, tmp_path_factory, monkeypatch
):
    """The external-account case: a checkout's `.env` with a complete enabled
    Last.fm configuration must leave a test app with Last.fm off, and no
    request may leave through a real transport."""
    import httpx

    from app.services.lastfm_accounts import lastfm_available
    from app.services.lastfm_state import LastfmService
    from tests.lastfm_secrets import LASTFM_ENV, valid_env

    for name in (*LASTFM_ENV, "OSML_INSECURE_LASTFM_API_URL"):
        monkeypatch.delenv(name, raising=False)  # the planted file is the only source
    planted = {**valid_env(), "OSML_INSECURE_LASTFM_API_URL": "http://127.0.0.1:9/"}
    checkout = tmp_path_factory.mktemp("developer-checkout")
    (checkout / ".env").write_text(
        "".join(f"{name}={value}\n" for name, value in planted.items()), encoding="utf-8"
    )
    monkeypatch.chdir(checkout)
    sent = []

    def _no_real_network(self, request):
        sent.append(request)
        raise AssertionError(f"a test app sent a real request to {request.url}")

    monkeypatch.setattr(httpx.HTTPTransport, "handle_request", _no_real_network)

    with open_app_client() as client:
        main_settings = client.app.state.settings
        assert main_settings.lastfm_enabled is None
        assert main_settings.osml_insecure_lastfm_api_url is None
        assert client.app.state.lastfm.service is LastfmService.OFF
        assert lastfm_available(client.app.state.lastfm) is False

    assert sent == []


def test_lastfm_variables_in_the_process_environment_never_reach_a_test_app(
    open_app_client, tmp_path, monkeypatch
):
    """The other route: a shell with a complete Last.fm configuration exported.
    An app started without Last.fm in ``env=`` has Last.fm off, starts no
    sender thread, and no request leaves through a real transport."""
    import threading

    import httpx

    from app.services.lastfm_accounts import lastfm_available
    from app.services.lastfm_state import LastfmService
    from tests.lastfm_secrets import valid_env

    exported = {**valid_env(), "OSML_INSECURE_LASTFM_API_URL": "http://127.0.0.1:9/"}
    for name, value in exported.items():
        monkeypatch.setenv(name, value)
    sent = []

    def _no_real_network(self, request):
        sent.append(request)
        raise AssertionError(f"a test app sent a real request to {request.url}")

    monkeypatch.setattr(httpx.HTTPTransport, "handle_request", _no_real_network)

    with open_app_client() as client:
        state = client.app.state
        assert state.lastfm.service is LastfmService.OFF
        assert lastfm_available(state.lastfm) is False
        assert state.lastfm_sender is None
        assert not any(t.name == "lastfm-sender" for t in threading.enumerate())

    assert sent == []


# --- 9-fix-r1 (9-R1-02): no test can reach a real host through httpx -------------------


def _no_socket_may_open(monkeypatch):
    """Records and refuses every socket open and name lookup, so a request that
    gets past the guard is seen here and still never leaves the machine."""
    import socket

    opened = []

    def refuse(*args, **kwargs):
        opened.append(args[0] if args else None)
        raise OSError("test: no socket may be opened")

    monkeypatch.setattr(socket, "create_connection", refuse)
    monkeypatch.setattr(socket, "getaddrinfo", refuse)
    return opened


def test_r1_a_lastfm_client_on_the_default_transport_is_refused_before_any_socket(monkeypatch):
    from app.services.lastfm_client import LastfmClient
    from tests import conftest
    from tests.lastfm_fake import make_config

    opened = _no_socket_may_open(monkeypatch)
    client = LastfmClient(make_config())  # no fake transport: the real default one
    raised = None
    try:
        client.get_token()
    except Exception as exc:  # noqa: BLE001 - the guard's own error is checked below
        raised = exc
    finally:
        client.close()

    assert opened == []
    assert isinstance(raised, conftest.RealNetworkRefused)
    assert conftest.take_refused_hosts() == ["ws.audioscrobbler.com"]


def test_r1_a_valid_env_app_that_forgot_its_fake_cannot_reach_lastfm(open_app_client, monkeypatch):
    """The scenario of the finding: a route test that forgets ``install()``."""
    from app.services.lastfm_gate import LastfmGate
    from tests import conftest
    from tests.lastfm_fake import FakeClock
    from tests.lastfm_secrets import LASTFM_ENV, valid_env

    for name in LASTFM_ENV:
        monkeypatch.delenv(name, raising=False)
    opened = _no_socket_may_open(monkeypatch)
    with open_app_client(env=valid_env()) as client:
        # Only the gate's clock is faked (the product default gap stays 5 s): the
        # client keeps its real default transport, which is what is under test.
        accounts = client.app.state.lastfm_accounts
        gate_clock = FakeClock()
        accounts.gate = LastfmGate(
            accounts.state,
            gap_s=accounts.state.config.min_request_gap_s,
            clock=gate_clock,
            wait=gate_clock.wait,
        )
        try:
            client.post("/settings/integrations/lastfm/connect", json={})
        except Exception as exc:  # noqa: BLE001 - TestClient re-raises the app's error
            assert isinstance(exc, conftest.RealNetworkRefused)

    assert opened == []
    assert conftest.take_refused_hosts() == ["ws.audioscrobbler.com"]


def test_r1_a_refused_attempt_fails_the_test_even_when_the_code_swallowed_it(monkeypatch):
    """The sender catches every exception per user; the guard's record makes the
    test fail at teardown anyway, and checking consumes the record."""
    import httpx
    import pytest

    from tests import conftest

    _no_socket_may_open(monkeypatch)
    with httpx.Client(transport=httpx.HTTPTransport()) as http:
        try:
            http.get("https://example.invalid/swallowed")
        except Exception:  # noqa: BLE001 - swallowed on purpose, like a worker would
            pass

    with pytest.raises(pytest.fail.Exception, match="example.invalid"):
        conftest.check_no_refused_network()
    conftest.check_no_refused_network()  # consumed: a second check passes


def test_r1_loopback_requests_are_left_to_the_test(monkeypatch):
    """The loopback simulator is the deferred live gate's; the guard only refuses
    hosts off this machine, so a loopback attempt reaches the socket layer."""
    import httpx

    from tests import conftest

    opened = _no_socket_may_open(monkeypatch)
    with httpx.Client(transport=httpx.HTTPTransport()) as http:
        try:
            http.get("http://127.0.0.1:9/")
        except httpx.HTTPError:
            pass

    assert opened != []
    assert conftest.take_refused_hosts() == []


# --- 9-fix-r1 (9-R1-03): importing the suite never reads a launch-directory .env -------


@pytest.mark.integration
def test_r1_the_suites_first_settings_never_read_a_dotenv_in_the_launch_directory(tmp_path):
    """Runs the conftest's import-time code in a child process launched from a
    directory holding a ``.env``, as pytest does from a developer's ``backend/``."""
    import os
    import subprocess
    import sys
    from pathlib import Path

    launch = tmp_path / "developer-backend"
    launch.mkdir()
    (launch / ".env").write_text(
        "UPLOAD_JANITOR_INTERVAL_S=7\nLASTFM_API_KEY=planted-dotenv-sentinel\n", encoding="utf-8"
    )
    backend = Path(__file__).resolve().parents[1]
    env = {
        name: value
        for name, value in os.environ.items()
        if not name.startswith(("LASTFM_", "OSML_INSECURE_LASTFM_", "UPLOAD_", "PYTHON"))
    }
    env["PYTHONPATH"] = str(backend)
    code = (
        "import tests.conftest\n"
        "import app.config\n"
        "s = app.config.settings\n"
        "print(s.upload_janitor_interval_s, s.lastfm_api_key is None)\n"
    )

    done = subprocess.run(
        [sys.executable, "-c", code], cwd=launch, env=env, capture_output=True, text=True, timeout=120
    )

    assert done.returncode == 0, done.stderr[-2000:]
    assert done.stdout.split()[-2:] == [str(UPLOAD_JANITOR_INTERVAL_DEFAULT_S), "True"]
