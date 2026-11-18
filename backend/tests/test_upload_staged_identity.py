"""7A.2c S2 (spec §3 "upload_item_audio_identity ... uses the SC-25 identity
column set and serializer verbatim, plus a fingerprint blob column"; plan D10,
D11, D13; 6.5 review N05): the staged identity is stored through the SC-25
serializer and read back through ``identity_from_columns`` before use, and the
duplicate report is stored as versioned JSON of refs only."""

import json

import pytest

from app.services.audio_identity import (
    FINGERPRINT_COLUMNS,
    IDENTITY_COLUMNS,
    AudioIdentity,
    ExactAudioHash,
    ExactUnavailable,
    FingerprintIdentity,
    FingerprintUnavailable,
)
from app.services.duplicate_detection import (
    DuplicateMatch,
    DuplicateReport,
    LayerCoverage,
    StagedRef,
    TrackRef,
)
from app.services.fingerprinter import pack_fingerprint
from app.services.upload_validation import (
    duplicate_report_from_json,
    duplicate_report_to_json,
    staged_identity_columns,
    staged_identity_from_row,
)

ALL_COLUMNS = set(IDENTITY_COLUMNS) | set(FINGERPRINT_COLUMNS) | {"fp_failure_reason"}
EXACT = ExactAudioHash("pcm_sha256", "ab" * 32, 44100, 2, 16)
PRINT = FingerprintIdentity("current", "fpcalc", "chromaprint-2", 31.5, (1, 2, 3, 2**32 - 1))


def _identity(exact=EXACT, fingerprint=None):
    return AudioIdentity(exact=exact, tool_versions="ffmpeg 8.1", computed_at=1700, fingerprint=fingerprint)


def test_without_a_fingerprinter_the_print_layer_is_stored_unavailable():
    columns = staged_identity_columns(_identity(), fingerprinter_present=False)

    assert set(columns) == ALL_COLUMNS
    assert columns["exact_state"] == "current"
    assert columns["exact_digest"] == "ab" * 32
    assert columns["fp_state"] == "unavailable"
    assert {k: columns[k] for k in FINGERPRINT_COLUMNS if k != "fp_state"} == dict.fromkeys(
        set(FINGERPRINT_COLUMNS) - {"fp_state"}
    )
    assert columns["fp_failure_reason"] is None


def test_a_print_that_could_not_be_made_is_stored_failed_with_its_reason():
    columns = staged_identity_columns(
        _identity(fingerprint=FingerprintUnavailable("timeout")), fingerprinter_present=True
    )

    assert (columns["fp_state"], columns["fp_failure_reason"]) == ("failed", "timeout")
    assert columns["fp_data"] is None


def test_a_computed_print_is_stored_with_its_blob():
    columns = staged_identity_columns(_identity(fingerprint=PRINT), fingerprinter_present=True)

    assert columns["fp_state"] == "current"
    assert columns["fp_data"] == pack_fingerprint(PRINT.items)
    assert (columns["fp_duration_s"], columns["fp_item_count"]) == (31.5, 4)
    assert columns["fp_failure_reason"] is None


@pytest.mark.parametrize(
    "identity, present",
    [
        (_identity(fingerprint=PRINT), True),
        (_identity(exact=ExactUnavailable("failed", "decode_error"), fingerprint=PRINT), True),
        (_identity(exact=ExactUnavailable("unsupported", None)), False),
        (_identity(fingerprint=FingerprintIdentity("too_short", "fpcalc", "chromaprint-2", None, ())), True),
        (_identity(fingerprint=FingerprintIdentity("low_information", "fpcalc", "chromaprint-2", 9.0, (5,) * 4)), True),
    ],
    ids=["current", "exact-failed", "unsupported", "too-short", "low-information"],
)
def test_the_stored_columns_read_back_to_the_same_identity(identity, present):
    assert staged_identity_from_row(staged_identity_columns(identity, fingerprinter_present=present)) == identity


def test_a_stored_failed_print_reads_back_as_failed_not_unavailable():
    row = staged_identity_columns(_identity(fingerprint=FingerprintUnavailable("killed")), fingerprinter_present=True)

    assert staged_identity_from_row(row).fingerprint == FingerprintUnavailable("killed")


def test_a_stored_unavailable_print_reads_back_as_not_computed():
    row = staged_identity_columns(_identity(), fingerprinter_present=False)

    assert staged_identity_from_row(row).fingerprint is None


@pytest.mark.parametrize(
    "damage",
    [
        {"fp_data": b"\x01\x02\x03"},  # not whole uint32 items (D10: a malformed carried print)
        {"fp_duration_s": None},  # N05: a current print without a duration
        {"fp_duration_s": 0.0},
        {"fp_backend": None},
    ],
    ids=["bad-blob", "no-duration", "zero-duration", "no-backend"],
)
def test_a_malformed_stored_print_reads_back_as_a_failed_print_not_an_error(damage):
    row = {**staged_identity_columns(_identity(fingerprint=PRINT), fingerprinter_present=True), **damage}

    identity = staged_identity_from_row(row)

    assert identity.exact == EXACT
    assert identity.fingerprint == FingerprintUnavailable("output_error")


def test_a_malformed_exact_layer_is_an_error_the_caller_must_handle():
    row = {**staged_identity_columns(_identity(), fingerprinter_present=False), "exact_digest": None}

    with pytest.raises(ValueError):
        staged_identity_from_row(row)


def _report():
    return DuplicateReport(
        exact=LayerCoverage("current", 2, 1, 3),
        fingerprint=LayerCoverage("unavailable", 0, 0, 0),
        matches=(
            DuplicateMatch(TrackRef("11111111-1111-4111-8111-111111111111"), "exact", "exact", None),
            DuplicateMatch(StagedRef("22222222-2222-4222-8222-222222222222"), "fingerprint", "strong", 0.93),
        ),
    )


def test_the_report_is_stored_as_versioned_json_of_refs_only():
    stored = json.loads(duplicate_report_to_json(_report()))

    assert stored == {
        "v": 1,
        "status": "complete",
        "exact": {"subject_state": "current", "library_pending": 2, "library_failed": 1,
                  "library_not_comparable": 3},
        "fingerprint": {"subject_state": "unavailable", "library_pending": 0, "library_failed": 0,
                        "library_not_comparable": 0},
        "matches": [
            {"ref": "library_track", "id": "11111111-1111-4111-8111-111111111111",
             "kind": "exact", "band": "exact", "score": None},
            {"ref": "staged_item", "id": "22222222-2222-4222-8222-222222222222",
             "kind": "fingerprint", "band": "strong", "score": 0.93},
        ],
    }


def test_the_stored_report_reads_back_to_the_same_report():
    assert duplicate_report_from_json(duplicate_report_to_json(_report())) == _report()


def test_a_check_that_failed_is_stored_as_failed_and_reads_back_as_none():
    stored = duplicate_report_to_json(None)

    assert json.loads(stored) == {"v": 1, "status": "failed", "exact": None, "fingerprint": None, "matches": []}
    assert duplicate_report_from_json(stored) is None


def _stored(**changes):
    return json.dumps({**json.loads(duplicate_report_to_json(_report())), **changes})


@pytest.mark.parametrize(
    "make_text",
    [
        lambda: "not json",
        lambda: json.dumps({"v": 2, "status": "complete"}),
        lambda: _stored(matches=[{"ref": "elsewhere", "id": "x", "kind": "exact", "band": "exact", "score": None}]),
        lambda: _stored(status="maybe"),
    ],
    ids=["not-json", "unknown-version", "unknown-ref", "unknown-status"],
)
def test_a_report_in_an_unknown_shape_is_refused(make_text):
    text = make_text()
    with pytest.raises(ValueError):
        duplicate_report_from_json(text)
