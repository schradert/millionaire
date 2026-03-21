from __future__ import annotations

import base64
import json
import secrets
from typing import Any

import pulumi
from pulumi.dynamic import (
    CreateResult,
    DiffResult,
    ReadResult,
    Resource,
    ResourceProvider,
)

from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives import serialization


def _int_to_base64url(n: int) -> str:
    """Convert an integer to a Base64url-encoded string (no padding)."""
    length = (n.bit_length() + 7) // 8
    return base64.urlsafe_b64encode(n.to_bytes(length, "big")).rstrip(b"=").decode()


def _generate_jwks() -> str:
    """Generate an RSA-2048 key pair formatted as a JWKS."""
    private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    public_numbers = private_key.public_key().public_numbers()
    private_numbers = private_key.private_numbers()
    kid = secrets.token_hex(8)
    jwk = {
        "kty": "RSA",
        "kid": kid,
        "use": "sig",
        "alg": "RS256",
        "n": _int_to_base64url(public_numbers.n),
        "e": _int_to_base64url(public_numbers.e),
        "d": _int_to_base64url(private_numbers.d),
        "p": _int_to_base64url(private_numbers.p),
        "q": _int_to_base64url(private_numbers.q),
        "dp": _int_to_base64url(private_numbers.dmp1),
        "dq": _int_to_base64url(private_numbers.dmq1),
        "qi": _int_to_base64url(private_numbers.iqmp),
    }
    return json.dumps({"keys": [jwk]})


# ---------------------------------------------------------------------------
# Oathkeeper JWKS Provider
# ---------------------------------------------------------------------------


class _OryJwksProvider(ResourceProvider):
    def create(self, props: dict[str, Any]) -> CreateResult:
        jwks_json = _generate_jwks()
        kid = json.loads(jwks_json)["keys"][0]["kid"]
        return CreateResult(id_=kid, outs={"jwks_json": jwks_json})

    def read(self, id_: str, props: dict[str, Any]) -> ReadResult:
        return ReadResult(id_=id_, outs=props)

    def diff(self, _id: str, _old: dict[str, Any], _new: dict[str, Any]) -> DiffResult:
        # Never replace — JWKS is stable once created.
        return DiffResult(changes=False)

    def delete(self, _id: str, _props: dict[str, Any]) -> None:
        pass  # Nothing to clean up — key material lives only in Pulumi state.


class OryJwks(Resource):
    """Generate an RSA JWKS for Oathkeeper ID token signing."""

    jwks_json: pulumi.Output[str]

    def __init__(self, name: str, opts: pulumi.ResourceOptions | None = None):
        super().__init__(_OryJwksProvider(), name, {"jwks_json": None}, opts)


