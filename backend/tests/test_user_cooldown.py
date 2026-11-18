"""UserCooldown (OPEN-9-03): one per-user, per-action limit shared by Last.fm
Connect and Finish. Undoing a claim gives back only that claim: it never
erases a newer claim taken meanwhile (review s9-review-answers #3)."""

from app.services.user_cooldown import UserCooldown
from tests.lastfm_fake import FakeClock


def test_a_claim_within_the_period_is_refused_with_the_whole_seconds_left():
    clock = FakeClock(start=0)
    cooldown = UserCooldown(clock=clock)
    assert cooldown.claim(1, "act", 5)[0] is None
    clock.advance(1.5)

    assert cooldown.claim(1, "act", 5)[0] == 4


def test_users_and_actions_are_independent():
    cooldown = UserCooldown(clock=FakeClock(start=0))
    assert cooldown.claim(1, "act", 5)[0] is None

    assert cooldown.claim(2, "act", 5)[0] is None
    assert cooldown.claim(1, "other", 5)[0] is None


def test_undoing_a_claim_restores_the_one_before_it():
    clock = FakeClock(start=0)
    cooldown = UserCooldown(clock=clock)
    cooldown.claim(1, "act", 5)
    clock.advance(5)
    _, undo = cooldown.claim(1, "act", 5)
    cooldown.release(1, "act", undo)
    clock.advance(1)

    assert cooldown.claim(1, "act", 5)[0] is None  # 6 s after the first claim


def test_undoing_an_old_claim_never_erases_a_newer_one():
    """A at t=0 (kept), B at t=5 (to be undone), C at t=10 (kept); B is undone
    after C was taken: C still holds, so a claim at t=11 is refused."""
    clock = FakeClock(start=0)
    cooldown = UserCooldown(clock=clock)
    cooldown.claim(1, "act", 5)
    clock.advance(5)
    _, undo_b = cooldown.claim(1, "act", 5)
    clock.advance(5)
    assert cooldown.claim(1, "act", 5)[0] is None
    cooldown.release(1, "act", undo_b)
    clock.advance(1)

    assert cooldown.claim(1, "act", 5)[0] == 4
