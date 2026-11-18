"""Other-issues row 36 (U02-B-09): ``OSML_INSECURE_FAST_PASSWORD_HASHING`` makes
the server hash passwords with cheap, test-only argon2 settings. When it is on,
start-up says so once, as a warning in the operator log (the logger uvicorn
shows at its default level); when it is off, nothing is said about it.

The sentence itself is a proposal to the owner, so these tests pin only the
level, the logger, the count and that the line names the setting."""

import logging

from fastapi.testclient import TestClient

OPERATOR = "uvicorn.error"
SETTING = "OSML_INSECURE_FAST_PASSWORD_HASHING"


def _naming_the_setting(caplog):
    return [r for r in caplog.records if SETTING in r.getMessage()]


def test_the_setting_on_gives_exactly_one_operator_warning(configure_app, caplog):
    main = configure_app(env={SETTING: "true"})

    with caplog.at_level(logging.DEBUG):
        with TestClient(main.app):
            pass

    lines = _naming_the_setting(caplog)
    assert [(r.name, r.levelno) for r in lines] == [(OPERATOR, logging.WARNING)]


def test_the_setting_off_gives_no_line(configure_app, caplog):
    main = configure_app(env={SETTING: "false"})

    with caplog.at_level(logging.DEBUG):
        with TestClient(main.app):
            pass

    assert _naming_the_setting(caplog) == []
