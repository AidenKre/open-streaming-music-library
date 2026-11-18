"""U02-A-02, SP-TS-16: the test adapter fills in an owner only for methods the
server itself treats as owned. A subset check, not equality: the server owns
more methods than the old direct-database tests call without an owner."""

from app.library import OWNED_METHODS
from tests.owned_database import OWNER_METHODS


def test_every_method_the_adapter_fills_an_owner_for_is_an_owned_method():
    assert set(OWNER_METHODS) - OWNED_METHODS == set()
