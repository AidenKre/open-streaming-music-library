"""9D.1a (D17, spec §7.8): one version constant, sent as ``User-Agent: OSML/<version>``."""

import tomllib
from pathlib import Path


def test_the_version_constant_equals_the_project_version():
    from app.version import OSML_VERSION

    pyproject = tomllib.loads(
        (Path(__file__).resolve().parents[1] / "pyproject.toml").read_text(encoding="utf-8")
    )
    assert OSML_VERSION == pyproject["project"]["version"]
