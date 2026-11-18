"""U01-B-04: an app started by ``configure_app`` never reads a ``.env`` from the
directory the tests happen to run in.

``app.config.Settings`` reads ``.env`` relative to the working directory, and a
developer checkout may hold a real ``backend/.env`` (including external
account settings that no test may ever use). The guard plants a ``.env`` in a
temporary stand-in for such a checkout, makes it the working directory, and
starts an app through the shared fixture: no value from that file may reach
the app's settings.
"""

UPLOAD_JANITOR_INTERVAL_DEFAULT_S = 3600


def test_a_dotenv_in_the_working_directory_never_reaches_a_test_app(
    configure_app, tmp_path_factory, monkeypatch
):
    checkout = tmp_path_factory.mktemp("developer-checkout")
    (checkout / ".env").write_text("UPLOAD_JANITOR_INTERVAL_S=7\n", encoding="utf-8")
    monkeypatch.chdir(checkout)

    main = configure_app()

    assert main.settings.upload_janitor_interval_s == UPLOAD_JANITOR_INTERVAL_DEFAULT_S
