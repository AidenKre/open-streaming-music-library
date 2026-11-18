"""Review r1 7-R1-10 (coordinator decision): startup makes one cheap probe that
an upload can be hard-linked from ``.uploads`` into each user's library root,
removes both names (the library name only once proven to be its own link, as
the publisher proves it) and only logs one operator warning per failing root.
It never refuses the start and never changes ``/app/info``."""
import errno
import os
import uuid
from pathlib import Path

import pytest

from app.library import library_root
from app.services import organizer
from app.services.upload_publish import probe_library_links
from tests.identity_worker_fixtures import make_db
from tests.owned_database import add_test_user


@pytest.fixture
def db(tmp_path):
    return make_db(tmp_path)


@pytest.fixture
def music(tmp_path):
    path = tmp_path / "music"
    (path / ".uploads").mkdir(parents=True)
    return path


def _roots(db, music):
    return {u["id"]: library_root(music, u) for u in db.list_users()}


def _files(root: Path) -> set:
    return {p for p in root.rglob("*")} if root.exists() else set()


def test_a_library_that_takes_links_logs_nothing_and_leaves_nothing(db, music, caplog):
    add_test_user(db, "sam")
    roots = _roots(db, music)
    for root in roots.values():
        root.mkdir(parents=True, exist_ok=True)
    before = {r: _files(r) for r in [music / ".uploads", *roots.values()]}

    with caplog.at_level("WARNING", logger="uvicorn.error"):
        failed = probe_library_links(db, uploads_root=music / ".uploads", music_library_dir=music)

    assert failed == []
    assert {r: _files(r) for r in before} == before
    assert [r for r in caplog.records if r.name == "uvicorn.error"] == []


def test_a_root_that_refuses_links_is_named_once_and_left_clean(db, music, monkeypatch, caplog):
    sam = add_test_user(db, "sam")
    roots = _roots(db, music)
    for root in roots.values():
        root.mkdir(parents=True, exist_ok=True)
    real_link = os.link

    def link(src, dst, *args, **kwargs):
        if Path(dst).is_relative_to(roots[sam]):
            raise OSError(errno.EXDEV, os.strerror(errno.EXDEV))
        return real_link(src, dst, *args, **kwargs)

    monkeypatch.setattr(organizer.os, "link", link)
    before = {r: _files(r) for r in [music / ".uploads", *roots.values()]}

    with caplog.at_level("WARNING", logger="uvicorn.error"):
        failed = probe_library_links(db, uploads_root=music / ".uploads", music_library_dir=music)

    assert failed == [sam]
    assert {r: _files(r) for r in before} == before
    lines = [r.getMessage() for r in caplog.records if r.name == "uvicorn.error"]
    assert len(lines) == 1
    assert "EXDEV" in lines[0] and "/" not in lines[0]
    # Link fallback (sign-off DEV-7-25): uploads still work there, less well protected.
    assert "cannot take uploaded files" not in lines[0]
    assert "moved or copied into place" in lines[0] and "crash" in lines[0]


def test_a_root_that_does_not_exist_yet_is_probed_at_the_music_library_and_left_clean(
        db, music, monkeypatch, caplog):
    """Review r2 7-R2-11 / DEV-r2be-5, pinned in review r3 7-R3-10: the root is
    not made; the probe links at the top of the music library instead and
    leaves nothing there or in ``.uploads``."""
    made = []
    real_link = os.link

    def link(src, dst, *args, **kwargs):
        made.append(Path(dst))
        return real_link(src, dst, *args, **kwargs)

    monkeypatch.setattr(organizer.os, "link", link)
    with caplog.at_level("WARNING", logger="uvicorn.error"):
        assert probe_library_links(db, uploads_root=music / ".uploads", music_library_dir=music) == []

    assert made and all(p.parent == music for p in made)
    assert not list(music.glob(".link-probe-*"))
    assert not list((music / ".uploads").glob(".link-probe-*"))
    assert all(not r.exists() for r in _roots(db, music).values())


def test_the_server_starts_and_warns_when_the_library_takes_no_links(open_app_client, monkeypatch, caplog):
    def refuse(src, dst, *args, **kwargs):
        raise OSError(errno.EPERM, os.strerror(errno.EPERM))

    with caplog.at_level("WARNING", logger="uvicorn.error"):
        monkeypatch.setattr(organizer.os, "link", refuse)
        with open_app_client() as client:
            assert client.get("/app/info").status_code == 200
            uploads = client.get("/app/info").json().get("uploads")
    assert any("EPERM" in r.getMessage() for r in caplog.records if r.name == "uvicorn.error")
    assert uploads is not None  # what /app/info advertises does not change


# ── Review r2 7-R2-11: leftovers, the walk above the library, errno wording ──

def _probe(db, music, uploads=None):
    return probe_library_links(db, uploads_root=uploads or music / ".uploads", music_library_dir=music)


def _leftover(music, root, name=None):
    """What a kill between the probe's link and its unlink leaves: the scratch in
    ``.uploads`` and its own hard link, under one name, in the probed folder."""
    name = name or f".link-probe-{uuid.uuid4().hex}"
    scratch = music / ".uploads" / name
    scratch.write_bytes(b"")
    os.link(scratch, root / name)
    return scratch, root / name


def test_a_probe_killed_after_its_link_is_swept_by_the_next_start(db, music):
    add_test_user(db, "sam")
    roots = _roots(db, music)
    for root in roots.values():
        root.mkdir(parents=True, exist_ok=True)
    left = [_leftover(music, root) for root in roots.values()]
    left.append(_leftover(music, music))  # a root that did not exist yet was probed at the top
    before = {r: _files(r) - {n for pair in left for n in pair} for r in [music / ".uploads", *roots.values()]}

    assert _probe(db, music) == []

    for scratch, name in left:
        assert not scratch.exists() and not name.exists()
    assert {r: _files(r) for r in before} == before
    assert not list(music.glob(".link-probe-*"))
    _probe(db, music)  # twice: nothing more to do
    assert {r: _files(r) for r in before} == before


def test_the_sweep_removes_only_names_proven_to_be_its_own(db, music):
    roots = _roots(db, music)
    for root in roots.values():
        root.mkdir(parents=True, exist_ok=True)
    root = next(iter(roots.values()))
    name = f".link-probe-{uuid.uuid4().hex}"
    (music / ".uploads" / name).write_bytes(b"")
    stranger = root / name
    stranger.write_bytes(b"not the probe's")  # same name, another file
    lookalike = root / ".link-probe-notahexname"
    lookalike.write_bytes(b"")

    _probe(db, music)

    assert stranger.read_bytes() == b"not the probe's"
    assert lookalike.exists()
    assert not (music / ".uploads" / name).exists()


def test_a_library_name_that_could_not_be_removed_keeps_its_proof(db, music, monkeypatch):
    """The scratch goes only once the library name is gone, so the next start
    can still prove the leftover is its own."""
    roots = _roots(db, music)
    for root in roots.values():
        root.mkdir(parents=True, exist_ok=True)
    real_unlink = os.unlink  # Path.unlink goes through os.unlink too

    def unlink(path, *args, **kwargs):
        path = Path(path)
        if path.parent != music / ".uploads" and path.name.startswith(".link-probe-"):
            raise PermissionError(errno.EACCES, "denied")
        return real_unlink(path, *args, **kwargs)

    monkeypatch.setattr(os, "unlink", unlink)
    _probe(db, music)
    monkeypatch.undo()

    names = {p.name for root in roots.values() for p in root.glob(".link-probe-*")}
    assert names and names == {p.name for p in (music / ".uploads").glob(".link-probe-*")}

    _probe(db, music)

    assert not [p for root in roots.values() for p in root.glob(".link-probe-*")]
    assert not list((music / ".uploads").glob(".link-probe-*"))


def test_the_probe_never_writes_above_the_music_library(db, tmp_path, monkeypatch):
    """A library root that does not exist is probed at the music library at
    most, never at a folder above it."""
    music = tmp_path / "library" / "music"  # not made yet
    uploads = tmp_path / "uploads"
    uploads.mkdir()
    made = []
    real_link = os.link

    def link(src, dst, *args, **kwargs):
        made.append(Path(dst))
        return real_link(src, dst, *args, **kwargs)

    monkeypatch.setattr(organizer.os, "link", link)

    assert _probe(db, music, uploads) == []

    assert all(p.is_relative_to(music) for p in made)
    assert not list(tmp_path.rglob(".link-probe-*"))  # (the test database lives in tmp_path)


def test_a_link_refused_for_another_reason_is_not_called_unsupported(db, music, monkeypatch, caplog):
    roots = _roots(db, music)
    for root in roots.values():
        root.mkdir(parents=True, exist_ok=True)

    def refuse(src, dst, *args, **kwargs):
        raise OSError(errno.EACCES, os.strerror(errno.EACCES))

    monkeypatch.setattr(organizer.os, "link", refuse)
    with caplog.at_level("WARNING", logger="uvicorn.error"):
        assert _probe(db, music) == []  # unknown is not a refusal

    lines = [r.getMessage() for r in caplog.records if r.name == "uvicorn.error"]
    assert lines and all("EACCES" in line and "not supported" not in line for line in lines)
    assert all("/" not in line for line in lines)


@pytest.mark.skipif(hasattr(os, "geteuid") and os.geteuid() == 0,
                    reason="root ignores mode bits, so chmod(0) cannot deny the search (review r3 7-R3-06)")
def test_a_twin_that_cannot_be_examined_keeps_its_proof(db, music):
    """In-piece review F2: a library folder the server cannot search proves
    nothing; the scratch (the only proof) stays until the twin is proven gone."""
    roots = _roots(db, music)
    root = next(iter(roots.values()))
    root.mkdir(parents=True, exist_ok=True)
    scratch, twin = _leftover(music, root)
    root.chmod(0)
    try:
        _probe(db, music)
        assert scratch.exists()
    finally:
        root.chmod(0o755)
    assert twin.exists()

    _probe(db, music)  # searchable again: both go

    assert not scratch.exists() and not twin.exists()


def test_one_users_unusable_root_does_not_stop_the_sweep_for_the_others(db, music, tmp_path):
    """In-piece review F3: a root that cannot be used (here a link out of the
    library) is skipped alone; proven twins elsewhere still go, and a scratch
    stays while a folder it might have a twin in could not be looked at."""
    sam = add_test_user(db, "sam")
    roots = _roots(db, music)
    outside = tmp_path / "elsewhere"
    outside.mkdir()
    roots[sam].symlink_to(outside, target_is_directory=True)
    good = next(r for uid, r in roots.items() if uid != sam)
    good.mkdir(parents=True, exist_ok=True)
    scratch, twin = _leftover(music, good)

    _probe(db, music)

    assert not twin.exists()
    assert scratch.exists()  # its twin could still be in the root that was skipped
    assert not list(outside.iterdir())
