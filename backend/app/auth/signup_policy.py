"""Signup valves (spec §5.2).

One function, ``check(conn, settings)``, called inside the BEGIN IMMEDIATE
register transaction. OSML_MAX_USERS counts every row in ``users``: the admin,
disabled and deleting users included.

Removing the valves = delete this module, its call, the two settings
(OSML_SIGNUP_ENABLED, OSML_MAX_USERS) and its tests.
"""


class SignupDisabled(Exception):
    """Signup is switched off."""


class UserLimitReached(Exception):
    """The user limit is reached."""


def check(conn, settings) -> None:
    if not settings.osml_signup_enabled:
        raise SignupDisabled("signup is disabled")
    count = conn.execute("SELECT count(*) FROM users").fetchone()[0]
    if count >= settings.osml_max_users:
        raise UserLimitReached("the user limit has been reached")
