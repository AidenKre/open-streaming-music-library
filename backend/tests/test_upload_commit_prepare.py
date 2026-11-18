"""7A.3a S5 (spec §6 step 1: "sanitize path components, pick collision-safe
filename `<sanitized-stem>-<track_uuid>.<validated-extension>`"; step 2: "Copy
source to same-filesystem work file ... Probe resulting file for technical
fields, then build final catalog metadata as those probed fields plus the
reviewed editable-field overlay (including explicit nulls). Re-probing must not
erase DB-only edits. ... Fsync; persist prepared journal fields ... Original
staged source remains recoverable until commit completes."; §3: the staged
quota "includes ... work copies"; SC-16g; SC-28 rule 5 (`library_root(owner)`
+ `assert_within`); review 7-U05 original staged source preservation). The
worker stops at ``prepared``: no move, no insert."""

import json
import os

import pytest

from tests.identity_worker_fixtures import make_db, sql
from tests.owned_database import add_test_user
from tests.upload_commit_fixtures import (
    FakeProbe,
    accept,
    journal,
    library_root,
    make_commit_worker,
    ready_item,
    reservations,
    sha,
)
from tests.upload_validation_fixtures import detected, item_row

FINAL_KEYS = {
    "v", "title", "artist", "album", "album_artist", "year", "date", "genre", "track_number",
    "disc_number", "codec", "duration", "bitrate_kbps", "sample_rate_hz", "channels",
    "has_album_art", "cover_art_id",
}


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


def test_nothing_to_prepare_is_idle(db, music):
    assert make_commit_worker(db, music).process_one() == "idle"


def test_a_skip_commit_is_prepared_into_a_work_copy(db, music):
    commit = accept(db, _ready(db, music, content=b"audio-A"))

    assert make_commit_worker(db, music).process_one() == "prepared"

    row = journal(db, commit)
    assert row["state"] == "prepared"
    assert row["lease_boot_id"] is None
    assert row["work_path"] == str(commit["work"])
    assert commit["work"].read_bytes() == b"audio-A"
    assert item_row(db, commit)["state"] == "committing"  # no move, no insert yet
    assert sql(db, "SELECT uuid_id FROM tracks") == []


@pytest.fixture
def umask_022():
    old = os.umask(0o022)
    try:
        yield
    finally:
        os.umask(old)


def test_the_work_copy_gets_the_usual_file_mode_not_a_private_one(db, music, umask_022):
    """Review r1 7-R1-11: the work copy becomes the library master (a hard
    link), so it is created like any file the server writes (0o666 less the
    umask), never owner-only like the staged source."""
    commit = accept(db, _ready(db, music, content=b"audio-A"))

    assert make_commit_worker(db, music).process_one() == "prepared"

    assert os.stat(commit["work"]).st_mode & 0o777 == 0o644


def test_the_staged_source_is_never_modified(db, music):
    commit = accept(db, _ready(db, music, content=b"audio-A"), edits={"title": "New"})
    before = sha(commit["source"])

    make_commit_worker(db, music).process_one()

    assert sha(commit["source"]) == before == item_row(db, commit)["expected_sha256"]
    assert item_row(db, commit)["source_path"] == str(commit["source"])


def test_the_final_metadata_is_the_probe_plus_the_reviewed_overlay(db, music):
    commit = accept(db, _ready(db, music), edits={"title": "New title", "album": None, "year": 1997})
    probe = FakeProbe(detected(title="Airbag"))

    make_commit_worker(db, music, probe=probe).process_one()

    final = json.loads(journal(db, commit)["final_metadata"])
    assert set(final) == FINAL_KEYS
    assert final["v"] == 1
    # reviewed fields win, an explicit null clears, an untouched one keeps the probe's value
    assert (final["title"], final["album"], final["year"]) == ("New title", None, 1997)
    assert final["artist"] == "Radiohead"
    # technical fields come from the probe of the work copy
    assert (final["codec"], final["duration"], final["bitrate_kbps"], final["sample_rate_hz"],
            final["channels"]) == ("flac", 12.5, 900.0, 44100, 2)
    assert (final["has_album_art"], final["cover_art_id"]) == (False, None)
    assert [call["path"] for call in probe.calls] == [commit["work"]]


def test_db_only_edits_survive_the_reprobe(db, music):
    """write_tags=false: the work copy keeps the source tags, yet the catalog
    takes the reviewed values."""
    commit = accept(db, _ready(db, music), edits={"title": "Mine", "genre": "Rock", "artist": None},
                    write_tags=False)

    make_commit_worker(db, music, probe=FakeProbe(detected(title="Source title"))).process_one()

    final = json.loads(journal(db, commit)["final_metadata"])
    assert (final["title"], final["genre"], final["artist"]) == ("Mine", "Rock", None)


def test_unknown_technical_fields_stay_unknown(db, music):
    meta = detected(duration_s=None)
    meta.update(bitrate_kbps=None, sample_rate_hz=None, channels=None)
    commit = accept(db, _ready(db, music))

    make_commit_worker(db, music, probe=FakeProbe(meta)).process_one()

    final = json.loads(journal(db, commit)["final_metadata"])
    assert (final["duration"], final["bitrate_kbps"], final["sample_rate_hz"], final["channels"]) == (
        None, None, None, None)


def test_the_final_path_is_the_sanitized_name_under_the_owners_library(db, music):
    commit = accept(db, _ready(db, music, filename="Airbag (Remaster).flac"))

    make_commit_worker(db, music).process_one()

    root = library_root(db, music, commit["owner_id"])
    expected = root / "Radiohead" / "OK Computer" / f"Airbag (Remaster)-{commit['track']}.flac"
    assert journal(db, commit)["final_path"] == str(expected)
    assert not expected.exists()  # planned, not moved


def test_the_folders_follow_the_reviewed_artist_and_album(db, music):
    commit = accept(db, _ready(db, music, filename="a.flac"),
                    edits={"artist": "AC/DC", "album": None})

    make_commit_worker(db, music).process_one()

    root = library_root(db, music, commit["owner_id"])
    assert journal(db, commit)["final_path"] == str(root / "AC_DC" / f"a-{commit['track']}.flac")


@pytest.mark.parametrize(
    "filename, stem",
    [
        ("../../etc/pass:wd.flac", "pass_wd"),
        ("a\x00b.flac", "a_b"),
        ("..flac", "upload"),
        (".hidden.flac", "hidden"),
        ("noext", "noext"),
        ("CON.flac", "CON_"),
    ],
)
def test_the_display_name_is_never_joined_into_the_path(db, music, filename, stem):
    commit = accept(db, _ready(db, music, filename=filename))

    make_commit_worker(db, music).process_one()

    final = journal(db, commit)["final_path"]
    root = library_root(db, music, commit["owner_id"])
    assert final == str(root / "Radiohead" / "OK Computer" / f"{stem}-{commit['track']}.flac")


def test_a_long_display_name_is_capped(db, music):
    commit = accept(db, _ready(db, music, filename="x" * 250 + ".flac"))

    make_commit_worker(db, music).process_one()

    name = os.path.basename(journal(db, commit)["final_path"])
    assert len(name) <= 200
    assert name.endswith(f"-{commit['track']}.flac")


def test_the_extension_comes_from_the_probe_not_the_display_name(db, music):
    meta = detected(codec="mp3", container="mp3", mime="audio/mpeg")
    commit = accept(db, _ready(db, music, filename="song.flac", meta=meta), ext=".mp3")

    make_commit_worker(db, music, probe=FakeProbe(meta)).process_one()

    assert journal(db, commit)["final_path"].endswith(f"/song-{commit['track']}.mp3")
    assert commit["work"].name.endswith(".mp3")


def test_each_owner_publishes_under_their_own_library(db, music):
    sam = add_test_user(db, "sam")
    commit = accept(db, _ready(db, music, owner_id=sam))

    make_commit_worker(db, music).process_one()

    final = journal(db, commit)["final_path"]
    assert final.startswith(str(music / "sam") + "/")


def test_the_work_copy_holds_a_durable_staged_reservation(db, music):
    commit = accept(db, _ready(db, music, content=b"x" * 1000))

    make_commit_worker(db, music).process_one()

    assert reservations(db, commit["owner_id"]) == [
        {"purpose": "upload_source", "subject_ref": commit["item_uuid"], "bytes": 1000, "lease_boot_id": None},
        {"purpose": "upload_work", "subject_ref": commit["op"], "bytes": 1000, "lease_boot_id": None},
    ]


def test_a_prepared_commit_is_not_claimed_again(db, music):
    accept(db, _ready(db, music))
    worker = make_commit_worker(db, music)

    assert worker.process_one() == "prepared"
    assert worker.process_one() == "idle"


def test_commits_are_prepared_oldest_first(db, music):
    late = accept(db, _ready(db, music, content=b"late"), created_at=200)
    early = accept(db, _ready(db, music, content=b"early"), created_at=100)
    worker = make_commit_worker(db, music)

    worker.process_one()

    assert (journal(db, early)["state"], journal(db, late)["state"]) == ("prepared", "committing")


def test_the_named_seam_runs_after_prepared(db, music):
    """7A.3b plugs steps 3-6 in here; the journal it gets is already prepared."""
    commit = accept(db, _ready(db, music))
    seen = []

    def after_prepared(row):
        seen.append((row["operation_uuid"], journal(db, commit)["state"]))
        return "handed-over"

    worker = make_commit_worker(db, music, after_prepared=after_prepared)

    assert worker.process_one() == "handed-over"
    assert seen == [(commit["op"], "prepared")]


def test_an_item_no_longer_committing_is_not_prepared(db, music):
    commit = accept(db, _ready(db, music))
    sql(db, "UPDATE upload_items SET state = 'cancelled' WHERE item_uuid = ?", (commit["item_uuid"],))

    assert make_commit_worker(db, music).process_one() == "idle"
    assert not commit["work"].exists()


def test_an_artist_or_album_named_like_an_internal_dir_is_prepared_beside_it(db, music):
    # 7-fix-r0 F0-2 (7A.3a review #3): was a retryable upload_commit_failed on
    # every attempt.
    commit = accept(db, _ready(db, music, filename="a.flac"),
                    edits={"artist": ".uploads", "album": ".staging"})

    assert make_commit_worker(db, music).process_one() == "prepared"

    root = library_root(db, music, commit["owner_id"])
    assert journal(db, commit)["final_path"] == str(
        root / ".uploads_" / ".staging_" / f"a-{commit['track']}.flac")


def test_the_final_metadata_and_path_are_nfc(db, music):
    """Bug row U05-A-08: an NFD tag or edit (macOS tools write them) is
    NFC-normalised before the final path is computed, so the upload lands in
    the same artist folder and row as an NFC spelling."""
    import unicodedata
    from pathlib import Path

    nfd = lambda s: unicodedata.normalize("NFD", s)  # noqa: E731
    meta = detected(title=nfd("Café"))
    meta["tags"]["artist"] = nfd("Beyoncé")
    meta["tags"]["album"] = nfd("Ágætis")
    commit = accept(db, _ready(db, music, meta=meta), edits={"genre": nfd("Pop é")})
    probe = FakeProbe(meta)

    make_commit_worker(db, music, probe=probe).process_one()

    row = journal(db, commit)
    final = json.loads(row["final_metadata"])
    assert (final["title"], final["artist"], final["album"], final["genre"]) == (
        "Café", "Beyoncé", "Ágætis", "Pop é")
    parts = Path(row["final_path"]).parts
    assert parts[-3:-1] == ("Beyoncé", "Ágætis")
