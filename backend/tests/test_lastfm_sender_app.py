"""9D.2b (spec §7.8, plan D19 and 9D.1d's hand-over): startup builds the one
sender only while Last.fm is ``running``, on the holder's own gate and client
(never a second of either); shutdown stops it before the client closes, and
the instance lock is kept while it is still alive."""

import pytest
from fastapi.testclient import TestClient

from app.services import lastfm_sender
from tests.lastfm_routes import clean_env
from tests.lastfm_secrets import valid_env
from tests.lastfm_sender_rig import FakeSender, SENDER_ON
from tests.worker_app_fixtures import _lock_is_held


@pytest.fixture
def fake_sender(monkeypatch):
    clean_env(monkeypatch)
    FakeSender.instances = []
    monkeypatch.setattr(lastfm_sender, "ScrobbleSender", FakeSender)
    return FakeSender


def test_a_running_server_starts_one_sender_on_the_holders_gate_and_client(configure_app, fake_sender):
    main = configure_app(env=valid_env(LASTFM_SETTLE_DELAY_S="42", **SENDER_ON))
    with TestClient(main.app):
        [sender] = fake_sender.instances
        state = main.app.state
        assert state.lastfm_sender is sender
        assert sender.events == ["start"]
        assert sender.gate is state.lastfm_accounts.gate
        assert sender.client is state.lastfm_accounts.client
        assert sender.notices is state.lastfm_accounts.notices  # 9-R1-11: one holder, built first
        assert sender.state is state.lastfm
        assert sender.database is state.database
        assert sender.settle_delay_s == 42


@pytest.mark.parametrize(
    "env",
    [
        {},  # off by default
        valid_env(LASTFM_ENABLED="false", **SENDER_ON),
        valid_env(LASTFM_MIN_REQUEST_GAP_S="0", **SENDER_ON),  # invalid: stopped at startup
        valid_env(ENABLE_LASTFM_SENDER="false"),
    ],
    ids=["off", "switched_off", "stopped_at_startup", "sender_disabled"],
)
def test_no_sender_unless_running_and_enabled(configure_app, fake_sender, env):
    main = configure_app(env=env)
    with TestClient(main.app):
        assert fake_sender.instances == []
        assert main.app.state.lastfm_sender is None


def test_the_test_configuration_never_starts_a_real_sender(configure_app, fake_sender):
    """``valid_env()`` turns the sender off, so no app test can start a thread
    whose client would talk to the real Last.fm URL."""
    main = configure_app(env=valid_env())
    with TestClient(main.app):
        assert fake_sender.instances == []


def test_shutdown_stops_the_sender_before_the_client_closes(configure_app, fake_sender, tmp_path):
    main = configure_app(env=valid_env(**SENDER_ON))
    with TestClient(main.app):
        [sender] = fake_sender.instances

    assert sender.events == ["start", "request_stop", "join while the client is open"]
    assert sender.client._client.is_closed
    assert not _lock_is_held(tmp_path / "data")


def test_the_instance_lock_is_kept_while_the_sender_is_still_alive(configure_app, fake_sender, tmp_path):
    main = configure_app(env=valid_env(**SENDER_ON))
    with TestClient(main.app):
        [sender] = fake_sender.instances
        sender.join_ends_thread = False  # the join times out: a request is still in flight

    assert _lock_is_held(tmp_path / "data")
    sender.finish()
    assert not _lock_is_held(tmp_path / "data")


# --- failures and stragglers around the instance lock and the Last.fm client -----------------


def test_a_raising_shutdown_step_still_removes_the_history_hook(configure_app, fake_sender, tmp_path):
    from app.services import history_hooks
    from app.services.lastfm_outbox import HOOK_NAME

    main = configure_app(env=valid_env(**SENDER_ON))
    client = TestClient(main.app)
    client.__enter__()
    assert HOOK_NAME in history_hooks._hooks
    coordinator = main.app.state.encoder_coordinator

    def broken_shutdown():
        raise RuntimeError("shutdown step failed")

    coordinator.shutdown = broken_shutdown
    with pytest.raises(RuntimeError):
        client.__exit__(None, None, None)

    assert HOOK_NAME not in history_hooks._hooks
    assert not _lock_is_held(tmp_path / "data")


def test_a_second_server_that_cannot_take_the_instance_lock_opens_no_lastfm_client(
        configure_app, fake_sender, monkeypatch, tmp_path):
    from app.core.instance_lock import InstanceLockHeld, acquire_instance_lock
    from app.services import lastfm_accounts

    built = []
    real_client = lastfm_accounts.LastfmClient

    def counting_client(*args, **kwargs):
        built.append(1)
        return real_client(*args, **kwargs)

    monkeypatch.setattr(lastfm_accounts, "LastfmClient", counting_client)
    data_dir = tmp_path / "data"
    data_dir.mkdir(parents=True, exist_ok=True)
    held = acquire_instance_lock(data_dir)
    try:
        main = configure_app(env=valid_env(**SENDER_ON))
        with pytest.raises(InstanceLockHeld):
            with TestClient(main.app):
                pass
    finally:
        held.release()

    assert built == []
    assert fake_sender.instances == []


def test_r1_a_sender_outliving_the_join_keeps_the_client_open_until_it_ends(configure_app, fake_sender, tmp_path):
    main = configure_app(env=valid_env(**SENDER_ON))
    with TestClient(main.app):
        [sender] = fake_sender.instances
        sender.join_ends_thread = False  # a request is still in flight after the join bound

    assert not sender.client._client.is_closed
    sender.finish()
    assert sender.client._client.is_closed


def test_r1_a_failure_building_the_lastfm_holder_releases_the_instance_lock(
        configure_app, fake_sender, monkeypatch, tmp_path):
    from app.services import lastfm_accounts

    def broken(state):
        raise RuntimeError("cannot build")

    monkeypatch.setattr(lastfm_accounts, "build_lastfm_accounts", broken)
    main = configure_app(env=valid_env(**SENDER_ON))
    with pytest.raises(RuntimeError):
        with TestClient(main.app):
            pass

    assert not _lock_is_held(tmp_path / "data")
