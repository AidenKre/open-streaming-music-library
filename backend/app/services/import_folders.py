"""Per-user import folders (spec §6.3).

``ImportDispatcher`` routes a file under ``USER_IMPORT_DIR/<folder>/`` to the
pipeline of the user whose ``library_folder`` matches ``<folder>``
(case-insensitively). The owner is fixed by which pipeline handles the file,
before any archive extraction. Disabled users' drops are still imported.
"""

import logging
import threading
from pathlib import Path
from typing import Callable

from app.library_folders import matching_import_dirs
from app.services.file_watcher import under_dot_folder
from app.services.ingestion import IMPORTED_DIR_NAME, Ingestor
from app.services.organizer import Organizer

logger = logging.getLogger(__name__)


def ensure_user_import_folder(user_import_dir: Path, folder: str) -> Path:
    """Return ``user_import_dir/<folder>``, creating it unless a directory
    matching ``folder`` by ``casefold()`` already exists (a pre-staged ``Sam/``
    serves user folder ``sam``)."""
    for entry in matching_import_dirs(user_import_dir, folder):
        if entry.is_dir():
            return entry
    target = user_import_dir / folder
    target.mkdir(parents=True, exist_ok=True)
    return target


def ensure_user_import_folders(user_import_dir: Path, users: list[dict]) -> None:
    for user in users:
        if user.get("deleting_at") is not None:
            continue
        ensure_user_import_folder(user_import_dir, user["library_folder"])


def prepare_signup_import_folder(user_import_dir: Path, folder_choice, watcher) -> None:
    """At signup: create the user's import folder (or adopt the pre-staged
    one), then scan it. The account already exists, so failures are logged
    and swallowed."""
    try:
        folder = folder_choice.adopted_import_dir or ensure_user_import_folder(
            user_import_dir, folder_choice.folder
        )
        if watcher is not None:
            watcher.scan_existing(folder)
    except OSError:
        logger.exception("could not prepare import folder for %s", folder_choice.folder)


class ImportDispatcher:
    def __init__(
        self,
        *,
        user_import_dir: Path,
        database,
        make_pipeline: Callable[[dict], tuple[Organizer, Ingestor]],
    ):
        self.user_import_dir = Path(user_import_dir)
        self.database = database
        self.make_pipeline = make_pipeline
        self._pipelines: dict[int, tuple[Organizer, Ingestor]] = {}
        self._lock = threading.Lock()

    def _relative(self, path: Path) -> Path | None:
        try:
            return path.relative_to(self.user_import_dir)
        except ValueError:
            pass
        try:
            return path.resolve().relative_to(self.user_import_dir.resolve())
        except ValueError:
            return None

    def pipeline_for(self, user: dict) -> tuple[Organizer, Ingestor]:
        """The owner's (organizer, ingestor): built at most once, then cached."""
        with self._lock:
            pipeline = self._pipelines.get(user["id"])
            if pipeline is None:
                pipeline = self.make_pipeline(user)
                self._pipelines[user["id"]] = pipeline
            return pipeline

    def dispatch(self, path) -> bool:
        path = Path(path)
        rel = self._relative(path)
        if rel is None:
            logger.info("Ignoring %s: not under %s", path, self.user_import_dir)
            return False
        if len(rel.parts) < 2:
            logger.info(
                "Ignoring %s: files directly in the user import root are ignored",
                path,
            )
            return False

        if under_dot_folder(self.user_import_dir / rel, self.user_import_dir):
            logger.info("Ignoring %s: under a dot-folder", path)
            return False

        folder = rel.parts[0].casefold()
        user = next(
            (
                u
                for u in self.database.list_user_folders()
                if u["library_folder"].casefold() == folder
            ),
            None,
        )
        if user is None:
            logger.info("Ignoring %s: no user owns folder %r", path, rel.parts[0])
            return False

        if user.get("deleting_at") is not None:
            logger.info(
                "Ignoring %s: user folder %s is being deleted", path, user["library_folder"]
            )
            return False

        _, ingestor = self.pipeline_for(user)
        imported_dir = self.user_import_dir / rel.parts[0] / IMPORTED_DIR_NAME
        return ingestor.ingest_file(path, imported_dir=imported_dir)
