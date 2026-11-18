"""SC-16c operation receipts: canonical request hash and replay outcomes."""

import hashlib
import json
from dataclasses import dataclass
from typing import Any, Optional
from uuid import UUID

from pydantic import BaseModel, Secret, SecretBytes, SecretStr, TypeAdapter

_ANY = TypeAdapter(Any)


@dataclass(frozen=True)
class New:
    """No receipt existed; one was stored in the caller's transaction."""


@dataclass(frozen=True)
class Replay:
    """The same owner sent the same operation before; its stored result."""

    result_ref: Optional[str]


class OperationConflict(Exception):
    """The same owner reused an operation uuid for a different request.

    Routes map it through api_error(409, "operation_conflict", ..., retryable=False).
    """

    status = 409
    code = "operation_conflict"


def _canonical(value):
    if isinstance(value, (Secret, SecretStr, SecretBytes)):
        raise TypeError("secrets must not enter an operation receipt hash")
    if isinstance(value, dict):
        return {str(k): _canonical(v) for k, v in value.items()}
    if isinstance(value, (set, frozenset)):
        items = [_canonical(v) for v in value]
        return sorted(items, key=_dumps)
    if isinstance(value, (list, tuple)):
        return [_canonical(v) for v in value]
    if isinstance(value, UUID):
        return str(value)
    if value is None or isinstance(value, (bool, int, float, str)):
        return value
    return _ANY.dump_python(value, mode="json")


def _dumps(obj) -> str:
    return json.dumps(
        obj,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
        allow_nan=False,
    )


def canonical_request_json(model) -> bytes:
    """Canonical JSON bytes of a validated request model.

    Fields never set are omitted (exclude_unset); an explicitly set null is kept
    as null; an explicitly set value equal to the default is kept, so it hashes
    differently from the field being absent. Sets are sorted by element JSON,
    keys are sorted, and no insignificant whitespace is emitted.
    """
    if not isinstance(model, BaseModel):
        raise TypeError("request_model must be a pydantic BaseModel instance")
    data = model.model_dump(mode="python", exclude_unset=True)
    return _dumps(_canonical(data)).encode("utf-8")


def request_hash(model) -> str:
    return hashlib.sha256(canonical_request_json(model)).hexdigest()
