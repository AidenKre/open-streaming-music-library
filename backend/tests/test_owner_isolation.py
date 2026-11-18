"""Phase M.0b two-user isolation (spec §4.6, review M-U06): sam and alex both
own "Radiohead / OK Computer"; each ``Library`` sees only its own rows, and
the owner predicate is in the SQL (it holds under ``LIMIT``)."""

import sqlite3
import uuid
from types import SimpleNamespace

import pytest

from app.database.database import (
    ConversionJobNotRunning,
    Database,
    HistoryEventConflict,
    OwnerMismatch,
)
from app.services.conversion import ConversionOrchestrator, reconcile_conversion_jobs
from app.services.cover_art_manager import CoverArtAddResult, CoverArtContext, CoverArtManager
from app.services.storage_ledger import StorageLedger
from app.services.track_editor import reconcile_journal
from app.services.track_locks import TrackLocks
from app.models.history import HistoryEvent
from app.services.history_hooks import register_history_hook, unregister_history_hook
from app.database import DatabaseContext, OrderParameter, SearchParameter, TrackNotFound
from app.library import Library
from app.models import Track, TrackMetaData
from tests.owned_database import OwnedTestDatabase, add_test_user
from tests.schema_fixtures import INIT_SQL


def _track(title, artist="Radiohead", album="OK Computer", n=1):
    return Track(
        file_path=f"/music/{artist}/{album}/{title}.flac",
        metadata=TrackMetaData(
            title=title, artist=artist, album=album, codec="flac", duration=1.0,
            bitrate_kbps=900.0, sample_rate_hz=44100, channels=2,
            track_number=n, disc_number=1,
        ),
    )


class Users:
    def __init__(self, db):
        self.db = db
        self.sam = Library(db, add_test_user(db, "sam"))
        self.alex = Library(db, add_test_user(db, "alex"))
        self.tracks = {"sam": [], "alex": []}

    def add(self, who, *tracks):
        library = getattr(self, who)
        for track in tracks:
            assert library.add_track(track)
            self.tracks[who].append(track.uuid_id)

    def uuids(self, who):
        return set(self.tracks[who])

    def parents(self, uuid_id):
        conn = sqlite3.connect(self.db.context.database_path)
        try:
            return conn.execute(
                "SELECT artist_id, album_id FROM trackmetadata WHERE uuid_id = ?",
                (uuid_id,),
            ).fetchone()
        finally:
            conn.close()


@pytest.fixture
def users(tmp_path):
    db = OwnedTestDatabase(
        DatabaseContext(database_path=tmp_path / "db.sqlite", init_sql_path=INIT_SQL)
    )
    assert db.initialize()
    users = Users(db)
    users.add("sam", _track("Airbag", n=1), _track("Lucky", n=2), _track("Karma Police", n=3))
    users.add("alex", _track("Paranoid Android", n=1), _track("Let Down", n=2))
    return users


# ── tracks: browse, counts, filters, single lookups ──────────────────────────

def test_browse_returns_only_the_owners_tracks(users):
    assert {t.uuid_id for t in users.sam.get_tracks()} == users.uuids("sam")
    assert {t.uuid_id for t in users.alex.get_tracks()} == users.uuids("alex")


def test_the_owner_predicate_holds_under_limit(users):
    # alex's tracks sort first by title; a predicate applied after LIMIT
    # would leave sam with an empty first page.
    users.add("alex", *[_track(f"A{i:02}", n=10 + i) for i in range(5)])
    order = [OrderParameter("title")]

    page = users.sam.get_tracks(order_parameters=order, limit=2)

    assert [t.uuid_id in users.uuids("sam") for t in page] == [True, True]


def test_counts_are_per_owner(users):
    assert users.sam.get_tracks_count() == 3
    assert users.alex.get_tracks_count() == 2


def test_filtering_by_another_owners_artist_or_album_finds_nothing(users):
    artist_id, album_id = users.parents(users.tracks["sam"][0])

    assert users.alex.get_tracks(artist_id=artist_id) == []
    assert users.alex.get_tracks(artist_id=artist_id, album_id=album_id) == []
    assert users.alex.get_tracks_count(artist_id=artist_id) == 0
    assert len(users.sam.get_tracks(artist_id=artist_id)) == 3


def test_search_parameters_naming_another_owners_track_find_nothing(users):
    theirs = users.tracks["sam"][0]
    by_uuid = [SearchParameter(column="uuid_id", operator="=", value=theirs)]

    assert users.alex.get_tracks(search_parameters=by_uuid) == []
    assert users.alex.get_tracks_count(search_parameters=by_uuid) == 0


def test_a_track_lookup_by_uuid_sees_only_the_owners_track(users):
    theirs = users.tracks["sam"][0]

    assert users.alex.get_track_by_uuid(theirs) is None
    assert users.sam.get_track_by_uuid(theirs).uuid_id == theirs


# ── metadata edits and file-path lookups ─────────────────────────────────────

def _title(users, uuid_id):
    conn = sqlite3.connect(users.db.context.database_path)
    try:
        return conn.execute(
            "SELECT title FROM trackmetadata WHERE uuid_id = ?", (uuid_id,)
        ).fetchone()[0]
    finally:
        conn.close()


def test_an_edit_of_another_owners_track_is_not_found_and_changes_nothing(users):
    theirs = users.sam.get_track_by_uuid(users.tracks["sam"][0])

    with pytest.raises(TrackNotFound):
        users.alex.apply_track_metadata_edit(theirs.uuid_id, {"title": "Stolen"}, theirs.revision)

    assert _title(users, theirs.uuid_id) == "Airbag"
    users.sam.apply_track_metadata_edit(theirs.uuid_id, {"title": "Mine"}, theirs.revision)
    assert _title(users, theirs.uuid_id) == "Mine"


def test_a_file_path_lookup_sees_only_the_owners_track(users):
    theirs = users.tracks["sam"][0]

    assert users.alex.get_track_file_path(theirs) is None
    assert users.sam.get_track_file_path(theirs) == "/music/Radiohead/OK Computer/Airbag.flac"


# ── delete, tombstones, all uuids ────────────────────────────────────────────

def test_deleting_another_owners_track_is_a_no_op(users):
    theirs = users.tracks["sam"][0]

    assert users.alex.delete_track(theirs) is False

    assert users.sam.get_track_by_uuid(theirs) is not None
    assert users.sam.get_track_tombstones() == []
    assert users.alex.get_track_tombstones() == []


def test_tombstones_are_per_owner(users):
    mine = users.tracks["sam"][0]

    assert users.sam.delete_track(mine) is True

    assert users.sam.get_track_tombstones() == [mine]
    assert users.alex.get_track_tombstones() == []


def test_all_track_uuids_are_per_owner(users):
    assert set(users.sam.get_all_track_uuids()) == users.uuids("sam")
    assert set(users.alex.get_all_track_uuids()) == users.uuids("alex")


# ── /changes: stream and latestRevision per owner ───────────────────────────

def test_the_change_stream_carries_only_the_owners_upserts_and_deletes(users):
    gone = users.tracks["alex"][0]
    assert users.alex.delete_track(gone)

    sam_changes, _, _ = users.sam.get_changes(after_revision=0, limit=100)
    alex_changes, _, _ = users.alex.get_changes(after_revision=0, limit=100)

    assert {(c.type, c.uuid_id) for c in sam_changes} == {
        ("upsert", u) for u in users.uuids("sam")
    }
    assert {(c.type, c.uuid_id) for c in alex_changes} == {
        ("upsert", users.tracks["alex"][1]), ("delete", gone),
    }


def test_the_change_stream_limit_applies_after_the_owner(users):
    seen = max(users.sam.get_track_by_uuid(u).revision for u in users.uuids("sam"))
    # Five of alex's revisions land between sam's synced rows and sam's next one.
    users.add("alex", *[_track(f"Later {i}", n=20 + i) for i in range(5)])
    last = _track("Last", n=9)
    users.add("sam", last)

    page, _, _ = users.sam.get_changes(after_revision=seen, limit=2)

    assert [c.uuid_id for c in page] == [last.uuid_id]


def test_latest_revision_is_the_owners_own(users):
    sam_latest = max(users.sam.get_track_by_uuid(u).revision for u in users.uuids("sam"))
    # alex writes after sam: the global counter moves past sam's rows.
    users.add("alex", _track("Newer", n=7))
    users.alex.delete_track(users.tracks["alex"][0])

    _, latest, _ = users.sam.get_changes(after_revision=0, limit=100)

    assert latest == sam_latest


# ── artists, albums, counts ──────────────────────────────────────────────────

def test_both_owners_own_their_own_radiohead(users):
    sam_artist, sam_album = users.parents(users.tracks["sam"][0])
    alex_artist, alex_album = users.parents(users.tracks["alex"][0])

    assert sam_artist != alex_artist and sam_album != alex_album
    assert [(a.id, a.name) for a in users.sam.get_artists()] == [(sam_artist, "Radiohead")]
    assert [(a.id, a.name) for a in users.alex.get_artists()] == [(alex_artist, "Radiohead")]


def test_artist_and_album_browse_and_counts_are_per_owner_under_limit(users):
    # alex's extra artists sort before "Radiohead".
    users.add("alex", *[_track(f"T{i}", artist=f"Air {i}", album=f"Moon {i}") for i in range(3)])
    sam_artist, sam_album = users.parents(users.tracks["sam"][0])

    assert [a.id for a in users.sam.get_artists(limit=1)] == [sam_artist]
    assert users.sam.get_artists_count() == 1
    assert users.alex.get_artists_count() == 4
    assert [a.id for a in users.sam.get_albums(limit=1)] == [sam_album]
    assert users.sam.get_albums_count() == 1
    assert users.alex.get_albums_count() == 4


def test_albums_of_another_owners_artist_are_empty(users):
    sam_artist, _ = users.parents(users.tracks["sam"][0])

    assert users.alex.get_albums(artist_id=sam_artist) == []
    assert users.alex.get_albums_count(artist_id=sam_artist) == 0
    assert len(users.sam.get_albums(artist_id=sam_artist)) == 1


# ── search: the owner joins the FTS query, LIMIT applies after it ────────────

def _lullabies(users):
    """sam: one long (low-ranked) match per type; alex: 12 short (high-ranked)
    matches per type, more than the limit."""
    mine = _track(
        "Lullaby for a long long evening",
        artist="The Lullaby Appreciation Society Band",
        album="Lullaby Sessions and other long names",
    )
    users.add("sam", mine)
    users.add("alex", *[
        _track(f"Lullaby {i}", artist=f"Lullaby {i}", album=f"Lullaby {i}") for i in range(12)
    ])
    return mine


def test_search_finds_the_owners_match_behind_more_than_limit_foreign_matches(users):
    mine = _lullabies(users)
    artist_id, album_id = users.parents(mine.uuid_id)

    results = users.sam.get_search_results("lullaby", limit_per_type=10)

    assert [t.uuid_id for t in results.tracks] == [mine.uuid_id]
    assert [a.id for a in results.artists] == [artist_id]
    assert [a.id for a in results.albums] == [album_id]


def test_search_never_returns_another_owners_rows(users):
    _lullabies(users)

    results = users.alex.get_search_results("lullaby", limit_per_type=50)

    assert len(results.tracks) == 12
    assert {t.owner_id for t in results.tracks} == {users.alex.owner_id}
    assert "The Lullaby Appreciation Society Band" not in {a.name for a in results.artists}
    assert "Lullaby Sessions and other long names" not in {a.name for a in results.albums}


# ── history: changes per owner, foreign event ids conflict, hooks get owners ─

def _event(**overrides):
    fields = dict(
        event_uuid=str(uuid.uuid4()), kind="listen", entity_type="track",
        entity_ref="t", occurred_at=1, seconds_played=1.0, track_length=2.0,
    )
    fields.update(overrides)
    return HistoryEvent(**fields)


def _history_uuids(library, after=0, limit=100):
    events, latest, _ = library.get_history_changes(after, limit)
    return [e["event_uuid"] for e in events], latest, events


def test_history_changes_and_latest_revision_are_per_owner(users):
    mine = _event()
    users.sam.insert_history_events([mine])
    users.alex.insert_history_events([_event(), _event()])

    sam_uuids, sam_latest, sam_events = _history_uuids(users.sam)
    alex_uuids, _, _ = _history_uuids(users.alex)

    assert sam_uuids == [mine.event_uuid]
    assert sam_latest == sam_events[0]["revision"]
    assert mine.event_uuid not in alex_uuids and len(alex_uuids) == 2


def test_history_changes_limit_applies_after_the_owner(users):
    first, second = _event(), _event()
    users.sam.insert_history_events([first])
    _, seen, _ = _history_uuids(users.sam)
    users.alex.insert_history_events([_event() for _ in range(5)])
    users.sam.insert_history_events([second])

    page, _, _ = _history_uuids(users.sam, after=seen, limit=1)

    assert page == [second.event_uuid]


def test_an_event_id_owned_by_another_user_conflicts_even_when_identical(users):
    theirs = _event()
    users.sam.insert_history_events([theirs])
    fresh = _event()

    with pytest.raises(HistoryEventConflict) as raised:
        users.alex.insert_history_events([fresh, theirs])

    assert raised.value.event_uuids == [theirs.event_uuid]
    assert _history_uuids(users.alex)[0] == []  # the whole batch rolled back
    assert _history_uuids(users.sam)[0] == [theirs.event_uuid]


def test_an_owners_own_replay_is_still_acknowledged(users):
    mine = _event()
    users.sam.insert_history_events([mine])

    assert users.sam.insert_history_events([mine]) == [mine.event_uuid]
    assert _history_uuids(users.sam)[0] == [mine.event_uuid]


def test_history_hooks_receive_each_new_events_owner(users):
    seen = []
    register_history_hook("capture", lambda conn, events: seen.extend(events))
    try:
        users.sam.insert_history_events([_event()])
        users.alex.insert_history_events([_event(), _event()])
    finally:
        unregister_history_hook("capture")

    assert [e["owner_id"] for e in seen] == [users.sam.owner_id] + [users.alex.owner_id] * 2


# ── conversion jobs ──────────────────────────────────────────────────────────

def _jobs(users):
    sam_job = users.sam.insert_conversion_job(users.tracks["sam"][0], "aac", "m4a", 192)
    alex_job = users.alex.insert_conversion_job(users.tracks["alex"][0], "aac", "m4a", 192)
    return sam_job, alex_job


def _status(users, job_id):
    conn = sqlite3.connect(users.db.context.database_path)
    try:
        return conn.execute(
            "SELECT status FROM conversion_jobs WHERE id = ?", (job_id,)
        ).fetchone()[0]
    finally:
        conn.close()


def test_job_lists_and_lookups_are_per_owner(users):
    sam_job, alex_job = _jobs(users)

    jobs, _ = users.sam.list_conversion_jobs()
    assert [j["id"] for j in jobs] == [sam_job]
    assert users.sam.list_conversion_jobs(uuid_id=users.tracks["alex"][0]) == ([], None)
    assert [j["id"] for j in users.sam.list_conversion_jobs_with_status("queued")] == [sam_job]
    assert users.sam.get_conversion_job(alex_job) is None
    assert users.alex.get_conversion_job(alex_job)["id"] == alex_job


def test_the_job_list_limit_applies_after_the_owner(users):
    alex_jobs = [
        users.alex.insert_conversion_job(u, "mp3", "mp3", 320) for u in users.tracks["alex"]
    ]
    sam_job = users.sam.insert_conversion_job(users.tracks["sam"][1], "aac", "m4a", 192)

    jobs, _ = users.sam.list_conversion_jobs(limit=1)

    assert alex_jobs and [j["id"] for j in jobs] == [sam_job]


def test_job_transitions_on_another_owners_job_change_nothing(users):
    sam_job, alex_job = _jobs(users)

    assert users.sam.mark_conversion_job_cancelled(alex_job) is False
    assert users.sam.mark_conversion_job_running(alex_job) is False
    assert users.sam.mark_conversion_job_failed(alex_job, "x") is False
    assert _status(users, alex_job) == "queued"

    assert users.alex.mark_conversion_job_running(alex_job) is True
    with pytest.raises(ConversionJobNotRunning):
        users.sam.complete_conversion_job(
            alex_job, users.tracks["alex"][0], "aac", 192.0, 44100, 2
        )
    assert _status(users, alex_job) == "running"


def test_restart_reconcile_fails_every_owners_orphaned_running_job(users, tmp_path):
    sam_job, alex_job = _jobs(users)
    assert users.sam.mark_conversion_job_running(sam_job)
    assert users.alex.mark_conversion_job_running(alex_job)

    reconcile_conversion_jobs(users.db, tmp_path / "no-staging")

    assert (_status(users, sam_job), _status(users, alex_job)) == ("failed", "failed")


def test_resume_resubmits_every_owners_queued_job(users, tmp_path):
    sam_job, alex_job = _jobs(users)
    submitted = []
    orchestrator = ConversionOrchestrator(
        database=users.db, music_library_dir=tmp_path, staging_dir=tmp_path / ".staging",
        track_locks=TrackLocks(),
        storage_ledger=StorageLedger(
            users.db, path=tmp_path, floor_bytes=0, boot_id="test-boot"
        ),
        encoder_coordinator=SimpleNamespace(
            submit_conversion=lambda fn, job_id: submitted.append(job_id)
        ),
        cache=None, default_cache=None, available_encoders=frozenset(),
    )

    orchestrator.resume_queued()

    assert sorted(submitted) == sorted([sam_job, alex_job])


# ── edit journal ─────────────────────────────────────────────────────────────

def _journal(users):
    sam_entry = users.sam.insert_journal_entry("inplace", users.tracks["sam"][0])
    alex_entry = users.alex.insert_journal_entry("inplace", users.tracks["alex"][0])
    return sam_entry, alex_entry


def _journal_ids(users):
    conn = sqlite3.connect(users.db.context.database_path)
    try:
        return sorted(r[0] for r in conn.execute("SELECT id FROM edit_journal"))
    finally:
        conn.close()


def test_journal_reads_are_per_owner(users):
    sam_entry, alex_entry = _journal(users)

    assert [e["id"] for e in users.sam.list_journal_entries()] == [sam_entry]
    assert users.sam.has_journal_entry_for_uuid(users.tracks["alex"][0]) is False
    assert users.alex.has_journal_entry_for_uuid(users.tracks["alex"][0]) is True


def test_deleting_another_owners_journal_entry_changes_nothing(users):
    sam_entry, alex_entry = _journal(users)

    users.sam.delete_journal_entry(alex_entry)

    assert _journal_ids(users) == sorted([sam_entry, alex_entry])


def test_startup_reconcile_finishes_every_owners_journal_rows(users, tmp_path):
    _journal(users)

    reconcile_journal(users.db, tmp_path)

    assert _journal_ids(users) == []


# ── cover-art backfill (ANY_OWNER worker) ────────────────────────────────────

def _art_missing_track(tmp_path, title):
    track = _track(title)
    track.file_path = tmp_path / f"{title}.flac"
    track.file_path.write_bytes(b"audio with art")
    track.metadata.has_album_art = True
    return track


def _cover_art_id(users, uuid_id):
    conn = sqlite3.connect(users.db.context.database_path)
    try:
        return conn.execute(
            "SELECT cover_art_id FROM trackmetadata WHERE uuid_id = ?", (uuid_id,)
        ).fetchone()[0]
    finally:
        conn.close()


def test_missing_art_reads_and_assignments_are_per_owner(users, tmp_path):
    mine, theirs = _art_missing_track(tmp_path, "A"), _art_missing_track(tmp_path, "B")
    users.add("sam", mine)
    users.add("alex", theirs)
    art = users.db.insert_cover_art("sha", "ph", "pp", str(tmp_path / "art.jpg"))

    assert [t.uuid_id for t in users.sam.get_tracks_missing_cover_art()] == [mine.uuid_id]
    assert users.sam.update_track_cover_art_id(theirs.uuid_id, art) is False
    assert _cover_art_id(users, theirs.uuid_id) is None
    assert users.alex.update_track_cover_art_id(theirs.uuid_id, art) is True


def test_startup_backfill_covers_every_owners_tracks(users, tmp_path, monkeypatch):
    mine, theirs = _art_missing_track(tmp_path, "A"), _art_missing_track(tmp_path, "B")
    users.add("sam", mine)
    users.add("alex", theirs)
    art = users.db.insert_cover_art("sha", "ph", "pp", str(tmp_path / "art.jpg"))
    manager = CoverArtManager(
        ctx=CoverArtContext(cover_art_dir=tmp_path / "art", database=users.db)
    )
    monkeypatch.setattr(
        "app.services.cover_art_manager.extract_cover_art_bytes", lambda path: b"img"
    )
    monkeypatch.setattr(manager, "add_album_art_with_status",
                        lambda image_bytes: CoverArtAddResult(art, False))

    manager.backfill_cover_art()

    assert (_cover_art_id(users, mine.uuid_id), _cover_art_id(users, theirs.uuid_id)) == (art, art)


# ── user settings ────────────────────────────────────────────────────────────

def test_user_settings_are_per_owner(users):
    users.sam.set_user_setting("default_streaming_quality", "320")
    users.alex.set_user_setting("default_streaming_quality", "96")
    users.sam.set_user_setting("default_streaming_quality", "256")

    assert users.sam.get_user_setting("default_streaming_quality") == "256"
    assert users.alex.get_user_setting("default_streaming_quality") == "96"
    assert users.alex.get_user_setting("never_set") is None


# ── consistency asserts: a track only ever links its own owner's parents ─────
# These simulate a future missed owner predicate in the upserts.

def _force_parent(monkeypatch, which, parent_id):
    if which == "artist":
        monkeypatch.setattr(Database, "_upsert_artist", lambda self, conn, *a, **k: parent_id)
    else:
        monkeypatch.setattr(Database, "_upsert_album", lambda self, conn, *a, **k: parent_id)


def _count_tracks(users, uuid_id):
    conn = sqlite3.connect(users.db.context.database_path)
    try:
        return conn.execute(
            "SELECT count(*) FROM tracks WHERE uuid_id = ?", (uuid_id,)
        ).fetchone()[0]
    finally:
        conn.close()


@pytest.mark.parametrize("which", ["artist", "album"])
def test_add_track_refuses_another_owners_artist_or_album(users, monkeypatch, which):
    alex_artist, alex_album = users.parents(users.tracks["alex"][0])
    _force_parent(monkeypatch, which, alex_artist if which == "artist" else alex_album)
    track = _track("Exit Music")

    assert users.sam.add_track(track) is False

    assert _count_tracks(users, track.uuid_id) == 0


@pytest.mark.parametrize("which", ["artist", "album"])
def test_an_edit_refuses_another_owners_artist_or_album(users, monkeypatch, which):
    alex_artist, alex_album = users.parents(users.tracks["alex"][0])
    mine = users.sam.get_track_by_uuid(users.tracks["sam"][0])
    before = users.parents(mine.uuid_id)
    _force_parent(monkeypatch, which, alex_artist if which == "artist" else alex_album)

    with pytest.raises(OwnerMismatch):
        users.sam.apply_track_metadata_edit(
            mine.uuid_id, {"artist": "Thom Yorke", "album": "Eraser"}, mine.revision
        )

    assert users.parents(mine.uuid_id) == before
    assert users.sam.get_track_by_uuid(mine.uuid_id).revision == mine.revision


def test_filtering_uuids_keeps_only_the_owners_in_order(users):
    mine, theirs = users.tracks["sam"], users.tracks["alex"]

    kept = users.sam.filter_owned_track_uuids([theirs[0], mine[1], "nope", mine[0]])

    assert kept == [mine[1], mine[0]]


# ── review r1: workers act as the row's owner ────────────────────────────────

def test_the_conversion_worker_runs_another_users_job_as_its_owner(users, tmp_path):
    # alex's master is missing: run as alex the job fails; run as anyone else
    # it could not even be claimed and would stay queued forever.
    _, alex_job = _jobs(users)
    orchestrator = ConversionOrchestrator(
        database=users.db, music_library_dir=tmp_path, staging_dir=tmp_path / ".staging",
        track_locks=TrackLocks(),
        storage_ledger=StorageLedger(
            users.db, path=tmp_path, floor_bytes=0, boot_id="test-boot"
        ),
        encoder_coordinator=SimpleNamespace(submit_conversion=lambda fn, job_id: None),
        cache=None, default_cache=None, available_encoders=frozenset({"aac"}),
    )

    orchestrator._run_job(alex_job)

    assert _status(users, alex_job) == "failed"


@pytest.mark.parametrize("intent", ["relocate", "convert"])
def test_reconcile_keeps_another_users_committed_relocated_master(users, tmp_path, intent):
    old, new = tmp_path / "alex" / "old.flac", tmp_path / "alex" / "moved" / "new.m4a"
    new.parent.mkdir(parents=True)
    old.write_bytes(b"old master")
    new.write_bytes(b"committed master")
    moved = _track("Moved")
    moved.file_path = new  # the relocate's DB commit landed
    users.add("alex", moved)
    users.alex.insert_journal_entry(intent, moved.uuid_id, old_path=str(old), new_path=str(new))

    reconcile_journal(users.db, tmp_path)

    assert new.read_bytes() == b"committed master"
    assert not old.exists()
    assert _journal_ids(users) == []


def test_startup_backfill_skips_a_user_being_deleted(users, tmp_path, monkeypatch):
    """Review r1 m-R1-09: art added after a delete's capture would leak; a
    user left ``deleting`` (refused boot resume) gets no new art."""
    mine, theirs = _art_missing_track(tmp_path, "A"), _art_missing_track(tmp_path, "B")
    users.add("sam", mine)
    users.add("alex", theirs)
    art = users.db.insert_cover_art("sha", "ph", "pp", str(tmp_path / "art.jpg"))
    manager = CoverArtManager(
        ctx=CoverArtContext(cover_art_dir=tmp_path / "art", database=users.db)
    )
    monkeypatch.setattr(
        "app.services.cover_art_manager.extract_cover_art_bytes", lambda path: b"img"
    )
    added = []
    monkeypatch.setattr(manager, "add_album_art_with_status",
                        lambda image_bytes: added.append(1) or CoverArtAddResult(art, False))
    users.db.mark_user_deleting(users.sam.owner_id, 1)

    manager.backfill_cover_art()

    assert (_cover_art_id(users, mine.uuid_id), _cover_art_id(users, theirs.uuid_id)) == (None, art)
    assert added == [1]
