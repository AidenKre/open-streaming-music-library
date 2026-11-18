"""9D.2b (spec §7.6, §7.9 last paragraph, review 9-U08b): whatever Last.fm
answers, no secret reaches a log, an exception or the database file. A failed
request is logged with its HTTP status, the error code and at most 4 KiB of the
reply, through the one redaction helper. Made-up values only."""

import logging

import httpx
import pytest

from tests import lastfm_secrets as planted
from tests.lastfm_fake import failed, ok_scrobbles, scrobble_result, xml_reply
from tests.lastfm_sender_rig import NOW_S, connect_user, make_rig, queue_row, session_key_for


def _echo(text: str) -> str:
    """A hostile reply message quoting every secret the server holds."""
    return text + " ".join(
        [planted.API_KEY, planted.API_SECRET, planted.CREDENTIAL_KEY, session_key_for("ana")]
    )


ANSWERS = {
    "rejected echoing secrets": lambda: failed(13, message=_echo("bad sig ")),
    "reconnect echoing secrets": lambda: failed(9, message=_echo("bad session ")),
    "stop echoing secrets": lambda: failed(26, message=_echo("suspended ")),
    "try later echoing secrets": lambda: failed(11, message=_echo("busy ")),
    "HTTP 502 echoing secrets": lambda: xml_reply(_echo("<html>"), status=502),
    "unreadable echoing secrets": lambda: xml_reply(_echo("<lfm status='ok'")),
    "ignored": lambda: ok_scrobbles(0, 1, [scrobble_result(NOW_S - 100, 1)]),
    "connect failure": lambda: httpx.ConnectError(_echo("refused ")),
    "network error": lambda: httpx.ReadError(_echo("reset ")),
}


@pytest.mark.parametrize("answer", ANSWERS.values(), ids=ANSWERS.keys())
def test_no_answer_puts_a_secret_in_a_log_or_the_database_file(tmp_path, caplog, capsys, answer):
    caplog.set_level(logging.DEBUG)
    rig = make_rig(tmp_path)
    ana = connect_user(rig, "ana")
    queue_row(rig, ana, listened_at_s=NOW_S - 100)
    queue_row(rig, ana, listened_at_s=NOW_S - 50)
    rig.fake.queue(answer())

    rig.sender.run_step()

    secrets = (*planted.ALL, session_key_for("ana"))
    planted.assert_no_secret(caplog.text, "captured logs", secrets)
    captured = capsys.readouterr()
    planted.assert_no_secret(captured.out + captured.err, "stdout/stderr", secrets)
    for suffix in ("", "-wal"):
        path = tmp_path / f"database.db{suffix}"
        if path.exists():
            data = path.read_bytes()
            for index, secret in enumerate(secrets):
                assert secret.encode() not in data, f"secret #{index} is in the database file"


def test_an_undecryptable_key_leaks_nothing(tmp_path, caplog):
    caplog.set_level(logging.DEBUG)
    rig = make_rig(tmp_path)
    ana = connect_user(rig, "ana", session_key_enc="gAAAAA-garbage-" + planted.SESSION_KEY)
    queue_row(rig, ana)

    rig.sender.run_step()

    planted.assert_no_secret(caplog.text, "captured logs")
    assert rig.fake.requests == []


def test_a_failed_request_logs_status_code_and_at_most_4_kib_of_the_reply(tmp_path, caplog):
    caplog.set_level(logging.DEBUG)
    rig = make_rig(tmp_path)
    ana = connect_user(rig, "ana")
    queue_row(rig, ana)
    rig.fake.queue(failed(13, message="x" * 20_000))

    rig.sender.run_step()

    lines = [r.getMessage() for r in caplog.records if "track.scrobble" in r.getMessage()]
    assert len(lines) == 1, lines
    line = lines[0]
    assert "13" in line and "200" in line
    reply = line.split("reply: ", 1)[1]
    assert 0 < len(reply.encode("utf-8")) <= 4096
