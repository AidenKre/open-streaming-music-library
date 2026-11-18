"""7A.3c S3 (spec §6: "Prepared/final file + no committed track means resume
the same commit from frozen metadata after validation ... Missing/corrupt file
means safe failure with source retained for retry; no dangling library row";
7-U07): before resuming, the startup step checks the file it would publish
(the work file of a ``prepared`` journal, the final file of a ``moved`` one):
a regular file whose exact audio digest still equals the journaled one. A
missing or corrupt file ends the commit as a retryable failure (journal
``failed``, item back at review with a new version), removes only this
operation's own file and keeps the staged source and its quota row."""

import errno
import os
import shutil
import sqlite3
import subprocess
from pathlib import Path

import pytest

from app.services import audio_identity, upload_recovery
from app.services.audio_identity import ExactUnavailable
from app.services.upload_publish import SimulatedCrash
from tests.identity_worker_fixtures import make_db, sql
from tests.upload_commit_fixtures import (
    FakeExact, accept, journal, make_commit_worker, ready_item, reservations,
)
from tests.upload_publish_fixtures import RecordingSeam, track_row
from tests.upload_recovery_fixtures import World
from tests.upload_validation_fixtures import item_row


@pytest.fixture
def db(tmp_path):
    return make_db(tmp_path)


@pytest.fixture
def music(tmp_path):
    path = tmp_path / "music"
    (path / ".uploads").mkdir(parents=True)
    return path


@pytest.fixture
def world(db, music):
    return World(db, music)


def assert_safe_failure(world, commit, *, version_before: int, final_kept: bool):
    db = world.db
    row = journal(db, commit)
    assert row["state"] == "failed"
    assert (row["final_path"] is not None) == final_kept
    item = item_row(db, commit)
    assert item["state"] == "review_ready"
    assert item["review_version"] == version_before + 1
    assert item["error_code"] == "upload_commit_failed"
    assert item["error_retryable"] == 1
    # The staged source stays for a retry, with its quota row.
    assert commit["source"].read_bytes() == commit["content"]
    assert item["source_path"] == str(commit["source"])
    assert [r["purpose"] for r in reservations(db, commit["owner_id"])].count("upload_source") == 1
    # No dangling library row.
    assert track_row(db, commit["track"]) is None
    assert sql(db, "SELECT count(*) AS n FROM tracks")[0]["n"] == 0


def _version(world, commit) -> int:
    return item_row(world.db, commit)["review_version"]


def test_a_prepared_journal_whose_work_file_is_gone_fails_safely(world):
    commit = world.crash_at("before_link")
    before = _version(world, commit)
    final = journal(world.db, commit)["final_path"]
    os.unlink(commit["work"])

    world.recover()

    assert_safe_failure(world, commit, version_before=before, final_kept=False)
    assert not os.path.lexists(final)


@pytest.mark.parametrize("damage", ["changed", "truncated", "empty"])
def test_a_prepared_journal_whose_work_file_is_corrupt_fails_safely(world, damage):
    commit = world.crash_at("before_link")
    before = _version(world, commit)
    final = journal(world.db, commit)["final_path"]
    data = commit["content"]
    commit["work"].write_bytes({"changed": data + b"!", "truncated": data[:3], "empty": b""}[damage])

    world.recover()

    assert_safe_failure(world, commit, version_before=before, final_kept=False)
    assert not os.path.lexists(final)
    assert not commit["work"].exists()  # this operation's own work copy is removed


def test_a_corrupt_work_file_already_linked_to_the_final_name_is_removed_under_both(world):
    commit = world.crash_at("after_link")
    before = _version(world, commit)
    final = journal(world.db, commit)["final_path"]
    with open(commit["work"], "r+b") as f:  # one inode, both names see it
        f.write(b"XX")

    world.recover()

    assert_safe_failure(world, commit, version_before=before, final_kept=True)
    assert not os.path.lexists(final)
    assert not commit["work"].exists()


@pytest.mark.parametrize("damage", ["changed", "missing"])
def test_a_moved_journal_whose_final_file_is_missing_or_corrupt_fails_safely(world, damage):
    commit = world.crash_at("after_work_unlink")
    before = _version(world, commit)
    final = journal(world.db, commit)["final_path"]
    if damage == "missing":
        os.unlink(final)
    else:
        with open(final, "ab") as f:
            f.write(b"!")

    world.recover()

    assert_safe_failure(world, commit, version_before=before, final_kept=True)
    assert not os.path.lexists(final)


# Review r2 7-R2-01 (coordinator decision; narrows 7-R1-09b, replaces its
# tests "…continues_the_commit_unverified" and "…crash_after_the_journal_says_
# unverified…"): when the journal carries a reference digest, why the digest
# could not be recomputed decides. The file's own content (it no longer
# decodes) is a mismatch: the existing safe failure, the staged source kept.
# The tool or the run (anything that says nothing about the file, and any
# reason not recognised) is unknown: nothing is touched until a later start.
CONTENT_REASONS = ["decode_error", "probe_error", "output_error", "master_missing"]
UNKNOWN_REASONS = ["tool_missing", "timeout", "killed", "internal_error", "a_reason_added_later", None]
POINTS = ("before_link", "after_link", "after_work_unlink")


@pytest.mark.parametrize("point, reason", [
    *[(point, "decode_error") for point in POINTS],
    *[("before_link", reason) for reason in CONTENT_REASONS if reason != "decode_error"],
])
def test_a_file_that_no_longer_decodes_is_a_mismatch_and_keeps_the_source(world, point, reason):
    commit = world.crash_at(point)
    before = _version(world, commit)
    final = journal(world.db, commit)["final_path"]
    exact = FakeExact()
    exact.result = ExactUnavailable("failed", reason)

    world.recover(compute_exact=exact)

    # A placed final (own link, or moved) is recorded and removed as this operation's own.
    assert_safe_failure(world, commit, version_before=before, final_kept=point != "before_link")
    assert not os.path.lexists(final)
    assert not commit["work"].exists()

    world.recover(compute_exact=exact)  # restart twice: the clean failed journal goes, nothing else
    world.recover(compute_exact=exact)

    item = item_row(world.db, commit)
    assert (item["state"], item["review_version"]) == ("review_ready", before + 1)
    assert commit["source"].read_bytes() == commit["content"]
    assert sql(world.db, "SELECT count(*) AS n FROM tracks")[0]["n"] == 0


def _snapshot(world, commit) -> dict:
    final = journal(world.db, commit)["final_path"]
    files = {}
    for name, path in (("work", commit["work"]), ("final", final), ("source", commit["source"])):
        files[name] = Path(path).read_bytes() if path and os.path.lexists(path) else None
    row = journal(world.db, commit)
    item = item_row(world.db, commit)
    return {
        "journal": {k: row[k] for k in ("digest_check", "final_path", "error_code", "exact_digest",
                                        "cover_art_id", "cover_art_created")},
        "item": {k: item[k] for k in ("state", "review_version", "error_code", "source_path")},
        "files": files,
        "reservations": [dict(r) for r in reservations(world.db, commit["owner_id"])],
        "tracks": sql(world.db, "SELECT count(*) AS n FROM tracks")[0]["n"],
        # Review r3 7-R3-11: the commit's cover art (A), rows and files.
        "art": [dict(r) for r in sql(world.db, "SELECT * FROM cover_arts ORDER BY id")],
        "art_files": sorted((str(p.relative_to(art)), p.read_bytes())
                            for art in [world.music.parent / "art"] if art.exists()
                            for p in art.rglob("*") if p.is_file()),
    }


@pytest.mark.parametrize("point, reason", [
    *[(point, "timeout") for point in POINTS],
    *[("before_link", reason) for reason in UNKNOWN_REASONS if reason != "timeout"],
])
def test_a_digest_the_tool_could_not_give_leaves_everything_for_the_next_start(world, point, reason, caplog):
    """Unknown is never "different" and never a reason to publish unchecked: the
    journal, the item and every file stay as they are (only a link already
    proven to be the operation's own is recorded as moved, a fact), one operator
    line per start says so, and the commit finishes once the digest can be checked."""
    commit = world.crash_at(point)
    exact = FakeExact()
    exact.result = ExactUnavailable("failed", reason)
    before = _snapshot(world, commit)
    assert before["art"] and before["art_files"]  # the commit made art: its release would show
    state = "prepared" if point == "before_link" else "moved"

    for _ in range(3):  # restart three times: nothing changes
        caplog.clear()
        with caplog.at_level("WARNING", logger="uvicorn.error"):
            world.recover(compute_exact=exact)
        assert journal(world.db, commit)["state"] == state
        assert _snapshot(world, commit) == before
        assert item_row(world.db, commit)["state"] == "committing"
        operator = [r.getMessage() for r in caplog.records if r.name == "uvicorn.error"]
        assert len(operator) == 1
        assert "could not be checked" in operator[0] and "/" not in operator[0]

    world.recover()  # the tool is back: the same digest, the commit finishes

    assert item_row(world.db, commit)["state"] == "imported"
    published = track_row(world.db, commit["track"])
    assert published is not None and os.path.isfile(published["file_path"])
    assert sql(world.db, "SELECT count(*) AS n FROM tracks")[0]["n"] == 1
    assert not commit["source"].exists()


@pytest.fixture(scope="module")
def real_flac(tmp_path_factory) -> Path:
    """One real 2 s FLAC, made once per module; each test copies it."""
    path = tmp_path_factory.mktemp("real_flac") / "real.flac"
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "sine=duration=2",
                    "-c:a", "flac", str(path)], check=True)
    return path


def _real_commit(world, tmp_path, point, real_flac):
    """A commit prepared with the real exact digest of a real FLAC, crashed at ``point``."""
    copy = tmp_path / "real.flac"
    shutil.copyfile(real_flac, copy)
    content = copy.read_bytes()
    staged = ready_item(world.db, world.music / ".uploads", content=content)
    commit = accept(world.db, staged)
    seam = RecordingSeam(crash_at=point)
    def real_exact(path, codec_hint, *, input_format=None, **_process_kwargs):
        return audio_identity.compute_exact(path, codec_hint, input_format=input_format)

    worker = make_commit_worker(world.db, world.music, exact=real_exact,
                                after_prepared=world.publisher(seam), seam=seam)
    with pytest.raises(SimulatedCrash):
        worker.process_one()
    assert journal(world.db, commit)["digest_check"] in ("verified", "computed", "changed")
    return commit


def _flac_audio_start(data: bytes) -> int:
    """Offset of the first audio frame: after ``fLaC`` and the metadata blocks."""
    assert data[:4] == b"fLaC"
    offset, last = 4, False
    while not last:
        last = bool(data[offset] & 0x80)
        offset += 4 + int.from_bytes(data[offset + 1:offset + 4], "big")
    return offset


def _damaged(data: bytes, damage: str) -> bytes:
    if damage == "truncated":
        return data[: len(data) // 3]
    if damage == "zeroed":
        return b"\0" * len(data)
    # frames_undecodable: the stream header (STREAMINFO, all the probe reads)
    # now says 24 bits per sample while every frame says 16, so the probe
    # succeeds and each frame fails to decode.
    assert data[4] & 0x7F == 0  # STREAMINFO is the first metadata block
    out = bytearray(data)
    bps = 24 - 1  # 5 bits: the low bit of byte 12, the high nibble of byte 13
    out[8 + 12] = (out[8 + 12] & 0xFE) | (bps >> 4)
    out[8 + 13] = (out[8 + 13] & 0x0F) | ((bps & 0x0F) << 4)
    return bytes(out)


# Review r3 7-R3-04: each damage is pinned to the branch it takes, checked with
# the real tools before the restart. A file cut short still decodes (exit 0) to
# a different digest: the plain mismatch path. A zeroed file fails the probe
# (``probe_error``); a file whose frames fail to decode makes ffmpeg exit non-zero
# (``decode_error``). The last two reach the content-reason branch of 7-R2-01.
@pytest.mark.requires_ffmpeg
@pytest.mark.parametrize("damage, reason", [
    ("truncated", None), ("zeroed", "probe_error"), ("frames_undecodable", "decode_error")])
@pytest.mark.parametrize("point", ["before_link", "after_work_unlink"])
def test_a_damaged_real_flac_fails_safely_and_keeps_the_good_source(world, tmp_path, real_flac, point, damage, reason):
    """The reviewer's case with the real decoder (FakeExact hashes raw bytes, so
    it cannot show which reason a damaged file really gives): the placed file is
    damaged before the restart; it is never published and S stays for a retry."""
    commit = _real_commit(world, tmp_path, point, real_flac)
    before = _version(world, commit)
    row = journal(world.db, commit)
    target = Path(row["work_path"] if point == "before_link" else row["final_path"])
    target.write_bytes(_damaged(target.read_bytes(), damage))

    found = audio_identity.compute_exact(target, "flac", input_format="flac")
    if reason is None:
        assert isinstance(found, audio_identity.ExactAudioHash)
        assert found.digest != row["exact_digest"]
    else:
        assert found == ExactUnavailable("failed", reason)

    world.recover(compute_exact=audio_identity.compute_exact)

    assert_safe_failure(world, commit, version_before=before, final_kept=point != "before_link")
    assert not target.exists()


@pytest.mark.requires_ffmpeg
def test_an_intact_real_flac_is_checked_and_published(world, tmp_path, real_flac):
    """Control for the test above: the same real digest recomputed is equal."""
    commit = _real_commit(world, tmp_path, "after_work_unlink", real_flac)

    world.recover(compute_exact=audio_identity.compute_exact)

    assert item_row(world.db, commit)["state"] == "imported"
    assert not commit["source"].exists()


def test_an_unverified_digest_is_not_rechecked_and_the_commit_resumes(world):
    """digest_check 'unverified': the journaled digest is the staged one, not
    the work file's, so only the file's presence is checked."""
    commit = world.crash_at("before_link")
    sql(world.db, "UPDATE upload_commit_journal SET digest_check = 'unverified'"
                  " WHERE owner_id = ? AND operation_uuid = ?", (commit["owner_id"], commit["op"]))
    commit["work"].write_bytes(commit["content"] + b"-tags")
    exact = FakeExact()

    world.recover(compute_exact=exact)

    assert item_row(world.db, commit)["state"] == "imported"
    assert exact.calls == []


def test_a_matching_work_file_is_checked_and_resumed(world):
    commit = world.crash_at("before_link")
    exact = FakeExact()

    world.recover(compute_exact=exact)

    assert item_row(world.db, commit)["state"] == "imported"
    assert [c["path"] for c in exact.calls] == [commit["work"]]
    assert exact.calls[0]["codec_hint"] == "flac"


def test_a_safe_failure_is_recorded_once_across_restarts(world):
    commit = world.crash_at("before_link")
    before = _version(world, commit)
    commit["work"].write_bytes(b"garbage")

    world.restart()
    assert_safe_failure(world, commit, version_before=before, final_kept=False)
    world.restart()

    # 7A.3c S4: the clean failed journal is then deleted; nothing else changes.
    assert sql(world.db, "SELECT count(*) AS n FROM upload_commit_journal")[0]["n"] == 0
    item = item_row(world.db, commit)
    assert (item["state"], item["review_version"]) == ("review_ready", before + 1)
    assert commit["source"].read_bytes() == commit["content"]
    assert track_row(world.db, commit["track"]) is None


def test_a_final_path_another_track_now_names_is_never_removed(world):
    """A moved journal's final file that a track names (any owner) is not this
    operation's to remove, even when the check fails."""
    commit = world.crash_at("after_work_unlink")
    final = journal(world.db, commit)["final_path"]
    with open(final, "ab") as f:
        f.write(b"!")
    from tests.identity_worker_fixtures import add_track
    add_track(world.db, final)

    world.recover()

    assert journal(world.db, commit)["state"] == "failed"
    assert os.path.isfile(final)


def test_the_recovery_check_forces_the_probed_demuxer(world):
    """Review r1 7-R1-18: the startup digest check runs on staged upload bytes
    (the work or final file) and opens only that file."""
    commit = world.crash_at("before_link")
    exact = FakeExact()

    world.recover(compute_exact=exact)

    assert exact.calls and all(c.get("input_format") == "flac" for c in exact.calls)
    assert journal(world.db, commit)["state"] == "imported"


def test_the_identity_code_classifies_its_own_failure_reasons():
    """One place says which reasons are about the file's content; anything
    else, including a reason added later, is about the tool or the run."""
    from app.services import identity_reasons

    for reason in CONTENT_REASONS:
        assert identity_reasons.is_content_failure(reason) is True
    for reason in UNKNOWN_REASONS:
        assert identity_reasons.is_content_failure(reason) is False


# Review r2 7-R2-08: an exception while checking is unknown, not "invalid";
# only a completed check (missing, not regular, empty, different) may remove.
def _failing_lstat(target: Path, err: int):
    real = os.lstat

    def lstat(path, *args, **kwargs):
        if Path(path) == target:
            raise OSError(err, os.strerror(err))
        return real(path, *args, **kwargs)

    return lstat


@pytest.mark.parametrize("err", [errno.EIO, errno.EACCES])
@pytest.mark.parametrize("point", ["before_link", "after_work_unlink"])
def test_a_file_that_cannot_be_examined_is_left_for_the_next_start(world, monkeypatch, caplog, point, err):
    commit = world.crash_at(point)
    row = journal(world.db, commit)
    target = Path(row["work_path"] if point == "before_link" else row["final_path"])
    before = _snapshot(world, commit)
    monkeypatch.setattr(upload_recovery.os, "lstat", _failing_lstat(target, err))

    with caplog.at_level("WARNING", logger="uvicorn.error"):
        world.recover()
    monkeypatch.undo()  # the snapshot reads the files through lstat too

    assert journal(world.db, commit)["state"] == row["state"]
    assert _snapshot(world, commit) == before
    assert item_row(world.db, commit)["state"] == "committing"
    assert len([r for r in caplog.records if r.name == "uvicorn.error"]) == 1

    world.recover()  # readable again: the commit finishes
    assert item_row(world.db, commit)["state"] == "imported"


def test_a_database_error_while_checking_is_left_for_the_next_start(world, monkeypatch, caplog):
    commit = world.crash_at("after_work_unlink")
    before = _snapshot(world, commit)

    def busy(*args, **kwargs):
        raise sqlite3.OperationalError("database is locked")

    monkeypatch.setattr(world.db, "get_upload_item", busy)
    with caplog.at_level("WARNING", logger="uvicorn.error"):
        world.recover()
    monkeypatch.undo()

    assert journal(world.db, commit)["state"] == "moved"
    assert _snapshot(world, commit) == before
    assert item_row(world.db, commit)["state"] == "committing"
    # Review r3 7-R3-08: classified by the check itself (the operator line), not
    # merely swallowed by the per-row guard.
    [line] = [r.getMessage() for r in caplog.records if r.name == "uvicorn.error"]
    assert "OperationalError" in line and f"user {commit['owner_id']}" in line


@pytest.mark.requires_ffmpeg
@pytest.mark.skipif(hasattr(os, "geteuid") and os.geteuid() == 0,
                    reason="root ignores mode bits, so chmod(0) cannot deny the read (review r3 7-R3-06)")
@pytest.mark.parametrize("point", ["before_link", "after_work_unlink"])
def test_a_placed_file_the_server_cannot_read_is_unknown_not_damaged(world, tmp_path, real_flac, point, caplog):
    """In-piece review F1: the decoder reports an unreadable file (EACCES) as a
    decode error; recovery reads the file itself first, so a file it cannot
    open says nothing about its content and is left for the next start."""
    commit = _real_commit(world, tmp_path, point, real_flac)
    row = journal(world.db, commit)
    target = Path(row["work_path"] if point == "before_link" else row["final_path"])
    target.chmod(0)
    try:
        with caplog.at_level("WARNING", logger="uvicorn.error"):
            world.recover(compute_exact=audio_identity.compute_exact)
    finally:
        if target.exists():
            target.chmod(0o644)

    assert journal(world.db, commit)["state"] == row["state"]
    assert item_row(world.db, commit)["state"] == "committing"
    assert target.is_file() and commit["source"].read_bytes() == commit["content"]
    [line] = [r.getMessage() for r in caplog.records if r.name == "uvicorn.error"]
    assert f"user {commit['owner_id']}" in line and "/" not in line

    world.recover(compute_exact=audio_identity.compute_exact)  # readable again: published
    assert item_row(world.db, commit)["state"] == "imported"


def test_the_operator_line_names_the_user_and_the_reason(world, caplog):
    """In-piece review F4: the operator can tell which commit waits, and why."""
    commit = world.crash_at("before_link")
    exact = FakeExact()
    exact.result = ExactUnavailable("failed", "tool_missing")

    with caplog.at_level("WARNING", logger="uvicorn.error"):
        world.recover(compute_exact=exact)

    [line] = [r.getMessage() for r in caplog.records if r.name == "uvicorn.error"]
    assert f"user {commit['owner_id']}" in line and "tool_missing" in line and "/" not in line


# Review r3 7-R3-01: the own-link proof taken before the check reads "could not
# examine the final name" as unknown, never as "not our link" (which would let
# the publisher record "nothing placed" and leave the placed file in the library).
@pytest.mark.parametrize("err", [errno.EACCES, errno.EIO])
def test_a_link_that_cannot_be_examined_is_left_for_the_next_start(world, monkeypatch, caplog, err):
    commit = world.crash_at("after_link")
    row = journal(world.db, commit)
    final = Path(row["final_path"])
    before = _snapshot(world, commit)
    monkeypatch.setattr(upload_recovery.os, "lstat", _failing_lstat(final, err))

    with caplog.at_level("WARNING", logger="uvicorn.error"):
        world.recover()
    monkeypatch.undo()  # the snapshot reads the files through lstat too

    assert journal(world.db, commit)["state"] == "prepared"
    assert _snapshot(world, commit) == before  # final_path kept, W, F and S as they were
    assert final.is_file()
    assert item_row(world.db, commit)["state"] == "committing"
    [line] = [r.getMessage() for r in caplog.records if r.name == "uvicorn.error"]
    assert f"user {commit['owner_id']}" in line and "/" not in line
    assert errno.errorcode[err] in line  # in-piece review F3: the operator learns what to fix

    world.recover()  # the folder can be searched again: the commit finishes
    assert item_row(world.db, commit)["state"] == "imported"
    assert Path(track_row(world.db, commit["track"])["file_path"]) == final


# Review r3 7-R3-02: an error in the journal's own stored data (its frozen
# metadata, its reference identity) is the same at every start: a safe failure
# that keeps the staged source, never "unknown" (which would hold the item in
# ``committing`` for ever). Errors of the tool, the run or the filesystem stay unknown.
BAD_STORED_DATA = [
    ("final_metadata", "{}"),  # KeyError: no codec
    ("final_metadata", "not json"),  # ValueError (JSONDecodeError)
    ("final_metadata", None),  # TypeError: a NULL column
    ("final_metadata", "[1]"),  # TypeError: not an object
    ("exact_digest", ""),  # ValueError: a malformed current identity
]


@pytest.mark.parametrize("codec", [None, "a_codec_nothing_can_hash", 5])
def test_a_journal_codec_the_digest_cannot_use_fails_safely(world, codec):
    """In-piece review F2: the stored codec decides the digest kind; one that
    no digest can use (none, unknown, not text) is the journal's own data and
    the same at every start, so it is a safe failure, never "unknown"."""
    import json

    commit = world.crash_at("before_link")
    before = _version(world, commit)
    sql(world.db, "UPDATE upload_commit_journal SET final_metadata = ?"
                  " WHERE owner_id = ? AND operation_uuid = ?",
        (json.dumps({"codec": codec}), commit["owner_id"], commit["op"]))

    world.recover(compute_exact=audio_identity.compute_exact)  # no tool runs for these codecs

    assert_safe_failure(world, commit, version_before=before, final_kept=False)


@pytest.mark.parametrize("column, value", BAD_STORED_DATA)
@pytest.mark.parametrize("point", ["before_link", "after_work_unlink"])
def test_a_journal_whose_own_data_cannot_be_read_fails_safely_and_keeps_the_source(
        world, point, column, value):
    commit = world.crash_at(point)
    before = _version(world, commit)
    final = journal(world.db, commit)["final_path"]
    sql(world.db, f"UPDATE upload_commit_journal SET {column} = ?"
                  " WHERE owner_id = ? AND operation_uuid = ?", (value, commit["owner_id"], commit["op"]))

    world.recover()

    assert_safe_failure(world, commit, version_before=before, final_kept=point != "before_link")
    assert not os.path.lexists(final)
    world.recover()  # restart twice: nothing more changes
    item = item_row(world.db, commit)
    assert (item["state"], item["review_version"]) == ("review_ready", before + 1)
    assert commit["source"].read_bytes() == commit["content"]


def test_unreadable_metadata_without_a_reference_digest_also_fails_safely(world):
    commit = world.crash_at("before_link")
    before = _version(world, commit)
    sql(world.db, "UPDATE upload_commit_journal SET digest_check = 'unverified', final_metadata = '{}'"
                  " WHERE owner_id = ? AND operation_uuid = ?", (commit["owner_id"], commit["op"]))

    world.recover()

    assert_safe_failure(world, commit, version_before=before, final_kept=False)


@pytest.mark.parametrize("error", [ValueError("x"), KeyError("x"), TypeError("x")])
def test_a_data_error_raised_by_the_tool_side_is_still_unknown(world, error, caplog):
    """Only the journal's own data is classified deterministic: the same
    exception kinds raised while computing the digest say nothing about the row."""
    commit = world.crash_at("before_link")
    before = _snapshot(world, commit)

    def raising(*args, **kwargs):
        raise error

    with caplog.at_level("WARNING", logger="uvicorn.error"):
        world.recover(compute_exact=raising)

    assert journal(world.db, commit)["state"] == "prepared"
    assert _snapshot(world, commit) == before
    assert item_row(world.db, commit)["state"] == "committing"
    assert len([r for r in caplog.records if r.name == "uvicorn.error"]) == 1


def test_the_identity_code_classifies_stored_data_failures():
    """One place says which exceptions mean the stored row itself is wrong."""
    import json

    from app.services import identity_reasons

    for e in (ValueError("x"), json.JSONDecodeError("x", "y", 0), KeyError("x"), TypeError("x"),
              UnicodeDecodeError("utf-8", b"\xff", 0, 1, "x")):
        assert identity_reasons.is_stored_data_failure(e) is True
    for e in (OSError(errno.EIO, "x"), PermissionError(errno.EACCES, "x"), FileNotFoundError(),
              sqlite3.OperationalError("database is locked"), RuntimeError("x"), MemoryError()):
        assert identity_reasons.is_stored_data_failure(e) is False
