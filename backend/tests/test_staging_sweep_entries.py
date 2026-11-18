"""The startup staging sweep never stops startup on an entry that is not a file.

Sign-off OPEN-6.5-05, coordinator addition of 2026-11-16. ``reconcile_conversion_jobs``
removes every staged temp no journal row owns, right after journal recovery. It
used to ``unlink`` every name that looked like a temp, so a folder with such a
name raised and stopped startup (the step is fatal). Before this piece a kept
journal row could protect such a folder; journal recovery now drops every row,
so the sweep would meet it at every start. The sweep now removes only regular
files and symbolic links (a link's name, never its target) and leaves anything
else in place.
"""

from fastapi.testclient import TestClient

from app.services.conversion import reconcile_conversion_jobs
from tests.test_track_editor import _db

TEMP_NAMES = (
    "11111111-1111-4111-8111-111111111111.3.convert.flac",
    "22222222-2222-4222-8222-222222222222.4.tagged.m4a",
    "33333333-3333-4333-8333-333333333333.0a1b.edit.m4a",
)


def test_the_sweep_leaves_a_folder_named_like_a_temp_and_removes_files_and_links(tmp_path):
    db = _db(tmp_path)
    staging = tmp_path / ".staging"
    staging.mkdir()
    folder = staging / TEMP_NAMES[0]
    folder.mkdir()
    (folder / "inside.txt").write_bytes(b"kept")
    orphan = staging / TEMP_NAMES[1]
    orphan.write_bytes(b"orphan")
    outside = tmp_path / "outside.m4a"
    outside.write_bytes(b"target")
    link = staging / TEMP_NAMES[2]
    link.symlink_to(outside)

    reconcile_conversion_jobs(db, staging)

    assert folder.is_dir() and (folder / "inside.txt").read_bytes() == b"kept"
    assert not orphan.exists()
    assert not link.is_symlink() and outside.read_bytes() == b"target"


def test_startup_completes_with_a_folder_named_like_a_temp_in_staging(configure_app):
    main = configure_app()
    with TestClient(main.app):
        staging = main.app.state.admin_library.root.parent / ".staging"
    staging.mkdir(parents=True, exist_ok=True)
    folder = staging / TEMP_NAMES[0]
    folder.mkdir()

    with TestClient(main.app) as client:
        assert client.app.state.database is not None

    assert folder.is_dir()
