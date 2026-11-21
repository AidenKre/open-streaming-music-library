"""The transcode cache prunes outside the lock that ``generation()`` takes.

Every encode start reads ``EncodedCache.generation``. A prune scans the whole
cache folder; it must not hold up that read. The prune's folder scan is held
on an event (the cache folder is a ``Path`` subclass whose first ``iterdir``
waits), so the order of the threads is fixed by events, not by timing.
"""

import os
import threading
from pathlib import Path

from app.services.encoded_cache import EncodedCache, EncodedCacheContext

GATE_TIMEOUT_S = 10  # a safety bound only; every wait below is released by an event


def gated_dir(path: Path):
    """``path`` as a folder whose first ``iterdir`` signals ``entered`` and waits for ``release``."""
    entered = threading.Event()
    release = threading.Event()

    class GatedDir(type(path)):
        _gated = False

        def iterdir(self):
            if not GatedDir._gated:
                GatedDir._gated = True
                entered.set()
                assert release.wait(GATE_TIMEOUT_S), "the test never released the scan"
            return super().iterdir()

    return GatedDir(path), entered, release


def write(path: Path, size: int, mtime: float | None = None) -> Path:
    path.write_bytes(b"x" * size)
    if mtime is not None:
        os.utime(path, (mtime, mtime))
    return path


def run(target) -> tuple[threading.Thread, dict]:
    out: dict = {}

    def body():
        try:
            out["value"] = target()
        except BaseException as exc:  # surfaced by the test's asserts
            out["error"] = exc

    thread = threading.Thread(target=body, daemon=True)
    thread.start()
    return thread, out


def test_generation_answers_while_an_insert_prunes(tmp_path):
    folder, entered, release = gated_dir(tmp_path / "cache")
    cache = EncodedCache(EncodedCacheContext(cache_dir=folder, max_size_bytes=250))
    oldest = write(cache.path_for("old", "128"), 100, mtime=1_000)
    newer = write(cache.path_for("mid", "128"), 100, mtime=2_000)
    source = write(tmp_path / "encoded.m4a", 100)

    inserting, inserted = run(lambda: cache.insert("new", "128", source, expected_generation=0))
    try:
        assert entered.wait(GATE_TIMEOUT_S), "the insert never reached its prune"
        reading, read = run(lambda: cache.generation("new"))
        reading.join(GATE_TIMEOUT_S)
        assert not reading.is_alive(), "generation() waited for the prune's folder scan"
        assert read == {"value": 0}
    finally:
        release.set()
        inserting.join(GATE_TIMEOUT_S)

    assert not inserting.is_alive()
    assert inserted == {"value": cache.path_for("new", "128")}
    assert cache.path_for("new", "128").read_bytes() == b"x" * 100  # the inserted file is kept
    assert not oldest.exists()  # the oldest file went to make room
    assert newer.exists()


class AcquireSignal:
    """Wraps a lock; sets ``second`` when a second ``with`` starts on it."""

    def __init__(self, lock):
        self._lock = lock
        self._count = 0
        self.second = threading.Event()

    def __enter__(self):
        self._count += 1
        if self._count == 2:
            self.second.set()
        return self._lock.__enter__()

    def __exit__(self, *exc):
        return self._lock.__exit__(*exc)


def test_a_file_inserted_while_another_insert_prunes_is_not_pruned_by_it(tmp_path):
    # The second insert's file is the oldest by mtime (os.replace keeps the source's
    # mtime), so a prune that could see it would delete it first. Its insert must
    # still return a file that exists.
    folder, entered, release = gated_dir(tmp_path / "cache")
    cache = EncodedCache(EncodedCacheContext(cache_dir=folder, max_size_bytes=250))
    signal = AcquireSignal(cache._prune_lock)
    cache._prune_lock = signal
    write(cache.path_for("old", "128"), 100, mtime=2_000)
    write(cache.path_for("mid", "128"), 100, mtime=3_000)
    first = write(tmp_path / "first.m4a", 100, mtime=4_000)
    second = write(tmp_path / "second.m4a", 100, mtime=1_000)

    a, a_out = run(lambda: cache.insert("a", "128", first))
    try:
        assert entered.wait(GATE_TIMEOUT_S), "the first insert never reached its prune"
        b, b_out = run(lambda: cache.insert("b", "128", second))
        assert signal.second.wait(GATE_TIMEOUT_S), "the second insert never reached the prune lock"
    finally:
        release.set()
        a.join(GATE_TIMEOUT_S)
    b.join(GATE_TIMEOUT_S)

    assert not a.is_alive() and not b.is_alive()
    assert a_out == {"value": cache.path_for("a", "128")}
    assert b_out == {"value": cache.path_for("b", "128")}
    assert cache.path_for("b", "128").exists()  # the just-inserted file was not pruned


def test_a_file_removed_beside_a_prune_counts_as_freed(tmp_path):
    # remove_all_for_uuid no longer waits for a prune. A file it deletes after the
    # prune listed the folder has freed its space all the same: the prune must not
    # evict a further file for it.
    entered = threading.Event()
    release = threading.Event()

    class ListedDir(type(tmp_path)):
        _gated = False

        def iterdir(self):
            entries = list(super().iterdir())
            yield from entries
            if not ListedDir._gated:  # the prune has stat'ed every entry
                ListedDir._gated = True
                entered.set()
                assert release.wait(GATE_TIMEOUT_S), "the test never released the scan"

    cache = EncodedCache(EncodedCacheContext(cache_dir=ListedDir(tmp_path / "cache"), max_size_bytes=250))
    oldest = write(cache.path_for("old", "128"), 100, mtime=1_000)
    kept = write(cache.path_for("mid", "128"), 100, mtime=2_000)
    source = write(tmp_path / "encoded.m4a", 100)

    inserting, inserted = run(lambda: cache.insert("new", "128", source))
    try:
        assert entered.wait(GATE_TIMEOUT_S), "the insert never finished listing the folder"
        removing, removed = run(lambda: cache.remove_all_for_uuid("old"))
        removing.join(GATE_TIMEOUT_S)
        assert not removing.is_alive(), "remove_all_for_uuid waited for the prune"
        assert removed == {"value": None}
        assert not oldest.exists()
    finally:
        release.set()
        inserting.join(GATE_TIMEOUT_S)

    assert not inserting.is_alive()
    assert inserted == {"value": cache.path_for("new", "128")}
    assert cache.path_for("new", "128").exists()
    assert kept.exists()  # 300 listed, 100 removed beside the prune: 200 fits the 250 budget


def test_evicting_one_track_lists_no_folder_and_removes_its_four_encodes(tmp_path, monkeypatch):
    # remove_all_for_uuid runs under the lock every encode start takes. It
    # names the track's files instead of listing a folder of thousands.
    folder = tmp_path / "cache"
    cache = EncodedCache(EncodedCacheContext(cache_dir=folder, max_size_bytes=0))
    others = [write(cache.path_for(f"other-{i}", "128"), 1) for i in range(2_000)]
    others.append(write(cache.path_for("track-2", "320"), 1))  # a neighbour of the evicted uuid
    own = [write(cache.path_for("track", q), 1) for q in ("320", "256", "192", "128")]

    listed: list[str] = []
    real_listdir, real_scandir = os.listdir, os.scandir

    def listdir(path="."):
        listed.append(os.fspath(path))
        return real_listdir(path)

    def scandir(path="."):
        listed.append(os.fspath(path))
        return real_scandir(path)

    monkeypatch.setattr(os, "listdir", listdir)
    monkeypatch.setattr(os, "scandir", scandir)
    cache.remove_all_for_uuid("track")
    monkeypatch.undo()

    assert listed == []
    assert [p for p in own if p.exists()] == []
    assert all(p.exists() for p in others)
    assert len(list(folder.iterdir())) == len(others)
