"""Piece 8A.3a: ``open_track_source`` is the stream route's only way to a file
(spec §5 "Reader and mutation coordination", SC-16i with its Phase M note,
SC-16j; review cases 8-U05 and 8-D08).

Races are instrumented, never timed: ``track_source._after_row_read`` runs on
the request thread right after the row the headers will come from is read and
before the encode / ``open()``; a test replaces it to mutate the library at
exactly that point. ``track_source._open_source`` is wrapped to record every
path the helper opens.
"""

import sqlite3
from pathlib import Path

import pytest

from app.models import Track, TrackMetaData
from app.services import track_source
from app.services.encoder_coordinator import EncoderCoordinator
from tests.pending_deletion import mark_pending_deletion
from tests.sqlite_helpers import sql_rows

UNKNOWN = "00000000-0000-4000-8000-000000000000"


@pytest.fixture
def client(app_client):
    return app_client


@pytest.fixture
def opened(monkeypatch):
    """Every file object the helper opened, in order (path, file)."""
    record: list[tuple[Path, object]] = []
    real = track_source._open_source

    def spy(path):
        f = real(path)
        record.append((Path(path), f))
        return f

    monkeypatch.setattr(track_source, "_open_source", spy)
    return record


def _on_row_read(monkeypatch, action):
    """Run ``action(track)`` once, at the first pause between row read and open."""
    calls: list[Track] = []

    def hook(track):
        calls.append(track)
        if len(calls) == 1:
            action(track)

    monkeypatch.setattr(track_source, "_after_row_read", hook)
    return calls


def _db_path(client) -> Path:
    return Path(client.app.state.database.context.database_path)


def _add(client, tmp_path, name="song.mp3", data=b"original-bytes" * 50, codec="mp3"):
    path = tmp_path / name
    path.write_bytes(data)
    track = Track(
        file_path=path,
        metadata=TrackMetaData(title=name, duration=1.0, codec=codec, bitrate_kbps=320.0),
    )
    assert client.app.state.admin_library.add_track(track=track)
    return track.uuid_id, path


def _unknown_body(uuid_id: str, client) -> dict:
    """The exact 404 an unknown uuid answers, re-keyed to ``uuid_id``."""
    r = client.get(f"/tracks/{UNKNOWN}/stream")
    assert r.status_code == 404
    return {"detail": r.json()["detail"].replace(UNKNOWN, uuid_id)}


def _install_coordinator(client, transcode_fn) -> EncoderCoordinator:
    """The app's coordinator, rebuilt around a fake transcode (no ffmpeg)."""
    old: EncoderCoordinator = client.app.state.encoder_coordinator
    coordinator = EncoderCoordinator(
        cache=client.app.state.encoded_cache,
        source_lookup=old.source_lookup,
        workers=1,
        transcode_fn=transcode_fn,
        default_cache=client.app.state.default_cache,
        default_quality=old.default_quality,
        admin_owner_id=old.admin_owner_id,
        owner_lookup=old.owner_lookup,
    )
    old.shutdown()
    client.app.state.encoder_coordinator = coordinator
    return coordinator


def _fake_transcode(calls):
    def transcode(src: Path, dst: Path, bitrate: int) -> bool:
        calls.append(Path(src))
        if not Path(src).exists():
            return False
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_bytes(b"aac:" + Path(src).read_bytes()[:32])
        return True

    return transcode


def _evict(client, uuid_id):
    client.app.state.encoded_cache.remove_all_for_uuid(uuid_id)
    if client.app.state.default_cache is not None:
        client.app.state.default_cache.remove_all_for_uuid(uuid_id)


# ── Pending deletion and tombstones before any open (O3) ─────────────────────


def test_a_pending_track_answers_410_and_opens_nothing(client, tmp_path, opened):
    uuid_id, _ = _add(client, tmp_path)
    mark_pending_deletion(_db_path(client), uuid_id)

    r = client.get(f"/tracks/{uuid_id}/stream")

    assert r.status_code == 410
    assert r.json()["detail"]["error"] == "track_pending_deletion"
    assert r.json()["detail"]["retryable"] is True
    assert str(tmp_path) not in r.text
    assert opened == []


def test_a_tombstoned_track_answers_exactly_like_an_unknown_one(client, tmp_path, opened):
    uuid_id, _ = _add(client, tmp_path)
    assert client.app.state.admin_library.delete_track(uuid_id)

    r = client.get(f"/tracks/{uuid_id}/stream")

    assert r.status_code == 404
    assert r.json() == _unknown_body(uuid_id, client)
    assert opened == []


# ── Races at the pause between row read and open (8-D08, deletion half) ─────


def test_a_deletion_committed_after_the_row_read_answers_404(client, tmp_path, monkeypatch, opened):
    uuid_id, _ = _add(client, tmp_path)
    _on_row_read(monkeypatch, lambda t: client.app.state.admin_library.delete_track(uuid_id))

    r = client.get(f"/tracks/{uuid_id}/stream")

    assert r.status_code == 404
    assert r.json() == _unknown_body(uuid_id, client)
    assert all(f.closed for _, f in opened)


def test_a_marker_planted_after_the_row_read_answers_410_and_closes_the_file(
    client, tmp_path, monkeypatch, opened
):
    # The master is still in place, so the open succeeds; the re-read refuses it.
    uuid_id, _ = _add(client, tmp_path)
    _on_row_read(monkeypatch, lambda t: mark_pending_deletion(_db_path(client), uuid_id))

    r = client.get(f"/tracks/{uuid_id}/stream")

    assert r.status_code == 410
    assert r.json()["detail"]["error"] == "track_pending_deletion"
    assert all(f.closed for _, f in opened)


def test_a_master_moved_to_quarantine_is_never_opened(client, tmp_path, monkeypatch, opened):
    uuid_id, master = _add(client, tmp_path)
    quarantine = tmp_path / ".deleting" / f"{uuid_id}.mp3"

    def delete_pending(track):
        mark_pending_deletion(_db_path(client), uuid_id)
        quarantine.parent.mkdir(parents=True)
        master.rename(quarantine)

    _on_row_read(monkeypatch, delete_pending)

    r = client.get(f"/tracks/{uuid_id}/stream")

    assert r.status_code == 410
    assert r.json()["detail"]["error"] == "track_pending_deletion"
    assert quarantine not in [p for p, _ in opened]
    assert str(tmp_path) not in r.text


# ── Encoder path: failures re-read and map, never 500 for a gone track ──────


def test_a_late_encode_for_a_pending_track_answers_410_not_500(client, tmp_path, monkeypatch, opened):
    calls: list[Path] = []
    _install_coordinator(client, _fake_transcode(calls))
    uuid_id, _ = _add(client, tmp_path)

    def delete_pending(track):
        mark_pending_deletion(_db_path(client), uuid_id)
        _evict(client, uuid_id)

    _on_row_read(monkeypatch, delete_pending)

    r = client.get(f"/tracks/{uuid_id}/stream", params={"quality": "128"})

    assert r.status_code == 410
    assert r.json()["detail"]["error"] == "track_pending_deletion"
    assert len(calls) == 1  # the encode ran ...
    assert not client.app.state.encoded_cache.has(uuid_id, "128")  # ... and was dropped


def test_a_late_encode_for_a_deleted_track_answers_404_not_500(client, tmp_path, monkeypatch, opened):
    calls: list[Path] = []
    _install_coordinator(client, _fake_transcode(calls))
    uuid_id, _ = _add(client, tmp_path)

    def delete(track):
        client.app.state.admin_library.delete_track(uuid_id)
        _evict(client, uuid_id)

    _on_row_read(monkeypatch, delete)

    r = client.get(f"/tracks/{uuid_id}/stream", params={"quality": "128"})

    assert r.status_code == 404
    assert r.json() == _unknown_body(uuid_id, client)
    assert not client.app.state.encoded_cache.has(uuid_id, "128")


def test_an_encode_failure_for_a_pending_track_answers_410_not_500(client, tmp_path, monkeypatch):
    _install_coordinator(client, lambda src, dst, bitrate: False)
    uuid_id, _ = _add(client, tmp_path)
    _on_row_read(monkeypatch, lambda t: mark_pending_deletion(_db_path(client), uuid_id))

    r = client.get(f"/tracks/{uuid_id}/stream", params={"quality": "128"})

    assert r.status_code == 410


def test_an_encode_failure_for_a_live_unchanged_track_keeps_the_existing_500(client, tmp_path):
    _install_coordinator(client, lambda src, dst, bitrate: False)
    uuid_id, _ = _add(client, tmp_path)

    r = client.get(f"/tracks/{uuid_id}/stream", params={"quality": "128"})

    assert r.status_code == 500
    assert str(tmp_path) not in r.text


def test_a_cached_encode_of_a_pending_track_is_not_served(client, tmp_path):
    calls: list[Path] = []
    _install_coordinator(client, _fake_transcode(calls))
    uuid_id, _ = _add(client, tmp_path)
    assert client.get(f"/tracks/{uuid_id}/stream", params={"quality": "128"}).status_code == 200
    mark_pending_deletion(_db_path(client), uuid_id)

    r = client.get(f"/tracks/{uuid_id}/stream", params={"quality": "128"})

    assert r.status_code == 410


# ── Ordinary streaming through the helper ────────────────────────────────────


def test_an_ordinary_stream_reads_one_row_and_serves_the_master(client, tmp_path, monkeypatch, opened):
    uuid_id, master = _add(client, tmp_path)
    calls = _on_row_read(monkeypatch, lambda t: None)

    r = client.get(f"/tracks/{uuid_id}/stream")

    assert r.status_code == 200
    assert r.content == master.read_bytes()
    assert len(calls) == 1
    assert [p for p, _ in opened] == [master]


# ── One retry on a path change or a replaced master (SC-16i, 8-D08) ─────────


def _revision(client, uuid_id) -> int:
    return sql_rows(client, "SELECT revision FROM tracks WHERE uuid_id = ?", (uuid_id,))[0][0]


def _commit_row(client, uuid_id, *, file_path=None, codec=None) -> int:
    """Commit a new row revision (optionally a new path / codec), as the
    in-place writers do *before* they touch the file. Returns the revision."""
    sql_rows(
        client,
        "UPDATE tracks SET revision = (SELECT MAX(revision) FROM tracks) + 1, "
        "file_path = COALESCE(?, file_path) WHERE uuid_id = ?",
        (None if file_path is None else str(file_path), uuid_id),
    )
    if codec is not None:
        sql_rows(client, "UPDATE trackmetadata SET codec = ? WHERE uuid_id = ?", (codec, uuid_id))
    return _revision(client, uuid_id)


def test_a_relocation_after_the_row_read_retries_once_and_serves_the_new_path(
    client, tmp_path, monkeypatch, opened
):
    original = b"the-real-master" * 40
    uuid_id, old_path = _add(client, tmp_path, data=original)
    new_path = tmp_path / "Artist" / "song.mp3"

    def relocate(track):
        new_path.parent.mkdir()
        old_path.rename(new_path)
        _commit_row(client, uuid_id, file_path=new_path)
        old_path.write_bytes(b"another-file-now-at-the-old-path")  # a reused path

    calls = _on_row_read(monkeypatch, relocate)

    r = client.get(f"/tracks/{uuid_id}/stream")

    assert r.status_code == 200
    assert r.content == original
    assert len(calls) == 2
    assert [p for p, _ in opened][-1] == new_path
    assert opened[0][1].closed


def test_a_conversion_commit_to_a_new_path_retries_once_with_the_new_headers(
    client, tmp_path, monkeypatch, opened
):
    uuid_id, old_path = _add(client, tmp_path)
    converted = tmp_path / "song.m4a"
    revisions = {}

    def convert(track):
        converted.write_bytes(b"alac-master-bytes" * 30)
        revisions["new"] = _commit_row(client, uuid_id, file_path=converted, codec="alac")
        _evict(client, uuid_id)
        old_path.unlink()

    calls = _on_row_read(monkeypatch, convert)

    r = client.get(f"/tracks/{uuid_id}/stream")

    assert r.status_code == 200
    assert r.content == converted.read_bytes()
    assert r.headers["X-Audio-Codec"] == "alac"
    assert r.headers["X-Track-Revision"] == str(revisions["new"])
    assert len(calls) == 2


def test_an_in_place_conversion_commit_retries_once(client, tmp_path, monkeypatch, opened):
    uuid_id, master = _add(client, tmp_path)
    revisions = {}

    def convert_in_place(track):
        revisions["new"] = _commit_row(client, uuid_id, codec="alac")  # DB first ...
        staged = tmp_path / "staged.tmp"
        staged.write_bytes(b"in-place-converted" * 30)
        staged.replace(master)  # ... then os.replace ...
        _evict(client, uuid_id)  # ... then eviction (conversion.py order)

    calls = _on_row_read(monkeypatch, convert_in_place)

    r = client.get(f"/tracks/{uuid_id}/stream")

    assert r.status_code == 200
    assert r.content == b"in-place-converted" * 30
    assert r.headers["X-Audio-Codec"] == "alac"
    assert r.headers["X-Track-Revision"] == str(revisions["new"])
    assert len(calls) == 2
    assert opened[0][1].closed


def test_an_in_place_conversion_racing_a_transcode_drops_the_late_encode_and_retries(
    client, tmp_path, monkeypatch
):
    transcodes: list[Path] = []
    _install_coordinator(client, _fake_transcode(transcodes))
    uuid_id, master = _add(client, tmp_path)

    def convert_in_place(track):
        _commit_row(client, uuid_id, codec="alac")
        staged = tmp_path / "staged.tmp"
        staged.write_bytes(b"in-place-converted" * 30)
        staged.replace(master)
        _evict(client, uuid_id)

    calls = _on_row_read(monkeypatch, convert_in_place)

    r = client.get(f"/tracks/{uuid_id}/stream", params={"quality": "128"})

    assert r.status_code == 200
    assert len(transcodes) == 2  # the first encode was dropped by the generation guard
    assert len(calls) == 2
    assert client.app.state.encoded_cache.has(uuid_id, "128")


def test_an_in_place_edit_keeps_the_earlier_revision_in_the_headers(
    client, tmp_path, monkeypatch, opened
):
    # Phase 1 `_inplace` tag writes commit the DB, then os.replace, and evict
    # nothing: the bytes may be newer than the header, never older.
    uuid_id, master = _add(client, tmp_path)
    before = _revision(client, uuid_id)

    def edit_in_place(track):
        _commit_row(client, uuid_id)
        staged = tmp_path / "staged.tmp"
        staged.write_bytes(b"retagged-bytes" * 30)
        staged.replace(master)

    calls = _on_row_read(monkeypatch, edit_in_place)

    r = client.get(f"/tracks/{uuid_id}/stream")

    assert r.status_code == 200
    assert r.headers["X-Track-Revision"] == str(before)
    assert len(calls) == 1


def test_db_only_edits_after_the_row_read_do_not_retry(client, tmp_path, monkeypatch, opened):
    # SC-16i: never compare `revision`; two quick PATCHes must not 404 a live track.
    uuid_id, master = _add(client, tmp_path)
    before = _revision(client, uuid_id)

    def two_edits(track):
        _commit_row(client, uuid_id)
        _commit_row(client, uuid_id)

    calls = _on_row_read(monkeypatch, two_edits)

    r = client.get(f"/tracks/{uuid_id}/stream")

    assert r.status_code == 200
    assert r.content == master.read_bytes()
    assert r.headers["X-Track-Revision"] == str(before)
    assert len(calls) == 1


def test_a_second_relocation_during_the_retry_gives_up_without_a_third_attempt(
    client, tmp_path, monkeypatch, opened
):
    uuid_id, first = _add(client, tmp_path)
    paths = [first, tmp_path / "second.mp3", tmp_path / "third.mp3"]
    calls: list[Track] = []

    def relocate_every_time(track):
        calls.append(track)
        src, dst = paths[len(calls) - 1], paths[len(calls)]
        src.rename(dst)
        _commit_row(client, uuid_id, file_path=dst)
        src.write_bytes(b"not-this-track")

    monkeypatch.setattr(track_source, "_after_row_read", relocate_every_time)

    r = client.get(f"/tracks/{uuid_id}/stream")

    assert r.status_code == 404
    assert len(calls) == 2
    assert all(f.closed for _, f in opened)
    assert str(tmp_path) not in r.text


# ── Review r1 #2: the opened file is closed on every error path ──────────────


def test_a_database_error_in_the_post_open_re_read_closes_the_file(
    client, tmp_path, monkeypatch, opened
):
    uuid_id, _ = _add(client, tmp_path)
    database = client.app.state.database
    real = type(database).is_pending_deletion
    broken = {"on": False}

    def flaky(self, *args, **kwargs):
        if broken["on"]:
            raise sqlite3.OperationalError("database is locked")
        return real(self, *args, **kwargs)

    monkeypatch.setattr(type(database), "is_pending_deletion", flaky)
    _on_row_read(monkeypatch, lambda t: broken.update(on=True))

    with pytest.raises(sqlite3.OperationalError):
        client.get(f"/tracks/{uuid_id}/stream")

    assert len(opened) == 1
    assert opened[0][1].closed


# ── review r1 8-R1-06: any open error is mapped, never a bare 500 ──────────


@pytest.mark.parametrize(
    "error",
    [PermissionError(13, "Permission denied"), IsADirectoryError(21, "Is a directory"),
     OSError(24, "Too many open files"), OSError(5, "Input/output error")],
    ids=["EACCES", "EISDIR", "EMFILE", "EIO"],
)
def test_an_open_error_on_a_track_marked_meanwhile_answers_410(
    client, tmp_path, monkeypatch, error
):
    uuid_id, _ = _add(client, tmp_path)

    def failing(path):
        mark_pending_deletion(_db_path(client), uuid_id)  # the deletion began
        raise error

    monkeypatch.setattr(track_source, "_open_source", failing)

    r = client.get(f"/tracks/{uuid_id}/stream")

    assert r.status_code == 410
    assert r.json()["detail"]["error"] == "track_pending_deletion"
    assert str(tmp_path) not in r.text


# ── review r2 OPEN-r1be-01 / 8-R2-01: only proof of absence is "gone" ──────
#
# A passthrough open that finds no file (FNF / ENOTDIR) proves the master is
# missing: 404. Any other open error says nothing about the track: 503, the
# stream route's plain-string shape, so a client checking the track (GET
# /tracks/{uuid} → 200) keeps it. A transcoded stream opens the encoded
# *cache* file, whose absence proves only a prune: 503, never 404.

_TRANSIENT = [
    PermissionError(13, "Permission denied"),
    IsADirectoryError(21, "Is a directory"),
    OSError(24, "Too many open files"),
    OSError(5, "Input/output error"),
]
_TRANSIENT_IDS = ["EACCES", "EISDIR", "EMFILE", "EIO"]


@pytest.mark.parametrize("error", _TRANSIENT, ids=_TRANSIENT_IDS)
def test_an_open_error_on_a_live_track_answers_503_without_a_path(
    client, tmp_path, monkeypatch, caplog, error
):
    # Review r2: was 404 (8-R1-06); a transient error is not proof of absence.
    uuid_id, _ = _add(client, tmp_path)

    def failing(path):
        raise type(error)(error.errno, error.strerror, str(path))

    monkeypatch.setattr(track_source, "_open_source", failing)

    with caplog.at_level("DEBUG"):
        r = client.get(f"/tracks/{uuid_id}/stream")

    assert r.status_code == 503
    assert isinstance(r.json()["detail"], str)  # the legacy plain-string shape
    assert str(tmp_path) not in r.text
    assert str(tmp_path) not in caplog.text
    assert type(error).__name__ in caplog.text
    # The client classifies through the track check: the track is still there.
    assert client.get(f"/tracks/{uuid_id}").status_code == 200


@pytest.mark.parametrize(
    "error",
    [FileNotFoundError(2, "No such file or directory"), NotADirectoryError(20, "Not a directory")],
    ids=["ENOENT", "ENOTDIR"],
)
def test_a_passthrough_open_that_finds_no_file_answers_404(client, tmp_path, monkeypatch, error):
    uuid_id, _ = _add(client, tmp_path)

    def failing(path):
        raise type(error)(error.errno, error.strerror, str(path))

    monkeypatch.setattr(track_source, "_open_source", failing)

    r = client.get(f"/tracks/{uuid_id}/stream")

    assert r.status_code == 404
    assert r.json()["detail"] == "The track's file is no longer available"
    assert str(tmp_path) not in r.text


def test_a_master_unlinked_before_the_passthrough_open_answers_404(client, tmp_path, monkeypatch):
    uuid_id, master = _add(client, tmp_path)
    real = track_source._open_source

    def unlink_then_open(path):
        Path(path).unlink()  # a real FileNotFoundError from the real open
        return real(path)

    monkeypatch.setattr(track_source, "_open_source", unlink_then_open)

    r = client.get(f"/tracks/{uuid_id}/stream")

    assert r.status_code == 404
    assert not master.exists()


def test_an_open_error_on_a_track_tombstoned_meanwhile_answers_like_an_unknown_one(
    client, tmp_path, monkeypatch
):
    uuid_id, _ = _add(client, tmp_path)

    def failing(path):
        client.app.state.admin_library.delete_track(uuid_id)  # the deletion committed
        raise PermissionError(13, "Permission denied")

    monkeypatch.setattr(track_source, "_open_source", failing)

    r = client.get(f"/tracks/{uuid_id}/stream")

    assert r.status_code == 404
    assert r.json() == _unknown_body(uuid_id, client)


def test_a_relocation_with_an_open_error_retries_once_and_serves_the_new_path(
    client, tmp_path, monkeypatch, opened
):
    original = b"the-real-master" * 40
    uuid_id, old_path = _add(client, tmp_path, data=original)
    new_path = tmp_path / "Artist" / "song.mp3"
    spy = track_source._open_source  # the `opened` recorder
    attempts: list[Path] = []

    def failing_first(path):
        attempts.append(Path(path))
        if len(attempts) == 1:
            new_path.parent.mkdir()
            old_path.rename(new_path)
            _commit_row(client, uuid_id, file_path=new_path)
            raise PermissionError(13, "Permission denied")
        return spy(path)

    monkeypatch.setattr(track_source, "_open_source", failing_first)

    r = client.get(f"/tracks/{uuid_id}/stream")

    assert r.status_code == 200
    assert r.content == original
    assert attempts == [old_path, new_path]


def test_a_pruned_cache_file_on_a_transcoded_stream_answers_503_not_404(
    client, tmp_path, monkeypatch
):
    calls: list[Path] = []
    _install_coordinator(client, _fake_transcode(calls))
    uuid_id, master = _add(client, tmp_path)
    real = track_source._open_source
    pruned: list[Path] = []

    def prune_then_open(path):
        if Path(path) != master:
            pruned.append(Path(path))
            Path(path).unlink()  # the cache prune wins the race: a real FNF
        return real(path)

    monkeypatch.setattr(track_source, "_open_source", prune_then_open)

    r = client.get(f"/tracks/{uuid_id}/stream", params={"quality": "128"})

    assert len(calls) == 1 and len(pruned) == 1  # a transcoded open, not the master
    assert r.status_code == 503
    assert isinstance(r.json()["detail"], str)
    assert str(tmp_path) not in r.text
    assert master.exists()
    assert client.get(f"/tracks/{uuid_id}").status_code == 200


# ── review r1 8-R1-15: one name per meaning ────────────────────────────────


def test_the_stream_refusal_does_not_share_the_mutator_exceptions_name():
    from app.database.database import TrackPendingDeletion as MutatorRefusal

    assert not hasattr(track_source, "TrackPendingDeletion")
    assert track_source.StreamTrackPendingDeletion is not MutatorRefusal
    assert issubclass(track_source.StreamTrackPendingDeletion, track_source.TrackSourceError)
