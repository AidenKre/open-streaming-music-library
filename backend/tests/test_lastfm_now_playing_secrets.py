"""9D.2c (spec §7.6, §7.10, review 9-U08b): whatever Last.fm answers a Now
Playing notice, no secret reaches a log, stdout/stderr or the database file,
and OSML never writes the track's own fields (user content that goes to
Last.fm) into a log line. Last.fm's own reply to a failed request may still be
logged, at most 4 KiB with secrets blanked (spec §7.9); these replies do not
quote the track. Nothing about a notice is stored. Made-up values only."""

import logging

import httpx
import pytest

from tests import lastfm_secrets as planted
from tests.lastfm_fake import failed, ok_now_playing, xml_reply
from tests.lastfm_sender_rig import connect_user, make_rig, query, session_key_for
from tests.test_lastfm_now_playing import add_track

TITLE = "Zqx-Title-Marker"
ARTIST = "Zqx-Artist-Marker"
ALBUM = "Zqx-Album-Marker"
CONTENT = (TITLE, ARTIST, ALBUM)


def _echo(text: str) -> str:
    """A hostile reply message quoting every secret the server holds."""
    return text + " ".join(
        [planted.API_KEY, planted.API_SECRET, planted.CREDENTIAL_KEY, session_key_for("ana")]
    )


ANSWERS = {
    "ok": ok_now_playing,
    "rejected echoing secrets": lambda: failed(6, message=_echo("bad track ")),
    "reconnect echoing secrets": lambda: failed(9, message=_echo("bad session ")),
    "stop echoing secrets": lambda: failed(26, message=_echo("suspended ")),
    "try later echoing secrets": lambda: failed(11, message=_echo("busy ")),
    "HTTP 502 echoing secrets": lambda: xml_reply(_echo("<html>"), status=502),
    "unreadable echoing secrets": lambda: xml_reply(_echo("<lfm status='ok'")),
    "connect failure": lambda: httpx.ConnectError(_echo("refused ")),
    "network error": lambda: httpx.ReadError(_echo("reset ")),
}


def _assert_clean(tmp_path, caplog, capsys):
    secrets = (*planted.ALL, session_key_for("ana"))
    planted.assert_no_secret(caplog.text, "captured logs", secrets)
    captured = capsys.readouterr()
    planted.assert_no_secret(captured.out + captured.err, "stdout/stderr", secrets)
    for marker in CONTENT:
        assert marker not in caplog.text, "a track field reached a log line"
        assert marker not in captured.out + captured.err, "a track field reached stdout/stderr"
    for suffix in ("", "-wal"):
        path = tmp_path / f"database.db{suffix}"
        if path.exists():
            data = path.read_bytes()
            for index, secret in enumerate(secrets):
                assert secret.encode() not in data, f"secret #{index} is in the database file"


@pytest.mark.parametrize("answer", ANSWERS.values(), ids=ANSWERS.keys())
def test_no_answer_puts_a_secret_or_a_track_field_in_a_log_and_nothing_is_stored(
    tmp_path, caplog, capsys, answer
):
    caplog.set_level(logging.DEBUG)
    rig = make_rig(tmp_path)
    ana = connect_user(rig, "ana")
    rig.sender.notices.put(ana, add_track(rig, tmp_path, ana, title=TITLE, artist=ARTIST, album=ALBUM))
    rig.fake.queue(answer())

    rig.sender.run_step()

    assert len(rig.fake.requests) == 1
    _assert_clean(tmp_path, caplog, capsys)
    assert query(rig, "SELECT * FROM scrobble_outbox") == []  # a notice is never stored


def test_an_error_while_sending_a_notice_logs_its_class_only(tmp_path, caplog, capsys, monkeypatch):
    caplog.set_level(logging.DEBUG)
    rig = make_rig(tmp_path)
    ana = connect_user(rig, "ana")
    rig.sender.notices.put(ana, add_track(rig, tmp_path, ana, title=TITLE, artist=ARTIST, album=ALBUM))

    def broken(**kwargs):
        raise RuntimeError(f"{TITLE} {ARTIST} {planted.SESSION_KEY}")

    monkeypatch.setattr(rig.db, "read_lastfm_now_playing", broken)

    rig.sender.run_step()

    assert "RuntimeError" in caplog.text
    assert all(r.exc_info is None for r in caplog.records)
    _assert_clean(tmp_path, caplog, capsys)
    assert rig.fake.requests == []
    assert len(rig.sender.notices) == 0


def test_an_undecryptable_key_leaks_nothing(tmp_path, caplog, capsys):
    caplog.set_level(logging.DEBUG)
    rig = make_rig(tmp_path)
    ana = connect_user(rig, "ana", session_key_enc="gAAAAA-garbage-" + planted.SESSION_KEY)
    rig.sender.notices.put(ana, add_track(rig, tmp_path, ana, title=TITLE, artist=ARTIST, album=ALBUM))

    rig.sender.run_step()

    planted.assert_no_secret(caplog.text, "captured logs")
    for marker in CONTENT:
        assert marker not in caplog.text
    assert rig.fake.requests == []
