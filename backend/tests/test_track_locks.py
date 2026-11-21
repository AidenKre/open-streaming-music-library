import threading

from app.services.track_locks import TrackLocks


def test_same_uuid_returns_identical_lock_and_never_deletes():
    locks = TrackLocks()
    first = locks.lock_for("a")
    assert locks.lock_for("a") is first  # stable identity across calls
    assert locks.lock_for("b") is not first  # distinct uuids, distinct locks


def test_lock_serializes_same_uuid():
    locks = TrackLocks()
    events: list[str] = []
    t1_in = threading.Event()
    release = threading.Event()

    def first():
        with locks.lock("x"):
            t1_in.set()
            events.append("t1_enter")
            assert release.wait(5)
            events.append("t1_exit")

    def second():
        assert t1_in.wait(5)  # ensure the first holder is inside the lock
        with locks.lock("x"):
            events.append("t2_enter")

    th1 = threading.Thread(target=first)
    th2 = threading.Thread(target=second)
    th1.start()
    th2.start()

    assert t1_in.wait(5)
    # The uuid's one lock is held while the first holder is inside, so the
    # second caller, which takes the same lock, waits (a check, not a window).
    assert not locks.lock_for("x").acquire(blocking=False)
    assert events == ["t1_enter"]

    release.set()
    th1.join(5)
    th2.join(5)
    assert not th1.is_alive() and not th2.is_alive()
    assert events == ["t1_enter", "t1_exit", "t2_enter"]


def test_different_uuids_do_not_block_each_other():
    locks = TrackLocks()
    with locks.lock("a"):
        other = locks.lock_for("b")
        assert other.acquire(timeout=0.5)  # a different uuid is free
        other.release()
