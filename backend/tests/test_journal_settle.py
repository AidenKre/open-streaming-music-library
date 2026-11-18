"""Startup recovery settles every edit-journal row itself.

Sign-off OPEN-6.5-05, the user's decision of 2026-11-16 ("Ideally, I should never
have to manually fix rows"; "I do not like having orphaned files in users
library"). At startup, for each row:

1. the track's own file is in place: the row goes; every other regular file the
   row names is settled (the existing ownership proofs, else the content rule);
2. the track's file is missing and a copy exists (the staged copy, or the file
   at the row's other path that no other track claims): the copy is adopted, the
   track's path and technical columns describe it, it is queued for re-hashing;
3. no copy: the row goes; the track is an ordinary "file missing" track.

The content rule compares a file the proofs do not cover with the track's own
file by decoded audio: the same audio is a redundant copy (deleted), other audio
becomes a track of the row's owner. The coordinator's decisions D1-D12 (progress
file ``s8-recovery-settle-progress.md``) pin the corners.

The audio is faked: a file's bytes ``b"<id>|<label>"`` read as audio ``<id>``
(``A``, ``B``, ``C``: aac; ``F``: flac, a different hash kind), ``X`` as a file
ffprobe refuses, ``T`` as a probe that timed out, ``H`` as a file that probes but
whose hash failed, ``E`` as a reader error. Real ffmpeg runs only in
``test_recovery_audio.py``.
"""

import logging
import os
import sqlite3
import uuid
from dataclasses import dataclass, field
from pathlib import Path

import pytest

from app.database import ANY_OWNER
from app.models.track import Track
from app.models.track_meta_data import TrackMetaData
from app.services.audio_identity import ExactAudioHash, ExactUnavailable
from app.services.recovery_audio import PROBE_OK, PROBE_REFUSED, PROBE_UNKNOWN, AudioReading
from app.services import journal_settle
from app.services.conversion import reconcile_conversion_jobs
from app.services.track_editor import reconcile_journal
from tests.test_conversion import _second_owner
from tests.test_track_editor import _db

OPERATOR = "uvicorn.error"

# --- the fake reader --------------------------------------------------------------------------------

_COLUMNS = {  # audio id -> (codec, bitrate, sample rate): distinct, so a refresh is visible
    "A": ("aac", 200.0, 48000),
    "B": ("aac", 128.0, 32000),
    "C": ("aac", 192.0, 44100),
    "F": ("flac", 900.0, 96000),
    "H": ("aac", 160.0, 22050),
    "Z": ("aac", 96.0, 16000),
}
INITIAL = ("aac", 256.0, 8000)  # the track's columns before recovery (matches no file)
INITIAL_FLAC = ("flac", 1000.0, 11025)


def fake_read(path):
    data = Path(path).read_bytes()
    audio = data.split(b"|", 1)[0].decode()
    if audio == "E":
        raise RuntimeError("reader failed")
    if audio == "X":
        return AudioReading(PROBE_REFUSED, None, None)
    if audio == "T":
        return AudioReading(PROBE_UNKNOWN, None, None)
    codec, bitrate, rate = _COLUMNS[audio]
    meta = TrackMetaData(codec=codec, bitrate_kbps=bitrate, sample_rate_hz=rate, channels=2,
                         duration=2.0, title=f"leftover {audio}", artist="Art")
    if audio == "H":
        exact = ExactUnavailable("failed", "timeout")
    else:
        kind = "pcm_sha256" if codec == "flac" else "packets_sha256"
        exact = ExactAudioHash(kind, audio * 8, rate, 2, None)
    return AudioReading(PROBE_OK, meta, exact)


# --- the world --------------------------------------------------------------------------------------


@dataclass
class World:
    db: object
    tmp: Path
    root: Path
    paths: dict  # label -> Path: O, N, T, X, R
    contents: dict  # label -> bytes planted (regular files only)
    uuid: str
    entry_id: int
    owner: int
    claimed: set = field(default_factory=set)


def _plant(path: Path, state, content: bytes, tmp: Path):
    if state in (0, None):
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    if state == 1:
        path.write_bytes(content)
        return True
    if state == "dir":
        path.mkdir()
    elif state == "dangling":
        path.symlink_to(tmp / "nowhere" / path.name)
    elif state == "link":
        target = tmp / "outside" / path.name
        target.parent.mkdir(exist_ok=True)
        target.write_bytes(b"Z|outside " + path.name.encode())
        path.symlink_to(target)
    elif isinstance(state, Path):  # a symlink to another planted path
        path.symlink_to(state)
    else:
        raise AssertionError(state)
    return False


def _add(db, path, columns, *, owner=None, title="T"):
    codec, bitrate, rate = columns
    track = Track(file_path=path, metadata=TrackMetaData(
        codec=codec, bitrate_kbps=bitrate, sample_rate_hz=rate, channels=2, duration=1.0,
        title=title, artist="Art"))
    if owner is None:
        assert db.add_track(track)
    else:
        assert db.add_track(track, owner_id=owner)
    return track


def world(tmp_path, *, intent, db_at, o=0, n=0, t=0, x=None, temp_recorded=True, claim=(),
          contents=None, owner="first", claim_path=None):
    """One journal row in one of the state table's states.

    ``intent``: relocate (edit) | convert (path change) | inplace | convert-inplace.
    ``db_at``: O | N | X | gone. ``o``/``n``/``t``/``x``: 1 regular, 0 absent,
    "dir", "link" (to an outside file), or a label (a symlink to that path)."""
    db = _db(tmp_path)
    owner_id = db.owner_id
    folder = "owner"
    if owner == "second":
        owner_id = _second_owner(db)
        folder = "other"
    root = tmp_path / folder
    root.mkdir(exist_ok=True)
    staging = tmp_path / ".staging"
    staging.mkdir()
    edit = intent in ("relocate", "inplace")
    if intent == "relocate":
        O, N = root / "Old" / "song.m4a", root / "New" / "song.m4a"
    elif intent == "convert":
        O, N = root / "Art" / "song.flac", root / "Art" / "song.m4a"
    else:  # in place: one path
        O, N = root / "Art" / "song.m4a", None
    X = root / "Later" / "song.m4a"
    if db_at == "outside":  # a database path outside the owner's root (old data)
        X, db_at = tmp_path / "elsewhere" / "song.m4a", "X"
    if edit:
        base = {"O": b"A|old", "N": b"A|new", "T": b"A|temp", "X": b"A|x"}
    elif intent == "convert":
        base = {"O": b"F|old", "N": b"C|new", "T": b"C|temp", "X": b"C|x"}
    else:  # convert-inplace: the original (F) and its converted temp (C) share a path
        base = {"O": b"F|old", "T": b"C|temp", "X": b"C|x"}
    base.update(contents or {})
    track_uuid = str(uuid.uuid4())
    paths = {"O": O, "X": X}
    if N is not None:
        paths["N"] = N
    planted = {}
    for label, state in (("O", o), ("N", n), ("X", x)):
        if label not in paths:
            continue
        if isinstance(state, str) and state in paths:
            state = paths[state]
        if _plant(paths[label], state, base[label], tmp_path):
            planted[label] = base[label]
    ext = ".m4a"
    temp = staging / (f"{track_uuid}.0a1b.edit{ext}" if edit else f"{track_uuid}.7.tagged{ext}")
    paths["T"] = temp
    if _plant(temp, t, base["T"], tmp_path):
        planted["T"] = base["T"]
    claimed = set()
    for label in claim:
        other = claim_path or paths[label]
        _add(db, other, INITIAL, title="Other", owner=None if owner == "first" else owner_id)
        claimed.add(label)
    if db_at != "gone":
        at = paths[db_at]
        columns = INITIAL_FLAC if intent in ("convert", "convert-inplace") and db_at == "O" else INITIAL
        track = Track(uuid_id=track_uuid, file_path=at, metadata=TrackMetaData(
            codec=columns[0], bitrate_kbps=columns[1], sample_rate_hz=columns[2], channels=2,
            duration=1.0, title="T", artist="Art"))
        if owner == "first":
            assert db.add_track(track)
        else:
            assert db.add_track(track, owner_id=owner_id)
    journal_intent = "convert" if intent.startswith("convert") else intent
    new_path = None if N is None else str(N)
    kwargs = {} if owner == "first" else {"owner_id": owner_id}
    entry_id = db.insert_journal_entry(
        journal_intent, track_uuid, str(O), new_path, str(temp) if temp_recorded else None, **kwargs)
    paths["R"] = (N or O).with_name(f"song (recovered {entry_id}){ext}")
    return World(db, tmp_path, root, paths, planted, track_uuid, entry_id, owner_id, claimed)


def run(w, caplog=None, **kwargs):
    """Startup's two steps in their order: journal recovery, then the staging sweep
    (which deletes every staged file no row owns, so a copy recovery leaves in
    .staging is lost)."""
    if caplog is not None:
        with caplog.at_level(logging.INFO, logger=OPERATOR):
            reconcile_journal(w.db, w.tmp, read_audio=fake_read, **kwargs)
    else:
        reconcile_journal(w.db, w.tmp, read_audio=fake_read, **kwargs)
    reconcile_conversion_jobs(w.db, w.tmp / ".staging")


def _rows(w):
    return _sql(w, "SELECT id FROM edit_journal")


def _sql(w, query, params=()):
    with w.db._connection() as conn:
        return [tuple(r) for r in conn.execute(query, params).fetchall()]


def _track_paths(w):
    return {p for (p,) in _sql(w, "SELECT file_path FROM tracks")}


def _db_path(w):
    rows = _sql(w, "SELECT file_path FROM tracks WHERE uuid_id = ?", (w.uuid,))
    return rows[0][0] if rows else None


def _columns(w):
    [(codec, bitrate, rate)] = _sql(
        w, "SELECT codec, bitrate_kbps, sample_rate_hz FROM trackmetadata WHERE uuid_id = ?",
        (w.uuid,))
    return (codec, bitrate, rate)


def _regular_files(tmp):
    return {p: p.read_bytes() for p in tmp.rglob("*") if p.is_file() and not p.is_symlink()
            and p.name != "database.db" and "database.db" not in p.name}


# --- the expectation of one state ------------------------------------------------------------------


@dataclass
class Expect:
    db: object = None  # label of the track's final path; "same" = unchanged
    present: dict = field(default_factory=dict)  # label -> expected bytes at that path
    tracks: tuple = ()  # labels whose file became a new track
    deleted: dict = field(default_factory=dict)  # planted bytes -> rule ("a", "b" or "c")
    rows: int = 0
    columns: object = None  # audio id whose columns the track carries; None = unchanged
    unreferenced: tuple = ()  # D2: labels left as files no track uses
    left: tuple = ()  # labels of non-regular entries that stay as they were


def check(w, e: Expect, before_files, before_db_path, before_columns):
    """The table's end state and the three invariants the coordinator asked for."""
    p = w.paths
    # where the track points
    if e.db == "same":
        assert _db_path(w) == before_db_path
    elif e.db is None:
        assert _db_path(w) is None
    else:
        assert _db_path(w) == str(p[e.db])
    # files that must be there, with their bytes
    for label, data in e.present.items():
        assert p[label].read_bytes() == data, label
    # (a) no row remains except the documented K1/K2 cases
    assert len(_rows(w)) == e.rows
    # (b) every regular file among the row's paths is some track's file (except D2)
    track_paths = _track_paths(w)
    for label in ("O", "N", "T", "R"):
        if label not in p:
            continue
        path = p[label]
        if path.is_file() and not path.is_symlink() and label not in e.unreferenced:
            if e.rows and label == "T":
                continue  # a kept row (K1/K2) still owns its staged copy
            # A track's file reached through a symlinked master (M8) counts as used.
            assert str(path) in track_paths or any(
                os.path.exists(tp) and os.path.samefile(path, tp) for tp in track_paths
            ), f"{label} is a regular file no track uses"
    for label in e.tracks:
        assert str(p[label]) in track_paths
        [(owner,)] = _sql(w, "SELECT owner_id FROM tracks WHERE file_path = ?", (str(p[label]),))
        assert owner == w.owner
    for label in e.left:
        assert os.path.lexists(p[label]) and not (p[label].is_file() and not p[label].is_symlink())
    # (c) nothing deleted outside rules a, b, c
    after = set(_regular_files(w.tmp).values())
    vanished = {data for data in before_files.values() if data not in after}
    assert vanished == set(e.deleted), f"deleted {vanished}, expected {set(e.deleted)}"
    final = _db_path(w)
    final_audio = Path(final).read_bytes().split(b"|")[0] if final and Path(final).is_file() else None
    for data, rule in e.deleted.items():
        assert rule in ("a", "b", "c")
        if rule == "b":  # the same audio as the track's own file in place
            assert data.split(b"|")[0] == final_audio
        if rule == "c":  # ffprobe refused it while the track's own file hashed
            assert data.startswith(b"X|") and final_audio not in (None, b"X", b"T", b"H")
    # the technical columns
    if e.columns is None:
        if e.db is not None:
            assert _columns(w) == before_columns
    else:
        assert _columns(w) == _COLUMNS[e.columns]


def settle(tmp_path, kwargs, expect, caplog=None):
    w = world(tmp_path, **kwargs)
    before_files = {k: v for k, v in _regular_files(w.tmp).items()}
    before_db_path = _db_path(w)
    before_columns = _columns(w) if before_db_path is not None else None
    run(w, caplog)
    check(w, expect, before_files, before_db_path, before_columns)
    return w


# --- the state table: relocate edit (rows 1-16) -----------------------------------------------------

A_OLD, A_NEW, A_TEMP = b"A|old", b"A|new", b"A|temp"
F_OLD, C_NEW, C_TEMP = b"F|old", b"C|new", b"C|temp"

EDIT_ROWS = {
    "1": (dict(db_at="O", o=1, n=1, t=1), Expect(db="O", present={"O": A_OLD}, deleted={A_NEW: "b", A_TEMP: "a"})),
    "2": (dict(db_at="O", o=1, n=1, t=0), Expect(db="O", present={"O": A_OLD}, deleted={A_NEW: "a"})),
    "3": (dict(db_at="O", o=1, n=0, t=1), Expect(db="O", present={"O": A_OLD}, deleted={A_TEMP: "a"})),
    "4": (dict(db_at="O", o=1, n=0, t=0), Expect(db="O", present={"O": A_OLD})),
    "5": (dict(db_at="O", o=0, n=1, t=1), Expect(db="O", present={"O": A_TEMP}, deleted={A_NEW: "b"}, columns="A")),
    "6": (dict(db_at="O", o=0, n=1, t=0), Expect(db="N", present={"N": A_NEW}, columns="A")),
    "7": (dict(db_at="O", o=0, n=0, t=1), Expect(db="O", present={"O": A_TEMP}, columns="A")),
    "8": (dict(db_at="O", o=0, n=0, t=0), Expect(db="O")),
    "9": (dict(db_at="N", o=1, n=1, t=1), Expect(db="N", present={"N": A_NEW}, deleted={A_OLD: "b", A_TEMP: "b"})),
    "10": (dict(db_at="N", o=1, n=1, t=0), Expect(db="N", present={"N": A_NEW}, deleted={A_OLD: "a"})),
    "11": (dict(db_at="N", o=1, n=0, t=1), Expect(db="N", present={"N": A_TEMP}, deleted={A_OLD: "a"}, columns="A")),
    "12": (dict(db_at="N", o=1, n=0, t=0), Expect(db="O", present={"O": A_OLD}, columns="A")),
    "13": (dict(db_at="N", o=0, n=1, t=1), Expect(db="N", present={"N": A_NEW}, deleted={A_TEMP: "b"})),
    "14": (dict(db_at="N", o=0, n=1, t=0), Expect(db="N", present={"N": A_NEW})),
    "15": (dict(db_at="N", o=0, n=0, t=1), Expect(db="N", present={"N": A_TEMP}, columns="A")),
    "16": (dict(db_at="N", o=0, n=0, t=0), Expect(db="N")),
}

CONVERT_ROWS = {
    "1": (dict(db_at="O", o=1, n=1, t=1), Expect(db="O", present={"O": F_OLD, "N": C_NEW}, tracks=("N",), deleted={C_TEMP: "a"})),
    "2": (dict(db_at="O", o=1, n=1, t=0), Expect(db="O", present={"O": F_OLD}, deleted={C_NEW: "a"})),
    "3": (dict(db_at="O", o=1, n=0, t=1), Expect(db="O", present={"O": F_OLD}, deleted={C_TEMP: "a"})),
    "4": (dict(db_at="O", o=1, n=0, t=0), Expect(db="O", present={"O": F_OLD})),
    # D7: the staged copy's place (N) is taken: it goes to "song (recovered <id>).m4a"
    "5": (dict(db_at="O", o=0, n=1, t=1), Expect(db="R", present={"R": C_TEMP}, deleted={C_NEW: "b"}, columns="C")),
    "6": (dict(db_at="O", o=0, n=1, t=0), Expect(db="N", present={"N": C_NEW}, columns="C")),
    "7": (dict(db_at="O", o=0, n=0, t=1), Expect(db="N", present={"N": C_TEMP}, columns="C")),
    "8": (dict(db_at="O", o=0, n=0, t=0), Expect(db="O")),
    # D6: the lossless original never matches the lossy result: it becomes a track
    "9": (dict(db_at="N", o=1, n=1, t=1), Expect(db="N", present={"N": C_NEW, "O": F_OLD}, tracks=("O",), deleted={C_TEMP: "b"})),
    "10": (dict(db_at="N", o=1, n=1, t=0), Expect(db="N", present={"N": C_NEW}, deleted={F_OLD: "a"})),
    "11": (dict(db_at="N", o=1, n=0, t=1), Expect(db="N", present={"N": C_TEMP}, deleted={F_OLD: "a"}, columns="C")),
    "12": (dict(db_at="N", o=1, n=0, t=0), Expect(db="O", present={"O": F_OLD}, columns="F")),
    "13": (dict(db_at="N", o=0, n=1, t=1), Expect(db="N", present={"N": C_NEW}, deleted={C_TEMP: "b"})),
    "14": (dict(db_at="N", o=0, n=1, t=0), Expect(db="N", present={"N": C_NEW})),
    "15": (dict(db_at="N", o=0, n=0, t=1), Expect(db="N", present={"N": C_TEMP}, columns="C")),
    "16": (dict(db_at="N", o=0, n=0, t=0), Expect(db="N")),
}

MODIFIERS = {
    # M1: a path another track claims is never touched, adopted or hashed
    "M1-new-claimed-row2": ("relocate", dict(db_at="O", o=1, n=1, t=0, claim=("N",)), Expect(db="O", present={"O": A_OLD, "N": A_NEW})),
    "M1-old-claimed-row10": ("relocate", dict(db_at="N", o=1, n=1, t=0, claim=("O",)), Expect(db="N", present={"O": A_OLD, "N": A_NEW})),
    "M1-new-claimed-row6-no-copy": ("relocate", dict(db_at="O", o=0, n=1, t=0, claim=("N",)), Expect(db="O", present={"N": A_NEW})),
    "M1-old-claimed-row12-no-copy": ("convert", dict(db_at="N", o=1, n=0, t=0, claim=("O",)), Expect(db="N", present={"O": F_OLD})),
    # M2: something that is not a regular file is never deleted, adopted or hashed
    "M2-new-is-a-folder-row2": ("relocate", dict(db_at="O", o=1, n="dir", t=0), Expect(db="O", present={"O": A_OLD}, left=("N",))),
    "M2-db-at-a-folder-row12": ("convert", dict(db_at="N", o=1, n="dir", t=0), Expect(db="O", present={"O": F_OLD}, columns="F", left=("N",))),
    "M2-old-is-a-symlink-row10": ("relocate", dict(db_at="N", o="link", n=1, t=0), Expect(db="N", present={"N": A_NEW}, left=("O",))),
    # M3: a staged copy that is not a regular file is never adopted
    "M3-temp-is-a-folder-row3": ("relocate", dict(db_at="O", o=1, n=0, t="dir"), Expect(db="O", present={"O": A_OLD}, left=("T",))),
    "M3-temp-is-a-symlink-row15": ("relocate", dict(db_at="N", o=0, n=0, t="link"), Expect(db="N")),
    # M4: a row from an old version without a recorded staged copy
    "M4-no-temp-undo-same-audio": ("relocate", dict(db_at="O", o=1, n=1, temp_recorded=False), Expect(db="O", present={"O": A_OLD}, deleted={A_NEW: "b"})),
    "M4-no-temp-undo-other-audio": ("convert", dict(db_at="O", o=1, n=1, temp_recorded=False), Expect(db="O", present={"O": F_OLD, "N": C_NEW}, tracks=("N",))),
    "M4-no-temp-finish": ("relocate", dict(db_at="N", o=1, n=1, temp_recorded=False), Expect(db="N", present={"N": A_NEW}, deleted={A_OLD: "a"})),
    # M5: the track moved on and its file is in place
    "M5-moved-on-in-place": ("relocate", dict(db_at="X", o=1, n=1, t=0, x=1), Expect(db="X", present={"X": b"A|x"}, deleted={A_NEW: "a", A_OLD: "b"})),
    "M5-moved-on-in-place-convert": ("convert", dict(db_at="X", o=1, n=1, t=1, x=1), Expect(db="X", present={"X": b"C|x", "O": F_OLD}, tracks=("O",), deleted={C_NEW: "b", C_TEMP: "a"})),
    # M6: the track moved on and its file is missing
    "M6-moved-on-missing": ("relocate", dict(db_at="X", o=1, n=1, t=1, x=0), Expect(db="X", present={"X": A_TEMP}, deleted={A_NEW: "b", A_OLD: "b"}, columns="A")),
    "M6-moved-on-missing-convert": ("convert", dict(db_at="X", o=1, n=1, t=0, x=0), Expect(db="N", present={"N": C_NEW, "O": F_OLD}, tracks=("O",), columns="C")),
    # M7: the track is gone (unreachable without a manual change): nothing to compare with
    "M7-track-gone": ("relocate", dict(db_at="gone", o=1, n=1, t=1), Expect(db=None, present={"O": A_OLD, "N": A_NEW}, tracks=("O", "N"), deleted={A_TEMP: "a"})),
    # M8: a symlinked master is in place; never delete through it
    "M8-symlinked-master": ("relocate", dict(db_at="O", o="link", n=1, t=0), Expect(db="O", deleted={A_NEW: "a"}, left=("O",))),
    # D8: a staged copy with other audio than the file at N becomes a track under
    # the recovered name (never a track inside .staging)
    "D8-temp-other-audio": ("convert", dict(db_at="N", o=0, n=1, t=1, contents={"T": b"B|temp"}), Expect(db="N", present={"N": C_NEW, "R": b"B|temp"}, tracks=("R",))),
    "M8-symlinked-master-to-new": ("relocate", dict(db_at="O", o="N", n=1, t=0), Expect(db="O", present={"N": A_NEW}, left=("O",))),
}

IN_PLACE = {
    "I1-edit": ("inplace", dict(db_at="O", o=1, t=1), Expect(db="O", present={"O": A_TEMP}, deleted={A_OLD: "a"})),
    "I1-convert": ("convert-inplace", dict(db_at="O", o=1, t=1), Expect(db="O", present={"O": C_TEMP}, deleted={F_OLD: "a"})),
    "I2-edit": ("inplace", dict(db_at="O", o=1, t=0), Expect(db="O", present={"O": A_OLD})),
    "I3-edit": ("inplace", dict(db_at="O", o=0, t=1), Expect(db="O", present={"O": A_TEMP})),
    "I4-edit": ("inplace", dict(db_at="O", o=0, t=0), Expect(db="O")),
    "I5-moved-on-in-place": ("inplace", dict(db_at="X", o=0, t=1, x=1), Expect(db="X", present={"X": b"A|x"}, deleted={A_TEMP: "a"})),
    "I5-moved-on-missing": ("inplace", dict(db_at="X", o=0, t=1, x=0), Expect(db="X", present={"X": A_TEMP}, columns="A")),
    "I6-edit": ("inplace", dict(db_at="X", o=0, t=0, x=1), Expect(db="X", present={"X": b"A|x"})),
    "I7-edit-temp-symlink": ("inplace", dict(db_at="O", o=1, t="link"), Expect(db="O", present={"O": A_OLD})),
    # D9: the replace never happened, so the columns describe the original again
    "I7-convert-temp-symlink": ("convert-inplace", dict(db_at="O", o=1, t="link"), Expect(db="O", present={"O": F_OLD}, columns="F")),
}


@pytest.mark.parametrize("row", list(EDIT_ROWS), ids=[f"edit-row{r}" for r in EDIT_ROWS])
def test_a_relocating_edit_row_settles_per_the_table(tmp_path, row):
    kwargs, expect = EDIT_ROWS[row]
    settle(tmp_path, {"intent": "relocate", **kwargs}, expect)


@pytest.mark.parametrize("row", list(CONVERT_ROWS), ids=[f"convert-row{r}" for r in CONVERT_ROWS])
def test_a_path_changing_conversion_row_settles_per_the_table(tmp_path, row):
    kwargs, expect = CONVERT_ROWS[row]
    settle(tmp_path, {"intent": "convert", **kwargs}, expect)


@pytest.mark.parametrize("case", list(MODIFIERS))
def test_a_modified_row_settles_per_the_table(tmp_path, case):
    intent, kwargs, expect = MODIFIERS[case]
    settle(tmp_path, {"intent": intent, **kwargs}, expect)


@pytest.mark.parametrize("case", list(IN_PLACE))
def test_an_in_place_row_settles_per_the_table(tmp_path, case):
    intent, kwargs, expect = IN_PLACE[case]
    settle(tmp_path, {"intent": intent, **kwargs}, expect)


def test_a_case_variant_of_another_tracks_master_is_never_touched(tmp_path):
    w = world(tmp_path, intent="relocate", db_at="O", o=1, n=1, t=0)
    variant = str(w.paths["N"]).replace("New", "NEW").replace("song", "SONG")
    _add(w.db, Path(variant), INITIAL, title="Other")

    run(w)

    assert w.paths["N"].read_bytes() == A_NEW
    assert _rows(w) == []


def test_a_second_owners_leftover_becomes_their_track_under_their_root(tmp_path):
    settle(tmp_path, {"intent": "convert", "db_at": "N", "o": 1, "n": 1, "t": 1, "owner": "second"},
           Expect(db="N", present={"N": C_NEW, "O": F_OLD}, tracks=("O",), deleted={C_TEMP: "b"}))


# --- the content rule (decisions D1, D2) -----------------------------------------------------------


def test_other_audio_at_the_other_path_becomes_a_track_with_its_own_metadata(tmp_path):
    w = settle(tmp_path, {"intent": "relocate", "db_at": "O", "o": 1, "n": 1, "t": 1,
                          "contents": {"N": b"B|foreign"}},
               Expect(db="O", present={"O": A_OLD, "N": b"B|foreign"}, tracks=("N",), deleted={A_TEMP: "a"}))
    [(title, codec)] = _sql(w, "SELECT m.title, m.codec FROM trackmetadata m JOIN tracks t "
                               "ON t.uuid_id = m.uuid_id WHERE t.file_path = ?", (str(w.paths["N"]),))
    assert (title, codec) == ("leftover B", "aac")


def test_d1_a_leftover_ffprobe_refuses_is_removed_when_the_tracks_file_hashed(tmp_path, caplog):
    w = settle(tmp_path, {"intent": "relocate", "db_at": "O", "o": 1, "n": 1, "t": 1,
                          "contents": {"N": b"X|junk"}},
               Expect(db="O", present={"O": A_OLD}, deleted={b"X|junk": "c", A_TEMP: "a"}), caplog)
    lines = [r.getMessage() for r in caplog.records if r.name == OPERATOR]
    assert any(w.uuid in line and "unreadable" in line for line in lines)


@pytest.mark.parametrize("leftover", [b"T|slow", b"H|nohash"], ids=["probe-timed-out", "hash-failed"])
def test_d1_a_leftover_whose_reading_is_unknown_is_never_removed(tmp_path, leftover):
    expect = (Expect(db="O", present={"O": A_OLD, "N": leftover}, unreferenced=("N",), deleted={A_TEMP: "a"})
              if leftover.startswith(b"T") else
              Expect(db="O", present={"O": A_OLD, "N": leftover}, tracks=("N",), deleted={A_TEMP: "a"}))
    settle(tmp_path, {"intent": "relocate", "db_at": "O", "o": 1, "n": 1, "t": 1,
                      "contents": {"N": leftover}}, expect)


def test_d2_an_unreadable_leftover_next_to_an_unreadable_track_is_left_and_logged(tmp_path, caplog):
    """The one documented exception to "no unreferenced file" (decision D2): the
    track's own file cannot be hashed and ffprobe refuses the leftover, so nothing
    proves anything; the leftover stays, the row goes, one distinct line."""
    w = settle(tmp_path, {"intent": "relocate", "db_at": "O", "o": 1, "n": 1, "t": 1,
                          "contents": {"O": b"H|track", "N": b"X|junk"}},
               Expect(db="O", present={"O": b"H|track", "N": b"X|junk"}, unreferenced=("N",),
                      deleted={A_TEMP: "a"}), caplog)
    lines = [r.getMessage() for r in caplog.records if r.name == OPERATOR]
    [line] = [x for x in lines if "left in place" in x]
    assert w.uuid in line and str(w.entry_id) in line and str(tmp_path) not in line


def test_a_track_whose_own_file_cannot_be_hashed_keeps_a_readable_leftover_as_a_track(tmp_path):
    settle(tmp_path, {"intent": "relocate", "db_at": "O", "o": 1, "n": 1, "t": 1,
                      "contents": {"O": b"H|track"}},
           Expect(db="O", present={"O": b"H|track", "N": A_NEW}, tracks=("N",), deleted={A_TEMP: "a"}))


# --- D7: the recovered name -------------------------------------------------------------------------


def test_d7_a_copy_placed_under_the_recovered_name_is_the_tracks_file(tmp_path):
    w = settle(tmp_path, {"intent": "convert", **CONVERT_ROWS["5"][0]}, CONVERT_ROWS["5"][1])
    assert w.paths["R"].name == f"song (recovered {w.entry_id}).m4a"
    assert _db_path(w) == str(w.paths["R"])


def test_k2_when_the_recovered_name_is_taken_too_the_row_is_kept_and_the_next_start_settles_it(
    tmp_path, caplog
):
    w = world(tmp_path, intent="convert", db_at="O", o=0, n=1, t=1)
    w.paths["R"].write_bytes(b"B|blocker")
    with caplog.at_level(logging.WARNING, logger=OPERATOR):
        run(w)
    assert len(_rows(w)) == 1
    assert w.paths["T"].read_bytes() == C_TEMP and w.paths["N"].read_bytes() == C_NEW
    assert any("kept" in r.getMessage() and w.uuid in r.getMessage()
               for r in caplog.records if r.name == OPERATOR)

    w.paths["R"].unlink()  # the fault is gone
    run(w)

    assert _rows(w) == [] and _db_path(w) == str(w.paths["R"])
    assert w.paths["R"].read_bytes() == C_TEMP


# --- D11: the startup durable point (K1) ------------------------------------------------------------


def test_startup_deletes_only_after_a_durable_point(tmp_path, monkeypatch):
    w = world(tmp_path, intent="relocate", db_at="N", o=1, n=1, t=0)
    seen = []

    def spy(*args, **kwargs):
        seen.append(w.paths["O"].exists())
        return True

    monkeypatch.setattr(w.db, "make_durable", spy)
    run(w)

    # s8-journal-flush: the first point is startup's own (before any row); the
    # second is the row's, still taken while the old master was there.
    assert seen == [True, True]
    assert not w.paths["O"].exists() and _rows(w) == []


@pytest.mark.parametrize("failure", [False, sqlite3.OperationalError("disk I/O error")], ids=["false", "raises"])
def test_k1_a_failed_startup_durable_point_keeps_the_row_and_deletes_nothing(
    tmp_path, monkeypatch, caplog, failure
):
    w = world(tmp_path, intent="relocate", db_at="N", o=1, n=1, t=0)

    def fail(*args, **kwargs):
        if isinstance(failure, BaseException):
            raise failure
        return failure

    monkeypatch.setattr(w.db, "make_durable", fail)
    with caplog.at_level(logging.WARNING, logger=OPERATOR):
        run(w)

    assert w.paths["O"].read_bytes() == A_OLD and len(_rows(w)) == 1
    assert any("kept" in r.getMessage() and w.uuid in r.getMessage()
               for r in caplog.records if r.name == OPERATOR)

    monkeypatch.undo()
    run(w)
    assert not w.paths["O"].exists() and _rows(w) == []


# --- rows are independent; logs carry no path -------------------------------------------------------


def test_one_row_whose_reading_fails_never_blocks_the_others(tmp_path):
    w = world(tmp_path, intent="relocate", db_at="O", o=1, n=1, t=1, contents={"N": b"E|boom"})
    other = Path(w.root / "Two" / "two.m4a")
    other.parent.mkdir()
    other.write_bytes(b"A|two")
    second = _add(w.db, other, INITIAL, title="Two")
    w.db.insert_journal_entry("inplace", second.uuid_id, str(other), None, None)

    run(w)

    remaining = _sql(w, "SELECT uuid_id FROM edit_journal")
    assert remaining == [(w.uuid,)]  # K2: kept, the other row settled
    assert w.paths["N"].read_bytes() == b"E|boom" and w.paths["O"].read_bytes() == A_OLD
    # Nothing was removed before the failure: the staged copy is still the row's
    # evidence that its move never happened (a consumed temp would make the next
    # start read the foreign file at the new path as the row's own output).
    assert w.paths["T"].read_bytes() == A_TEMP


@pytest.mark.parametrize("row", ["5", "9", "11", "12"])
def test_settle_lines_name_the_entry_and_the_track_never_a_path(tmp_path, caplog, row):
    kwargs, expect = CONVERT_ROWS[row]
    w = settle(tmp_path, {"intent": "convert", **kwargs}, expect, caplog)
    lines = [r.getMessage() for r in caplog.records if r.name == OPERATOR]
    assert lines and any(w.uuid in line and str(w.entry_id) in line for line in lines)
    for line in lines:
        assert str(tmp_path) not in line and "song" not in line and "Art" not in line


def test_an_adopted_copy_is_queued_for_re_hashing(tmp_path):
    w = world(tmp_path, intent="convert", db_at="O", o=0, n=1, t=0)
    w.db.insert_missing_identity_rows(fingerprinter_present=False, owner_id=ANY_OWNER)
    [(before,)] = _sql(w, "SELECT generation FROM track_audio_identity WHERE uuid_id = ?", (w.uuid,))

    run(w)

    [(generation, state)] = _sql(
        w, "SELECT generation, exact_state FROM track_audio_identity WHERE uuid_id = ?", (w.uuid,))
    assert generation > before and state == "pending"


# --- review of the first build (lead, 2026-11-16) ---------------------------------------------------


def test_f1_a_track_that_moved_on_never_loses_an_older_old_master_by_proof(tmp_path):
    """P-old after adopting the staged copy holds only for the row's own move: when
    the track moved on (X) and its file is missing, a staged copy placed at N does
    not prove that O is redundant; O goes to the content rule."""
    w = world(tmp_path, intent="convert", db_at="X", o=1, n=0, t=1, x=0,
              contents={"X": b"C|x"})
    # X has the staged copy's suffix: make it unusable so the copy lands at N.
    w.paths["X"].mkdir(parents=True)
    before_files = dict(_regular_files(w.tmp))
    run(w)

    assert _db_path(w) == str(w.paths["N"]) and w.paths["N"].read_bytes() == C_TEMP
    assert w.paths["O"].read_bytes() == F_OLD  # other audio: became a track, not deleted
    assert str(w.paths["O"]) in _track_paths(w)
    assert F_OLD in before_files.values()


def _fail(monkeypatch, db, name):
    def boom(*args, **kwargs):
        raise sqlite3.OperationalError("database is locked")

    monkeypatch.setattr(db, name, boom)


def test_f2_a_failed_adoption_puts_the_staged_copy_back_and_keeps_the_row(tmp_path, monkeypatch):
    w = world(tmp_path, intent="convert", db_at="O", o=0, n=1, t=1)  # row 5: copy -> recovered name
    _fail(monkeypatch, w.db, "refresh_track_audio_properties")

    run(w)

    assert w.paths["T"].read_bytes() == C_TEMP  # back where the row expects it
    assert not w.paths["R"].exists()
    assert w.paths["N"].read_bytes() == C_NEW
    assert len(_rows(w)) == 1

    monkeypatch.undo()
    run(w)  # the next start settles it
    assert _rows(w) == [] and _db_path(w) == str(w.paths["R"])


def test_f2_a_staged_copy_that_could_not_become_a_track_is_put_back(tmp_path, monkeypatch):
    w = world(tmp_path, intent="convert", db_at="N", o=0, n=1, t=1, contents={"T": b"B|temp"})
    _fail(monkeypatch, w.db, "add_track")

    run(w)

    assert w.paths["T"].read_bytes() == b"B|temp"
    assert not w.paths["R"].exists()
    assert len(_rows(w)) == 1


def test_f3_the_unreadable_line_is_written_only_when_the_file_was_removed(tmp_path, monkeypatch, caplog):
    w = world(tmp_path, intent="relocate", db_at="O", o=1, n=1, t=1, contents={"N": b"X|junk"})
    monkeypatch.setattr(w.db, "make_durable", lambda *a, **k: False)

    run(w, caplog)

    assert w.paths["N"].read_bytes() == b"X|junk" and len(_rows(w)) == 1
    lines = [r.getMessage() for r in caplog.records if r.name == OPERATOR]
    assert not any("unreadable" in line for line in lines)


def test_f4_an_in_place_redo_waits_for_the_durable_point(tmp_path, monkeypatch):
    """The redo replaces the old bytes: like any deletion it comes after the
    durable point, so a failed point keeps the row and both files."""
    w = world(tmp_path, intent="inplace", db_at="O", o=1, t=1)
    monkeypatch.setattr(w.db, "make_durable", lambda *a, **k: False)

    run(w)

    assert w.paths["O"].read_bytes() == A_OLD and w.paths["T"].read_bytes() == A_TEMP
    assert len(_rows(w)) == 1


def test_f5_an_in_place_row_of_a_gone_track_leaves_no_unreferenced_old_file(tmp_path):
    settle(tmp_path, {"intent": "inplace", "db_at": "gone", "o": 1, "t": 1},
           Expect(db=None, present={"O": A_OLD}, tracks=("O",), deleted={A_TEMP: "a"}))


@pytest.mark.parametrize("target_audio,old_survives", [(b"B|elsewhere", True), (b"A|elsewhere", False)],
                         ids=["other-audio", "same-audio"])
def test_f6_a_symlink_at_new_path_is_no_proof_that_the_old_master_is_redundant(
    tmp_path, target_audio, old_survives
):
    """s7 review F3, kept: P-old reads the name at N itself (lstat). A symlink
    there, even to a real file, proves nothing; O goes to the content rule against
    the file the link reaches (the track's file in place)."""
    w = world(tmp_path, intent="relocate", db_at="N", o=1, n=0, t=0)
    target = w.root / "elsewhere.m4a"
    target.write_bytes(target_audio)
    w.paths["N"].parent.mkdir(parents=True, exist_ok=True)
    w.paths["N"].symlink_to(target)

    run(w)

    assert w.paths["N"].is_symlink() and target.read_bytes() == target_audio
    assert _rows(w) == []
    if old_survives:
        assert w.paths["O"].read_bytes() == A_OLD
        assert str(w.paths["O"]) in _track_paths(w)  # other audio: a track of its own
    else:
        assert not w.paths["O"].exists()  # the same audio as the track's file: rule b


# --- review round 1 of the table (s8-recovery-settle-review-table.md) -------------------------------


class _Kill(BaseException):
    """A process killed mid-recovery: nothing after this point runs, no put-back."""


def _killed_at(monkeypatch, db, name):
    real = getattr(db, name)

    def kill(*args, **kwargs):
        raise _Kill()

    monkeypatch.setattr(db, name, kill)
    monkeypatch.setattr(journal_settle, "move_back", lambda *a, **k: False)
    return real


@pytest.mark.parametrize("intent", ["relocate", "convert"])
def test_r1_a_kill_after_the_staged_copy_moved_never_costs_the_foreign_audio_at_new_path(
    tmp_path, monkeypatch, intent
):
    """Review #1/#4: recovery's own move of the staged copy must not read, at the
    next start, as the operation's move: the foreign audio at N stays (as a track)
    and the staged copy ends as the track's file."""
    w = world(tmp_path, intent=intent, db_at="O", o=0, n=1, t=1, contents={"N": b"B|foreign"})
    _killed_at(monkeypatch, w.db, "refresh_track_audio_properties")
    with pytest.raises(_Kill):
        reconcile_journal(w.db, w.tmp, read_audio=fake_read)
    monkeypatch.undo()

    run(w)

    staged = A_TEMP if intent == "relocate" else C_TEMP
    final = w.paths["O"] if intent == "relocate" else w.paths["R"]
    assert w.paths["N"].read_bytes() == b"B|foreign"
    assert str(w.paths["N"]) in _track_paths(w)
    assert _db_path(w) == str(final) and final.read_bytes() == staged
    assert _rows(w) == []


def test_r1_a_kill_after_a_staged_copy_was_placed_under_the_recovered_name_settles_it_next_start(
    tmp_path, monkeypatch
):
    """D8 with other audio: the staged copy moves to the recovered name and becomes
    a track; a kill between the two leaves the recovered name as this row's own
    staged copy, which the next start settles (a track, never unreferenced)."""
    w = world(tmp_path, intent="convert", db_at="N", o=0, n=1, t=1, contents={"T": b"B|temp"})
    _killed_at(monkeypatch, w.db, "add_track")
    with pytest.raises(_Kill):
        reconcile_journal(w.db, w.tmp, read_audio=fake_read)
    monkeypatch.undo()

    run(w)

    assert w.paths["R"].read_bytes() == b"B|temp"
    assert str(w.paths["R"]) in _track_paths(w)
    assert _db_path(w) == str(w.paths["N"]) and _rows(w) == []


@pytest.mark.parametrize("row,o", [("9", 1), ("13", 0)])
def test_r1_a_staged_copy_nothing_can_read_is_never_swept(tmp_path, row, o, caplog):
    """Review #2: D2 for a staged copy: it is not left in .staging (the sweep would
    delete it) but placed under the recovered name, untouched otherwise."""
    w = settle(tmp_path, {"intent": "convert", "db_at": "N", "o": o, "n": 1, "t": 1,
                          "contents": {"T": b"T|slow"}},
               Expect(db="N", present={"N": C_NEW, "R": b"T|slow", **({"O": F_OLD} if o else {})},
                      tracks=("O",) if o else (), unreferenced=("R",)), caplog)
    assert any("left in place" in r.getMessage() for r in caplog.records if r.name == OPERATOR)


def test_r1_in_place_rows_with_an_old_file_present_leave_nothing_unreferenced(tmp_path):
    """Review #5: I5 with O present: O goes to the content rule against X."""
    settle(tmp_path, {"intent": "inplace", "db_at": "X", "o": 1, "t": 1, "x": 1},
           Expect(db="X", present={"X": b"A|x"}, deleted={A_OLD: "b", A_TEMP: "a"}))


def test_r1_an_in_place_row_whose_track_moved_on_to_a_missing_file_adopts_the_old_file(tmp_path):
    """Review #5: I6 with X missing and O present: O is the copy to adopt."""
    settle(tmp_path, {"intent": "inplace", "db_at": "X", "o": 1, "t": 0, "x": 0},
           Expect(db="O", present={"O": A_OLD}, columns="A"))


@pytest.mark.parametrize("intent", ["inplace", "relocate"])
def test_r1_a_gone_tracks_only_copy_becomes_a_track(tmp_path, intent):
    """Review #6: with the track gone and only the staged copy left, it is the only
    copy: placed under the recovered name and made a track, never deleted."""
    kwargs = {"o": 0, "t": 1} if intent == "inplace" else {"o": 0, "n": 0, "t": 1}
    w = settle(tmp_path, {"intent": intent, "db_at": "gone", **kwargs},
               Expect(db=None, present={"R": A_TEMP}, tracks=("R",)))
    assert w.paths["R"].name == f"song (recovered {w.entry_id}).m4a"


def test_r1_a_database_path_outside_the_root_is_never_a_placement_target(tmp_path):
    """Review #7: the track's own path is a target only inside the owner's root."""
    w = settle(tmp_path, {"intent": "relocate", "db_at": "outside", "o": 0, "n": 0, "t": 1},
               Expect(db="N", present={"N": A_TEMP}, columns="A"))
    assert not (tmp_path / "elsewhere").exists()


def test_r1_a_dangling_symlink_at_the_staged_path_is_no_proof_of_a_move(tmp_path):
    """Review #8: any entry at the staged name means the move did not consume it;
    the foreign audio at N goes to the content rule, not to P-new."""
    settle(tmp_path, {"intent": "relocate", "db_at": "O", "o": 1, "n": 1, "t": "dangling",
                      "contents": {"N": b"B|foreign"}},
           Expect(db="O", present={"O": A_OLD, "N": b"B|foreign"}, tracks=("N",)))


def test_r1_an_in_place_row_whose_old_path_is_a_folder_settles(tmp_path):
    """Review #9: the redo never replaces a folder; the staged copy goes under the
    recovered name and the track points there; the folder stays."""
    settle(tmp_path, {"intent": "inplace", "db_at": "O", "o": "dir", "t": 1},
           Expect(db="R", present={"R": A_TEMP}, columns="A", left=("O",)))


def test_r1_a_same_path_conversion_with_a_staged_folder_describes_the_original_again(tmp_path):
    """Review #9 nit (D9): the replace never happened, whatever is at the staged name."""
    settle(tmp_path, {"intent": "convert-inplace", "db_at": "O", "o": 1, "t": "dir"},
           Expect(db="O", present={"O": F_OLD}, columns="F", left=("T",)))


def test_r1_a_symlinked_master_to_another_tracks_file_never_proves_a_copy_redundant(tmp_path):
    """Review #10: when the track's file is a link (here to another track's master),
    nothing is deleted on its strength: the old master becomes a track."""
    w = world(tmp_path, intent="relocate", db_at="N", o=1, n=0, t=0)
    other = w.root / "Other" / "theirs.m4a"
    other.parent.mkdir()
    other.write_bytes(b"A|theirs")
    _add(w.db, other, INITIAL, title="Other")
    w.paths["N"].parent.mkdir(parents=True, exist_ok=True)
    w.paths["N"].symlink_to(other)

    run(w)

    assert w.paths["O"].read_bytes() == A_OLD
    assert str(w.paths["O"]) in _track_paths(w)
    assert other.read_bytes() == b"A|theirs" and _rows(w) == []


def test_r1_the_left_in_place_line_is_written_only_when_the_row_settles(tmp_path, monkeypatch, caplog):
    """Review #11 (as F3): a kept row writes no settle-outcome lines."""
    w = world(tmp_path, intent="relocate", db_at="O", o=1, n=1, t=1,
              contents={"O": b"H|track", "N": b"X|junk"})
    monkeypatch.setattr(w.db, "make_durable", lambda *a, **k: False)

    run(w, caplog)

    assert len(_rows(w)) == 1
    lines = [r.getMessage() for r in caplog.records if r.name == OPERATOR]
    assert not any("left in place" in line for line in lines)


# --- durability review (s8-recovery-settle-review-durability.md) ------------------------------------


def test_d1_rev_a_failure_after_the_track_points_at_the_placed_copy_never_takes_it_back(
    tmp_path, monkeypatch
):
    """Durability review #1: once the database points at the placed copy, a later
    failure keeps the row but never moves the copy back to staging."""
    w = world(tmp_path, intent="convert", db_at="O", o=0, n=0, t=1)  # row 7: T -> N
    real = w.db.delete_journal_entry

    def locked(*args, **kwargs):
        raise sqlite3.OperationalError("database is locked")

    monkeypatch.setattr(w.db, "delete_journal_entry", locked)
    reconcile_journal(w.db, w.tmp, read_audio=fake_read)
    monkeypatch.setattr(w.db, "delete_journal_entry", real)

    assert _db_path(w) == str(w.paths["N"]) and w.paths["N"].read_bytes() == C_TEMP
    assert len(_rows(w)) == 1
    run(w)
    assert _rows(w) == [] and w.paths["N"].read_bytes() == C_TEMP


def test_r1_a_staged_copy_an_earlier_run_placed_is_no_proof_that_the_old_file_is_redundant(
    tmp_path, monkeypatch
):
    """A copy recovery itself moved to the recovered name (and made a track) leaves
    the staged name empty; at the next start that must not read as "the move
    consumed it", which would let P-old remove an old file nothing could read."""
    w = world(tmp_path, intent="convert", db_at="N", o=1, n=1, t=1,
              contents={"O": b"T|slow", "T": b"B|temp"})
    _killed_at(monkeypatch, w.db, "delete_journal_entry")  # after placement and registration
    with pytest.raises(_Kill):
        reconcile_journal(w.db, w.tmp, read_audio=fake_read)
    monkeypatch.undo()
    assert str(w.paths["R"]) in _track_paths(w) and not w.paths["T"].exists()

    run(w)

    assert w.paths["O"].read_bytes() == b"T|slow"  # D2: left, never deleted by proof
    assert _rows(w) == []


@pytest.mark.parametrize("case", ["edit-row5", "convert-moved-on"])
def test_r2_a_leftover_nothing_can_read_survives_a_failed_row_delete_after_adoption(
    tmp_path, monkeypatch, case
):
    """Table re-check R-1: when a leftover's verdict is LEAVE, the staged copy is
    placed under the row's recovered name (recognisable at the next start), so a
    failure after the adoption never turns into a proof that removes the leftover."""
    if case == "edit-row5":
        w = world(tmp_path, intent="relocate", db_at="O", o=0, n=1, t=1, contents={"N": b"T|slow"})
        leftover = w.paths["N"]
    else:
        w = world(tmp_path, intent="convert", db_at="X", o=1, n=0, t=1, x=0,
                  contents={"O": b"T|slow"})
        w.paths["X"].mkdir(parents=True)  # the track's moved-on path is no file
        leftover = w.paths["O"]
    data = leftover.read_bytes()

    def locked(*args, **kwargs):
        raise sqlite3.OperationalError("database is locked")

    real = w.db.delete_journal_entry
    monkeypatch.setattr(w.db, "delete_journal_entry", locked)
    reconcile_journal(w.db, w.tmp, read_audio=fake_read)
    monkeypatch.setattr(w.db, "delete_journal_entry", real)
    assert len(_rows(w)) == 1

    run(w)

    assert leftover.read_bytes() == data  # D2: left, never deleted by proof
    assert _db_path(w) == str(w.paths["R"]) and _rows(w) == []
