"""Phase M.2a (M-U16, spec §6.3 "At signup"): registering creates the user's
import folder, or adopts a pre-staged one (§4.5), and scans it."""

from tests.test_import_startup import (
    WATCH,
    _drain_imports,
    _titles,
    _tone,
    requires_ffmpeg,
)


import pytest

pytestmark = pytest.mark.usefixtures("fast_stability_poll")

PASSWORD = "correct horse battery"


def _register(client, username):
    response = client.post(
        "/auth/register", json={"username": username, "password": PASSWORD}
    )
    assert response.status_code == 201, response.text
    return response.json()["user"]["id"]


def test_signup_creates_the_users_import_folder(app_client, tmp_path):
    _register(app_client, "alex")

    assert (tmp_path / "import-users" / "alex").is_dir()


@requires_ffmpeg
def test_signup_adopts_a_prestaged_folder_and_imports_it(open_app_client, tmp_path):
    from app.library import Library

    _tone(tmp_path / "import-users" / "Sam" / "Airbag.mp3", "Airbag")
    with open_app_client(env=WATCH) as client:
        _drain_imports(client)  # the startup scan: Sam/ belongs to nobody yet
        assert client.app.state.admin_library.get_tracks() == []

        sam_id = _register(client, "Sam")
        _drain_imports(client)

        assert _titles(Library(client.app.state.database, sam_id)) == ["Airbag"]
    # Adopted, not duplicated: no second "sam" folder beside "Sam".
    assert [p.name for p in (tmp_path / "import-users").iterdir() if p.name.lower() == "sam"] == ["Sam"]
