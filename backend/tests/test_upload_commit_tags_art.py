"""7A.3a S6–S7 (spec §6 step 2: "optionally write tags using shared metadata
writer ... Extract/register embedded artwork through existing CoverArtManager
(`add_album_art_with_status` already reports `was_created`), persist resulting
cover_art_id plus newly-created/shared ownership in the journal, and reference
it in final metadata. ... Re-verify the exact audio digest (SC-25) of the
prepared work file against the staged identity: a tag write must not change
audio. On a mismatch keep the new digest, set the fingerprint to recompute and
log an anomaly; it is not a commit failure."; §4: "`true` writes a **copy of
the staged source** before publication ... The user's original selected file is
never modified"; plan D10: a staged row with a malformed print never reaches
the insert; review 7-U05, 7-U06)."""

import hashlib
import json
import subprocess

import pytest

from app.services.audio_identity import AudioIdentity
from tests.identity_worker_fixtures import make_db, sql
from tests.upload_commit_fixtures import (
    FakeArt,
    FakeCoverArt,
    FakeExact,
    FakeProbe,
    FakeTagWriter,
    accept,
    journal,
    make_commit_worker,
    ready_item,
    sha,
)
from tests.upload_validation_fixtures import DEAD_BOOT, detected


@pytest.fixture
def db(tmp_path):
    return make_db(tmp_path)


@pytest.fixture
def music(tmp_path):
    path = tmp_path / "music"
    (path / ".uploads").mkdir(parents=True)
    return path


def _ready(db, music, **kwargs):
    return ready_item(db, music / ".uploads", **kwargs)


def _art_meta():
    meta = detected()
    meta["has_album_art"] = True
    return meta


# ── S6: tag write on the work copy ──────────────────────────────────────────

def test_write_tags_writes_the_reviewed_fields_into_the_work_copy(db, music):
    commit = accept(db, _ready(db, music, content=b"audio-A"), write_tags=True,
                    edits={"title": "New", "album": None, "year": 1997})
    writer = FakeTagWriter()
    before = sha(commit["source"])

    assert make_commit_worker(db, music, tag_writer=writer).process_one() == "prepared"

    [call] = writer.calls
    assert (call["source"], call["dest"]) == (commit["source"], commit["work"])
    assert call["tags"] == {"title": "New", "album": None, "date": "1997"}
    assert sha(commit["source"]) == before
    assert json.loads(journal(db, commit)["final_metadata"])["title"] == "New"


def test_without_write_tags_the_tag_writer_never_runs(db, music):
    commit = accept(db, _ready(db, music), edits={"title": "New"}, write_tags=False)
    writer = FakeTagWriter()

    make_commit_worker(db, music, tag_writer=writer).process_one()

    assert writer.calls == []
    assert commit["work"].read_bytes() == commit["content"]


def test_write_tags_with_nothing_to_write_is_a_plain_copy(db, music):
    commit = accept(db, _ready(db, music), edits={}, write_tags=True)
    writer = FakeTagWriter()

    assert make_commit_worker(db, music, tag_writer=writer).process_one() == "prepared"

    assert writer.calls == []
    assert commit["work"].read_bytes() == commit["content"]


def test_a_tag_write_reserves_room_for_its_output(db, music):
    commit = accept(db, _ready(db, music, content=b"x" * 1000), write_tags=True, edits={"title": "New"})

    make_commit_worker(db, music).process_one()

    [row] = sql(db, "SELECT bytes, lease_boot_id FROM storage_reservations WHERE purpose = 'upload_work'"
                    " AND subject_ref = ?", (commit["op"],))
    assert row["bytes"] > 1000 and row["lease_boot_id"] is None


def _ffmpeg_flac(path, title):
    subprocess.run(
        ["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=1",
         "-metadata", f"title={title}", "-metadata", "album=Orig album", "-c:a", "flac", str(path)],
        check=True,
    )


def _tags(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-show_format", "-of", "json", str(path)],
                         check=True, capture_output=True).stdout
    return {k.lower(): v for k, v in json.loads(out)["format"].get("tags", {}).items()}


@pytest.mark.requires_ffmpeg
def test_a_real_tag_write_changes_only_the_work_copy_and_keeps_the_audio(db, music, tmp_path):
    from app.services import audio_identity
    from app.services.ffmpeg_runner import FfmpegProcessRegistry
    from app.services.metadata import write_metadata_tags
    from app.services.upload_validation import probe_upload

    original = tmp_path / "user" / "song.flac"  # the user's selected file, as the client read it
    original.parent.mkdir()
    _ffmpeg_flac(original, "Orig")
    user_hash = sha(original)
    content = original.read_bytes()
    meta = probe_upload(original)
    identity = AudioIdentity(exact=audio_identity.compute_exact(original, "flac"),
                             tool_versions="ffmpeg", computed_at=1)
    staged = _ready(db, music, content=content, meta=meta, identity=identity)
    commit = accept(db, staged, write_tags=True, edits={"title": "Tagged", "album": None})

    worker = make_commit_worker(db, music, probe=probe_upload, exact=audio_identity.compute_exact,
                                tag_writer=write_metadata_tags, registry=FfmpegProcessRegistry())
    assert worker.process_one() == "prepared"

    work_tags = _tags(commit["work"])
    assert work_tags.get("title") == "Tagged"
    assert "album" not in work_tags
    assert _tags(commit["source"])["title"] == "Orig"
    assert hashlib.sha256(commit["source"].read_bytes()).hexdigest() == hashlib.sha256(content).hexdigest()
    assert sha(original) == user_hash
    row = journal(db, commit)
    assert row["digest_check"] == "verified"
    final = json.loads(row["final_metadata"])
    assert (final["title"], final["album"], final["codec"]) == ("Tagged", None, "flac")
    assert final["duration"] == pytest.approx(1.0, abs=0.05)


# ── S7: artwork ─────────────────────────────────────────────────────────────

def test_new_artwork_is_registered_and_journaled_as_created(db, music):
    commit = accept(db, _ready(db, music))
    art, covers = FakeArt(b"img"), FakeCoverArt(first_id=500)

    make_commit_worker(db, music, probe=FakeProbe(_art_meta()), art=art, cover_art=covers).process_one()

    row = journal(db, commit)
    assert (row["cover_art_id"], row["cover_art_created"]) == (500, 1)
    final = json.loads(row["final_metadata"])
    assert (final["has_album_art"], final["cover_art_id"]) == (True, 500)
    assert art.calls == [commit["work"]]


def test_the_commit_reads_the_staged_art_through_the_probed_demuxer_only(db, music):
    """Review r2 7-R2-13 (guards 7-R1-18 at this site): the art extraction runs
    on staged upload bytes, so it forces the demuxer the upload probe found."""
    accept(db, _ready(db, music))
    art = FakeArt(b"img")

    make_commit_worker(db, music, probe=FakeProbe(_art_meta()), art=art,
                       cover_art=FakeCoverArt()).process_one()

    assert art.kwargs == [{"input_format": "flac"}]


def test_shared_artwork_is_journaled_as_not_created(db, music):
    commit = accept(db, _ready(db, music))
    covers = FakeCoverArt(first_id=500)
    covers.add_album_art_with_status(b"img")  # another track's cover

    make_commit_worker(db, music, probe=FakeProbe(_art_meta()), art=FakeArt(b"img"),
                       cover_art=covers).process_one()

    row = journal(db, commit)
    assert (row["cover_art_id"], row["cover_art_created"]) == (500, 0)


def test_no_embedded_art_means_no_extraction(db, music):
    commit = accept(db, _ready(db, music))
    art = FakeArt(b"img")

    make_commit_worker(db, music, art=art).process_one()

    assert art.calls == []
    row = journal(db, commit)
    assert (row["cover_art_id"], row["cover_art_created"]) == (None, None)


@pytest.mark.parametrize("data, raises", [(None, None), (b"img", ValueError("not an image"))])
def test_unreadable_artwork_imports_without_a_cover(db, music, data, raises):
    commit = accept(db, _ready(db, music))
    covers = FakeCoverArt()
    covers.raises = raises

    assert make_commit_worker(db, music, probe=FakeProbe(_art_meta()), art=FakeArt(data),
                              cover_art=covers).process_one() == "prepared"

    row = journal(db, commit)
    assert row["cover_art_id"] is None
    assert json.loads(row["final_metadata"])["cover_art_id"] is None


def test_a_rerun_keeps_ownership_of_art_this_operation_created(db, music):
    """A crash after the art was journaled: the rerun dedupes onto the same art
    (was_created false) and still owns it."""
    commit = accept(db, _ready(db, music), lease=DEAD_BOOT)
    sql(db, "UPDATE upload_commit_journal SET cover_art_id = 500, cover_art_created = 1")
    covers = FakeCoverArt(first_id=500)
    covers.ids[b"img"] = 500  # it exists now: the rerun's add is a dedupe

    assert make_commit_worker(db, music, probe=FakeProbe(_art_meta()), art=FakeArt(b"img"),
                              cover_art=covers).process_one() == "prepared"

    row = journal(db, commit)
    assert (row["cover_art_id"], row["cover_art_created"]) == (500, 1)


def test_a_rerun_onto_different_art_takes_the_new_answer(db, music):
    commit = accept(db, _ready(db, music), lease=DEAD_BOOT)
    sql(db, "UPDATE upload_commit_journal SET cover_art_id = 499, cover_art_created = 1")
    covers = FakeCoverArt(first_id=500)
    covers.ids[b"img"] = 500

    make_commit_worker(db, music, probe=FakeProbe(_art_meta()), art=FakeArt(b"img"),
                       cover_art=covers).process_one()

    row = journal(db, commit)
    assert (row["cover_art_id"], row["cover_art_created"]) == (500, 0)


def test_the_art_is_journaled_before_the_digest_check(db, music):
    """A crash after registration must find the art in the journal."""
    commit = accept(db, _ready(db, music))
    seen = []
    exact = FakeExact()

    def spying_exact(path, codec_hint, **kwargs):
        seen.append(journal(db, commit)["cover_art_id"])
        return exact(path, codec_hint, **kwargs)

    make_commit_worker(db, music, probe=FakeProbe(_art_meta()), art=FakeArt(b"img"),
                       exact=spying_exact).process_one()

    assert seen == [500]


