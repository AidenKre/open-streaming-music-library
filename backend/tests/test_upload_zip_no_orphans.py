"""7A.2d review r1 (F1-F4): no staged file is ever orphaned. After every
scenario each file under the uploads root is the recorded source_path of some
row, or does not exist."""

import errno
from pathlib import Path

import pytest

from app.library import Library
from app.services.upload_receipt import ReceiptFiles
from app.services.upload_zip import reconcile_expanded_archives
from app.services.uploads import cancel
from tests.identity_worker_fixtures import sql
from tests.upload_validation_fixtures import item_row, source_rows
from tests.upload_zip_fixtures import (
    CallbackFiles, Entry, HookFiles, children_of, files_under, make_expander, make_ledger, stage_zip,
    tiny_limits, unrecorded_files, zip_worker,
)

NOW = 1_700_000_000
BOOT2 = "boot-2"
DATA = [bytes([i + 1]) * (40 + i) for i in range(3)]


@pytest.fixture
def root(tmp_path):
    path = tmp_path / "music" / ".uploads"
    path.mkdir(parents=True)
    return path


@pytest.fixture
def staged(db, root, tmp_path):
    return stage_zip(db, root, tmp_path, [Entry(f"m{i}.flac", d) for i, d in enumerate(DATA)])


def lib(db, staged):
    return Library(db, staged["owner_id"])


def first_worker(db, root, tmp_path, files):
    return zip_worker(db, root, tmp_path, expander=make_expander(db, root, tmp_path, files=files))


def boot2(db, root, tmp_path, *, free=10**12, limits=None, files=None):
    expander = make_expander(db, root, tmp_path, ledger=make_ledger(db, tmp_path, free=free, boot_id=BOOT2),
                             boot_id=BOOT2, limits=limits, files=files)
    return zip_worker(db, root, tmp_path, expander=expander, boot_id=BOOT2)


def stop_at(db, root, tmp_path, nth):
    seam = CallbackFiles(nth=nth)
    worker = first_worker(db, root, tmp_path, seam)
    seam.callback = worker.request_stop
    assert worker.process_one() == "interrupted"


def by_name(db, staged):
    return {c["member_order_key"]: c for c in children_of(db, staged)}


def cancel_child(db, staged, uid, root):
    cancel(lib(db, staged), uid, now=NOW, uploads_root=root)


# ── F1: a child cancelled while the parent is expanding ────────────────────

def test_f1a_child_cancelled_during_expansion(db, root, tmp_path, staged):
    def hook():
        third = by_name(db, staged)["m2.flac"]["item_uuid"]
        cancel_child(db, staged, third, root)

    seam = CallbackFiles(nth=2, callback=hook)
    assert first_worker(db, root, tmp_path, seam).process_one() == "expanded"
    assert by_name(db, staged)["m2.flac"]["state"] == "cancelled"
    assert unrecorded_files(db, root) == set()


def test_f1b_child_cancelled_between_a_stop_and_the_restart(db, root, tmp_path, staged):
    stop_at(db, root, tmp_path, 2)
    kids = by_name(db, staged)
    cancel_child(db, staged, kids["m0.flac"]["item_uuid"], root)
    assert boot2(db, root, tmp_path).process_one() == "expanded"
    assert by_name(db, staged)["m0.flac"]["state"] == "cancelled"
    assert unrecorded_files(db, root) == set()


# ── F2: a re-run that fails before staging ─────────────────────────────────

def test_f2a_storage_refusal_after_a_stop_leaves_nothing_staged(db, root, tmp_path, staged):
    stop_at(db, root, tmp_path, 3)
    boot2(db, root, tmp_path, free=10).process_one()
    row = item_row(db, staged)
    assert (row["state"], row["error_code"], row["error_retryable"]) == ("failed", "insufficient_storage", 1)
    assert children_of(db, staged) == []
    assert unrecorded_files(db, root) == set()
    assert files_under(root) == {staged["source"]}


def test_f2b_inspection_failure_after_a_stop_leaves_nothing(db, root, tmp_path, staged):
    stop_at(db, root, tmp_path, 3)
    boot2(db, root, tmp_path, limits=tiny_limits(max_audio_items_per_batch=1)).process_one()
    row = item_row(db, staged)
    assert (row["state"], row["error_code"]) == ("failed", "upload_archive_too_many_audio")
    assert children_of(db, staged) == []
    assert files_under(root) == set()


def test_f2c_a_failure_while_stopping_is_an_interruption(db, root, tmp_path, staged):
    holder = {}

    def hook(member, first):
        if member == 2 and first:
            holder["worker"].request_stop()
            raise OSError(errno.ENOSPC, "No space")

    holder["worker"] = first_worker(db, root, tmp_path, HookFiles(write_hook=hook))
    assert holder["worker"].process_one() == "interrupted"
    row = item_row(db, staged)
    assert (row["state"], row["error_code"]) == ("validating", None)
    assert len(children_of(db, staged)) == 3
    assert boot2(db, root, tmp_path).process_one() == "expanded"
    assert unrecorded_files(db, root) == set()


# ── F3: archive not removed after the flip ─────────────────────────────────

def _expanded_with_stuck_archive(db, root, tmp_path, staged):
    def refuse(path):
        if Path(path) == staged["source"]:
            raise PermissionError(errno.EACCES, "denied")

    assert first_worker(db, root, tmp_path, HookFiles(remove_hook=refuse)).process_one() == "expanded"
    row = item_row(db, staged)
    assert row["state"] == "expanded" and row["source_path"] == str(staged["source"])


def _archive_released(db, root, staged):
    row = item_row(db, staged)
    assert row["state"] == "expanded" and row["source_path"] is None
    assert not staged["source"].exists()
    assert source_rows(db, staged) == []


def test_f3a_cancel_removes_a_stuck_archive(db, root, tmp_path, staged):
    _expanded_with_stuck_archive(db, root, tmp_path, staged)
    cancel(lib(db, staged), staged["item_uuid"], now=NOW, uploads_root=root)
    _archive_released(db, root, staged)


def test_f3b_startup_cleanup_removes_a_stuck_archive(db, root, tmp_path, staged):
    _expanded_with_stuck_archive(db, root, tmp_path, staged)
    reconcile_expanded_archives(db, root)
    _archive_released(db, root, staged)
    reconcile_expanded_archives(db, root)
    _archive_released(db, root, staged)


def _stuck_archive_stays_recorded_and_counted(db, staged):
    row = item_row(db, staged)
    assert row["state"] == "expanded" and row["source_path"] == str(staged["source"])
    assert staged["source"].exists()
    assert [r["purpose"] for r in source_rows(db, staged)] == ["upload_source"]


def test_f3c_an_archive_that_cannot_be_removed_after_the_flip_keeps_its_path_and_quota_row(
        db, root, tmp_path, staged):
    """The expansion's own release: while the archive is still on disk, the
    parent keeps its recorded path and its quota row."""
    _expanded_with_stuck_archive(db, root, tmp_path, staged)
    _stuck_archive_stays_recorded_and_counted(db, staged)


def test_f3d_startup_cleanup_keeps_an_archive_it_cannot_remove_recorded_and_counted(
        db, root, tmp_path, staged, monkeypatch):
    _expanded_with_stuck_archive(db, root, tmp_path, staged)
    real = ReceiptFiles.remove

    def refuse(self, path):
        if Path(path) == staged["source"]:
            raise PermissionError(errno.EACCES, "denied")
        return real(self, path)

    monkeypatch.setattr(ReceiptFiles, "remove", refuse)
    assert reconcile_expanded_archives(db, root) == 0
    _stuck_archive_stays_recorded_and_counted(db, staged)

    monkeypatch.setattr(ReceiptFiles, "remove", real)
    assert reconcile_expanded_archives(db, root) == 1
    _archive_released(db, root, staged)


def test_f3e_startup_cleanup_never_removes_an_archive_recorded_outside_the_owners_stage(
        db, root, tmp_path, staged):
    _expanded_with_stuck_archive(db, root, tmp_path, staged)
    foreign = tmp_path / "elsewhere.zip"
    foreign.write_bytes(b"not ours")
    sql(db, "UPDATE upload_items SET source_path = ? WHERE item_uuid = ?", (str(foreign), staged["item_uuid"]))

    assert reconcile_expanded_archives(db, root) == 0

    assert foreign.read_bytes() == b"not ours"
    assert item_row(db, staged)["source_path"] == str(foreign)
    assert [r["purpose"] for r in source_rows(db, staged)] == ["upload_source"]


# ── F4: crash between a cancel's transaction and its file removal ──────────

def test_f4_startup_cleanup_removes_files_of_cancelled_children(db, root, tmp_path, staged):
    assert zip_worker(db, root, tmp_path).process_one() == "expanded"
    kids = by_name(db, staged)
    folders = {n: Path(c["source_path"]).parent for n, c in kids.items()}
    for name, state in (("m0.flac", "cancelled"), ("m1.flac", "cancelled")):
        sql(db, "UPDATE upload_items SET state = ?, source_path = NULL WHERE item_uuid = ?",
            (state, kids[name]["item_uuid"]))
        sql(db, "DELETE FROM storage_reservations WHERE subject_ref = ?", (kids[name]["item_uuid"],))
    (folders["m1.flac"] / "source.part").write_bytes(b"part")
    assert len(unrecorded_files(db, root)) == 3
    keep = Path(kids["m2.flac"]["source_path"])

    reconcile_expanded_archives(db, root)
    assert files_under(root) == {keep}
    assert unrecorded_files(db, root) == set()
    reconcile_expanded_archives(db, root)
    assert files_under(root) == {keep} and keep.read_bytes() == DATA[2]


# ── Re-check r1 ─────────────────────────────────────────────────────────────

@pytest.mark.parametrize("n", [1, 2])
def test_r1_cancelling_the_child_being_written_does_not_fail_the_archive(db, root, tmp_path, staged, n):
    seam = CallbackFiles(nth=n)
    seam.callback = lambda: cancel_child(db, staged, by_name(db, staged)[f"m{n - 1}.flac"]["item_uuid"], root)
    assert first_worker(db, root, tmp_path, seam).process_one() == "expanded"
    kids = by_name(db, staged)
    assert len(kids) == 3
    for name, kid in kids.items():
        if name == f"m{n - 1}.flac":
            assert kid["state"] == "cancelled"
        else:
            assert kid["state"] == "validating" and kid["source_path"] is not None
    assert unrecorded_files(db, root) == set()


def test_r2_lost_archive_after_a_stop_leaves_no_staged_files(db, root, tmp_path, staged):
    stop_at(db, root, tmp_path, 2)
    assert files_under(root) - {staged["source"]}  # member 1 is staged
    staged["source"].unlink()
    boot2(db, root, tmp_path).process_one()
    row = item_row(db, staged)
    assert (row["state"], row["error_code"]) == ("failed", "upload_source_missing")
    assert children_of(db, staged) == []
    assert unrecorded_files(db, root) == set()


def _app_with_spy(configure_app, monkeypatch, calls):
    from app.services import upload_zip

    monkeypatch.setattr(upload_zip, "reconcile_expanded_archives", lambda *a, **k: calls.append((a, k)))
    return configure_app()


def test_r4_startup_runs_the_zip_cleanup_once(configure_app, monkeypatch):
    from fastapi.testclient import TestClient

    calls = []
    with TestClient(_app_with_spy(configure_app, monkeypatch, calls).app) as c:
        database = c.app.state.database
        expected = Path(c.app.state.settings.music_library_dir).resolve() / ".uploads"
    [(args, kwargs)] = calls
    values = list(args) + list(kwargs.values())
    assert values[0] is database and Path(values[1]) == expected


def test_r4_the_zip_cleanup_runs_even_if_the_validation_reclaim_raises(configure_app, monkeypatch):
    from fastapi.testclient import TestClient

    from app.services import upload_validation

    def boom(*a, **k):
        raise RuntimeError("reclaim failed")

    monkeypatch.setattr(upload_validation, "reconcile_upload_validation", boom)
    calls = []
    with TestClient(_app_with_spy(configure_app, monkeypatch, calls).app):
        pass
    assert len(calls) == 1
