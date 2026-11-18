from pathlib import Path
from typing import Literal

from pydantic import Field, SecretStr, field_validator, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    # Project directories
    import_dir: Path = Path("./import")
    user_import_dir: Path = Path("./import-users")
    music_library_dir: Path = Path("./music")
    app_data_dir: Path = Path("./data")

    # Server settings
    debug: bool = True
    host: str = "0.0.0.0"
    port: int = 8000

    # Feature flags
    enable_file_watcher: bool = True
    enable_upload_commit_worker: bool = True  # prepares accepted upload commits (7A.3a); off leaves them committing
    enable_upload_validation_worker: bool = True  # probes and duplicate-checks received uploads (7A.2c); off leaves them validating
    enable_upload_janitor: bool = True  # periodically expires and cleans staged uploads (7A.3c); off leaves them until the next start
    upload_janitor_interval_s: int = Field(3600, ge=1)  # seconds between periodic janitor passes
    upload_stage_expiry_s: int = Field(7 * 86400, ge=1)  # an unconfirmed staged item expires after this long without progress
    upload_retention_s: int = Field(30 * 86400, ge=1)  # ended batch and item records are pruned after this long
    library_delete_enabled: bool = False  # operator switch for server-side library delete (8A); off hides it and refuses it
    enable_deletion_worker: bool = True  # executes accepted server deletion jobs (8A.3c); off leaves them pending until a start with it on
    deletion_janitor_interval_s: int = Field(3600, ge=1)  # seconds between the deletion worker's retries of pending committed clean-ups
    enable_identity_worker: bool = True  # background audio-identity scan (6.5); off stops identity backfill and recompute
    enable_lastfm_sender: bool = True  # test seam, not an operator setting (off silently queues listens without sending); left out of the operator guide

    # Encoded tracks cache (used for transcoded streams)
    encoded_cache_size_gb: float = 5.0
    encoded_cache_prefetch_workers: int = 4
    prefetch_lookahead: int = 20

    # Default streaming quality preset. The master admin's user_settings value
    # (default_streaming_quality) takes precedence at runtime; this env value is
    # its first-boot seed and the fallback when the stored value is invalid.
    default_streaming_quality: str = "original"

    # Master admin, created at first startup from the environment.
    osml_admin_username: str | None = None
    osml_admin_password: SecretStr | None = None
    osml_admin_password_file: Path | None = None
    # Removable signup valves.
    osml_signup_enabled: bool = True
    osml_max_users: int = Field(25, ge=0)
    # Test-only: cheap argon2 parameters. Never enable in production.
    osml_insecure_fast_password_hashing: bool = False

    # Last.fm: loose types, no validators, so a typo never stops Settings();
    # app.services.lastfm_config.resolve_lastfm_config checks them.
    lastfm_enabled: str | None = None
    lastfm_api_key: SecretStr | None = None
    lastfm_api_secret: SecretStr | None = None
    lastfm_credential_key: SecretStr | None = None
    lastfm_api_key_file: str | None = None
    lastfm_api_secret_file: str | None = None
    lastfm_credential_key_file: str | None = None
    lastfm_settle_delay_s: str | None = None
    lastfm_min_request_gap_s: str | None = None
    lastfm_app_name: str | None = None
    osml_insecure_lastfm_api_url: str | None = None

    # Fingerprinter selection: auto = fpcalc or none (the ffmpeg chromaprint
    # backend is not built, so "ffmpeg" means no fingerprinting). fpcalc_path is used
    # verbatim as the executable path, so it is deliberately not resolved.
    audio_fingerprint_backend: Literal["auto", "fpcalc", "ffmpeg", "off"] = "auto"
    fpcalc_path: Path | None = None
    fpcalc_timeout_s: float = Field(60.0, gt=0)

    # Fingerprint matcher (Phase 6.5). Counts are fingerprint items, not
    # seconds: fpcalc 1.6.2 gives about 8.08 items per second, less a fixed
    # edge loss of about 21 items (221 items for 30 s, 948 for 120 s), so 120 items
    # ~ 17 s and 24 items ~ 3.0 s. fp_max_offset is searched both around 0 and
    # around the offset the two durations imply.
    # Thresholds and window were validated on 2026-11-17 on 1,111 compared
    # tracks of one Creative Commons catalogue (MTG-Jamendo, mono ~100 kbps MP3;
    # the project's report fingerprint-validation-jamendo.md, kept outside git).
    # No unrelated pair scored above 0.591, 0.11 below 0.70. That is a zero
    # count: its 95 % bound still allows about 1 false pair per 1,000 tracks in a
    # 10,000-track library. Known cost of 0.70: about 1 vocal/instrumental pair
    # per 1,000 tracks shows as possible. The 7 s window raises the share of
    # the 2,480 core test copies found at 0.70 from 87.0 % to 99.9 % (lead-ins,
    # cut starts and tails of 3.5-6 s), for 63 % more pairs compared. Not
    # covered: about a third of copies 0.5 % faster or slower and most at 1 %; a
    # copy with a longer lead-in but an earlier ending, which only a wider
    # fp_max_offset finds (the second range sits at the offset the length
    # difference implies); differences beyond the window. Re-tune with
    # backend/scripts/identity_tuning.py. Env vars are FP_*.
    fp_max_offset: int = Field(24, ge=0)
    fp_min_overlap: int = Field(120, ge=1)
    fp_min_items: int = Field(120, ge=1)
    # Fraction of unique top-14-bit keys below which a print is low_information.
    fp_min_diversity: float = Field(0.15, ge=0, le=1)
    # The score is 1 - BER, raised to 8 - 7*D when the less diverse print's
    # compare2 diversity D is below 1 (fewer than about half distinct coarse
    # keys). So 0.90 / 0.70 mean BER <= 0.10 / <= 0.30 without that penalty,
    # and about BER <= 0.031 / <= 0.100 at the low-information cutoff
    # (exponent 3.38).
    fp_strong: float = Field(0.90, gt=0, le=1)
    fp_possible: float = Field(0.70, gt=0, le=1)
    fp_duration_tolerance_s: float = Field(7.0, ge=0)
    fp_duration_tolerance_frac: float = Field(0.02, ge=0)

    # Upload limits (spec §3). Advertised and enforced only through
    # services/upload_limits.effective_upload_limits, which applies the caps.
    # They apply to uploads only, except upload_max_compression_ratio, which is
    # also the bomb guard of archives in import folders (import_archive).
    upload_max_files_per_batch: int = Field(100, ge=1)
    upload_max_file_bytes: int = Field(250 * 1024**2, ge=1)
    upload_max_batch_bytes: int = Field(2 * 1024**3, ge=1)
    upload_max_expanded_bytes_per_batch: int = Field(2 * 1024**3, ge=1)
    upload_max_expanded_member_bytes: int = Field(250 * 1024**2, ge=1)
    upload_max_audio_items_per_batch: int = Field(1000, ge=1)
    # Counts ignored non-audio entries too.
    upload_max_archive_members: int = Field(2000, ge=1)
    upload_max_compression_ratio: int = Field(100, ge=1)
    # Archives in import folders: a guard against archives built to overwhelm
    # the server with huge numbers of tiny files, not a size limit (a box set
    # has hundreds to a few thousand entries, a whole-library archive tens of
    # thousands). Counts ignored non-audio entries too.
    import_archive_max_entries: int = Field(100_000, ge=1)
    upload_max_receives: int = Field(2, ge=1)
    upload_staged_quota_bytes: int = Field(10 * 1024**3, ge=1)
    # O4 / DEV-7-02 per-user fairness.
    upload_max_receives_per_user: int = Field(1, ge=1)
    upload_user_staged_quota_bytes: int = Field(5 * 1024**3, ge=1)
    # Server-internal free-disk floor for the storage ledger; not advertised.
    storage_free_space_floor_bytes: int = Field(256 * 1024**2, ge=0)

    model_config = SettingsConfigDict(
        env_file=".env", env_file_encoding="utf-8", validate_default=True
    )

    @model_validator(mode="after")
    def _fingerprint_thresholds_consistent(self):
        if self.fp_possible > self.fp_strong:
            raise ValueError("fp_possible must be <= fp_strong")
        if self.fp_min_overlap > self.fp_min_items:
            raise ValueError("fp_min_overlap must be <= fp_min_items")
        return self

    @field_validator("osml_admin_password_file", "fpcalc_path", mode="before")
    @classmethod
    def _empty_path_is_unset(cls, value):
        if isinstance(value, str) and not value.strip():
            return None
        return value

    # Absolute at load, so stored file paths and journal paths are always
    # absolute and recovery's string compares stay valid.
    @field_validator(
        "import_dir", "music_library_dir", "app_data_dir", "user_import_dir"
    )
    @classmethod
    def _absolute(cls, value: Path) -> Path:
        return value.expanduser().resolve()


settings = Settings()
