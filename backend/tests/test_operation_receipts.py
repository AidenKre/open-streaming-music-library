"""Phase 7A.1c (SC-16c, 7-U06 hash, decision O2 / DEV-7-01): operation receipts.

The request hash is SHA-256 of the canonical JSON of the *validated* request:
keys sorted, no insignificant whitespace, sets sorted, absent fields omitted.
``Database._with_operation_in`` answers New, Replay(result_ref) or raises
``OperationConflict`` (409 ``operation_conflict``), and never sees another
owner's receipt.
"""

import hashlib
import sqlite3
from typing import Optional, Union
from uuid import UUID

import pytest
from pydantic import BaseModel, ConfigDict, Field, Secret, SecretStr

from app.database import ANY_OWNER
from app.database.database import Database
from app.database.operation_receipts import (
    New,
    OperationConflict,
    Replay,
    canonical_request_json,
    request_hash,
)
from tests.schema_fixtures import INIT_SQL

U1 = UUID("00000000-0000-4000-8000-000000000001")
U2 = UUID("00000000-0000-4000-8000-000000000002")
U3 = UUID("00000000-0000-4000-8000-000000000003")


class Acks(BaseModel):
    model_config = ConfigDict(extra="forbid")
    library_tracks: frozenset[UUID] = frozenset()
    staged_items: frozenset[UUID] = frozenset()


class Edits(BaseModel):
    model_config = ConfigDict(extra="forbid")
    title: Optional[str] = None
    track_number: Optional[int] = None


class Commit(BaseModel):
    """Shaped like the 7A.3a commit body (spec §4)."""

    model_config = ConfigDict(extra="forbid")
    operation_uuid: UUID
    base_review_version: int
    edits: Edits = Field(default_factory=Edits)
    write_tags: bool = False
    acknowledged_duplicates: Acks = Field(default_factory=Acks)
    order: list[int] = []


def _commit(raw: str) -> Commit:
    return Commit.model_validate_json(raw)


# --- the canonical form ---------------------------------------------------------------------


def test_the_canonical_json_of_a_commit_body():
    """Independent fixture: keys sorted, compact separators, the set sorted,
    explicit null kept, absent fields (write_tags, order, staged_items)
    left out."""
    body = _commit(
        '{"operation_uuid": "%s", "base_review_version": 3, '
        '"acknowledged_duplicates": {"library_tracks": ["%s", "%s"]}, '
        '"edits": {"title": null}}' % (U3, U2, U1)
    )

    assert canonical_request_json(body) == (
        '{"acknowledged_duplicates":{"library_tracks":["%s","%s"]},'
        '"base_review_version":3,"edits":{"title":null},"operation_uuid":"%s"}' % (U1, U2, U3)
    ).encode()


def test_the_hash_is_the_sha256_of_the_canonical_json():
    body = _commit('{"operation_uuid": "%s", "base_review_version": 0}' % U1)
    expected = hashlib.sha256(
        ('{"base_review_version":0,"operation_uuid":"%s"}' % U1).encode()
    ).hexdigest()
    assert request_hash(body) == expected


def test_set_order_and_duplicates_do_not_change_the_hash():
    a = _commit('{"operation_uuid": "%s", "base_review_version": 1, '
                '"acknowledged_duplicates": {"library_tracks": ["%s", "%s"], '
                '"staged_items": ["%s"]}}' % (U1, U2, U3, U1))
    b = _commit('{"operation_uuid": "%s", "base_review_version": 1, '
                '"acknowledged_duplicates": {"staged_items": ["%s"], '
                '"library_tracks": ["%s", "%s", "%s"]}}' % (U1, U1, U3, U2, U3))
    assert request_hash(a) == request_hash(b)


def test_key_order_and_whitespace_do_not_change_the_hash():
    a = _commit('{"operation_uuid":"%s","base_review_version":1,"write_tags":true}' % U1)
    b = _commit('{\n  "write_tags" : true ,\n  "base_review_version": 1,\n'
                '  "operation_uuid": "%s"\n}' % U1)
    assert request_hash(a) == request_hash(b)


def test_uuid_spelling_does_not_change_the_hash():
    """A validated UUID is canonical (lowercase, hyphenated)."""
    a = _commit('{"operation_uuid": "%s", "base_review_version": 1}' % U1)
    b = _commit('{"operation_uuid": "%s", "base_review_version": 1}' % str(U1).upper())
    assert request_hash(a) == request_hash(b)


def test_list_order_is_significant():
    a = _commit('{"operation_uuid": "%s", "base_review_version": 1, "order": [1, 2]}' % U1)
    b = _commit('{"operation_uuid": "%s", "base_review_version": 1, "order": [2, 1]}' % U1)
    assert request_hash(a) != request_hash(b)


def test_an_absent_field_an_explicit_null_and_a_value_hash_differently():
    """The staged edits model distinguishes untouched (absent) from clear
    (null), so the hash does too."""
    base = '{"operation_uuid": "%s", "base_review_version": 1, "edits": {%s}}'
    absent = _commit(base % (U1, ""))
    null = _commit(base % (U1, '"title": null'))
    value = _commit(base % (U1, '"title": "x"'))
    assert len({request_hash(absent), request_hash(null), request_hash(value)}) == 3


def test_an_explicit_default_differs_from_an_absent_field():
    absent = _commit('{"operation_uuid": "%s", "base_review_version": 1}' % U1)
    explicit = _commit('{"operation_uuid": "%s", "base_review_version": 1, '
                       '"write_tags": false}' % U1)
    assert request_hash(absent) != request_hash(explicit)


class Loose(BaseModel):
    value: Union[bool, int, str, None] = None


@pytest.mark.parametrize("a, b", [(1, "1"), (True, 1), (0, None), ("", None), (False, 0)])
def test_values_of_different_types_hash_differently(a, b):
    assert request_hash(Loose(value=a)) != request_hash(Loose(value=b))


def test_non_ascii_text_is_canonical_utf8():
    body = Loose(value="Sigur Rós")
    assert canonical_request_json(body) == '{"value":"Sigur Rós"}'.encode("utf-8")


class WithSecret(BaseModel):
    name: str
    token: SecretStr


def test_a_secret_never_enters_a_receipt_hash():
    with pytest.raises(TypeError):
        request_hash(WithSecret(name="x", token=SecretStr("hunter2")))


def test_only_a_validated_model_can_be_hashed():
    with pytest.raises(TypeError):
        request_hash({"operation_uuid": str(U1)})


# --- _with_operation_in ---------------------------------------------------------------------

SAM, ALEX = 1, 2
KIND = "upload_commit"


@pytest.fixture
def conn():
    connection = sqlite3.connect(":memory:", isolation_level=None)
    connection.executescript(INIT_SQL.read_text())
    connection.execute("PRAGMA foreign_keys=ON")
    connection.executemany(
        "INSERT INTO users (id, username, username_key, password_hash, library_folder, "
        "created_at) VALUES (?, ?, ?, 'h', ?, 0)",
        [(SAM, "Sam", "sam", "sam"), (ALEX, "Alex", "alex", "alex")],
    )
    try:
        yield connection
    finally:
        connection.close()


def _in_transaction(conn, call):
    """Run ``call`` the way a caller must: inside its own BEGIN IMMEDIATE."""
    conn.execute("BEGIN IMMEDIATE")
    try:
        result = call()
    except BaseException:
        conn.execute("ROLLBACK")
        raise
    conn.execute("COMMIT")
    return result


def _op(conn, owner, body, *, kind=KIND, operation_uuid=U1, now=100):
    return _in_transaction(conn, lambda: Database._with_operation_in(
        conn, owner_id=owner, operation_uuid=operation_uuid, kind=kind, request_model=body, now=now
    ))


def _set(conn, owner, result_ref, *, operation_uuid=U1):
    _in_transaction(conn, lambda: Database._set_operation_result_in(
        conn, owner_id=owner, operation_uuid=operation_uuid, result_ref=result_ref
    ))


BODY = _commit('{"operation_uuid": "%s", "base_review_version": 2, '
               '"acknowledged_duplicates": {"library_tracks": ["%s", "%s"]}}' % (U1, U2, U3))
SAME_BODY_OTHER_ORDER = _commit('{"acknowledged_duplicates": {"library_tracks": ["%s", "%s"]}, '
                                '"base_review_version": 2, "operation_uuid": "%s"}' % (U3, U2, U1))
OTHER_BODY = _commit('{"operation_uuid": "%s", "base_review_version": 3}' % U1)


def _rows(conn):
    return conn.execute(
        "SELECT owner_id, operation_uuid, kind, request_hash, created_at, result_ref "
        "FROM operation_receipts ORDER BY owner_id"
    ).fetchall()


def test_a_first_operation_is_new_and_stores_its_receipt(conn):
    assert _op(conn, SAM, BODY) == New()
    assert _rows(conn) == [(SAM, str(U1), KIND, request_hash(BODY), 100, None)]


def test_an_exact_replay_returns_the_stored_result(conn):
    _op(conn, SAM, BODY)
    _set(conn, SAM, "item-7")

    assert _op(conn, SAM, SAME_BODY_OTHER_ORDER, now=999) == Replay("item-7")
    assert _rows(conn) == [(SAM, str(U1), KIND, request_hash(BODY), 100, "item-7")]


def test_a_replay_before_the_result_is_recorded_has_no_result(conn):
    _op(conn, SAM, BODY)
    assert _op(conn, SAM, BODY) == Replay(None)


def test_the_same_uuid_with_a_different_body_is_an_operation_conflict(conn):
    _op(conn, SAM, BODY)
    before = _rows(conn)

    with pytest.raises(OperationConflict) as conflict:
        _op(conn, SAM, OTHER_BODY)

    assert conflict.value.status == 409
    assert conflict.value.code == "operation_conflict"
    assert _rows(conn) == before


def test_the_same_uuid_and_body_under_another_kind_is_an_operation_conflict(conn):
    _op(conn, SAM, BODY)
    with pytest.raises(OperationConflict):
        _op(conn, SAM, BODY, kind="upload_resolve_duplicate")


def test_another_users_receipt_under_the_same_uuid_is_invisible(conn):
    """Decision O2: the same operation uuid from two users gives two
    independent receipts; neither can tell the other's exists."""
    _op(conn, SAM, BODY)
    _set(conn, SAM, "sam")

    assert _op(conn, ALEX, OTHER_BODY, kind="upload_resolve_duplicate") == New()
    assert _op(conn, SAM, BODY) == Replay("sam")
    assert _op(conn, ALEX, OTHER_BODY, kind="upload_resolve_duplicate") == Replay(None)


def test_recording_a_result_never_touches_another_users_receipt(conn):
    _op(conn, SAM, BODY)
    with pytest.raises(LookupError):
        _set(conn, ALEX, "alex")
    assert _rows(conn)[0][5] is None


def test_the_receipt_is_part_of_the_callers_transaction(conn):
    """A ``_..._in`` primitive never commits: rolling the caller back leaves
    no receipt behind."""
    conn.execute("BEGIN IMMEDIATE")
    assert Database._with_operation_in(
        conn, owner_id=SAM, operation_uuid=U1, kind=KIND, request_model=BODY, now=100
    ) == New()
    conn.execute("ROLLBACK")

    assert _rows(conn) == []


@pytest.mark.parametrize("owner", [ANY_OWNER, None, "1", True])
def test_a_receipt_needs_a_real_owner(conn, owner):
    with pytest.raises(TypeError):
        _op(conn, owner, BODY)


class Tags(BaseModel):
    tags: frozenset[str]


def test_set_elements_are_listed_in_sorted_order():
    """A set's iteration order follows hashing (and PYTHONHASHSEED for
    strings), never the sort order: the canonical form must sort it, or two
    processes would hash the same request differently."""
    names = [f"name-{n:02d}" for n in range(20)]
    body = Tags(tags=frozenset(reversed(names)))
    assert canonical_request_json(body) == ('{"tags":[%s]}' % ",".join(f'"{n}"' for n in names)).encode()


# --- review 7A.1c r1 --------------------------------------------------------------------------


def test_the_primitive_refuses_to_run_outside_the_callers_write_transaction(conn):
    """Review r1 #2: check-then-insert is atomic only under the caller's
    BEGIN IMMEDIATE; without one a concurrent replay could fail as 'locked'."""
    with pytest.raises(RuntimeError):
        Database._with_operation_in(
            conn, owner_id=SAM, operation_uuid=U1, kind=KIND, request_model=BODY, now=100
        )
    with pytest.raises(RuntimeError):
        Database._set_operation_result_in(conn, owner_id=SAM, operation_uuid=U1, result_ref="x")
    assert _rows(conn) == []


UL = UUID("abcdef01-2345-4678-9abc-def012345678")


@pytest.mark.parametrize("spelling", [str(UL).upper(), str(UL), UL, UL.hex, UL.hex.upper()])
def test_any_spelling_of_the_operation_uuid_is_the_same_operation(conn, spelling):
    """Review r1 #3: the key is the canonical uuid, not the caller's string."""
    _op(conn, SAM, BODY, operation_uuid=UL)
    assert _op(conn, SAM, BODY, operation_uuid=spelling) == Replay(None)
    assert [row[1] for row in _rows(conn)] == [str(UL)]


class WithGenericSecret(BaseModel):
    pin: Secret[int]


def test_a_generic_secret_never_enters_a_receipt_hash():
    """Review r1 nit: pydantic's generic Secret[T] would hash masked."""
    with pytest.raises(TypeError):
        request_hash(WithGenericSecret(pin=1234))
