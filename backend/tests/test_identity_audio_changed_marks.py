"""Pre-merge review A3-01: once a track's audio has changed, its old exact
digest must not keep matching as "exact".

The finder matches ``pending`` rows that still carry a digest (spec §5): "a
library copy whose tag write has not been re-verified yet", where the audio
did not change. The marks ``conversion`` (journal recovery of a conversion)
and ``settle`` (the file changed after import; the conversion's own re-hash
found the stored digest wrong) are made after the audio itself changed or may
have changed, so the old digest describes audio the file no longer holds.

The questions are the ones a person's action asks: does an upload of the
original audio still meet the changed track as an exact copy (the upload
duplicate check), does the finder still call them exact matches, and does
Possible duplicates still list the pair as exact?
"""

import pytest

from app.database.database import Database
from app.services.audio_identity import AudioIdentity, ExactAudioHash
from app.services.duplicate_detection import TrackRef, find_duplicates
from tests.identity_worker_fixtures import DIGEST_A, add_track, identity, sql

ORIGINAL = ExactAudioHash("pcm_sha256", DIGEST_A, 44100, 2, 16)
CURRENT = {
    "exact_state": "current", "exact_kind": "pcm_sha256", "exact_digest": DIGEST_A,
    "sample_rate_hz": 44100, "channels": 2, "bits_per_sample": 16, "match_state": "current",
}


@pytest.fixture
def music(tmp_path):
    root = tmp_path / "music"
    root.mkdir()
    return root


def _twins(db, music):
    """Two tracks holding the same audio, matched: an open exact pair."""
    uuids = []
    for name in ("original", "copy"):
        path = music / f"{name}.flac"
        path.write_bytes(b"audio")
        uuids.append(add_track(db, path, identity=dict(CURRENT)))
    a, b = sorted(uuids)
    sql(db, "INSERT INTO track_duplicate_candidates (owner_id, uuid_a, uuid_b, kind, band_rank,"
            " sort_score, matcher_version, detected_at) VALUES (?, ?, ?, 'exact', 0, 1.0, 'm1', 0)",
        (db.owner_id, a, b))
    return uuids


def _exact_matches_of_the_original(db, *, exclude=frozenset()):
    """The finder's exact matches for the original audio, and the uuids the
    upload duplicate check would refuse an upload of that audio against."""
    original = AudioIdentity(exact=ORIGINAL, tool_versions=None, computed_at=0)
    with db._connection() as conn:
        report = find_duplicates(conn, original, owner_id=db.owner_id, exclude=exclude)
        _, refused = Database._exact_library_matches_in(
            conn, owner_id=db.owner_id, item_uuid="item-1", identity=original, acknowledged={},
            exclude=exclude)
    finder = [m.subject.uuid_id for m in report.matches
              if isinstance(m.subject, TrackRef) and m.kind == "exact"]
    return finder, refused


def _open_exact_pairs(db):
    return sql(db, "SELECT uuid_a, uuid_b FROM track_duplicate_candidates"
                   " WHERE kind = 'exact' AND status = 'open'")


def _settle(db, uuid_id):
    """The settle check found the file changed after import (settle_check.make_settle_refresh)."""
    return db.refresh_track_audio_properties(
        uuid_id, codec="flac", bitrate_kbps=None, sample_rate_hz=44100, channels=2,
        duration=None, owner_id=db.owner_id)


def _conversion_recovered(db, uuid_id):
    """Journal recovery after an in-place conversion (journal_recovery.mark_identity_stale)."""
    return db.mark_audio_identity_stale(uuid_id, "conversion", owner_id=db.owner_id)


AUDIO_CHANGED = {"settle": _settle, "conversion": _conversion_recovered}


@pytest.mark.parametrize("reason", sorted(AUDIO_CHANGED))
def test_after_an_audio_change_the_old_digest_no_longer_matches_as_exact(db, music, reason):
    original, changed = _twins(db, music)
    assert _exact_matches_of_the_original(db, exclude=frozenset({original})) == ([changed], [changed])

    assert AUDIO_CHANGED[reason](db, changed)

    # Unknown until the worker hashes the new bytes: never a wrong exact match.
    assert _exact_matches_of_the_original(db, exclude=frozenset({original})) == ([], [])
    assert _open_exact_pairs(db) == []
    row = identity(db, changed)
    assert (row["exact_state"], row["exact_kind"], row["exact_digest"]) == ("pending", None, None)


@pytest.mark.parametrize("reason", sorted(AUDIO_CHANGED))
def test_after_an_audio_change_a_dismissed_pair_stays_dismissed(db, music, reason):
    original, changed = _twins(db, music)
    sql(db, "UPDATE track_duplicate_candidates SET status = 'dismissed', status_changed_at = 5")

    AUDIO_CHANGED[reason](db, changed)

    assert sql(db, "SELECT status, status_changed_at FROM track_duplicate_candidates") \
        == [{"status": "dismissed", "status_changed_at": 5}]


def test_a_tag_write_keeps_the_digest_matchable(db, music):
    # Spec §5: a tag write does not change the audio, so the stale digest still
    # matches (the safe direction for every consumer) and the pair stays open.
    original, edited = _twins(db, music)

    assert db.mark_audio_identity_stale(edited, "tag_write", owner_id=db.owner_id)

    assert _exact_matches_of_the_original(db, exclude=frozenset({original})) == ([edited], [edited])
    assert len(_open_exact_pairs(db)) == 1
    row = identity(db, edited)
    assert (row["exact_state"], row["exact_digest"]) == ("pending", DIGEST_A)
