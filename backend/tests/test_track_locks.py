import threading
import time

from app.services.track_locks import TrackLocks


def test_same_uuid_returns_identical_lock_and_never_deletes():
    locks = TrackLocks()
    first = locks._lock_for("a")
    assert locks._lock_for("a") is first  # stable identity across calls
    assert locks._lock_for("b") is not first  # distinct uuids, distinct locks


def test_lock_serializes_same_uuid():
    locks = TrackLocks()
    events: list[str] = []
    t1_in = threading.Event()
    release = threading.Event()

    def first():
        with locks.lock("x"):
            t1_in.set()
            events.append("t1_enter")
            release.wait(1)
            events.append("t1_exit")

    def second():
        t1_in.wait(1)  # ensure the first holder is inside the lock
        with locks.lock("x"):
            events.append("t2_enter")

    th1 = threading.Thread(target=first)
    th2 = threading.Thread(target=second)
    th1.start()
    th2.start()

    t1_in.wait(1)
    time.sleep(0.05)  # give the second thread a chance to (wrongly) enter
    assert events == ["t1_enter"]  # it is blocked on the same uuid

    release.set()
    th1.join(1)
    th2.join(1)
    assert events == ["t1_enter", "t1_exit", "t2_enter"]


def test_different_uuids_do_not_block_each_other():
    locks = TrackLocks()
    with locks.lock("a"):
        other = locks._lock_for("b")
        assert other.acquire(timeout=0.5)  # a different uuid is free
        other.release()
