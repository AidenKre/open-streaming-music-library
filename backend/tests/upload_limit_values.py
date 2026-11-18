"""The upload limits the server enforces by default (7A.1d, spec §3), moved out
of ``tests/test_upload_limits.py`` for the tests that compare an answer with them."""

MiB = 1024 * 1024
GiB = 1024 * MiB

EFFECTIVE_DEFAULTS = {
    "max_files_per_batch": 100,
    "max_file_bytes": 250 * MiB,
    "max_batch_bytes": 2 * GiB,
    "max_expanded_bytes_per_batch": 2 * GiB,
    "max_expanded_member_bytes": 250 * MiB,
    "max_audio_items_per_batch": 1000,
    "max_archive_members": 2000,
    "max_compression_ratio": 100,
    "receives": 2,
    "staged_quota_bytes": 10 * GiB,
    # O4 / DEV-7-02 (tests/test_upload_fairness.py).
    "receives_per_user": 1,
    "user_staged_quota_bytes": 5 * GiB,
}
