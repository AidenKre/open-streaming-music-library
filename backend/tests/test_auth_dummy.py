"""Phase M.1a review r1 #1 (spec §5.2 "timing doesn't tell them apart"): the
dummy hash an unknown-user login verifies against is built at startup, so the
first unknown-user login after a restart costs the same as any other.
"""

from argon2 import PasswordHasher

from app.auth import passwords


def test_the_dummy_hash_is_ready_before_the_first_unknown_login(open_app_client, monkeypatch):
    passwords._dummy_hash.cache_clear()  # as after a restart
    with open_app_client() as client:
        hashes = []
        real_hash = PasswordHasher.hash

        def counting_hash(hasher, *args, **kwargs):
            hashes.append(args)
            return real_hash(hasher, *args, **kwargs)

        monkeypatch.setattr(PasswordHasher, "hash", counting_hash)

        response = client.post("/auth/login", json={"username": "nobody", "password": "a long enough password"})
        assert response.status_code == 401

        assert hashes == []  # no extra hash makes this login slower
