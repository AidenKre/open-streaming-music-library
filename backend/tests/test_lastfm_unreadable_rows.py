"""9-fix-r3 (live gate 9-L-01): an outbox row whose stored text cannot be read
(a lone surrogate, bytes that are not UTF-8, text that is not JSON, a field that
is not text) never breaks a reader of the outbox.

Such a row only exists in a damaged or hand-edited database: the subscriber's
own rules never write one. The status route still answers 200 and lists the
problem with the unreadable field as null (unknown, never an empty title, never
partly decoded text); the sender settles it ``failed``/``invalid_row`` and sends
the rest. Another user's status is unaffected."""

import json
import sqlite3

import pytest

from tests.lastfm_fake import ok_scrobbles, scrobble_result
from tests.lastfm_routes import BASE, admin_id, clean_env, open_rig, second_user, seed_connection, seed_outbox
from tests.lastfm_sender_rig import NOW_S, WALL_MS, connect_user, make_rig, query, sent

LISTENED_S = 1_799_000_000

# (stored payload, expected artist, expected track). Bytes are stored as TEXT as-is.
UNREADABLE = {
    "lone surrogate": (
        '{"artist": "Some Artist", "track": "\\udcff", "timestamp": %d}' % LISTENED_S,
        "Some Artist", None,
    ),
    "bytes that are not UTF-8": (
        b'{"artist": "Some Artist", "track": "Bad \xff\xfe", "timestamp": %d}' % LISTENED_S,
        "Some Artist", None,
    ),
    "not JSON": ("this is not JSON", None, None),
    "not an object": ('["Some Artist", "Some Track"]', None, None),
    "a field that is not text": (
        '{"artist": 5, "track": "Some Track", "timestamp": %d}' % LISTENED_S,
        None, "Some Track",
    ),
    # The JSON reader gives up on deep nesting with a RecursionError.
    "nested too deep": ("[" * 100_000 + "]" * 100_000, None, None),
}


def _insert_raw(database_path, event_uuid, owner, payload, *, listened_at_s, created_at,
                status="pending", code=None, done_at=None):
    """Writes a payload byte for byte, as a damaged or hand-edited database holds it
    (the table's JSON check is switched off for this one connection)."""
    conn = sqlite3.connect(database_path)
    try:
        conn.execute("PRAGMA ignore_check_constraints = ON")
        conn.execute(
            "INSERT INTO scrobble_outbox (event_uuid, owner_id, payload, listened_at_s, status,"
            " result_code, attempts, alone, created_at, done_at)"
            " VALUES (?, ?, CAST(? AS TEXT), ?, ?, ?, 0, 0, ?, ?)",
            (event_uuid, owner, payload, listened_at_s, status, code, created_at, done_at),
        )
        conn.commit()
    finally:
        conn.close()


# ── the status route ─────────────────────────────────────────────────────────


@pytest.fixture
def _clean(monkeypatch):
    clean_env(monkeypatch)


@pytest.mark.parametrize("case", list(UNREADABLE))
def test_the_status_lists_an_unreadable_problem_row_with_unknown_fields(open_app_client, _clean, case):
    payload, artist, track = UNREADABLE[case]
    with open_rig(open_app_client) as rig:
        owner = admin_id(rig)
        seed_connection(rig, owner, opted_in=True)
        now = rig.wall.ms
        _insert_raw(
            rig.db.context.database_path, "a0000000-0000-4000-8000-000000000001", owner, payload,
            listened_at_s=LISTENED_S, created_at=now - 10, status="failed", code="invalid_row",
            done_at=now - 1_000,
        )
        seed_outbox(rig, owner, status="failed", code="13", done_at=now - 2_000,
                    listened_at_s=LISTENED_S + 1, artist="Readable", track="Row")
        b, b_headers = second_user(rig)
        seed_connection(rig, b, account="beta", opted_in=True)
        seed_outbox(rig, b, status="ignored", code="1", done_at=now - 500,
                    listened_at_s=LISTENED_S + 2, artist="Bea's", track="Own")

        response = rig.client.get(BASE)
        b_response = rig.client.get(BASE, headers=b_headers)

        assert response.status_code == 200, response.text
        assert response.json()["recent_problems"] == [
            {"artist": artist, "track": track, "listened_at": LISTENED_S * 1000,
             "status": "failed", "code": "invalid_row"},
            {"artist": "Readable", "track": "Row", "listened_at": (LISTENED_S + 1) * 1000,
             "status": "failed", "code": "13"},
        ]
        assert response.json()["counts"]["failed"] == 2
        assert "Bad" not in response.text  # no partly decoded text is shown
        assert b_response.status_code == 200, b_response.text
        assert b_response.json()["recent_problems"] == [
            {"artist": "Bea's", "track": "Own", "listened_at": (LISTENED_S + 2) * 1000,
             "status": "ignored", "code": "1"},
        ]


# ── the sender ───────────────────────────────────────────────────────────────


@pytest.mark.parametrize("case", ["lone surrogate", "bytes that are not UTF-8", "not JSON", "not an object",
                                  "nested too deep"])
def test_the_sender_fails_an_unreadable_pending_row_and_sends_the_rest(tmp_path, case):
    rig = make_rig(tmp_path)
    ana = connect_user(rig, "ana")
    t_bad, t_good = NOW_S - 300, NOW_S - 200
    bad = "a0000000-0000-4000-8000-000000000002"
    _insert_raw(rig.db.context.database_path, bad, ana, UNREADABLE[case][0],
                listened_at_s=t_bad, created_at=WALL_MS - 61_000)
    good = "a0000000-0000-4000-8000-000000000003"
    _insert_raw(rig.db.context.database_path, good, ana,
                '{"artist": "A", "track": "T", "timestamp": %d}' % t_good,
                listened_at_s=t_good, created_at=WALL_MS - 61_000)
    rig.fake.queue(ok_scrobbles(1, 0, [scrobble_result(t_good)]))

    rig.sender.run_pass()

    assert [s.timestamps for s in sent(rig)] == [[t_good]]
    assert _settled(rig, bad) == ("failed", "invalid_row")
    assert _settled(rig, good) == ("sent", None)


def _settled(rig, event_uuid):
    """Status and code only: the stored payload of a damaged row may not be readable."""
    found = query(rig, "SELECT status, result_code FROM scrobble_outbox WHERE event_uuid = ?", (event_uuid,))
    return found[0]["status"], found[0]["result_code"]


@pytest.mark.parametrize("fields", [
    {"album": None},
    {"artist": ["A"]},
    {"albumArtist": True},
    {"track": 7},
    {"timestamp": "x"},
    {"timestamp": 1.5},
    {"timestamp": True},
    {"duration": "200"},
    {"duration": False},
], ids=repr)
def test_the_sender_fails_a_row_whose_value_has_the_wrong_type(tmp_path, fields):
    """Audit DR-F903-BE-B-04: a value that is not text where text is sent, or not a
    whole number for the time and length, is never turned into text such as "None"
    or "True" and sent: the row is failed and the rest is sent."""
    rig = make_rig(tmp_path)
    ana = connect_user(rig, "ana")
    t_bad, t_good = NOW_S - 300, NOW_S - 200
    payload = {"artist": "A", "track": "T", "timestamp": t_bad, **fields}
    bad = "a0000000-0000-4000-8000-000000000004"
    _insert_raw(rig.db.context.database_path, bad, ana, json.dumps(payload),
                listened_at_s=t_bad, created_at=WALL_MS - 61_000)
    good = "a0000000-0000-4000-8000-000000000005"
    _insert_raw(rig.db.context.database_path, good, ana,
                '{"artist": "A", "track": "T", "timestamp": %d, "duration": 200}' % t_good,
                listened_at_s=t_good, created_at=WALL_MS - 61_000)
    rig.fake.queue(ok_scrobbles(1, 0, [scrobble_result(t_good)]))

    rig.sender.run_pass()

    assert [s.timestamps for s in sent(rig)] == [[t_good]]
    assert _settled(rig, bad) == ("failed", "invalid_row")
    assert _settled(rig, good) == ("sent", None)
