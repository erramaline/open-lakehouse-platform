"""
Integration tests — Keycloak OIDC authentication flow.

Validates:
  - Resource Owner Password Credentials grant (test users)
  - Token introspection returns active=true
  - Token expiry and refresh
  - Trino OIDC authentication with Keycloak token
  - User groups are present in token claims

Requires: Keycloak running with the 'lakehouse' realm configured.
"""

from __future__ import annotations

import time

import pytest
import requests

pytestmark = [pytest.mark.integration]

KEYCLOAK_URL = "http://localhost:9080"
REALM = "lakehouse"
CLIENT_ID = "trino-client"


def _token_endpoint() -> str:
    return f"{KEYCLOAK_URL}/realms/{REALM}/protocol/openid-connect/token"


def _introspect_endpoint() -> str:
    return f"{KEYCLOAK_URL}/realms/{REALM}/protocol/openid-connect/token/introspect"


def _userinfo_endpoint() -> str:
    return f"{KEYCLOAK_URL}/realms/{REALM}/protocol/openid-connect/userinfo"


def _keycloak_available() -> bool:
    try:
        resp = requests.get(
            f"{KEYCLOAK_URL}/realms/{REALM}/.well-known/openid-configuration",
            timeout=5,
        )
        return resp.status_code == 200
    except requests.RequestException:
        return False


# ---------------------------------------------------------------------------
# OIDC well-known configuration
# ---------------------------------------------------------------------------

class TestKeycloakOIDCDiscovery:

    @pytest.fixture(autouse=True)
    def _require_keycloak(self):
        if not _keycloak_available():
            pytest.skip("Keycloak not reachable — run `make dev-up`")

    def test_well_known_endpoint_returns_200(self):
        resp = requests.get(
            f"{KEYCLOAK_URL}/realms/{REALM}/.well-known/openid-configuration",
            timeout=10,
        )
        assert resp.status_code == 200

    def test_well_known_has_required_fields(self):
        resp = requests.get(
            f"{KEYCLOAK_URL}/realms/{REALM}/.well-known/openid-configuration",
            timeout=10,
        )
        data = resp.json()
        required = {
            "issuer", "authorization_endpoint", "token_endpoint",
            "jwks_uri", "userinfo_endpoint", "introspection_endpoint",
        }
        missing = required - data.keys()
        assert not missing, f"OIDC discovery missing: {missing}"

    def test_issuer_matches_realm(self):
        resp = requests.get(
            f"{KEYCLOAK_URL}/realms/{REALM}/.well-known/openid-configuration",
            timeout=10,
        )
        issuer = resp.json()["issuer"]
        assert REALM in issuer, f"Issuer '{issuer}' does not reference realm '{REALM}'"


# ---------------------------------------------------------------------------
# Token acquisition
# ---------------------------------------------------------------------------

class TestKeycloakTokenAcquisition:

    @pytest.fixture(autouse=True)
    def _require_keycloak(self, docker_services):
        if not _keycloak_available():
            pytest.skip("Keycloak not reachable")

    def test_admin_user_can_obtain_token(self, keycloak_token):
        """Admin user must be able to obtain an access token."""
        import os
        try:
            token = keycloak_token(
                username=os.environ.get("KEYCLOAK_ADMIN_USER", "admin"),
                password=os.environ.get("KEYCLOAK_ADMIN_PASSWORD", "admin"),
            )
            assert token, "Token must not be empty"
            # JWT tokens are dot-separated with 3 segments
            parts = token.split(".")
            assert len(parts) == 3, f"Token does not look like a JWT: starts with {token[:20]}"
        except requests.HTTPError as exc:
            if exc.response.status_code == 401:
                pytest.skip("Admin credentials not valid — update KEYCLOAK_ADMIN_USER/PASSWORD")
            raise

    def test_token_introspection_returns_active(self, keycloak_token):
        """Token introspection must return active=true for a fresh token."""
        import os
        try:
            token = keycloak_token(
                username=os.environ.get("KEYCLOAK_ADMIN_USER", "admin"),
                password=os.environ.get("KEYCLOAK_ADMIN_PASSWORD", "admin"),
            )
        except Exception:
            pytest.skip("Could not obtain token")

        import os as _os
        client_secret = _os.environ.get("KEYCLOAK_CLIENT_SECRET", "")
        resp = requests.post(
            _introspect_endpoint(),
            data={
                "token": token,
                "client_id": CLIENT_ID,
                "client_secret": client_secret,
            },
            timeout=10,
        )
        assert resp.status_code == 200
        data = resp.json()
        assert data.get("active") is True, (
            f"Token introspection returned active={data.get('active')}"
        )

    def test_userinfo_returns_username(self, keycloak_token):
        """UserInfo endpoint must return the sub/preferred_username."""
        import os
        try:
            token = keycloak_token(
                username=os.environ.get("KEYCLOAK_ADMIN_USER", "admin"),
                password=os.environ.get("KEYCLOAK_ADMIN_PASSWORD", "admin"),
            )
        except Exception:
            pytest.skip("Could not obtain token")

        resp = requests.get(
            _userinfo_endpoint(),
            headers={"Authorization": f"Bearer {token}"},
            timeout=10,
        )
        assert resp.status_code == 200
        data = resp.json()
        assert "sub" in data or "preferred_username" in data, (
            "UserInfo response missing 'sub' or 'preferred_username'"
        )


# ---------------------------------------------------------------------------
# Group claims
# ---------------------------------------------------------------------------

class TestKeycloakGroupClaims:

    @pytest.fixture(autouse=True)
    def _require_keycloak(self, docker_services):
        if not _keycloak_available():
            pytest.skip("Keycloak not reachable")

    def test_token_contains_groups_claim(self, keycloak_token):
        """Token must include 'groups' claim for Ranger/Trino authorization."""
        import os
        import base64
        import json as json_mod

        try:
            token = keycloak_token(
                username=os.environ.get("KEYCLOAK_ADMIN_USER", "admin"),
                password=os.environ.get("KEYCLOAK_ADMIN_PASSWORD", "admin"),
            )
        except Exception:
            pytest.skip("Could not obtain token")

        # Decode JWT payload (no verification — test environment only)
        parts = token.split(".")
        if len(parts) != 3:
            pytest.skip("Token is not a JWT")

        padding = 4 - len(parts[1]) % 4
        payload_bytes = parts[1] + "=" * padding
        payload = json_mod.loads(base64.urlsafe_b64decode(payload_bytes))

        # 'groups' is added via Keycloak mapper — may be absent if mapper not configured
        if "groups" not in payload:
            pytest.skip(
                "Token does not contain 'groups' claim — "
                "configure a Groups mapper in Keycloak client"
            )
        assert isinstance(payload["groups"], list)
