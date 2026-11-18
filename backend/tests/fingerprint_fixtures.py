"""Synthetic fingerprint rows and prints for the 6.5B.2b finder and store tests.

Prints are seeded random uint32 arrays (fully diverse, so no diversity
penalty). Flipping the k low bits of every item gives a bit error rate of
exactly k/32, so a score of exactly 1 - k/32.
"""

import random
from dataclasses import fields

from app.services.audio_identity import KIND_PCM
from app.services.duplicate_detection import MatcherParams
from app.services.fingerprinter import pack_fingerprint
from tests.identity_worker_fixtures import add_track, sql

ALGO = "chromaprint-2"
ITEMS = 300

# U09-B-06 (owner's small item, row 59): the matching tests state the matcher
# settings they prove things with, instead of inheriting the defaults, so that a
# change of a default never silently changes what they prove. These are the
# values the band and window tests were written against (strong 0.90, possible
# 0.80, window max(3 s, 2%)), not the shipped defaults; the defaults themselves
# are pinned in test_matcher_params.py and exercised by the "at the defaults" tests.
EXPLICIT = MatcherParams(
    max_offset=24, min_overlap=120, min_items=120, min_diversity=0.15,
    strong=0.90, possible=0.80, duration_tolerance_s=3.0, duration_tolerance_frac=0.02,
)


def pin_matcher_settings(monkeypatch, params: MatcherParams = EXPLICIT) -> MatcherParams:
    """Make the process settings (read by the workers and by ``find_duplicates``
    without ``params``) carry exactly ``params`` for this test."""
    from app import config

    for field in fields(MatcherParams):
        monkeypatch.setattr(config.settings, f"fp_{field.name}", getattr(params, field.name))
    return params


def random_print(seed: int, n: int = ITEMS) -> tuple[int, ...]:
    rng = random.Random(seed)
    return tuple(rng.getrandbits(32) for _ in range(n))


def noisy(items, bits: int) -> tuple[int, ...]:
    """Flip the ``bits`` low bits of every item: BER exactly bits/32."""
    mask = (1 << bits) - 1
    return tuple(item ^ mask for item in items)


BASE = random_print(1)


def fp_track(db, name, items=BASE, *, duration=200.0, state="current", algorithm=ALGO,
             owner_id=None, digest=None, metadata_duration=None):
    """A library track whose identity row has ``fp_state=state`` and (unless
    ``items`` is None) a stored print. Each track gets its own exact digest
    unless one is given, so only the fingerprint layer can pair them."""
    uuid_id = add_track(
        db, f"/m/{name}.flac", owner_id=owner_id,
        identity={
            "exact_state": "current", "exact_kind": KIND_PCM,
            "exact_digest": digest or (name.encode().hex() * 64)[:64],
            "sample_rate_hz": 44100, "channels": 2, "bits_per_sample": 16,
            "fp_state": state, "fp_algorithm": algorithm,
        },
    )
    if items is not None:
        sql(db, "INSERT INTO track_audio_fingerprint (uuid_id, backend, algorithm, duration_s, item_count, data) "
                "VALUES (?, 'fpcalc', ?, ?, ?, ?)",
            (uuid_id, algorithm, duration, len(items), pack_fingerprint(items)))
    sql(db, "UPDATE trackmetadata SET duration = ? WHERE uuid_id = ?", (metadata_duration, uuid_id))
    return uuid_id
