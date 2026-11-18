"""Review r1 static guards for Phase 6.5's boundaries.

- N09 (review 6.5-U03): identity and fingerprint code starts processes only
  through ``run_capture``: it never imports ``subprocess``, never calls
  ``run_ffmpeg`` and never uses the ``os`` process calls.
- N10 (review 6.5-U11): Phase 6.5 adds no endpoint and no ``/app/info``
  block; the identity API is in-process (SC-25) until a later phase exposes
  it. That phase updates the second and third tests on purpose.
- 7A.2c (plan D36), the planned exception, deliberately narrow: the upload
  item DTO carries ``duplicate_check`` (spec §4 `GET item`). Still no route
  *path* names identity or duplicates and ``/app/info`` gets no identity
  block; the response-schema guard below lists exactly what is exposed, so
  any other field or model fails it. The upload validation module joins the
  process guard (exit proof: no ``subprocess`` outside ``run_capture``).
"""

import ast
import re
from pathlib import Path

import pytest

SERVICES = Path(__file__).resolve().parents[1] / "app" / "services"
IDENTITY_MODULES = [
    "audio_identity.py",
    "duplicate_detection.py",
    "fingerprinter.py",
    "identity_reasons.py",
    "identity_wakeup.py",
    "identity_worker.py",
    # 7A.2c: the upload probe and validation worker.
    "upload_validation.py",
]
OS_PROCESS_CALLS = re.compile(r"^(system|popen|spawn\w*|exec\w*|fork\w*|posix_spawn\w*)$")
IDENTITY_WORDS = re.compile(r"identit|duplicate|fingerprint|matcher|fpcalc", re.IGNORECASE)


def _process_uses(source: str) -> list[str]:
    found = []
    for node in ast.walk(ast.parse(source)):
        if isinstance(node, ast.Import):
            found += [a.name for a in node.names if a.name.split(".")[0] in ("subprocess", "multiprocessing")]
        elif isinstance(node, ast.ImportFrom):
            if (node.module or "").split(".")[0] in ("subprocess", "multiprocessing"):
                found.append(node.module)
            found += [a.name for a in node.names if a.name == "run_ffmpeg"]
        elif isinstance(node, ast.Name) and node.id in ("run_ffmpeg", "Popen"):
            found.append(node.id)
        elif isinstance(node, ast.Attribute):
            if node.attr in ("run_ffmpeg", "Popen"):
                found.append(node.attr)
            elif isinstance(node.value, ast.Name) and node.value.id == "os" and OS_PROCESS_CALLS.match(node.attr):
                found.append(f"os.{node.attr}")
    return found


@pytest.mark.parametrize("module", IDENTITY_MODULES)
def test_identity_code_starts_processes_only_through_run_capture(module):
    assert _process_uses((SERVICES / module).read_text()) == []


def test_the_guard_sees_the_process_calls_it_forbids():
    assert _process_uses("import subprocess\nsubprocess.run(['x'])") == ["subprocess"]
    assert _process_uses("from app.services.ffmpeg_runner import run_ffmpeg") == ["run_ffmpeg"]
    assert _process_uses("from app.services import ffmpeg_runner\nffmpeg_runner.run_ffmpeg([])") == ["run_ffmpeg"]
    assert _process_uses("import os\nos.system('x')\nos.posix_spawn('x', [], {})") == ["os.system", "os.posix_spawn"]
    assert _process_uses("from app.services.ffmpeg_runner import run_capture\nrun_capture(['x'])") == []


def test_the_tool_running_modules_use_run_capture():
    for module in ("audio_identity.py", "fingerprinter.py", "upload_validation.py"):
        assert "run_capture" in (SERVICES / module).read_text(), module


def test_no_route_serves_identity_or_duplicates(configure_app):
    paths = [getattr(route, "path", "") for route in configure_app().app.routes]
    assert paths  # the app has routes, so an empty match below means something
    # 7A.3b: the spec names the one upload route that resolves a duplicate.
    allowed = {
        "/tracks/uploads/items/{item_uuid:uuid}/resolve-duplicate",
        # 8A.1 / 8A.4 (plan D18, spec §4): Phase 8's duplicates routes, by name.
        "/tracks/duplicates",
        "/tracks/duplicates/summary",
        "/tracks/duplicates/dismiss",
        "/tracks/duplicates/restore",
    }
    assert [p for p in paths if IDENTITY_WORDS.search(p) and p not in allowed] == []


def _keys(value, prefix=""):
    if isinstance(value, dict):
        for key, inner in value.items():
            yield f"{prefix}{key}"
            yield from _keys(inner, f"{prefix}{key}.")
    elif isinstance(value, list):
        for inner in value:
            yield from _keys(inner, prefix)


def test_app_info_has_no_identity_block(app_client):
    response = app_client.get("/app/info")
    assert response.status_code == 200
    keys = list(_keys(response.json()))
    assert keys
    # 8A.1 (plan D18, spec §3, SC-03): the one allowed key is Phase 8's
    # ``library_tools.duplicate_review`` capability flag. It is a boolean that
    # says whether the duplicates review endpoints exist; it carries no
    # identity data. Still no identity block.
    allowed = {"library_tools.duplicate_review"}
    assert [k for k in keys if IDENTITY_WORDS.search(k) and k not in allowed] == []


# 7A.2c (D36): the only response schema that exposes duplicate data is the
# upload item's ``duplicate_check`` and the models it is built from.
EXPOSED_DUPLICATE_SCHEMA = {
    "UploadItemOut.duplicate_check",
    "UploadItemOut.duplicate_kind",  # 7A.3b: a duplicate receipt names exact or fingerprint (spec 3)
    "DuplicateCheckOut",
    "DuplicateCheckOut.no_duplicates_found",
    "DuplicateCheckOut.fingerprint",  # the fingerprint layer's coverage
    "DuplicateCoverageOut",
    "DuplicateMatchOut",
    "DuplicateStagedSummary",
    "DuplicateTrackSummary",
    # 8A.1 (plan D18): the library_tools capability flag, a boolean, no data.
    "LibraryToolsCapabilities.duplicate_review",
    # 8A.4 (plan D18, spec §4): the Possible duplicates list, on purpose.
    "DuplicatePairPage",
    "DuplicatePairOut",
    "DuplicatePairTrack",
    # 8A.4 (spec §4 summary, plan D17): per-band counts, the coverage counts
    # and the active fingerprinter's name, on purpose.
    "DuplicateSummaryOut",
    "DuplicateSummaryOut.fingerprinter",
    "DuplicateBands",
    "IdentityCoverage",
    "IdentityCoverage.fingerprint",
    "FingerprintCoverage",
}


def test_only_the_upload_item_exposes_duplicate_data(configure_app):
    schemas = configure_app().app.openapi()["components"]["schemas"]
    hits = set()
    for name, schema in schemas.items():
        if IDENTITY_WORDS.search(name):
            hits.add(name)
        hits.update(f"{name}.{field}" for field in schema.get("properties", {}) if IDENTITY_WORDS.search(field))

    assert hits == EXPOSED_DUPLICATE_SCHEMA
