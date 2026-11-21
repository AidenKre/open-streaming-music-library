"""The commit's work copy is flushed with the full flush that edits and
conversions use (``durable_fs.fsync_file``: ``F_FULLFSYNC`` on macOS, where a
plain ``fsync`` leaves the data in the drive's cache), on both the copy path
and the tag-writing path, once its bytes are written."""

from pathlib import Path

import pytest

from app.core import durable_fs
from app.services import upload_commit
from tests.upload_commit_fixtures import FakeTagWriter, accept, make_commit_worker, ready_item


@pytest.fixture
def music(tmp_path):
    path = tmp_path / "music"
    (path / ".uploads").mkdir(parents=True)
    return path


@pytest.fixture
def flushed(monkeypatch):
    """Each full flush of the commit: (path, the file's bytes at that moment)."""
    calls = []

    def spy(path):
        calls.append((Path(path), Path(path).read_bytes()))
        durable_fs.fsync_file(path)

    monkeypatch.setattr(upload_commit, "fsync_file", spy, raising=False)
    return calls


def test_the_copied_work_file_gets_the_full_flush(db, music, flushed):
    commit = accept(db, ready_item(db, music / ".uploads", content=b"audio-A"), write_tags=False)

    assert make_commit_worker(db, music).process_one() == "prepared"

    assert flushed == [(commit["work"], b"audio-A")]


def test_the_tag_written_work_file_gets_the_full_flush(db, music, flushed):
    commit = accept(db, ready_item(db, music / ".uploads", content=b"audio-A"), write_tags=True,
                    edits={"title": "New"})

    assert make_commit_worker(db, music, tag_writer=FakeTagWriter(extra=b"+tags")).process_one() \
        == "prepared"

    assert flushed == [(commit["work"], b"audio-A+tags")]
