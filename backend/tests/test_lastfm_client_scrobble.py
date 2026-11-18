"""9D.1c: per-row outcomes of an "ok" scrobble reply (spec §7.9 kind 1).

- "If `accepted` equals the number sent and `ignored` is 0, every row is `sent`."
- "Otherwise each result is matched to a row by timestamp (two rows with the
  same timestamp are matched in the order sent): ignored code 0 is `sent`; any
  other code is `ignored` with that code."
- "A row the reply does not mention is `dropped` (`no_answer`)."
- "Corrected names in the reply are ignored and never stored."
"""

import pytest

from app.services.lastfm_client import AnswerKind, LastfmClient, RowOutcome, RowStatus
from tests import lastfm_secrets as planted
from tests.lastfm_fake import FakeLastfm, make_config, ok_scrobbles, scrobble_result, xml_reply

SENT = RowOutcome(RowStatus.SENT, None)
NO_ANSWER = RowOutcome(RowStatus.DROPPED, "no_answer")


def ignored(code):
    return RowOutcome(RowStatus.IGNORED, code)


def _rows(*timestamps):
    return [{"artist": "A", "track": f"T{i}", "timestamp": ts} for i, ts in enumerate(timestamps)]


def _scrobble(rows, reply):
    fake = FakeLastfm(reply)
    return LastfmClient(make_config(), transport=fake.transport).scrobble(planted.SESSION_KEY, rows)


def test_all_accepted_marks_every_row_sent():
    rows = _rows(100, 200, 300)

    result = _scrobble(rows, ok_scrobbles(3, 0, [scrobble_result(t) for t in (100, 200, 300)]))

    assert result.answer.kind is AnswerKind.OK
    assert result.rows == (SENT, SENT, SENT)


def test_a_partly_ignored_batch_is_read_row_by_row():
    rows = _rows(100, 200, 300)
    reply = ok_scrobbles(
        2, 1, [scrobble_result(100, 0), scrobble_result(200, 1), scrobble_result(300, 0)]
    )

    assert _scrobble(rows, reply).rows == (SENT, ignored(1), SENT)


def test_a_reordered_reply_is_matched_by_timestamp():
    rows = _rows(100, 200, 300, 400)
    reply = ok_scrobbles(
        2,
        2,
        [scrobble_result(400, 5), scrobble_result(100, 0), scrobble_result(300, 3), scrobble_result(200, 0)],
    )

    assert _scrobble(rows, reply).rows == (SENT, SENT, ignored(3), ignored(5))


def test_rows_with_the_same_timestamp_are_matched_in_the_order_sent():
    rows = _rows(500, 500, 600)
    reply = ok_scrobbles(
        1, 2, [scrobble_result(600, 0), scrobble_result(500, 2), scrobble_result(500, 0)]
    )

    assert _scrobble(rows, reply).rows == (ignored(2), SENT, SENT)


def test_a_row_the_reply_omits_is_dropped_with_no_answer():
    rows = _rows(100, 200, 300)
    reply = ok_scrobbles(2, 0, [scrobble_result(300, 0), scrobble_result(100, 0)])

    assert _scrobble(rows, reply).rows == (SENT, NO_ANSWER, SENT)


def test_accepted_equal_to_the_count_but_ignored_nonzero_is_read_row_by_row():
    rows = _rows(100, 200)
    reply = ok_scrobbles(2, 1, [scrobble_result(100, 0), scrobble_result(200, 4)])

    assert _scrobble(rows, reply).rows == (SENT, ignored(4))


def test_an_unknown_ignored_code_is_kept_as_is():
    rows = _rows(100, 200)
    reply = ok_scrobbles(0, 2, [scrobble_result(100, 7), scrobble_result(200, 42)])

    assert _scrobble(rows, reply).rows == (ignored(7), ignored(42))


def test_an_unreadable_ignored_code_is_ignored_with_an_unknown_code():
    # Unknown is not zero: an unreadable code never becomes "sent".
    rows = _rows(100)
    reply = ok_scrobbles(0, 1, [scrobble_result(100, "x")])

    assert _scrobble(rows, reply).rows == (ignored(None),)


def test_a_result_for_a_timestamp_that_was_not_sent_changes_nothing():
    rows = _rows(100, 200)
    reply = ok_scrobbles(
        1, 1, [scrobble_result(999, 0), scrobble_result(100, 0), scrobble_result(200, 1)]
    )

    assert _scrobble(rows, reply).rows == (SENT, ignored(1))


def test_a_result_with_a_corrected_name_counts_like_any_other():
    rows = _rows(100, 200)
    corrected = scrobble_result(200, 0, track="Corrected Title").replace(
        'corrected="0">Corrected', 'corrected="1">Corrected'
    )
    reply = ok_scrobbles(1, 1, [scrobble_result(100, 1), corrected])

    result = _scrobble(rows, reply)

    assert result.rows == (ignored(1), SENT)
    assert "Corrected Title" not in repr(result)


def test_names_and_counts_are_read_case_insensitively():
    rows = _rows(100, 200)
    reply = xml_reply(
        '<LFM STATUS="ok"><Scrobbles Accepted="1" Ignored="1">'
        "<Scrobble><Timestamp> 200 </Timestamp><IgnoredMessage Code=\"2\"></IgnoredMessage></Scrobble>"
        "<SCROBBLE><TIMESTAMP>100</TIMESTAMP><IGNOREDMESSAGE CODE=\"0\"></IGNOREDMESSAGE></SCROBBLE>"
        "</Scrobbles></LFM>"
    )

    assert _scrobble(rows, reply).rows == (SENT, ignored(2))


@pytest.mark.parametrize(
    "body",
    [
        '<lfm status="ok"></lfm>',
        '<lfm status="ok"><scrobbles></scrobbles></lfm>',
        '<lfm status="ok"><scrobbles accepted="1"></scrobbles></lfm>',
        '<lfm status="ok"><scrobbles accepted="one" ignored="0"></scrobbles></lfm>',
        '<lfm status="ok"><scrobbles accepted="1" ignored=""></scrobbles></lfm>',
    ],
    ids=["no scrobbles", "no totals", "no ignored total", "non-numeric", "empty total"],
)
def test_an_ok_reply_without_readable_totals_is_try_later(body):
    result = _scrobble(_rows(100), xml_reply(body))

    assert result.answer.kind is AnswerKind.TRY_LATER
    assert result.rows is None


def test_one_outcome_per_row_for_a_full_batch():
    timestamps = list(range(1000, 1050))
    rows = _rows(*timestamps)
    results = [scrobble_result(t, 1 if t % 7 == 0 else 0) for t in reversed(timestamps[1:])]
    ignored_count = sum(1 for t in timestamps[1:] if t % 7 == 0)
    reply = ok_scrobbles(49 - ignored_count, ignored_count, results)

    outcomes = _scrobble(rows, reply).rows

    assert len(outcomes) == 50
    assert outcomes[0] == NO_ANSWER
    for t, outcome in zip(timestamps[1:], outcomes[1:]):
        assert outcome == (ignored(1) if t % 7 == 0 else SENT)
