"""SC-16d: every server start gets its own boot id (Phase 7A.1b, review case
7-U02). Leases written by an earlier process carry another boot id and so
read as dead. The id is not a secret, but it identifies this process's leases
only and is never written to a log line."""

import logging
import uuid

from fastapi.testclient import TestClient


def test_each_start_gets_a_fresh_random_boot_id(configure_app):
    main = configure_app()
    with TestClient(main.app):
        first = main.app.state.boot_id
    with TestClient(main.app):
        second = main.app.state.boot_id

    assert isinstance(first, str) and isinstance(second, str)
    assert uuid.UUID(first).version == 4
    assert uuid.UUID(second).version == 4
    assert first != second


def test_the_boot_id_exists_before_the_recovery_steps_run(configure_app, monkeypatch):
    main = configure_app()
    seen = []
    real = main.reconcile_journal

    def journal(*args, **kwargs):
        seen.append(getattr(main.app.state, "boot_id", None))
        return real(*args, **kwargs)

    monkeypatch.setattr(main, "reconcile_journal", journal)

    with TestClient(main.app):
        boot_id = main.app.state.boot_id

    assert seen == [boot_id]


def test_the_boot_id_is_never_logged_or_printed(configure_app, caplog, capsys):
    main = configure_app()
    with caplog.at_level(logging.DEBUG):
        with TestClient(main.app) as client:
            boot_id = main.app.state.boot_id
            client.get("/")

    assert boot_id
    assert not [r for r in caplog.records if boot_id in r.getMessage()]
    printed = capsys.readouterr()
    assert boot_id not in printed.out and boot_id not in printed.err
