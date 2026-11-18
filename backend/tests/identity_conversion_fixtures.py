"""Shared setup of the conversion identity tests, moved out of
``tests/test_identity_conversion.py``: the real audio fixtures (built once per
module), a settled identity row, a spy around the identity computer, and a
lossless conversion job ready to run."""

import shutil
from pathlib import Path

import pytest

import tests.conversion_fixtures as conv
from app.services.audio_identity import compute_identity
from tests.audio_fixtures import build_identity_fixtures
from tests.identity_rows import DIGEST, _identity
from tests.sqlite_helpers import sql_dicts
from tests.tool_call_capture import tool_call


def _settled(db, uuid_id, *, fp_state="current"):
    """The worker's finished state for a track: every layer current, generation 3."""
    sql_dicts(db, "UPDATE track_audio_identity SET generation = 3, exact_state = 'current', "
             "exact_kind = 'pcm_sha256', exact_digest = ?, sample_rate_hz = 44100, channels = 2, "
             "bits_per_sample = 16, fp_state = ?, fp_algorithm = 'chromaprint-2', "
             "match_state = 'current', matcher_version = 'm1', priority = 1, attempts = 2, "
             "next_attempt_at = 99, failure_reason = 'timeout' WHERE uuid_id = ?",
         (DIGEST, fp_state, uuid_id))
    return _identity(db, uuid_id)


@pytest.fixture(scope="module")
def fixtures(tmp_path_factory):
    if shutil.which("ffmpeg") is None:
        pytest.skip("ffmpeg not available")
    return build_identity_fixtures(tmp_path_factory.mktemp("conversion-fixtures"))


class _ComputeSpy:
    """Wraps the real identity computer; records (file name, codec hint, kwargs) and can
    rewrite the result for the converted temp (the test seam for a mismatch)."""

    def __init__(self, rewrite_temp=None):
        self.calls, self.rewrite_temp = [], rewrite_temp

    def __call__(self, path, codec_hint, **kwargs):
        self.calls.append((Path(path).name, codec_hint, tool_call(compute_identity, path, codec_hint, **kwargs)))
        identity = compute_identity(path, codec_hint, **kwargs)
        if self.rewrite_temp is not None and ".tagged." in Path(path).name:
            identity = self.rewrite_temp(identity)
        return identity

    def computed_source(self):
        return [c for c in self.calls if ".tagged." not in c[0]]


class _JobWakeup:
    """Records, at each notify, the committed generation and the journal rows left."""

    def __init__(self, db, uuid_id):
        self.db, self.uuid_id, self.seen = db, uuid_id, []

    def notify(self):
        self.seen.append((_identity(self.db, self.uuid_id)["generation"],
                          len(self.db.list_journal_entries())))


def _lossless_world(tmp_path, fixture, target, *, stored=None):
    """A track whose master is a copy of ``fixture``; its identity row carries a
    current fingerprint and either the given stored exact layer or a stale pending one."""
    db, orch, coordinator = conv._make_orchestrator(tmp_path)
    source = conv._root(tmp_path) / f"song{fixture.path.suffix}"
    shutil.copyfile(fixture.path, source)
    track = conv._add_track(db, source, codec=fixture.codec_hint)
    _settled(db, track.uuid_id)
    if stored is None:  # stale digest from an older generation: must not be trusted
        sql_dicts(db, "UPDATE track_audio_identity SET exact_state = 'pending' WHERE uuid_id = ?",
             (track.uuid_id,))
    else:
        sql_dicts(db, "UPDATE track_audio_identity SET exact_digest = ? WHERE uuid_id = ?",
             (stored, track.uuid_id))
    before = _identity(db, track.uuid_id)
    spy = _ComputeSpy()
    orch.compute_identity = spy
    wakeup = _JobWakeup(db, track.uuid_id)
    orch.identity_signal = wakeup
    job_id = orch.enqueue(conv._lib(orch), track.uuid_id, target, None, track.revision)
    return db, orch, coordinator, track, source, before, spy, wakeup, job_id
