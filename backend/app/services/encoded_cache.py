"""Disk-backed LRU cache for transcoded audio files.

The cache is keyed by (uuid_id, quality_preset). On lookup hits we touch the
file's mtime so it bubbles up the LRU. When the directory exceeds the size
budget, oldest files (by mtime) are evicted.
"""

import os
from dataclasses import dataclass
from pathlib import Path
from threading import Lock
from typing import Optional


CACHE_FILE_SUFFIX = ".m4a"


@dataclass(frozen=True)
class EncodedCacheContext:
    cache_dir: Path
    max_size_bytes: int


class EncodedCache:
    def __init__(self, ctx: EncodedCacheContext):
        self.ctx = ctx
        self.ctx.cache_dir.mkdir(parents=True, exist_ok=True)
        self._lock = Lock()

    def _key_filename(self, uuid_id: str, quality: str) -> str:
        # uuid_id and quality are constrained values; use directly to keep cache
        # files debuggable.
        safe_uuid = uuid_id.replace("/", "_")
        return f"{safe_uuid}__q{quality}{CACHE_FILE_SUFFIX}"

    def path_for(self, uuid_id: str, quality: str) -> Path:
        return self.ctx.cache_dir / self._key_filename(uuid_id, quality)

    def get(self, uuid_id: str, quality: str) -> Optional[Path]:
        path = self.path_for(uuid_id, quality)
        if not path.exists():
            return None
        # Touch atime+mtime so this entry becomes the most-recently-used.
        try:
            os.utime(path, None)
        except OSError:
            pass
        return path

    def has(self, uuid_id: str, quality: str) -> bool:
        return self.path_for(uuid_id, quality).exists()

    def insert(self, uuid_id: str, quality: str, source_path: Path) -> Path:
        """Move ``source_path`` into the cache and prune if over budget."""
        target = self.path_for(uuid_id, quality)
        with self._lock:
            target.parent.mkdir(parents=True, exist_ok=True)
            os.replace(source_path, target)
            self._prune_locked()
        return target

    def remove(self, uuid_id: str, quality: str) -> bool:
        target = self.path_for(uuid_id, quality)
        try:
            target.unlink()
            return True
        except FileNotFoundError:
            return False

    def clear(self) -> None:
        with self._lock:
            for entry in self.ctx.cache_dir.iterdir():
                if entry.is_file() and entry.name.endswith(CACHE_FILE_SUFFIX):
                    entry.unlink(missing_ok=True)

    def total_size_bytes(self) -> int:
        total = 0
        for entry in self.ctx.cache_dir.iterdir():
            if entry.is_file() and entry.name.endswith(CACHE_FILE_SUFFIX):
                try:
                    total += entry.stat().st_size
                except OSError:
                    continue
        return total

    def _prune_locked(self) -> None:
        if self.ctx.max_size_bytes <= 0:
            return
        entries = []
        for entry in self.ctx.cache_dir.iterdir():
            if not entry.is_file() or not entry.name.endswith(CACHE_FILE_SUFFIX):
                continue
            try:
                stat = entry.stat()
            except OSError:
                continue
            entries.append((stat.st_mtime, stat.st_size, entry))

        total = sum(size for _, size, _ in entries)
        if total <= self.ctx.max_size_bytes:
            return

        # Oldest first.
        entries.sort(key=lambda item: item[0])
        for _, size, entry in entries:
            if total <= self.ctx.max_size_bytes:
                break
            try:
                entry.unlink()
                total -= size
            except OSError:
                continue
