"""``Database.track_path_in_use``: is a path some track's master?

Journal recovery asks this before it deletes a file, so it must answer "yes"
for every spelling the filesystem treats as the same name. APFS (macOS) folds
Unicode case and ignores the NFC/NFD difference, and ingest paths are not
normalised, so ``Élan/…`` and ``élan/…``, or ``Café`` spelled with one code
point or two, name the same file. On a case-sensitive filesystem the answer is
then more careful than it needs to be, which is the safe direction.
"""

from pathlib import Path

import pytest

from app.database import ANY_OWNER
from app.models.track import Track
from app.models.track_meta_data import TrackMetaData
from tests.owned_database import add_test_user
from tests.test_track_editor import _add_track, _db

NFC_CAFE = "Café"
NFD_CAFE = "Café"


@pytest.mark.parametrize("stored,asked", [
    ("Élan", "élan"),   # non-ASCII case
    ("élan", "ÉLAN"),
    (NFC_CAFE, NFD_CAFE),         # composed vs decomposed
    (NFD_CAFE, NFC_CAFE),
    ("STRASSE", "straße"),   # full case folding (ß)
    ("Art", "art"),               # ASCII case, as before
    ("\u0390", "\u0399\u0308\u0301"),  # canonical caseless: NFC before casefold is not enough
])
def test_another_spelling_of_a_tracks_master_is_in_use(tmp_path, stored, asked):
    db = _db(tmp_path)
    _add_track(db, tmp_path / "owner" / stored / "song.m4a", "B", "Art")

    assert db.track_path_in_use(str(tmp_path / "owner" / asked / "song.m4a"), owner_id=ANY_OWNER)


@pytest.mark.parametrize("stored,asked", [
    (NFC_CAFE, "Cafe"),           # an accent is not a case
    ("Élan", "Elan"),
    ("Art", "Art2"),
])
def test_a_different_name_is_not_in_use(tmp_path, stored, asked):
    db = _db(tmp_path)
    _add_track(db, tmp_path / "owner" / stored / "song.m4a", "B", "Art")

    assert not db.track_path_in_use(str(tmp_path / "owner" / asked / "song.m4a"), owner_id=ANY_OWNER)


def test_the_excluded_track_is_excluded_under_every_spelling(tmp_path):
    db = _db(tmp_path)
    track = _add_track(db, tmp_path / "owner" / "Élan" / "song.m4a", "A", "Art")
    variant = str(tmp_path / "owner" / "élan" / "song.m4a")

    assert db.track_path_in_use(variant, owner_id=ANY_OWNER)
    assert not db.track_path_in_use(variant, owner_id=ANY_OWNER, exclude_uuid=track.uuid_id)


# --- 6-5-R3-04: the owner clause --------------------------------------------------------------


def test_a_named_owner_sees_only_its_own_tracks(tmp_path):
    db = _db(tmp_path)
    other = add_test_user(db, "other")
    mine = str(tmp_path / "owner" / "Art" / "song.m4a")
    theirs = str(tmp_path / "other" / "Art" / "song.m4a")
    _add_track(db, Path(mine), "A", "Art")
    assert db.add_track(Track(file_path=theirs, metadata=TrackMetaData(
        codec="aac", duration=1.0, bitrate_kbps=128.0, sample_rate_hz=44100,
        channels=2, title="B", artist="Art")), owner_id=other)

    assert db.track_path_in_use(mine, owner_id=db.owner_id)
    assert not db.track_path_in_use(mine, owner_id=other)
    assert db.track_path_in_use(theirs, owner_id=other)
    assert not db.track_path_in_use(theirs, owner_id=db.owner_id)
    assert db.track_path_in_use(mine, owner_id=ANY_OWNER)
    assert db.track_path_in_use(theirs, owner_id=ANY_OWNER)
