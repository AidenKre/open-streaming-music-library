"""Sign-off s7-live-findings item 3 (link-fallback design table D6, row HP;
user decision "recover at restart"). On a library that takes hard links the
import links the work file at the final name, flushes the folders, commits
``moved``, then removes the work link. A power cut can lose that ``moved``
commit and keep the removal: the next start finds the journal ``prepared``,
the work file gone and a file at the final name, which no hard link and no
placement record can prove. Two other facts name it: the final name holds the
track UUID reserved for this one import, and the journal holds the exact audio
digest of the prepared work file. At restart only, a regular file at exactly
that name, inside the owner's library root, whose exact audio digest equals the
journaled one (same kind and parameters) finishes the import. A different
digest sends the item back to review as before, the file untouched; a digest
that cannot be computed now leaves everything for the next start."""

import json
import logging
import os
from pathlib import Path

import pytest

from app.services import upload_recovery
from app.services.audio_identity import ExactUnavailable
from tests.identity_worker_fixtures import sql
from tests.upload_commit_fixtures import FakeExact, journal, library_root, make_commit_worker
from tests.upload_publish_fixtures import make_publisher, prepared_commit, track_row
from tests.upload_recovery_fixtures import World
from tests.upload_validation_fixtures import item_row

OPERATOR = "uvicorn.error"


@pytest.fixture
def music(tmp_path):
    path = tmp_path / "music"
    (path / ".uploads").mkdir(parents=True)
    return path


@pytest.fixture
def world(db, music):
    return World(db, music)


def _hp(db, music, *, final_bytes=b"audio-A", digest_check="verified", final=None):
    """Row HP: a prepared journal (digest of b"audio-A", the prepared work
    file's), its work file gone, ``final_bytes`` at its final name in the
    owner's library root (or at ``final``), no placement record."""
    commit = prepared_commit(db, music)
    root = library_root(db, music, commit["owner_id"])
    final = final or root / "Radiohead" / f"Airbag-{commit['track']}.flac"
    sql(db, "UPDATE upload_commit_journal SET final_path = ?, digest_check = ?,"
            " final_metadata = json_set(final_metadata, '$.codec', 'flac')"
            " WHERE owner_id = ? AND operation_uuid = ?",
        (str(final), digest_check, commit["owner_id"], commit["op"]))
    final.parent.mkdir(parents=True, exist_ok=True)
    if final_bytes is not None:
        final.write_bytes(final_bytes)
    assert not os.path.lexists(commit["work"])
    assert not os.path.lexists(str(commit["work"]) + ".place")
    return commit, final


def _recover(world, exact, caplog) -> list[str]:
    caplog.clear()
    with caplog.at_level(logging.WARNING, logger=OPERATOR):
        world.recover(compute_exact=exact)
    return [r.getMessage() for r in caplog.records if r.name == OPERATOR]


def _decoded(exact) -> list[Path]:
    return [call["path"] for call in exact.calls]


def assert_back_in_review(db, commit, final, final_bytes):
    """As before this change: the item back at review, nothing of ours placed,
    the file at the final name left exactly as it was."""
    row = journal(db, commit)
    assert (row["state"], row["final_path"]) == ("failed", None)
    item = item_row(db, commit)
    assert (item["state"], item["error_code"]) == ("review_ready", "upload_commit_failed")
    assert track_row(db, commit["track"]) is None
    assert sql(db, "SELECT count(*) AS n FROM tracks")[0]["n"] == 0
    if final_bytes is not None:
        assert final.read_bytes() == final_bytes
    assert commit["source"].read_bytes() == commit["content"]


def assert_untouched(db, commit, final, final_bytes):
    row = journal(db, commit)
    assert (row["state"], row["final_path"]) == ("prepared", str(final))
    assert item_row(db, commit)["state"] == "committing"
    assert track_row(db, commit["track"]) is None
    assert final.read_bytes() == final_bytes
    assert commit["source"].read_bytes() == commit["content"]


# ── match: the import is finished ───────────────────────────────────────────

def test_a_final_whose_audio_matches_finishes_the_import(world, db, music, caplog):
    commit, final = _hp(db, music)
    exact = FakeExact()

    lines = _recover(world, exact, caplog)

    assert item_row(db, commit)["state"] == "imported"
    published = track_row(db, commit["track"])
    assert published["file_path"] == str(final)
    assert final.read_bytes() == b"audio-A"
    assert journal(db, commit)["state"] == "imported"
    assert not commit["source"].exists()  # the staged source is released as for any import
    # One bounded decode at restart: the final, its probed demuxer forced, low priority.
    assert exact.calls == [{"path": final, "codec_hint": "flac", "registry": None, "job_id": None,
                            "low_priority": True, "input_format": "flac"}]
    [line] = lines
    assert commit["op"] in line and commit["item_uuid"] in line
    assert "/" not in line and "Airbag" not in line and str(commit["owner_id"]) + "/" not in line


def test_the_next_start_cleans_the_finished_journal(world, db, music):
    commit, final = _hp(db, music)
    world.recover()
    world.recover()

    assert sql(db, "SELECT count(*) AS n FROM upload_commit_journal")[0]["n"] == 0
    assert track_row(db, commit["track"])["file_path"] == str(final)
    assert final.read_bytes() == b"audio-A"


# ── mismatch: as before ─────────────────────────────────────────────────────

@pytest.mark.parametrize("reason", [None, "decode_error"])
def test_a_final_with_other_audio_goes_back_to_review_untouched(world, db, music, caplog, reason):
    commit, final = _hp(db, music, final_bytes=b"audio-B")
    exact = FakeExact()
    if reason is not None:  # the file's own content does not decode
        exact.result = ExactUnavailable("failed", reason)

    lines = _recover(world, exact, caplog)

    assert_back_in_review(db, commit, final, b"audio-B")
    assert _decoded(exact) == [final]  # decoded once, not again by the recovered failure
    assert [line for line in lines if commit["op"] in line] == []


# ── unknown: nothing changes, checked again at the next start ──────────────

@pytest.mark.parametrize("reason", ["timeout", "tool_missing", "killed", None])
def test_a_digest_that_cannot_be_computed_now_leaves_everything(world, db, music, caplog, reason):
    commit, final = _hp(db, music)
    exact = FakeExact()
    exact.result = ExactUnavailable("failed", reason)

    for _ in range(3):
        lines = _recover(world, exact, caplog)
        assert_untouched(db, commit, final, b"audio-A")
        [line] = lines
        assert "could not be checked" in line and "/" not in line

    world.recover()  # the tool is back

    assert item_row(db, commit)["state"] == "imported"
    assert track_row(db, commit["track"])["file_path"] == str(final)


def test_a_final_that_changes_while_it_is_checked_is_unknown(world, db, music, caplog):
    commit, final = _hp(db, music)

    class Swaps(FakeExact):
        def __call__(self, path, codec_hint, **kwargs):
            answer = super().__call__(path, codec_hint, **kwargs)
            other = final.with_name(".swap")
            other.write_bytes(b"audio-A")
            os.replace(other, final)  # another file now at the name
            return answer

    lines = _recover(world, Swaps(), caplog)

    assert_untouched(db, commit, final, b"audio-A")
    assert any("could not be checked" in line for line in lines)


# ── the stored digest must describe the prepared work file ─────────────────

@pytest.mark.parametrize("stored", ["unverified", "exact_failed", "exact_unsupported"])
def test_a_journal_without_a_checked_current_digest_behaves_as_before(world, db, music, stored):
    commit, final = _hp(db, music, digest_check="unverified" if stored == "unverified" else "verified")
    if stored != "unverified":
        sql(db, "UPDATE upload_commit_journal SET exact_state = ?, exact_kind = NULL,"
                " exact_digest = NULL, sample_rate_hz = NULL, channels = NULL,"
                " bits_per_sample = NULL, failure_reason = ?"
                " WHERE owner_id = ? AND operation_uuid = ?",
            (stored.split("_")[1], "timeout" if stored == "exact_failed" else None,
             commit["owner_id"], commit["op"]))
    exact = FakeExact()

    world.recover(compute_exact=exact)

    assert_back_in_review(db, commit, final, b"audio-A")
    assert exact.calls == []


@pytest.mark.parametrize("container", [None, "ogg"])
def test_an_item_without_a_known_demuxer_is_never_decoded(world, db, music, container):
    commit, final = _hp(db, music)
    item = item_row(db, commit)
    detected = {**json.loads(item["detected_metadata"]), "container": container}
    sql(db, "UPDATE upload_items SET detected_metadata = ? WHERE owner_id = ? AND item_uuid = ?",
        (json.dumps(detected), commit["owner_id"], commit["item_uuid"]))
    exact = FakeExact()

    world.recover(compute_exact=exact)

    assert_back_in_review(db, commit, final, b"audio-A")
    assert exact.calls == []


# ── only when the work file is proven gone, only a regular file in the root ─

def test_with_the_work_file_present_the_audio_is_never_consulted(world, db, music):
    """A matching file at the final name that is not the work file's own link
    while the work file is still there: the placement is retried, the name is
    taken, the commit fails as before; the file is never decoded or taken."""
    commit, final = _hp(db, music)
    commit["work"].write_bytes(b"audio-A")
    exact = FakeExact()

    world.recover(compute_exact=exact)

    assert final not in _decoded(exact)
    assert_back_in_review(db, commit, final, b"audio-A")


def test_a_symlink_at_the_final_name_is_not_ours_and_not_followed(world, db, music):
    root = library_root(db, music, 1)
    target = root / "elsewhere.flac"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(b"audio-A")
    commit, final = _hp(db, music, final_bytes=None)
    final.symlink_to(target)
    exact = FakeExact()

    world.recover(compute_exact=exact)

    assert exact.calls == []
    assert final.is_symlink() and target.read_bytes() == b"audio-A"
    assert_back_in_review(db, commit, final, None)


def test_a_final_name_outside_the_owners_root_is_never_opened(world, db, music, tmp_path):
    outside = tmp_path / "elsewhere" / "Airbag.flac"
    commit, final = _hp(db, music, final=outside)
    exact = FakeExact()

    world.recover(compute_exact=exact)

    assert exact.calls == []
    assert outside.read_bytes() == b"audio-A"
    assert track_row(db, commit["track"]) is None
    assert item_row(db, commit)["state"] != "imported"


# ── the commit worker's in-process retry keeps today's proofs ──────────────

def test_the_runtime_retry_never_decodes(db, music, monkeypatch):
    commit, final = _hp(db, music)
    exact = FakeExact()
    monkeypatch.setattr(upload_recovery.audio_identity, "compute_exact", exact)
    worker = make_commit_worker(db, music, exact=exact, after_prepared=make_publisher(db, music))
    worker._unrecorded[(commit["owner_id"], commit["op"])] = 0  # an outcome this process could not record

    worker.process_one()

    assert exact.calls == []
    assert_back_in_review(db, commit, final, b"audio-A")


def test_advance_if_placed_without_the_audio_check_leaves_the_journal(db, music):
    commit, _final = _hp(db, music)

    row = upload_recovery.advance_if_placed(
        db, journal(db, commit), uploads_root=music / ".uploads", music_library_dir=music)

    assert row["state"] == "prepared" and journal(db, commit)["state"] == "prepared"


# ── review r1 (s7-live-findings-review.md) ──────────────────────────────────

@pytest.mark.parametrize("digest_check", ["computed", "changed"])
def test_every_checked_digest_state_finishes_the_import(world, db, music, digest_check):
    """S7LF-R-04a: the stored digest is the work file's in all three checked states."""
    commit, final = _hp(db, music, digest_check=digest_check)

    world.recover(compute_exact=FakeExact())

    assert item_row(db, commit)["state"] == "imported"
    assert track_row(db, commit["track"])["file_path"] == str(final)


@pytest.mark.requires_chmod_denial
def test_a_final_the_server_cannot_open_is_unknown_not_other_audio(world, db, music, caplog):
    """S7LF-R-01: ffprobe on a file it cannot open exits non-zero, which reads as
    a decode error (the file's content). A final that cannot be opened proves
    nothing either way: it is never decoded and everything stays."""
    commit, final = _hp(db, music)
    exact = FakeExact()
    exact.result = ExactUnavailable("failed", "decode_error")  # what ffprobe would answer
    final.chmod(0)
    try:
        lines = _recover(world, exact, caplog)
        assert exact.calls == []
        assert any("could not be checked" in line and "EACCES" in line for line in lines)
    finally:
        final.chmod(0o644)
    assert_untouched(db, commit, final, b"audio-A")


def test_a_symlink_loop_above_the_final_is_not_ours_and_never_raises(world, db, music, caplog):
    """S7LF-R-02: resolving a final whose folder is a symlink loop raises; the
    final cannot be this import's, so the item goes back to review. The folder
    on the way is a link below the library folder, so the refusal is for good."""
    commit, _ = _hp(db, music, final_bytes=None)
    root = library_root(db, music, commit["owner_id"])
    (root / "a").symlink_to(root / "b")
    (root / "b").symlink_to(root / "a")
    looped = root / "a" / "Airbag.flac"
    sql(db, "UPDATE upload_commit_journal SET final_path = ? WHERE owner_id = ? AND operation_uuid = ?",
        (str(looped), commit["owner_id"], commit["op"]))
    exact = FakeExact()

    world.recover(compute_exact=exact)

    assert exact.calls == []
    item = item_row(db, commit)
    assert (item["state"], item["error_code"]) == ("review_ready", "upload_library_changed")
    assert track_row(db, commit["track"]) is None


def test_a_database_error_while_preparing_the_check_is_unknown(world, db, music, monkeypatch, caplog):
    """S7LF-R-03: reading the item's demuxer fails: the operator is told it could
    not be checked; nothing changes."""
    import sqlite3

    commit, final = _hp(db, music)

    def broken(*args, **kwargs):
        raise sqlite3.OperationalError("database is locked")

    monkeypatch.setattr(db, "get_upload_item", broken)
    lines = _recover(world, FakeExact(), caplog)
    monkeypatch.undo()

    assert any("could not be checked" in line and "/" not in line for line in lines)
    assert_untouched(db, commit, final, b"audio-A")


def test_a_decoder_that_raises_is_unknown(world, db, music, caplog):
    """S7LF-R-04b."""
    commit, final = _hp(db, music)
    exact = FakeExact()
    exact.result = RuntimeError("the decoder broke")

    lines = _recover(world, exact, caplog)

    assert_untouched(db, commit, final, b"audio-A")
    [line] = lines
    assert "could not be checked" in line and "RuntimeError" in line


def test_an_adopted_final_that_meets_a_duplicate_in_the_transaction_is_removed_as_ours(world, db, music):
    """S7LF-R-04c: once proven, the final is this import's own file: a duplicate
    found by the insert transaction removes it, as for any moved journal."""
    from tests.upload_publish_fixtures import library_track

    commit, final = _hp(db, music)
    winner = library_track(db, music, b"audio-A")

    world.recover(compute_exact=FakeExact())

    assert item_row(db, commit)["state"] == "duplicate_conflict"
    assert not os.path.lexists(final)
    assert track_row(db, commit["track"]) is None
    assert track_row(db, winner) is not None


def test_no_name_and_audio_line_for_a_final_proven_by_its_own_link(world, db, caplog):
    """S7LF-R-04d."""
    commit = world.crash_at("after_link")
    lines = _recover(world, FakeExact(), caplog)

    assert item_row(db, commit)["state"] == "imported"
    assert [line for line in lines if "name and audio" in line] == []


def test_a_final_rewritten_in_place_while_it_is_checked_is_unknown(world, db, music, caplog):
    """S7LF-R-04e: same inode, other size and time."""
    commit, final = _hp(db, music)

    class Appends(FakeExact):
        def __call__(self, path, codec_hint, **kwargs):
            answer = super().__call__(path, codec_hint, **kwargs)
            with open(final, "ab") as f:
                f.write(b"!")
            return answer

    lines = _recover(world, Appends(), caplog)

    assert_untouched(db, commit, final, b"audio-A!")
    assert any("could not be checked" in line for line in lines)
