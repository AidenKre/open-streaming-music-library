"""Phase M.2a (M-U16, spec §6.3): ``user_import_dir`` is validated at startup
as non-overlapping with ``import_dir`` and ``music_library_dir``: every pair of
the three trees, equal or nested either way, refuses to start."""

import pytest
from fastapi.testclient import TestClient


@pytest.mark.parametrize(
    "music, imports, user_imports",
    [
        # user_import_dir against music_library_dir
        ("music", "import", "music"),
        ("music", "import", "music/inbox"),
        ("lib/music", "import", "lib"),
        # user_import_dir against import_dir
        ("music", "import", "import"),
        ("music", "import", "import/users"),
        ("music", "drop/import", "drop"),
        # the existing pair still refuses
        ("music", "music/import", "import-users"),
        ("import/music", "import", "import-users"),
    ],
)
def test_overlapping_import_trees_refuse_to_start(
    configure_app, tmp_path, music, imports, user_imports
):
    main = configure_app(
        music_dir=music,
        import_dir=imports,
        env={"USER_IMPORT_DIR": str(tmp_path / user_imports)},
    )

    with pytest.raises(RuntimeError, match="must not overlap"):
        with TestClient(main.app):
            pass


def test_sibling_import_trees_start(configure_app, tmp_path):
    main = configure_app(env={"USER_IMPORT_DIR": str(tmp_path / "import-users")})

    with TestClient(main.app) as client:
        assert client.get("/").status_code == 200


# Review r1 m-R1-13: the data dir joins the check. A data dir inside a watched
# import tree would have its caches dispatched (and a user named like it could
# adopt it); inside the library a user folder could be it. The data dir may
# still hold the other trees (a single /data volume).
@pytest.mark.parametrize(
    "data, music, imports, user_imports",
    [
        ("import-users/data", "music", "import", "import-users"),
        ("import/data", "music", "import", "import-users"),
        ("music/data", "music", "import", "import-users"),
        ("import-users", "music", "import", "import-users"),
        ("music", "music", "import", "import-users"),
        ("import", "music", "import", "import-users"),
    ],
)
def test_a_data_dir_inside_or_equal_to_another_tree_refuses_to_start(
    configure_app, tmp_path, data, music, imports, user_imports
):
    main = configure_app(
        data_dir=data,
        music_dir=music,
        import_dir=imports,
        env={"USER_IMPORT_DIR": str(tmp_path / user_imports)},
    )

    with pytest.raises(RuntimeError, match="must not overlap"):
        with TestClient(main.app):
            pass


def test_other_trees_inside_the_data_dir_start(configure_app, tmp_path):
    main = configure_app(
        data_dir="srv",
        music_dir="srv/music",
        import_dir="srv/import",
        env={"USER_IMPORT_DIR": str(tmp_path / "srv" / "import-users")},
    )

    with TestClient(main.app) as client:
        assert client.get("/").status_code == 200


def _case_insensitive(path):
    probe = path / "CaseProbe"
    probe.mkdir()
    try:
        return (path / "caseprobe").exists()
    finally:
        probe.rmdir()


def test_a_case_alias_of_a_nested_tree_refuses_to_start(configure_app, tmp_path):
    """On a case-insensitive volume ``Music/in`` is inside ``music``."""
    if not _case_insensitive(tmp_path):
        pytest.skip("needs a case-insensitive filesystem")
    main = configure_app(music_dir="music", import_dir="Music/in")

    with pytest.raises(RuntimeError, match="must not overlap"):
        with TestClient(main.app):
            pass
