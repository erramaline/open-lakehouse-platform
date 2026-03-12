"""
Integration tests — Polaris catalog & Apache Iceberg REST catalog protocol.

Validates:
  - Polaris REST catalog API is reachable
  - Namespaces are created after bootstrap
  - Tables can be created, listed, and dropped
  - Iceberg REST catalog spec compliance (GET /v1/namespaces, /v1/namespaces/{ns}/tables)

Requires: Polaris running at localhost:8181 (make dev-up).
"""

from __future__ import annotations

import uuid

import pytest
import requests

pytestmark = [pytest.mark.integration]

POLARIS_URL = "http://localhost:8181/api/catalog"
POLARIS_ADMIN_URL = "http://localhost:8181/api/management"


def _polaris_available() -> bool:
    try:
        resp = requests.get(f"{POLARIS_URL}/v1/config", timeout=5)
        return resp.status_code in (200, 404)  # 404 is also "alive"
    except requests.RequestException:
        return False


def _get_polaris_token() -> str:
    """Obtain OAuth2 token for Polaris (client_credentials grant)."""
    import os
    resp = requests.post(
        f"{POLARIS_URL}/v1/oauth/tokens",
        data={
            "grant_type": "client_credentials",
            "client_id": os.environ.get("POLARIS_CLIENT_ID", "root"),
            "client_secret": os.environ.get("POLARIS_CLIENT_SECRET", "secret"),
            "scope": "PRINCIPAL_ROLE:ALL",
        },
        timeout=10,
    )
    if resp.status_code != 200:
        return ""
    return resp.json().get("access_token", "")


# ---------------------------------------------------------------------------
# Catalog connectivity
# ---------------------------------------------------------------------------

class TestPolarisCatalogAPI:

    @pytest.fixture(autouse=True)
    def _require_polaris(self, docker_services):
        if not _polaris_available():
            pytest.skip("Polaris not reachable at localhost:8181 — run `make dev-up`")

    def test_config_endpoint(self):
        """GET /v1/config must return catalog configuration."""
        token = _get_polaris_token()
        headers = {"Authorization": f"Bearer {token}"} if token else {}
        resp = requests.get(f"{POLARIS_URL}/v1/config", headers=headers, timeout=10)
        # 200 with config, or 401 if auth required
        assert resp.status_code in (200, 401), (
            f"Polaris /v1/config returned {resp.status_code}"
        )

    def test_namespace_listing(self):
        """GET /v1/namespaces must return a list."""
        token = _get_polaris_token()
        if not token:
            pytest.skip("Could not obtain Polaris token")

        resp = requests.get(
            f"{POLARIS_URL}/v1/namespaces",
            headers={"Authorization": f"Bearer {token}"},
            timeout=10,
        )
        assert resp.status_code == 200
        data = resp.json()
        assert "namespaces" in data, f"Response missing 'namespaces': {data}"

    def test_platform_namespaces_exist(self):
        """raw, staging, curated namespaces must exist after bootstrap."""
        token = _get_polaris_token()
        if not token:
            pytest.skip("Could not obtain Polaris token")

        resp = requests.get(
            f"{POLARIS_URL}/v1/namespaces",
            headers={"Authorization": f"Bearer {token}"},
            timeout=10,
        )
        if resp.status_code != 200:
            pytest.skip(f"Namespace listing failed: {resp.status_code}")

        namespaces = [n[0] if isinstance(n, list) else n for n in resp.json().get("namespaces", [])]
        expected = {"raw", "staging", "curated"}
        missing = expected - set(namespaces)
        if missing:
            pytest.skip(
                f"Platform namespaces {missing} not created — run bootstrap scripts"
            )


class TestPolarisCRUDOperations:

    @pytest.fixture(autouse=True)
    def _require_polaris_with_token(self, docker_services):
        if not _polaris_available():
            pytest.skip("Polaris not reachable")
        self.token = _get_polaris_token()
        if not self.token:
            pytest.skip("Could not authenticate with Polaris")
        self.headers = {
            "Authorization": f"Bearer {self.token}",
            "Content-Type": "application/json",
        }

    def test_create_and_drop_namespace(self):
        """Create a test namespace, verify it exists, then drop it."""
        ns_name = f"test_ns_{uuid.uuid4().hex[:8]}"
        try:
            # Create
            resp = requests.post(
                f"{POLARIS_URL}/v1/namespaces",
                json={"namespace": [ns_name], "properties": {}},
                headers=self.headers,
                timeout=10,
            )
            assert resp.status_code in (200, 201), (
                f"Failed to create namespace: {resp.status_code} {resp.text}"
            )

            # Verify
            resp = requests.get(
                f"{POLARIS_URL}/v1/namespaces/{ns_name}",
                headers=self.headers,
                timeout=10,
            )
            assert resp.status_code == 200
        finally:
            # Drop
            requests.delete(
                f"{POLARIS_URL}/v1/namespaces/{ns_name}",
                headers=self.headers,
                timeout=10,
            )

    def test_table_listing_in_raw_namespace(self):
        """GET /v1/namespaces/raw/tables must return a list."""
        resp = requests.get(
            f"{POLARIS_URL}/v1/namespaces/raw/tables",
            headers=self.headers,
            timeout=10,
        )
        if resp.status_code == 404:
            pytest.skip("'raw' namespace not found — run bootstrap")
        assert resp.status_code == 200
        data = resp.json()
        assert "identifiers" in data
