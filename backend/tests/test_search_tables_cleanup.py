"""Refactor BE-TIDY row 10 (U05-A-09), written before the change: the three
search tables (``fts_tracks``, ``fts_artists``, ``fts_albums``) are left with
exactly the terms of the tracks that remain, whatever was inserted, edited and
deleted on the way.

The tables are contentless FTS5 tables: a row is removed by repeating the
terms it was filled with. A delete that carries other terms removes the row id
but leaves its terms in the index for ever. So these tests read the index's
terms directly (``fts5vocab``), not only the row ids.

The names mix precomposed and decomposed accents, case variants of one artist,
an album artist that wins over the artist, padding, a whitespace-only album
and a single without an album. The expected terms come from an independent
oracle: a fresh database filled directly with the final values.
"""

import sqlite3
import unicodedata

from app.models.track import Track
from app.models.track_meta_data import TrackMetaData
from tests.database_fixtures import make_db

TABLES = ("fts_tracks", "fts_artists", "fts_albums")

DECOMPOSED_E = "é"  # e + combining acute accent

# uuid -> (title, artist, album, album_artist, year)
TRACKS = {
    "t-cafe": ("Café del Mar", "Beyoncé", "Dangerously in Love", None, 2003),
    "t-cafe-nfd": (f"Caf{DECOMPOSED_E} Noir", f"Beyonc{DECOMPOSED_E}", "   ", None, 2004),
    "t-sigur": ("Svefn-g-englar", "Ignored Artist", "Ágætis byrjun", "Sigur Rós", 1999),
    "t-gold": ("Dancing Queen", "ABBA", "Gold", None, 1992),
    "t-arrival": ("Money, Money, Money", "abba", "Arrival", None, 1976),
    "t-lonely": ("Ünïcode Song", None, None, None, None),
    "t-single": ("Kickstart My Heart", "Mötley Crüe", None, None, 1989),
    "t-padded": ("Jóga", "  Björk  ", "Homogenic", "  ", 1997),
}

# uuid -> fields of one edit, applied in this order.
EDITS = [
    ("t-cafe", {"artist": f"Beyonc{DECOMPOSED_E}"}),
    ("t-cafe-nfd", {"title": f"Caf{DECOMPOSED_E} Bleu", "album": "Lemonade"}),
    ("t-sigur", {"album_artist": None}),
    ("t-gold", {"album": "   "}),
    ("t-lonely", {"artist": "Sigur Rós", "album": "Takk..."}),
    ("t-single", {"album": "Dr. Feelgood"}),
    ("t-padded", {"album_artist": "BJÖRK", "title": "Bachelorette"}),
    ("t-arrival", {"artist": "ABBA", "album": "Gold"}),
]


def _add(db, tmp_path, uuid_id, title, artist, album, album_artist, year):
    metadata = TrackMetaData(
        codec="flac", duration=2.0, bitrate_kbps=900.0, sample_rate_hz=44100, channels=2,
    )
    metadata.title = title
    metadata.artist = artist
    metadata.album = album
    metadata.album_artist = album_artist
    metadata.year = year
    track = Track(file_path=tmp_path / f"{uuid_id}.flac", metadata=metadata)
    track.uuid_id = uuid_id
    assert db.add_track(track=track)


def _edit(db, uuid_id, fields):
    revision = _read(db, "SELECT revision FROM tracks WHERE uuid_id = ?", (uuid_id,))[0][0]
    db.apply_track_metadata_edit(uuid_id, fields, revision)


def _read(db, query, params=()):
    conn = sqlite3.connect(db.context.database_path)
    try:
        return conn.execute(query, params).fetchall()
    finally:
        conn.close()


def _terms(db, table):
    """{term: (rows holding it, occurrences)} straight from the FTS index."""
    conn = sqlite3.connect(db.context.database_path)
    try:
        conn.execute(f"CREATE VIRTUAL TABLE temp.vocab USING fts5vocab(main, {table}, 'row')")
        return {
            term: (docs, cnt)
            for term, docs, cnt in conn.execute("SELECT term, doc, cnt FROM temp.vocab")
        }
    finally:
        conn.close()


def _row_ids(db, table):
    return sorted(rowid for (rowid,) in _read(db, f"SELECT rowid FROM {table}"))


def _library(db, tmp_path):
    for uuid_id, values in TRACKS.items():
        _add(db, tmp_path, uuid_id, *values)
    for uuid_id, fields in EDITS:
        _edit(db, uuid_id, fields)


def _fresh_copy(db, tmp_path):
    """A new database filled directly with the tracks' current values."""
    fresh_dir = tmp_path / "fresh"
    fresh_dir.mkdir()
    fresh = make_db(fresh_dir)
    for uuid_id, title, artist, album, album_artist, year in _read(
        db,
        'SELECT uuid_id, title, artist, album, album_artist, "year" FROM trackmetadata '
        "ORDER BY track_id",
    ):
        _add(fresh, fresh_dir, uuid_id, title, artist, album, album_artist, year)
    return fresh


def test_the_test_data_holds_decomposed_and_precomposed_names(db, tmp_path):
    _add(db, tmp_path, "t-cafe-nfd", *TRACKS["t-cafe-nfd"])

    stored = _read(db, "SELECT title, artist FROM trackmetadata")[0]

    # The database keeps an added name as given (the organizer normalises
    # before it calls add_track), so both spellings reach the search tables.
    assert stored == (f"Caf{DECOMPOSED_E} Noir", f"Beyonc{DECOMPOSED_E}")
    assert unicodedata.normalize("NFC", stored[1]) != stored[1]


def test_after_inserts_and_edits_the_search_tables_hold_only_the_current_terms(db, tmp_path):
    _library(db, tmp_path)
    fresh = _fresh_copy(db, tmp_path)

    for table in TABLES:
        assert _terms(db, table) == _terms(fresh, table), table
        assert len(_row_ids(db, table)) == len(_row_ids(fresh, table)), table
    # Terms that only an edited-away value held are gone; a term the edit
    # brought in is there.
    for stale in ("noir", "joga", "arrival"):
        assert stale not in _terms(db, "fts_tracks"), stale
    assert "arrival" not in _terms(db, "fts_albums")
    assert "ignored" in _terms(db, "fts_tracks")  # t-sigur's artist once its album artist went


def test_after_inserts_edits_and_deletes_the_three_search_tables_are_empty(db, tmp_path):
    _library(db, tmp_path)
    assert all(_terms(db, table) for table in TABLES)

    for uuid_id in TRACKS:
        assert db.delete_track(uuid_id)

    for table in TABLES:
        assert _terms(db, table) == {}, table
        assert _row_ids(db, table) == [], table
    assert _read(db, "SELECT count(*) FROM artists") == [(0,)]
    assert _read(db, "SELECT count(*) FROM albums") == [(0,)]


def test_deleting_every_track_without_edits_empties_the_search_tables(db, tmp_path):
    for uuid_id, values in TRACKS.items():
        _add(db, tmp_path, uuid_id, *values)

    for uuid_id in reversed(list(TRACKS)):
        assert db.delete_track(uuid_id)

    for table in TABLES:
        assert _terms(db, table) == {}, table
        assert _row_ids(db, table) == [], table
