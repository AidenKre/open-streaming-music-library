"""7A.2d S4 (spec §5 "on archive-wide structural/quota failure mark parent
failed and remove unpublished derived data. Use stream counters ... fail on
CRC/corruption. Separate transport error, invalid audio, invalid archive,
quota, probe-timeout and disk failures. Clean temporary work."; §3 "handle
ENOSPC at every write anyway"): any failure after the manifest exists fails
the parent, deletes the children rows and every staged child file, and
carries no path or member name in its message."""

import errno
import stat
import zipfile

import pytest

from tests.identity_worker_fixtures import make_db, sql
from tests.upload_validation_fixtures import item_row, source_rows
from tests.upload_zip_fixtures import (
    Entry, FailingFiles, children_of, corrupt_local_name, corrupt_member_data, files_under,
    make_expander, make_ledger, stage_zip, tiny_limits, zip_worker,
)

ONE, TWO = "one-secret.flac", "two-secret.flac"
DATA = bytes(range(60))


@pytest.fixture
def db(tmp_path):
    return make_db(tmp_path)


@pytest.fixture
def root(tmp_path):
    path = tmp_path / "music" / ".uploads"
    path.mkdir(parents=True)
    return path


def two(extra=()):
    return [Entry(ONE, DATA), Entry(TWO, DATA[::-1]), *extra]


def expect_failed(db, root, tmp_path, staged, code, retryable):
    row = item_row(db, staged)
    assert (row["state"], row["error_code"], row["error_retryable"]) == ("failed", code, int(retryable))
    assert row["skipped_members"] is None and row["lease_boot_id"] is None
    assert children_of(db, staged) == []
    assert sql(db, "SELECT * FROM storage_reservations WHERE purpose = 'upload_expand'") == []
    msg = row["error_message"] or ""
    assert "/" not in msg and str(tmp_path) not in msg and "secret" not in msg
    sources = source_rows(db, staged)
    if retryable:
        assert files_under(root) == {staged["source"]}
        assert row["source_path"] == str(staged["source"])
        assert [r["purpose"] for r in sources] == ["upload_source"]
    else:
        assert files_under(root) == set()
        assert row["source_path"] is None and sources == []


def run(db, root, tmp_path, staged_entries=None, *, limits=None, ledger=None, files=None, staged=None):
    staged = staged or stage_zip(db, root, tmp_path, staged_entries)
    expander = make_expander(db, root, tmp_path, limits=limits, ledger=ledger, files=files)
    zip_worker(db, root, tmp_path, expander=expander).process_one()
    return staged


@pytest.mark.parametrize("entries,code", [
    ([Entry("../" + ONE, DATA)], "upload_archive_unsafe_path"),
    ([Entry(ONE, DATA), Entry("in-secret.zip", b"x")], "upload_archive_nested"),
    ([Entry(ONE, DATA, external_attr=(stat.S_IFLNK | 0o777) << 16)], "upload_archive_unsafe_member"),
    ([Entry(ONE, DATA, flag_bits=1)], "upload_archive_encrypted"),
    ([Entry(ONE, DATA), Entry(ONE.upper(), DATA)], "upload_archive_duplicate_names"),
    ([Entry(f"{i}-secret.flac", DATA) for i in range(5)], "upload_archive_too_many_audio"),
    ([Entry(ONE, bytes(2000))], "upload_archive_member_too_large"),
], ids=["traversal", "nested", "symlink", "encrypted", "duplicate", "too-many-audio", "too-large"])
def test_inspection_rejections_end_to_end(db, root, tmp_path, entries, code):
    staged = run(db, root, tmp_path, entries)
    expect_failed(db, root, tmp_path, staged, code, False)


def test_crc_failure_on_second_member(db, root, tmp_path):
    staged = stage_zip(db, root, tmp_path, two())
    corrupt_member_data(staged["source"], TWO)
    run(db, root, tmp_path, staged=staged)
    expect_failed(db, root, tmp_path, staged, "upload_archive_corrupt", False)


def test_bad_zip_file_on_open_of_second_member(db, root, tmp_path):
    staged = stage_zip(db, root, tmp_path, two())
    corrupt_local_name(staged["source"], TWO)
    with pytest.raises(zipfile.BadZipFile):
        with zipfile.ZipFile(staged["source"]) as zf:
            zf.open(TWO)
    run(db, root, tmp_path, staged=staged)
    expect_failed(db, root, tmp_path, staged, "upload_archive_corrupt", False)


def test_insufficient_free_space(db, root, tmp_path):
    staged = run(db, root, tmp_path, two(), ledger=make_ledger(db, tmp_path, free=10))
    expect_failed(db, root, tmp_path, staged, "insufficient_storage", True)


def test_user_quota(db, root, tmp_path):
    staged = stage_zip(db, root, tmp_path, two())
    size = staged["source"].stat().st_size
    run(db, root, tmp_path, staged=staged, limits=tiny_limits(user_staged_quota_bytes=size + 10))
    expect_failed(db, root, tmp_path, staged, "user_staged_quota_exceeded", True)


@pytest.mark.parametrize("op,exc,code", [
    ("write_block", OSError(errno.ENOSPC, "No space"), "insufficient_storage"),
    ("write_block", OSError(errno.EDQUOT, "Quota"), "insufficient_storage"),
    ("rename", OSError(errno.EIO, "io"), "upload_write_failed"),
    ("write_block", RuntimeError("boom"), "upload_validation_failed"),
], ids=["enospc", "edquot", "eio-rename", "runtime"])
def test_write_failures(db, root, tmp_path, op, exc, code):
    staged = run(db, root, tmp_path, two(), files=FailingFiles(op, exc))
    expect_failed(db, root, tmp_path, staged, code, True)


def _two_archives(db, root, tmp_path, limits, second_n):
    batch = "c3000000-0000-4000-8000-000000000001"
    first = stage_zip(db, root, tmp_path, [Entry(f"a{i}-secret.flac", bytes([i]) * 100) for i in range(3)],
                      batch_uuid=batch)
    second = stage_zip(db, root, tmp_path, [Entry(f"b{i}-secret.flac", bytes([9 - i]) * 100) for i in range(second_n)],
                       batch_uuid=batch)
    worker = zip_worker(db, root, tmp_path, expander=make_expander(db, root, tmp_path, limits=limits))
    assert worker.process_one() == "expanded"
    kids = children_of(db, first)
    files = files_under(root)
    worker.process_one()
    return first, second, kids, files


@pytest.mark.parametrize("limits,second_n,code", [
    (tiny_limits(), 2, "upload_archive_too_many_audio"),
    (tiny_limits(max_audio_items_per_batch=10, max_expanded_bytes_per_batch=400), 2,
     "upload_archive_expanded_too_large"),
], ids=["audio", "expanded-bytes"])
def test_second_archive_fails_first_untouched(db, root, tmp_path, limits, second_n, code):
    first, second, kids, files_before = _two_archives(db, root, tmp_path, limits, second_n)
    row = item_row(db, second)
    assert (row["state"], row["error_code"], row["error_retryable"]) == ("failed", code, 0)
    assert children_of(db, second) == [] and row["source_path"] is None
    assert children_of(db, first) == kids
    assert item_row(db, first)["state"] == "expanded"
    assert files_under(root) == files_before - {second["source"]}
    assert "/" not in row["error_message"] and "secret" not in row["error_message"]
    assert sql(db, "SELECT * FROM storage_reservations WHERE purpose = 'upload_expand'") == []


@pytest.mark.parametrize("outcome", ["stale", "raises"])
def test_a_flip_that_does_not_land_leaves_no_staged_child_file(db, root, tmp_path, monkeypatch, outcome):
    """The children's files are only trusted while their rows say so: if the
    publishing transaction does not commit (guard lost, or the database
    fails), the staged files are removed before the step ends."""
    staged = stage_zip(db, root, tmp_path, two())

    def flip(**kw):
        if outcome == "raises":
            raise RuntimeError("database is locked")
        return False

    monkeypatch.setattr(db, "finish_upload_expansion", flip)
    run(db, root, tmp_path, staged=staged)
    assert files_under(root) == {staged["source"]}
    assert sql(db, "SELECT * FROM storage_reservations WHERE purpose = 'upload_expand'") == []


def test_a_passing_read_error_while_inspecting_keeps_the_upload_for_a_retry(db, root, tmp_path, monkeypatch):
    """U11-B-03: an I/O error while reading the archive's directory is not a
    refusal of the archive: the item fails retryable and keeps its staged copy."""
    staged = stage_zip(db, root, tmp_path, two())
    real = zipfile._EndRecData
    failed = []

    def fails_once(fp):
        if not failed:
            failed.append(True)
            raise OSError(errno.EIO, "io")
        return real(fp)

    monkeypatch.setattr(zipfile, "_EndRecData", fails_once)
    run(db, root, tmp_path, staged=staged)

    assert failed
    expect_failed(db, root, tmp_path, staged, "upload_validation_failed", True)
