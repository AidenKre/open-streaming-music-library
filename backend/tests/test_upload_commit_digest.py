"""7A.3a S5/S8 (spec §6 step 2: "optionally write tags using shared metadata
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

import logging

import pytest

from app.services.audio_identity import (
    AudioIdentity,
    ExactUnavailable,
    FingerprintIdentity,
    FingerprintUnavailable,
    identity_from_columns,
)
from app.services.upload_validation import staged_identity_columns
from tests.identity_worker_fixtures import make_db
from tests.upload_commit_fixtures import (
    FakeExact,
    FakeTagWriter,
    accept,
    journal,
    make_commit_worker,
    ready_item,
)
from tests.upload_validation_fixtures import exact_for, print_of


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


# ── S8: exact digest re-verification ────────────────────────────────────────

def _journal_identity(row):
    return identity_from_columns(row)


def test_a_matching_digest_carries_the_staged_identity(db, music):
    staged_identity = AudioIdentity(exact=exact_for(b"audio-A"), tool_versions="ffmpeg 8.1",
                                    computed_at=1700, fingerprint=print_of())
    commit = accept(db, _ready(db, music, content=b"audio-A", identity=staged_identity))
    exact = FakeExact()

    make_commit_worker(db, music, exact=exact).process_one()

    row = journal(db, commit)
    assert row["digest_check"] == "verified"
    assert _journal_identity(row) == staged_identity
    assert [(c["path"], c["codec_hint"]) for c in exact.calls] == [(commit["work"], "flac")]


def test_a_changed_digest_is_kept_and_the_print_recomputed(db, music, caplog):
    staged_identity = AudioIdentity(exact=exact_for(b"audio-A"), tool_versions="ffmpeg 8.1",
                                    computed_at=1700, fingerprint=print_of())
    commit = accept(db, _ready(db, music, content=b"audio-A", identity=staged_identity),
                    write_tags=True, edits={"title": "T"})
    caplog.set_level(logging.WARNING)

    assert make_commit_worker(db, music, tag_writer=FakeTagWriter(extra=b"changed")).process_one() == "prepared"

    row = journal(db, commit)
    assert row["digest_check"] == "changed"
    assert row["exact_digest"] == exact_for(b"audio-Achanged").digest
    assert all(row[c] is None for c in ("fp_state", "fp_algorithm", "fp_backend", "fp_duration_s",
                                        "fp_item_count", "fp_data"))
    assert _journal_identity(row).fingerprint is None
    messages = [r.getMessage() for r in caplog.records]
    assert any("digest" in m and "changed" in m for m in messages), messages
    assert not any(str(music) in m for m in messages)


def test_a_staged_identity_without_a_digest_takes_the_work_files(db, music):
    staged_identity = AudioIdentity(exact=ExactUnavailable("failed", "timeout"), tool_versions="ffmpeg 8.1",
                                    computed_at=1700, fingerprint=print_of())
    commit = accept(db, _ready(db, music, content=b"audio-A", identity=staged_identity))

    make_commit_worker(db, music).process_one()

    row = journal(db, commit)
    assert row["digest_check"] == "computed"
    ident = _journal_identity(row)
    assert ident.exact == exact_for(b"audio-A")
    assert ident.fingerprint == print_of()


def test_an_unhashable_work_file_carries_the_staged_identity_unverified(db, music):
    staged_identity = AudioIdentity(exact=exact_for(b"audio-A"), tool_versions="ffmpeg 8.1",
                                    computed_at=1700, fingerprint=print_of())
    commit = accept(db, _ready(db, music, content=b"audio-A", identity=staged_identity))
    exact = FakeExact()
    exact.result = ExactUnavailable("failed", "timeout")

    assert make_commit_worker(db, music, exact=exact).process_one() == "prepared"

    row = journal(db, commit)
    assert row["digest_check"] == "unverified"
    assert _journal_identity(row) == staged_identity


def test_a_malformed_staged_print_never_reaches_the_journal(db, music):
    """Plan D10: the staged row is read through the serializer; a print that
    does not round-trip is carried as not computed, never as a current print."""
    columns = staged_identity_columns(
        AudioIdentity(exact=exact_for(b"audio-A"), tool_versions="ffmpeg 8.1", computed_at=1700,
                      fingerprint=print_of()), fingerprinter_present=True)
    columns["fp_data"] = b"\x01\x02\x03"  # not whole uint32 items
    commit = accept(db, _ready(db, music, content=b"audio-A", identity_columns=columns))

    assert make_commit_worker(db, music).process_one() == "prepared"

    row = journal(db, commit)
    assert row["digest_check"] == "verified"
    assert row["fp_state"] is None and row["fp_data"] is None
    ident = _journal_identity(row)
    assert ident.exact == exact_for(b"audio-A")
    assert not isinstance(ident.fingerprint, FingerprintIdentity)


def test_a_failed_staged_print_is_journaled_as_not_computed(db, music):
    staged_identity = AudioIdentity(exact=exact_for(b"audio-A"), tool_versions="ffmpeg 8.1",
                                    computed_at=1700, fingerprint=FingerprintUnavailable("timeout"))
    commit = accept(db, _ready(db, music, content=b"audio-A", identity=staged_identity))

    make_commit_worker(db, music).process_one()

    row = journal(db, commit)
    assert row["fp_state"] is None
    assert row["exact_digest"] == exact_for(b"audio-A").digest
