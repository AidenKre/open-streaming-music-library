"""7A.3b S2 (spec §6 steps 4-6, happy path): the publisher moves the prepared
work file to its final path (no-replace link under the organizer lock, journal
``moved``, work link removed), then inserts track, metadata, identity and FTS in
one transaction that also marks the item and journal ``imported``; the identity
worker is woken only after that commit. Prepared state comes from the real
7A.3a worker."""

import json
import os

import pytest

from app.services.audio_identity import AudioIdentity, ExactUnavailable
from app.services.upload_publish import SEAM_POINTS, SimulatedCrash
from tests.identity_worker_fixtures import sql
from tests.owned_database import add_test_user
from tests.upload_commit_fixtures import (
    FakeExact,
    accept,
    journal,
    library_root,
    make_commit_worker,
    ready_item,
    reservations,
)
from tests.upload_publish_fixtures import (
    FakeSignal,
    RecordingSeam,
    identity_of,
    item_state_via_new_connection,
    library_track,
    make_publisher,
    meta_row,
    track_row,
)
from tests.upload_validation_fixtures import exact_for, item_row, print_of


@pytest.fixture
def music(tmp_path):
    path = tmp_path / "music"
    (path / ".uploads").mkdir(parents=True)
    return path


def _publish(db, music, *, edits=None, write_tags=False, ready=None, publisher=None, worker=None,
             **publisher_kwargs):
    """Accept an item and run the real commit worker with the publisher."""
    staged = ready_item(db, music / ".uploads", **(ready or {}))
    commit = accept(db, staged, edits=edits, write_tags=write_tags)
    publisher = publisher or make_publisher(db, music, **publisher_kwargs)
    outcome = make_commit_worker(db, music, after_prepared=publisher, **(worker or {})).process_one()
    return commit, outcome


def _final_path(db, commit):
    return journal(db, commit)["final_path"]


def test_happy_path_publishes_the_track(db, music):
    commit, outcome = _publish(db, music, edits={"title": "New"})

    assert outcome == "imported"
    row = journal(db, commit)
    final = row["final_path"]
    assert os.path.isfile(final)
    assert final.startswith(str(library_root(db, music, commit["owner_id"])) + os.sep)
    assert open(final, "rb").read() == b"audio-A"
    assert not commit["work"].exists()
    assert not commit["source"].exists()  # S6: given back after the import

    track = track_row(db, commit["track"])
    assert track["file_path"] == final
    assert track["owner_id"] == commit["owner_id"]
    meta = meta_row(db, commit["track"])
    assert meta["title"] == "New"
    assert meta["codec"] == "flac"
    [names] = sql(db, "SELECT a.name AS artist, b.name AS album FROM trackmetadata m"
                      " LEFT JOIN artists a ON a.id = m.artist_id LEFT JOIN albums b ON b.id = m.album_id"
                      " WHERE m.uuid_id = ?", (commit["track"],))
    assert names == {"artist": "Radiohead", "album": "OK Computer"}

    item = item_row(db, commit)
    assert item["state"] == "imported"
    assert item["result_track_uuid"] == commit["track"]
    assert item["result_revision"] == track["revision"]
    assert item["final_path"] == final
    assert item["error_code"] is None
    assert row["state"] == "imported"
    assert [r for r in reservations(db, commit["owner_id"]) if r["subject_ref"] == commit["op"]] == []
    assert sql(db, "SELECT rowid FROM fts_tracks WHERE fts_tracks MATCH 'New'") != []


def test_the_identity_row_carries_the_digest_and_the_final_stat(db, music):
    commit, outcome = _publish(db, music)

    assert outcome == "imported"
    row = identity_of(db, commit["track"])
    stat = os.stat(_final_path(db, commit))
    assert row["exact_state"] == "current"
    assert row["exact_digest"] == exact_for(b"audio-A").digest
    assert (row["stat_size"], row["stat_mtime_ns"], row["stat_inode"]) == (
        stat.st_size, stat.st_mtime_ns, stat.st_ino)
    assert None not in (row["stat_size"], row["stat_mtime_ns"], row["stat_inode"])


def test_an_unverified_digest_is_stored_pending_with_the_digest_kept(db, music):
    exact = FakeExact()
    exact.result = ExactUnavailable("failed", "decode_error")

    commit, outcome = _publish(db, music, worker={"exact": exact})

    assert journal(db, commit)["digest_check"] == "unverified"
    assert outcome == "imported"
    row = identity_of(db, commit["track"])
    assert row["exact_state"] == "pending"
    assert row["exact_digest"] == exact_for(b"audio-A").digest


def test_without_a_print_the_fingerprint_is_unavailable_when_no_fingerprinter(db, music):
    commit, outcome = _publish(db, music, fingerprinter_present=False)

    assert outcome == "imported"
    assert identity_of(db, commit["track"])["fp_state"] == "unavailable"


def test_without_a_print_the_fingerprint_is_pending_when_a_fingerprinter_exists(db, music):
    commit, outcome = _publish(db, music, fingerprinter_present=True)

    assert outcome == "imported"
    assert identity_of(db, commit["track"])["fp_state"] == "pending"


def test_a_current_staged_print_is_stored_with_the_track(db, music):
    identity = AudioIdentity(exact=exact_for(b"audio-A"), tool_versions="ffmpeg 8.1", computed_at=1700,
                             fingerprint=print_of())

    commit, outcome = _publish(db, music, ready={"identity": identity})

    assert outcome == "imported"
    assert identity_of(db, commit["track"])["fp_state"] == "current"
    assert len(sql(db, "SELECT uuid_id FROM track_audio_fingerprint WHERE uuid_id = ?",
                   (commit["track"],))) == 1


def test_the_identity_worker_is_woken_only_after_the_commit(db, music):
    holder = {}
    signal = FakeSignal(probe=lambda: item_state_via_new_connection(db, holder["commit"]) == "imported")
    staged = ready_item(db, music / ".uploads")
    holder["commit"] = accept(db, staged)

    outcome = make_commit_worker(
        db, music, after_prepared=make_publisher(db, music, identity_signal=signal)).process_one()

    assert outcome == "imported"
    assert signal.notifies == 1
    assert signal.observed == [True]


def test_the_seams_fire_in_order(db, music):
    seam = RecordingSeam()

    _commit, outcome = _publish(db, music, seam=seam)

    assert outcome == "imported"
    # 7A.3c S1 added before_link / before_insert_commit around these.
    assert [p for p in seam.points if p.startswith("after_")][:4] == [
        "after_link", "after_moved_journal", "after_work_unlink", "after_insert_commit"]
    assert set(seam.points) <= set(SEAM_POINTS)


def _crash(db, music, point):
    seam = RecordingSeam(crash_at=point)
    staged = ready_item(db, music / ".uploads")
    commit = accept(db, staged, edits={"title": "New"})
    worker = make_commit_worker(db, music, after_prepared=make_publisher(db, music, seam=seam))
    with pytest.raises(SimulatedCrash):
        worker.process_one()
    assert seam.points[-1] == point  # nothing after the crash point ran
    return commit


def test_a_crash_after_the_link_leaves_both_names_and_a_prepared_journal(db, music):
    commit = _crash(db, music, "after_link")

    row = journal(db, commit)
    assert row["state"] == "prepared"
    assert os.path.exists(commit["work"]) and os.path.exists(row["final_path"])
    assert os.path.samefile(commit["work"], row["final_path"])
    assert track_row(db, commit["track"]) is None
    assert item_row(db, commit)["state"] == "committing"


def test_a_crash_after_the_moved_journal_keeps_the_work_link(db, music):
    commit = _crash(db, music, "after_moved_journal")

    row = journal(db, commit)
    assert row["state"] == "moved"
    assert os.path.samefile(commit["work"], row["final_path"])
    assert track_row(db, commit["track"]) is None


def test_a_crash_after_the_work_unlink_keeps_the_reservation(db, music):
    commit = _crash(db, music, "after_work_unlink")

    row = journal(db, commit)
    assert row["state"] == "moved"
    assert not commit["work"].exists()
    assert os.path.isfile(row["final_path"])
    assert track_row(db, commit["track"]) is None
    assert [r for r in reservations(db, commit["owner_id"])
            if r["purpose"] == "upload_work" and r["subject_ref"] == commit["op"]] != []


def test_a_crash_after_the_insert_commit_is_already_imported(db, music):
    commit = _crash(db, music, "after_insert_commit")

    assert item_row(db, commit)["state"] == "imported"
    assert track_row(db, commit["track"]) is not None


def test_another_users_identical_track_does_not_block_this_users_commit(db, music):
    other = add_test_user(db, "other")
    library_track(db, music, b"audio-A", owner_id=other)

    commit, outcome = _publish(db, music)

    assert outcome == "imported"
    assert item_row(db, commit)["state"] == "imported"


def test_write_tags_publishes_the_tagged_work_copy(db, music):
    from tests.upload_commit_fixtures import FakeTagWriter

    writer = FakeTagWriter(extra=b"+tags")

    commit, outcome = _publish(db, music, edits={"title": "New"}, write_tags=True,
                               worker={"tag_writer": writer})

    assert outcome == "imported"
    assert open(_final_path(db, commit), "rb").read() == b"audio-A+tags"
    assert json.loads(journal(db, commit)["final_metadata"])["title"] == "New"


def test_the_final_name_is_made_durable_before_the_journal_says_moved(db, music, monkeypatch):
    """Review r1 7-R1-12 (spec §6 step 6: the source goes only after the receipt
    is durable): the new directory entry of the final file is synced (its
    parent directory fsynced) after the link and before the journal says
    ``moved``, so the row, the source unlink and the name cannot outlive it."""
    from app.services.upload_receipt import ReceiptFiles

    events = []
    real_sync = ReceiptFiles.sync_dir
    real_moved = db.mark_upload_commit_moved

    def sync_dir(self, path):
        events.append(("sync", os.fspath(path)))
        return real_sync(self, path)

    def moved(**kwargs):
        events.append(("moved",))
        return real_moved(**kwargs)

    monkeypatch.setattr(ReceiptFiles, "sync_dir", sync_dir)
    monkeypatch.setattr(db, "mark_upload_commit_moved", moved)
    seam = RecordingSeam()

    def recording_seam(name):
        events.append(("seam", name))
        seam(name)

    commit, outcome = _publish(db, music, seam=recording_seam)

    assert outcome == "imported"
    final = track_row(db, commit["track"])["file_path"]
    parent = os.fspath(os.path.dirname(final))
    linked = events.index(("seam", "before_link"))
    synced = [i for i, e in enumerate(events) if e == ("sync", parent) and i > linked]
    assert synced, events
    assert synced[0] < events.index(("moved",)), events
