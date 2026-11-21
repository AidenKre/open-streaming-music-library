"""The folded form of a track's path is stored with the path, and no two
tracks can name one file (pre-merge PM-BE-PATHKEY).

``tracks.file_path_fold`` holds the path in canonical caseless form (NFD,
casefold, NFD: the comparison ``track_path_in_use`` always made, one Python call
per row). It is written in the same statement as every write of ``file_path``,
and a unique index on it makes the database itself refuse a second row naming
the same file under any spelling a caseless disk reads as one name.
``tracks.file_folder_fold`` holds the folder of the path in the same form: what
``track_identities_in_folder`` compared, also once per row.
"""

import ast
import random
import re
import sqlite3
import unicodedata
from pathlib import Path

import pytest

from app.database import ANY_OWNER
from app.database.database import TrackPathTaken
from tests.owned_database import add_test_user
from tests.sqlite_helpers import sql_dicts, sql_exec, sql_rows
from tests.track_editor_fixtures import _add_track
from tests.track_paths import PATH_COLUMNS, PATH_MARKS, path_values, stale_path_rows

BACKEND = Path(__file__).parent.parent

# One name in four spellings a caseless disk reads as the same file. The folded
# form is written out here, not computed: "É" decomposed and lower-cased, "ß"
# folded to "ss", the extension lower-cased.
NFC = "/music/owner/Élan/Straße.M4A"
NFD = "/music/owner/E\u0301lan/Straße.M4A"
UPPER = "/music/owner/ÉLAN/STRASSE.M4A"
LOWER = "/music/owner/élan/strasse.m4a"
FOLDED = "/music/owner/e\u0301lan/strasse.m4a"
FOLDED_FOLDER = "/music/owner/e\u0301lan"
SPELLINGS = [NFC, NFD, UPPER, LOWER]


def _stored(db, uuid_id) -> dict:
    [row] = sql_dicts(db, "SELECT file_path, file_path_fold, file_folder_fold, revision FROM tracks"
                          " WHERE uuid_id = ?", (uuid_id,))
    return row


def _running_job(db, uuid_id) -> int:
    job_id = db.insert_conversion_job(uuid_id, "aac", "m4a", 256, base_revision=None)
    assert db.mark_conversion_job_running(job_id)
    return job_id


# How each statement that changes a track's path is reached (see
# ``test_every_statement_that_writes_a_tracks_path_writes_its_fold``).
def _edit_moves_it(db, uuid_id, path):
    db.apply_track_metadata_edit(
        uuid_id, {"artist": "Moved"}, _stored(db, uuid_id)["revision"], new_file_path=path)


def _conversion_moves_it(db, uuid_id, path):
    db.complete_conversion_job(
        _running_job(db, uuid_id), uuid_id, "aac", 256.0, 44100, 2, file_path=path)


def _recovery_adopts_it(db, uuid_id, path):
    db.refresh_track_audio_properties(
        uuid_id, codec="aac", bitrate_kbps=128.0, sample_rate_hz=44100, channels=2,
        duration=1.0, file_path=path, owner_id=db.owner_id)


MOVES = {
    "a tag edit's move": _edit_moves_it,
    "a conversion to another file type": _conversion_moves_it,
    "start-up recovery adopting a copy": _recovery_adopts_it,
}


@pytest.mark.parametrize("path", SPELLINGS)
def test_a_new_track_stores_the_folded_form_of_its_path(db, path):
    track = _add_track(db, path, "Song", "Élan")

    assert _stored(db, track.uuid_id)["file_path"] == path
    assert _stored(db, track.uuid_id)["file_path_fold"] == FOLDED
    assert _stored(db, track.uuid_id)["file_folder_fold"] == FOLDED_FOLDER
    assert stale_path_rows(db) == []


@pytest.mark.parametrize("move", MOVES.values(), ids=MOVES.keys())
def test_a_changed_path_stores_its_folded_form_in_the_same_statement(db, move):
    track = _add_track(db, "/music/owner/Art/song.flac", "Song", "Art")
    bystander = _add_track(db, "/music/owner/Art/other.flac", "Other", "Art")

    move(db, track.uuid_id, NFC)

    assert _stored(db, track.uuid_id)["file_path"] == NFC
    assert _stored(db, track.uuid_id)["file_path_fold"] == FOLDED
    assert _stored(db, track.uuid_id)["file_folder_fold"] == FOLDED_FOLDER
    assert _stored(db, bystander.uuid_id)["file_path_fold"] == "/music/owner/art/other.flac"
    assert _stored(db, bystander.uuid_id)["file_folder_fold"] == "/music/owner/art"
    assert stale_path_rows(db) == []


@pytest.mark.parametrize("move", MOVES.values(), ids=MOVES.keys())
def test_a_rename_that_changes_only_the_spelling_is_not_refused(db, move):
    """A case-only rename (a disk that tells letter case apart) changes the
    path and not its folded form: the track's own row is no clash."""
    track = _add_track(db, LOWER, "Song", "Élan")

    move(db, track.uuid_id, UPPER)

    assert _stored(db, track.uuid_id)["file_path"] == UPPER
    assert _stored(db, track.uuid_id)["file_path_fold"] == FOLDED
    assert stale_path_rows(db) == []


@pytest.mark.parametrize("taken", SPELLINGS)
@pytest.mark.parametrize("move", MOVES.values(), ids=MOVES.keys())
def test_a_path_another_tracks_row_names_is_refused_by_the_database(db, move, taken):
    """The backstop: whatever spelling the other row uses, the statement is
    refused with ``TrackPathTaken`` and its transaction writes nothing."""
    other = _add_track(db, taken, "Other", "Élan")
    track = _add_track(db, "/music/owner/Art/song.flac", "Song", "Art")
    before = sql_rows(db, "SELECT * FROM tracks ORDER BY id")
    jobs_before = sql_rows(db, "SELECT COUNT(*) FROM conversion_jobs WHERE status = 'done'")

    with pytest.raises(TrackPathTaken):
        move(db, track.uuid_id, NFC)

    assert sql_rows(db, "SELECT * FROM tracks ORDER BY id") == before
    assert sql_rows(db, "SELECT COUNT(*) FROM conversion_jobs WHERE status = 'done'") == jobs_before
    assert _stored(db, other.uuid_id)["file_path"] == taken
    assert stale_path_rows(db) == []


@pytest.mark.parametrize("taken", SPELLINGS)
def test_a_second_new_track_naming_the_same_file_is_not_added(db, taken):
    first = _add_track(db, taken, "First", "Élan")
    rows = sql_rows(db, "SELECT COUNT(*) FROM tracks")

    with pytest.raises(sqlite3.IntegrityError, match="UNIQUE constraint failed: tracks.file_path_fold"):
        sql_exec(db, f"INSERT INTO tracks (uuid_id, {PATH_COLUMNS}, owner_id)"
                     f" VALUES ('second', {PATH_MARKS}, ?)", (*path_values(NFC), db.owner_id))

    assert sql_rows(db, "SELECT COUNT(*) FROM tracks") == rows
    assert _stored(db, first.uuid_id)["file_path"] == taken


def test_a_row_cannot_be_written_without_its_folded_path(db):
    with pytest.raises(sqlite3.IntegrityError, match="NOT NULL constraint failed: tracks.file_path_fold"):
        sql_exec(db, "INSERT INTO tracks (uuid_id, file_path, file_folder_fold, owner_id)"
                     " VALUES ('u', ?, ?, ?)", (NFC, FOLDED_FOLDER, db.owner_id))


def test_a_row_cannot_be_written_without_its_folded_folder(db):
    with pytest.raises(sqlite3.IntegrityError, match="NOT NULL constraint failed: tracks.file_folder_fold"):
        sql_exec(db, "INSERT INTO tracks (uuid_id, file_path, file_path_fold, owner_id)"
                     " VALUES ('u', ?, ?, ?)", (NFC, FOLDED, db.owner_id))


def test_another_constraint_is_not_reported_as_a_taken_path(db):
    """Only the unique index on the folded path becomes ``TrackPathTaken``."""
    track = _add_track(db, "/music/owner/Art/song.flac", "Song", "Art")
    sql_exec(db, "CREATE TRIGGER no_moves BEFORE UPDATE OF file_path ON tracks"
                 " BEGIN SELECT RAISE(ABORT, 'UNIQUE constraint failed: tracks.uuid_id'); END")

    with pytest.raises(sqlite3.IntegrityError, match="tracks.uuid_id"):
        _edit_moves_it(db, track.uuid_id, NFC)


# --- the two questions answer as the per-row comparison did -------------------------------------------

def _per_row_fold(text: str) -> str:
    """The comparison both methods made on every row before the stored columns
    (written out here, not imported: the stored columns must give its answers)."""
    return unicodedata.normalize("NFD", unicodedata.normalize("NFD", text).casefold())


# Names that are hard on a folded comparison: letters whose folded form is
# longer (sharp s, n with apostrophe, j with caron, the ffi ligature, dotted
# capital I), composed and decomposed accents, a name that starts with a
# combining mark (it must not attach to the folder before it), a name that is
# another name plus one letter, Greek with two marks, Hangul in both forms,
# marks in two orders, a full-width letter, spaces and dots at the edges.
HOSTILE = [
    "Art", "ART", "Art2", "Arte", "Arté", "Arté", "́rt", "é", "é", "E",
    "Straße", "STRASSE", "strasse", "ŉ", "ʼN", "ǰ", "J̌", "ﬃ", "FFI",
    "İ", "i̇", "I", "ΐ", "Ϊ́", "한글", "한",
    "ậ", "ậ", "Ａ", "x y", " lead", "trail ", "a.b", "..x",
]


def _hostile_library(seed: int, count: int) -> list[str]:
    """``count`` paths, one to three hostile folders deep, no two of which fold alike."""
    rng = random.Random(seed)
    paths, seen = [], set()
    while len(paths) < count:
        folders = [rng.choice(HOSTILE) for _ in range(rng.randint(1, 3))]
        path = "/".join(["/music", rng.choice(["owner", "sam"]), *folders,
                         rng.choice(HOSTILE) + rng.choice([".flac", ".MP3", ""])])
        if _per_row_fold(path) not in seen:
            seen.add(_per_row_fold(path))
            paths.append(path)
    return paths


def _respelled(rng, text: str) -> str:
    """Another spelling of ``text`` (it may or may not fold alike), or ``text`` itself."""
    return rng.choice([text, text.upper(), text.lower(), text.casefold(),
                       unicodedata.normalize("NFC", text), unicodedata.normalize("NFD", text)])


@pytest.mark.parametrize("seed", [1, 2, 3])
def test_both_questions_answer_as_the_per_row_comparison_did(db, seed):
    sam = add_test_user(db, "sam")
    paths = _hostile_library(seed, 150)
    owner_of = {p: (sam if p.startswith("/music/sam/") else db.owner_id) for p in paths}
    conn = sqlite3.connect(db.context.database_path)
    with conn:
        conn.executemany(
            f"INSERT INTO tracks (uuid_id, {PATH_COLUMNS}, owner_id) VALUES (?, {PATH_MARKS}, ?)",
            [(f"u{n}", *path_values(p), owner_of[p]) for n, p in enumerate(paths)])
    conn.close()
    rng = random.Random(seed)
    folders = sorted({str(Path(p).parent) for p in paths} | {str(Path(p).parent.parent) for p in paths})
    asked_folders = [_respelled(rng, f) for f in folders] + ["/music", "/music/owner/Nobody"]
    asked_paths = [_respelled(rng, p) for p in paths[:60]] + [p + "x" for p in paths[:10]] + [
        str(Path(p).parent) for p in paths[:10]]

    for owner in (ANY_OWNER, db.owner_id, sam):
        mine = [p for p in paths if owner is ANY_OWNER or owner_of[p] == owner]
        for folder in asked_folders:
            expected = sorted(p for p in mine
                              if _per_row_fold(str(Path(p).parent)) == _per_row_fold(folder))
            found = sorted(r["file_path"] for r in db.track_identities_in_folder(folder, owner_id=owner))
            assert found == expected, (folder, owner)
        for path in asked_paths:
            expected = any(_per_row_fold(p) == _per_row_fold(path) for p in mine)
            assert db.track_path_in_use(path, owner_id=owner) is expected, (path, owner)
            for n in (0, 7):  # leaving a track out: its own path is free, another's is not
                others = any(_per_row_fold(p) == _per_row_fold(path) for p in mine if p != paths[n])
                assert db.track_path_in_use(path, owner_id=owner, exclude_uuid=f"u{n}") is others
    assert stale_path_rows(db) == []


def test_a_folders_tracks_come_with_their_stored_audio_hash(db):
    """One row per track directly in the folder, the identity columns the
    organizer compares, None for a track with no identity row; a track in a
    folder below, or in a folder whose name only starts alike, is not there."""
    inside = _add_track(db, "/music/owner/Art/Album/one.flac", "One", "Art", "Album")
    bare = _add_track(db, "/music/owner/ART/album/two.flac", "Two", "Art", "Album")
    _add_track(db, "/music/owner/Art/Album/Bonus/three.flac", "Three", "Art", "Album")
    _add_track(db, "/music/owner/Art/Album (Deluxe)/four.flac", "Four", "Art", "Album (Deluxe)")
    _add_track(db, "/music/owner/Art/five.flac", "Five", "Art")
    sql_exec(db, "UPDATE track_audio_identity SET exact_state = 'current', exact_kind = 'pcm_sha256',"
                 " exact_digest = 'ab', sample_rate_hz = 44100, channels = 2, bits_per_sample = 16"
                 " WHERE uuid_id = ?", (inside.uuid_id,))
    sql_exec(db, "DELETE FROM track_audio_identity WHERE uuid_id = ?", (bare.uuid_id,))

    rows = sorted(db.track_identities_in_folder("/music/owner/Art/Album", owner_id=ANY_OWNER),
                  key=lambda r: r["file_path"])

    assert rows == [
        {"file_path": "/music/owner/ART/album/two.flac", "exact_state": None, "exact_kind": None,
         "exact_digest": None, "sample_rate_hz": None, "channels": None, "bits_per_sample": None},
        {"file_path": "/music/owner/Art/Album/one.flac", "exact_state": "current",
         "exact_kind": "pcm_sha256", "exact_digest": "ab", "sample_rate_hz": 44100, "channels": 2,
         "bits_per_sample": 16},
    ]


# --- no statement writes the path without its fold ----------------------------------------------------

TABLE = r"(?:main\.)?\"?tracks\"?"
UPDATES = re.compile(rf"\bupdate\s+(?:or\s+\w+\s+)?{TABLE}\s+set\b", re.I)
INSERTS = re.compile(rf"\b(?:insert\s+(?:or\s+\w+\s+)?|replace\s+)into\s+{TABLE}(?![\w.])", re.I)
INSERT_COLUMNS = re.compile(rf"into\s+{TABLE}\s*\(([^)]*)\)", re.I)
SETS = r"\b{}\b\"?\s*="

# Every place a statement writes ``tracks.file_path``: (file, function).
PATH_WRITERS = {
    ("app/database/core.py", "_insert_track_in"),
    ("app/database/tracks.py", "_set_track_path_in"),
    ("scripts/identity_benchmark.py", "_build"),
}
FOLDED_COLUMNS = ("file_path_fold", "file_folder_fold")


def _writes_column(statement: str, column: str) -> bool:
    if UPDATES.search(statement):
        return re.search(SETS.format(column), statement) is not None
    columns = INSERT_COLUMNS.search(statement)
    # An INSERT with no column list writes every column.
    return columns is None or column in re.findall(r"\w+", columns[1])


def _writes_path(statement: str) -> bool:
    return _writes_column(statement, "file_path")


def _text(node) -> str | None:
    """The text of a string expression: a literal (adjacent literals joined),
    the fixed parts of an f-string, strings joined with ``+`` (a part that is
    not a literal reads ``{}``); None for any other node."""
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return node.value
    if isinstance(node, ast.JoinedStr):
        return "".join(v.value if isinstance(v, ast.Constant) else "{}" for v in node.values)
    if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
        left, right = _text(node.left), _text(node.right)
        if left is not None or right is not None:
            return (left if left is not None else "{}") + (right if right is not None else "{}")
    return None


def _writes_tracks(text: str) -> bool:
    return UPDATES.search(text) is not None or INSERTS.search(text) is not None


def _track_writes() -> list[tuple[str, str, str]]:
    """(file, enclosing function, statement text) of every string in the
    product and its scripts that inserts into or updates ``tracks``."""
    found = []
    for folder in ("app", "scripts"):
        for path in sorted((BACKEND / folder).rglob("*.py")):
            source = path.read_text()
            if "tracks" not in source:
                continue
            rel = str(path.relative_to(BACKEND))

            def visit(node, function):
                if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                    function = node.name
                text = _text(node)
                if text is not None:
                    if _writes_tracks(text):
                        found.append((rel, function, text))
                    return
                for child in ast.iter_child_nodes(node):
                    visit(child, function)

            visit(ast.parse(source), None)
    return found


def test_every_statement_that_writes_a_tracks_path_writes_its_fold():
    """A statement that sets ``file_path`` and not the folded column would
    leave a row the index does not protect and the lookup does not find."""
    writers = [(rel, function, text) for rel, function, text in _track_writes()
               if _writes_path(text)]

    for rel, function, text in writers:
        for column in FOLDED_COLUMNS:
            assert _writes_column(text, column), (
                f"{rel}: {function} writes tracks.file_path without {column}: {text}")
    assert {(rel, function) for rel, function, _ in writers} == PATH_WRITERS


def test_no_trigger_or_view_in_the_schema_writes_a_tracks_path():
    """The schema script itself has no statement that writes ``tracks``: a
    trigger could set the path where the inventory above does not look."""
    schema = (BACKEND / "app" / "database" / "init.sql").read_text()
    assert not _writes_tracks(schema)


def test_the_inventory_sees_a_statement_that_forgets_the_fold():
    assert _writes_path('"UPDATE tracks SET file_path = ? WHERE uuid_id = ?"')
    assert not _writes_column('"UPDATE tracks SET file_path = ? WHERE uuid_id = ?"', "file_path_fold")
    assert _writes_path('"INSERT INTO tracks (uuid_id, file_path, owner_id) VALUES (?, ?, ?)"')
    assert not _writes_column(
        '"INSERT INTO tracks (uuid_id, file_path, owner_id) VALUES (?, ?, ?)"', "file_path_fold")
    assert _writes_path('"INSERT INTO tracks VALUES (?, ?, ?)"')
    assert not _writes_path('"INSERT INTO tracks (uuid_id, owner_id) VALUES (?, ?)"')
    assert not _writes_path('"UPDATE tracks SET revision = ?, last_updated = unixepoch() WHERE uuid_id = ?"')
    assert _writes_column(
        '"UPDATE tracks SET file_path = ?, file_path_fold = ? WHERE uuid_id = ?"', "file_path_fold")
    # The shapes a statement can take: every one is seen as a write of tracks.
    for statement in (
        "UPDATE OR IGNORE tracks SET file_path = :path WHERE uuid_id = :uuid",
        "REPLACE INTO tracks (uuid_id, file_path) VALUES ('u', '/p')",
        "INSERT OR REPLACE INTO main.tracks (uuid_id, file_path) VALUES (?, ?)",
        'UPDATE "tracks" SET "file_path" = ?',
    ):
        assert _writes_tracks(statement) and _writes_path(statement), statement
        assert not _writes_column(statement, "file_path_fold"), statement
    joined = ast.parse('"UPDATE tracks " + "SET file_path = ? " + where').body[0].value
    assert _writes_tracks(_text(joined)) and _writes_path(_text(joined))
    for other in ("INSERT INTO track_tombstones (uuid_id) VALUES (?)", "UPDATE tracks_old SET x = 1",
                  "DELETE FROM tracks WHERE uuid_id = ?", "its ``tracks`` row is updated"):
        assert not _writes_tracks(other), other
