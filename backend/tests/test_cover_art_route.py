"""Phase M.0c (spec §4.2 "Cover art", SC-28 rule 6, review M-U06 art).

Cover art is a shared server resource behind an ownership check on every read:
``GET /cover_art/{id}`` serves only when one of the caller's tracks references
the art, otherwise 404; the response is ``Cache-Control: private``.
"""

import sqlite3
from contextlib import contextmanager
from io import BytesIO

import pytest
from PIL import Image

from app.library import Library
from app.models import Track, TrackMetaData
from tests.owned_database import add_test_user


def _png(color) -> bytes:
    buf = BytesIO()
    Image.new("RGB", (8, 8), color).save(buf, format="PNG")
    return buf.getvalue()


def _track(path, title, cover_art_id):
    return Track(
        file_path=path,
        metadata=TrackMetaData(
            title=title, artist="Radiohead", album="OK Computer", codec="flac",
            duration=1.0, has_album_art=True, cover_art_id=cover_art_id,
        ),
    )


@pytest.fixture
def art(app_client, tmp_path):
    """mine: the admin's track; theirs: only sam's; shared: both; loose: none."""
    state = app_client.app.state
    sam = Library(state.database, add_test_user(state.database, "sam"))
    # Distinct rows inserted directly: solid-colour images would phash-dedupe
    # into one shared row through add_album_art.
    ids = {}
    for i, name in enumerate(("mine", "theirs", "shared", "loose")):
        path = tmp_path / "data" / "cover_art" / f"{name}.png"
        path.write_bytes(_png((60 * i, 0, 0)))
        ids[name] = state.database.insert_cover_art(
            sha256=name, phash=f"{i:016x}", phash_prefix=f"{i:02x}", file_path=str(path)
        )
    music = tmp_path / "music"
    assert state.admin_library.add_track(_track(music / "admin" / "a.flac", "A", ids["mine"]))
    assert state.admin_library.add_track(_track(music / "admin" / "b.flac", "B", ids["shared"]))
    assert sam.add_track(_track(music / "sam" / "c.flac", "C", ids["theirs"]))
    assert sam.add_track(_track(music / "sam" / "d.flac", "D", ids["shared"]))
    return app_client, ids


@pytest.mark.parametrize("name", ["mine", "shared"])
def test_art_the_caller_references_is_served_privately(art, name):
    client, ids = art

    r = client.get(f"/cover_art/{ids[name]}")

    assert r.status_code == 200
    assert r.headers["cache-control"] == "private, max-age=31536000, immutable"
    path = client.app.state.cover_art_manager.get_album_art(ids[name])
    assert r.content == path.read_bytes()


@pytest.mark.parametrize("name", ["theirs", "loose"])
def test_art_no_track_of_the_caller_references_is_404(art, name):
    client, ids = art

    assert client.get(f"/cover_art/{ids[name]}").status_code == 404


def test_an_unknown_id_is_404(art):
    client, _ = art

    assert client.get("/cover_art/999999").status_code == 404


def test_owns_cover_art_is_per_owner(art):
    client, ids = art
    admin = client.app.state.admin_library

    assert admin.owns_cover_art(ids["mine"]) is True
    assert admin.owns_cover_art(ids["shared"]) is True
    assert admin.owns_cover_art(ids["theirs"]) is False
    assert admin.owns_cover_art(ids["loose"]) is False


# U04-B-03: a busy database is a retryable 503 ("Database busy, retry", the
# shape PATCH /tracks uses today), never a 404 the app would take as "no art".


class _BusyOn:
    """A connection whose statements containing ``fragment`` find the database
    locked (SQLite's own error); everything else runs normally."""

    def __init__(self, conn, fragment):
        self._conn = conn
        self._fragment = fragment

    def execute(self, sql, *args):
        if self._fragment in sql:
            raise sqlite3.OperationalError("database is locked")
        return self._conn.execute(sql, *args)

    def __getattr__(self, name):
        return getattr(self._conn, name)


def _busy_on(monkeypatch, database, fragment):
    real = type(database)._connection

    @contextmanager
    def connection(self, **kwargs):
        with real(self, **kwargs) as conn:
            yield _BusyOn(conn, fragment)

    monkeypatch.setattr(type(database), "_connection", connection)


@pytest.mark.parametrize(
    "fragment",
    [
        "FROM cover_arts WHERE id",  # the art row lookup
        "tm.cover_art_id = ? AND t.owner_id",  # the ownership check
    ],
)
def test_a_busy_database_answers_503_not_404(art, monkeypatch, fragment):
    client, ids = art
    _busy_on(monkeypatch, client.app.state.database, fragment)

    r = client.get(f"/cover_art/{ids['mine']}")

    assert r.status_code == 503, r.text
    assert r.json() == {"detail": "Database busy, retry"}


@pytest.mark.parametrize("name", ["mine", "theirs", "loose", "unknown"])
def test_a_busy_database_answers_every_id_alike(art, monkeypatch, name):
    """Busy for every cover-art statement: an own, foreign, unreferenced or
    unknown id all get the same 503, so busy reveals nothing about ownership."""
    client, ids = art
    cover_art_id = ids.get(name, 999999)
    _busy_on(monkeypatch, client.app.state.database, "cover_art")

    r = client.get(f"/cover_art/{cover_art_id}")

    assert (r.status_code, r.json()) == (503, {"detail": "Database busy, retry"})


@pytest.mark.parametrize("name", ["theirs", "loose"])
def test_a_busy_art_lookup_leaves_a_foreign_ids_answer_unchanged(art, monkeypatch, name):
    client, ids = art
    before = client.get(f"/cover_art/{ids[name]}")
    _busy_on(monkeypatch, client.app.state.database, "FROM cover_arts WHERE id")

    r = client.get(f"/cover_art/{ids[name]}")

    assert (r.status_code, r.json()) == (before.status_code, before.json()) == (
        404, {"detail": "Cover art not found"})
