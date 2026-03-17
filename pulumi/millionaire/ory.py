from __future__ import annotations

import base64
import hashlib
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
    UpdateResult,
)

import requests
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


# ---------------------------------------------------------------------------
# Hydra OAuth2 Client Provider
# ---------------------------------------------------------------------------


class _HydraOAuth2ClientProvider(ResourceProvider):
    def _api(self, admin_url: str, method: str, path: str, **kwargs: Any) -> requests.Response:
        resp = requests.request(method, f"{admin_url}{path}", timeout=30, **kwargs)
        resp.raise_for_status()
        return resp

    def create(self, props: dict[str, Any]) -> CreateResult:
        admin_url = props["admin_url"]
        if not admin_url:
            # Hydra not reachable yet — return placeholders.
            placeholder_id = f"deferred-{secrets.token_hex(8)}"
            return CreateResult(
                id_=placeholder_id,
                outs={**props, "client_id": placeholder_id, "client_secret": ""},
            )
        body = {
            "client_name": props["client_name"],
            "grant_types": props["grant_types"],
            "redirect_uris": props["redirect_uris"],
            "response_types": props["response_types"],
            "scope": props["scope"],
            "token_endpoint_auth_method": props["token_endpoint_auth_method"],
        }
        result = self._api(admin_url, "POST", "/admin/clients", json=body).json()
        return CreateResult(
            id_=result["client_id"],
            outs={
                **props,
                "client_id": result["client_id"],
                "client_secret": result["client_secret"],
            },
        )

    def read(self, id_: str, props: dict[str, Any]) -> ReadResult:
        admin_url = props.get("admin_url", "")
        if not admin_url or id_.startswith("deferred-"):
            return ReadResult(id_=id_, outs=props)
        try:
            result = self._api(admin_url, "GET", f"/admin/clients/{id_}").json()
            return ReadResult(
                id_=id_,
                outs={
                    **props,
                    "client_id": result["client_id"],
                    # Hydra does not return client_secret on read; keep existing.
                    "client_secret": props.get("client_secret", ""),
                },
            )
        except requests.RequestException:
            return ReadResult(id_=id_, outs=props)

    def diff(self, _id: str, old: dict[str, Any], new: dict[str, Any]) -> DiffResult:
        compare_keys = ["client_name", "grant_types", "redirect_uris", "response_types", "scope", "token_endpoint_auth_method"]
        changes = any(old.get(k) != new.get(k) for k in compare_keys)
        # If admin_url changed from empty to set, we need to replace (deferred → real).
        if _id.startswith("deferred-") and new.get("admin_url"):
            return DiffResult(changes=True, replaces=["admin_url"])
        return DiffResult(changes=changes)

    def update(self, id_: str, _old: dict[str, Any], new: dict[str, Any]) -> UpdateResult:
        admin_url = new["admin_url"]
        if not admin_url:
            return UpdateResult(outs={**new, "client_id": id_, "client_secret": _old.get("client_secret", "")})
        body = {
            "client_name": new["client_name"],
            "grant_types": new["grant_types"],
            "redirect_uris": new["redirect_uris"],
            "response_types": new["response_types"],
            "scope": new["scope"],
            "token_endpoint_auth_method": new["token_endpoint_auth_method"],
        }
        result = self._api(admin_url, "PUT", f"/admin/clients/{id_}", json=body).json()
        return UpdateResult(outs={
            **new,
            "client_id": result["client_id"],
            # PUT does not return secret; keep old one.
            "client_secret": _old.get("client_secret", ""),
        })

    def delete(self, id_: str, props: dict[str, Any]) -> None:
        admin_url = props.get("admin_url", "")
        if not admin_url or id_.startswith("deferred-"):
            return
        try:
            self._api(admin_url, "DELETE", f"/admin/clients/{id_}")
        except requests.RequestException:
            pass  # Best-effort cleanup.


class HydraOAuth2Client(Resource):
    """Manage an OAuth2 client in Ory Hydra."""

    client_id: pulumi.Output[str]
    client_secret: pulumi.Output[str]

    def __init__(
        self,
        name: str,
        *,
        admin_url: pulumi.Input[str],
        client_name: pulumi.Input[str],
        grant_types: pulumi.Input[list[str]],
        redirect_uris: pulumi.Input[list[str]],
        response_types: pulumi.Input[list[str]],
        scope: pulumi.Input[str],
        token_endpoint_auth_method: pulumi.Input[str] = "client_secret_post",
        opts: pulumi.ResourceOptions | None = None,
    ):
        super().__init__(
            _HydraOAuth2ClientProvider(),
            name,
            {
                "admin_url": admin_url,
                "client_name": client_name,
                "grant_types": grant_types,
                "redirect_uris": redirect_uris,
                "response_types": response_types,
                "scope": scope,
                "token_endpoint_auth_method": token_endpoint_auth_method,
                "client_id": None,
                "client_secret": None,
            },
            opts,
        )
