from pydantic import BaseSettings
from pathlib import Path

class Settings(BaseSettings):
    # Project directories
    import_dir: Path = Path("./import")

    music_library_dir: Path = Path("./music")

    # Server settings
    debug: bool = True
    host: str = "0.0.0.0"
    port: int = 8000

    # Feature flags
    enable_file_watcher: bool = True

    class Config:
        env_file = ".env"
        env_file_encoding = "utf-8"

settings = Settings()