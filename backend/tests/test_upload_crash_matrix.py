"""7A.3c exit proof (spec §6 crash list, 7-U07; 7-U06 invariant): every crash
boundary of an upload commit, on each publication path, followed by two
restarts, converges: no lost stage, no dangling row, no duplicate track, no
unrelated deletion; art recovers on an import and is released on a conflict
or failure, while art another track shares survives.

Paths:
- import: nothing in the way;
- preflight conflict: an unacknowledged exact match exists before the commit;
- transaction conflict: the match appears after the move (inserted by the
  seam at ``before_insert_commit``), so the insert transaction finds it;
- collision: an unrelated file appears at the final path (written by the seam
  at ``before_link``).

Placement modes (sign-off DEV-7-25 link fallback): every path runs with hard
links (``link``), on a library that refuses them on one filesystem
(``rename``), across filesystems where the destination takes links
(``copy``), and across filesystems onto a library without links
(``copy-rename``). The refusal holds through the restarts too.

A restart is the startup journal step followed by a fresh commit worker (new
boot id) draining its queue."""

import errno
import os
from pathlib import Path

import pytest

from app.services import organizer, upload_commit, upload_publish
from app.services.upload_publish import SimulatedCrash
from tests.identity_worker_fixtures import add_track, make_db, sql
from tests.owned_database import add_test_user
from tests.upload_commit_fixtures import journal, reservations
from tests.upload_publish_fixtures import library_track, track_row
from tests.upload_recovery_fixtures import World, art_ids
from tests.upload_validation_fixtures import item_row, stage_item

WORKER = list(upload_commit.SEAM_POINTS)
IMPORT_POINTS = WORKER + ["before_link", "after_link", "after_moved_journal", "after_work_unlink",
                          "before_insert_commit", "after_insert_commit", "after_source_removed"]
# after_art_registered: the art adopted at restart (7A.3a review #2, test_upload_recovery_art.py).
PREFLIGHT_CONFLICT_POINTS = WORKER + ["after_conflict_journal", "after_conflict_cleanup"]
TXN_CONFLICT_POINTS = ["after_conflict_journal", "after_conflict_cleanup"]
COLLISION_POINTS = ["after_failure_journal"]
# The fallback's own boundaries, by mode (the copy's are reached only in the copy modes).
FALLBACK_POINTS = {
    "link": [],
    "rename": ["after_place_record"],
    "copy": ["after_place_record", "mid_copy", "after_copy", "after_temp_placed"],
    "copy-rename": ["after_place_record", "mid_copy", "after_copy", "after_temp_placed"],
}
MODES = list(FALLBACK_POINTS)
_real_link = os.link


class Seam:
    """Records points, runs a side effect at one point, crashes at another."""

    def __init__(self, crash_at, *, effect_at=None, effect=None):
        self.crash_at, self.effect_at, self.effect = crash_at, effect_at, effect
        self.points = []

    def __call__(self, name):
        self.points.append(name)
        if name == self.effect_at and self.effect is not None:
            self.effect()
        if name == self.crash_at:
            raise SimulatedCrash(name)


@pytest.fixture
def db(tmp_path):
    return make_db(tmp_path)


@pytest.fixture
def music(tmp_path):
    path = tmp_path / "music"
    (path / ".uploads").mkdir(parents=True)
    return path


@pytest.fixture
def world(db, music):
    return World(db, music)


@pytest.fixture(params=MODES)
def mode(request, monkeypatch, music):
    """How the library takes the placed file, for the whole test (crash and restarts)."""
    name = request.param
    uploads = music / ".uploads"
    if name != "link":
        err = errno.ENOTSUP if name == "rename" else errno.EXDEV

        def link(src, dst, *args, **kwargs):
            if name == "copy" and not Path(src).is_relative_to(uploads):
                return _real_link(src, dst, *args, **kwargs)  # the temp -> final link
            raise OSError(err, os.strerror(err))

        monkeypatch.setattr(organizer.os, "link", link)
    return name


@pytest.fixture
def bystanders(db, music):
    other = add_test_user(db, "bystander")
    staged = stage_item(db, music / ".uploads", owner_id=other, state="review_ready", content=b"theirs")
    loose = music / "loose.txt"
    loose.write_bytes(b"not ours")
    master = music / "other-master.flac"
    master.write_bytes(b"master")
    add_track(db, master, owner_id=other)
    return {"staged": staged, "loose": loose, "master": master}


def crash(world, commit, seam):
    with pytest.raises(SimulatedCrash):
        world.worker(seam=seam).process_one()
    assert seam.points[-1] == seam.crash_at


def staged_files(world, commit) -> list[str]:
    root = world.music / ".uploads" / str(commit["owner_id"])
    return sorted(str(p.relative_to(root)) for p in root.rglob("*") if p.is_file())


def converge(world, commit, bystanders):
    world.restart()
    world.restart()
    db = world.db
    # No dangling or duplicate rows, no journal left, receipts kept.
    assert sql(db, "SELECT count(*) AS n FROM upload_commit_journal")[0]["n"] == 0
    assert sql(db, "SELECT kind FROM operation_receipts WHERE owner_id = ? AND operation_uuid = ?",
               (commit["owner_id"], commit["op"])) == [{"kind": "upload_commit"}]
    # Nothing unrelated touched.
    assert bystanders["staged"]["source"].read_bytes() == b"theirs"
    assert bystanders["loose"].read_bytes() == b"not ours"
    assert bystanders["master"].read_bytes() == b"master"
    # No copy's temp left anywhere in the library.
    assert [p for p in world.music.rglob("*.osml-part")] == []


def assert_imported(world, commit):
    db = world.db
    item = item_row(db, commit)
    assert item["state"] == "imported"
    tracks = sql(db, "SELECT uuid_id, file_path FROM tracks WHERE uuid_id = ?", (commit["track"],))
    assert len(tracks) == 1
    with open(tracks[0]["file_path"], "rb") as f:
        assert f.read() == commit["content"]
    assert sql(db, "SELECT count(*) AS n FROM tracks WHERE file_path = ?", (tracks[0]["file_path"],))[0]["n"] == 1
    assert staged_files(world, commit) == []  # no stage (or placement record) left behind
    assert [r["purpose"] for r in reservations(db, commit["owner_id"])] == []
    [meta] = sql(db, "SELECT cover_art_id FROM trackmetadata WHERE uuid_id = ?", (commit["track"],))
    assert meta["cover_art_id"] is not None and meta["cover_art_id"] in art_ids(db)


def assert_retained_review(world, commit, state):
    db = world.db
    item = item_row(db, commit)
    assert item["state"] == state
    assert track_row(db, commit["track"]) is None  # never inserted
    assert commit["source"].read_bytes() == commit["content"]  # no lost stage
    assert staged_files(world, commit) == [str(commit["source"].relative_to(
        world.music / ".uploads" / str(commit["owner_id"])))]
    assert [r["purpose"] for r in reservations(db, commit["owner_id"])] == ["upload_source"]


def _import_cases():
    return [(m, p) for m in MODES for p in IMPORT_POINTS[:len(WORKER) + 1] + FALLBACK_POINTS[m]
            + IMPORT_POINTS[len(WORKER) + 1:]]


@pytest.mark.parametrize("mode, point", _import_cases(), indirect=["mode"])
def test_import_path(world, bystanders, mode, point):
    commit = world.commit()
    crash(world, commit, Seam(point))

    converge(world, commit, bystanders)

    assert_imported(world, commit)


@pytest.mark.parametrize("point", PREFLIGHT_CONFLICT_POINTS)
def test_preflight_conflict_path(world, bystanders, mode, point):
    winner = library_track(world.db, world.music, b"audio-A")
    commit = world.commit()
    crash(world, commit, Seam(point))

    converge(world, commit, bystanders)

    assert_retained_review(world, commit, "duplicate_conflict")
    assert item_row(world.db, commit)["conflict_track_uuids"] == f'["{winner}"]'
    assert art_ids(world.db) == []  # this operation's art, unreferenced: released


@pytest.mark.parametrize("point", TXN_CONFLICT_POINTS)
@pytest.mark.parametrize("shared_art", [False, True])
def test_transaction_conflict_path(world, bystanders, mode, point, shared_art):
    commit = world.commit()
    holder = {}

    def race():
        holder["winner"] = library_track(world.db, world.music, b"audio-A")
        if shared_art:
            art = journal(world.db, commit)["cover_art_id"]
            sql(world.db, "UPDATE trackmetadata SET cover_art_id = ? WHERE uuid_id = ?", (art, holder["winner"]))
            holder["art"] = art

    crash(world, commit, Seam(point, effect_at="before_insert_commit", effect=race))
    final = journal(world.db, commit)["final_path"]

    converge(world, commit, bystanders)

    assert_retained_review(world, commit, "duplicate_conflict")
    assert not os.path.lexists(final)  # the placed file was this operation's
    assert art_ids(world.db) == ([holder["art"]] if shared_art else [])  # shared art survives


@pytest.mark.parametrize("point", COLLISION_POINTS)
def test_collision_path(world, bystanders, mode, point):
    commit = world.commit()
    holder = {}

    def collide():
        final = journal(world.db, commit)["final_path"]
        os.makedirs(os.path.dirname(final), exist_ok=True)
        with open(final, "wb") as f:
            f.write(b"someone else's file")
        holder["final"] = final

    crash(world, commit, Seam(point, effect_at="before_link", effect=collide))

    converge(world, commit, bystanders)

    assert_retained_review(world, commit, "review_ready")
    assert item_row(world.db, commit)["error_code"] == "upload_commit_failed"
    with open(holder["final"], "rb") as f:
        assert f.read() == b"someone else's file"  # never replaced, never removed
    assert art_ids(world.db) == []


@pytest.mark.parametrize("point", ["after_work_unlink", "before_insert_commit"])
def test_a_lost_moved_commit_path(world, bystanders, mode, point):
    """Row HP (sign-off s7-live-findings item 3): a power cut loses the
    ``moved`` commit but keeps the work file's removal. Restart finds the
    journal ``prepared``, no work file and the file at the final name: on the
    link path its name and audio prove it this import's (no placement record
    exists there); on the fallback paths its record does. Either way the
    import finishes."""
    commit = world.commit()
    crash(world, commit, Seam(point))
    sql(world.db, "UPDATE upload_commit_journal SET state = 'prepared'"
                  " WHERE owner_id = ? AND operation_uuid = ? AND state = 'moved'",
        (commit["owner_id"], commit["op"]))
    assert not os.path.lexists(commit["work"])

    converge(world, commit, bystanders)

    assert_imported(world, commit)


def test_the_matrix_covers_every_seam():
    covered = (set(IMPORT_POINTS) | set(PREFLIGHT_CONFLICT_POINTS) | set(TXN_CONFLICT_POINTS)
               | set(COLLISION_POINTS) | {p for points in FALLBACK_POINTS.values() for p in points})
    assert covered == set(upload_commit.SEAM_POINTS) | set(upload_publish.SEAM_POINTS)
