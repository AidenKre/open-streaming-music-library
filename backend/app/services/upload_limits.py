"""Effective upload limits (spec §3, SC-03)."""

from dataclasses import dataclass


@dataclass(frozen=True)
class UploadLimits:
    max_files_per_batch: int
    max_file_bytes: int
    max_batch_bytes: int
    max_expanded_bytes_per_batch: int
    max_expanded_member_bytes: int
    max_audio_items_per_batch: int
    max_archive_members: int
    max_compression_ratio: int
    receives: int
    staged_quota_bytes: int
    # O4 / DEV-7-02 per-user fairness.
    receives_per_user: int
    user_staged_quota_bytes: int


def effective_upload_limits(settings) -> UploadLimits:
    """The one place caps are applied; everything that advertises or checks
    an upload limit reads this, never the raw settings."""
    quota = settings.upload_staged_quota_bytes
    # O4 / DEV-7-02 per-user fairness: byte caps follow the user's quota.
    user_quota = min(settings.upload_user_staged_quota_bytes, quota)
    batch = min(settings.upload_max_batch_bytes, user_quota)
    expanded = min(settings.upload_max_expanded_bytes_per_batch, user_quota)
    return UploadLimits(
        max_files_per_batch=settings.upload_max_files_per_batch,
        max_file_bytes=min(settings.upload_max_file_bytes, batch),
        max_batch_bytes=batch,
        max_expanded_bytes_per_batch=expanded,
        max_expanded_member_bytes=min(
            settings.upload_max_expanded_member_bytes, expanded
        ),
        max_audio_items_per_batch=settings.upload_max_audio_items_per_batch,
        max_archive_members=settings.upload_max_archive_members,
        max_compression_ratio=settings.upload_max_compression_ratio,
        receives=settings.upload_max_receives,
        staged_quota_bytes=quota,
        # O4 / DEV-7-02 per-user fairness.
        receives_per_user=min(
            settings.upload_max_receives_per_user, settings.upload_max_receives
        ),
        user_staged_quota_bytes=user_quota,
    )
