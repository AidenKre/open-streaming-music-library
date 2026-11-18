"""Phase 7A.2b S3 (spec §3 "two receiving transfers globally per server"):
the in-process transfer slots. Taking a slot never waits: a full server
answers at once. A slot is given back exactly once, however many times its
holder's exit paths try."""

import threading

from app.services.upload_receipt import TransferSlots

ALEX, SAM = 1, 2


def test_up_to_the_server_wide_count_slots_are_handed_out_then_none():
    slots = TransferSlots(total=2)

    first = slots.try_acquire(ALEX)
    second = slots.try_acquire(SAM)

    assert first is not None and second is not None
    assert slots.try_acquire(SAM) is None
    assert slots.in_use() == 2


def test_a_released_slot_can_be_taken_again():
    slots = TransferSlots(total=1)
    slot = slots.try_acquire(ALEX)

    assert slot.release() is True

    assert slots.in_use() == 0
    assert slots.try_acquire(SAM) is not None


def test_a_slot_is_given_back_exactly_once():
    slots = TransferSlots(total=2)
    slot = slots.try_acquire(ALEX)
    other = slots.try_acquire(SAM)

    assert slot.release() is True
    assert slot.release() is False
    assert slot.release() is False

    # A second release of the same slot never frees someone else's.
    assert slots.in_use() == 1
    assert slots.try_acquire(ALEX) is not None
    assert slots.try_acquire(ALEX) is None
    assert other.release() is True


def test_concurrent_takers_never_get_more_than_the_count():
    slots = TransferSlots(total=2)
    start = threading.Barrier(16)
    got = []

    def take(owner):
        start.wait()
        slot = slots.try_acquire(owner)
        if slot is not None:
            got.append(slot)

    threads = [threading.Thread(target=take, args=(n % 3,)) for n in range(16)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()

    assert len(got) == 2
    assert slots.in_use() == 2


# ── O4 / DEV-7-02: a per-user cap inside the server-wide one ───────────────

def test_a_user_at_their_cap_gets_no_slot_while_another_user_still_does():
    slots = TransferSlots(total=2, per_user=1)

    mine = slots.try_acquire(ALEX)

    assert mine is not None
    assert slots.try_acquire(ALEX) is None
    assert slots.try_acquire(SAM) is not None
    assert slots.try_acquire(3) is None  # the server-wide count still holds


def test_a_released_slot_frees_its_users_share():
    slots = TransferSlots(total=2, per_user=1)
    mine = slots.try_acquire(ALEX)

    mine.release()
    mine.release()  # a second release frees nothing more

    again = slots.try_acquire(ALEX)
    assert again is not None
    assert slots.try_acquire(ALEX) is None


def test_without_a_per_user_cap_one_user_may_take_every_slot():
    slots = TransferSlots(total=2)

    assert slots.try_acquire(ALEX) is not None
    assert slots.try_acquire(ALEX) is not None
    assert slots.try_acquire(SAM) is None
