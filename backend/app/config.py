from pathlib import Path

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    # Project directories
    import_dir: Path = Path("./import")
    music_library_dir: Path = Path("./music")
    app_data_dir: Path = Path("./data")

    # Server settings
    debug: bool = True
    host: str = "0.0.0.0"
    port: int = 8000

    # Feature flags
    enable_file_watcher: bool = True

    # Encoded tracks cache (used for transcoded streams)
    encoded_cache_size_gb: float = 5.0
    encoded_cache_prefetch_workers: int = 4
    prefetch_lookahead: int = 20

    # Default streaming quality preset served to all clients.
    # Overridden by the value stored in app_settings at runtime.
    default_streaming_quality: str = "original"

    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8")


settings = Settings()
