"""The commit's exact-duplicate check (the preflight before the move, and the
check inside the publish transaction) reads only the matches: the finder's
coverage counts read every live track of the owner and nobody uses them
there. The matches are the same as before."""

from pathlib import Path

import pytest

from app.services import duplicate_detection
from tests.identity_worker_fixtures import sql
from tests.upload_commit_fixtures import journal, library_root
from tests.upload_publish_fixtures import library_track, make_publisher, prepared_commit, track_row
from tests.upload_validation_fixtures import item_row


@pytest.fixture
def music(tmp_path):
    path = tmp_path / "music"
    (path / ".uploads").mkdir(parents=True)
    return path


@pytest.fixture
def coverage_reads(monkeypatch):
    calls = []
    real = duplicate_detection._coverage
    monkeypatch.setattr(duplicate_detection, "_coverage", lambda *a: calls.append(1) or real(*a))
    return calls


def test_the_preflight_finds_the_exact_match_without_counting_coverage(db, music, coverage_reads):
    commit = prepared_commit(db, music, content=b"audio-A")
    match = library_track(db, music, b"audio-A")
    library_track(db, music, b"audio-B")  # another song: no match

    assert db.upload_commit_preflight(owner_id=commit["owner_id"], operation_uuid=commit["op"]) == [match]
    assert coverage_reads == []


def test_an_acknowledged_match_is_published_without_counting_coverage(db, music, coverage_reads):
    match = library_track(db, music, b"audio-A")
    commit = prepared_commit(db, music, content=b"audio-A", acks={"library_tracks": [match]})
    Path(commit["work"]).write_bytes(b"audio-A")
    final = library_root(db, music, commit["owner_id"]) / "Artist" / f"{commit['track']}.flac"
    sql(db, "UPDATE upload_commit_journal SET final_path = ? WHERE owner_id = ? AND operation_uuid = ?",
        (str(final), commit["owner_id"], commit["op"]))

    assert make_publisher(db, music)(journal(db, commit)) == "imported"

    assert item_row(db, commit)["state"] == "imported"
    assert track_row(db, commit["track"]) is not None
    assert coverage_reads == []
