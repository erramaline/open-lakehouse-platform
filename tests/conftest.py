"""
Pytest fixtures for the Open Lakehouse Platform test suite.

Fixture scopes:
  - session: one connection shared across all tests (cheap to create)
  - function: fresh instance per test (stateful operations)

Environment variables (override via local/.env or CI secrets):
  TRINO_HOST, TRINO_PORT, TRINO_USER, TRINO_PASSWORD
  MINIO_ENDPOINT, MINIO_ACCESS_KEY, MINIO_SECRET_KEY
  OPENBAO_ADDR, OPENBAO_ROLE_ID, OPENBAO_SECRET_ID
  RANGER_ADMIN_URL, RANGER_ADMIN_USER, RANGER_ADMIN_PASSWORD
  KEYCLOAK_URL, KEYCLOAK_REALM, KEYCLOAK_CLIENT_ID
  OPENMETADATA_HOST, OPENMETADATA_JWT_TOKEN
"""

from __future__ import annotations

import os
import time
from typing import Generator

import pytest
import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _env(key: str, default: str = "") -> str:
    return os.environ.get(key, default)


def _retry_session(retries: int = 3, backoff: float = 0.5) -> requests.Session:
    session = requests.Session()
    retry = Retry(
        total=retries,
        backoff_factor=backoff,
        status_forcelist=[502, 503, 504],
    )
    adapter = HTTPAdapter(max_retries=retry)
    session.mount("http://", adapter)
    session.mount("https://", adapter)
    return session


# ---------------------------------------------------------------------------
# Trino
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def trino_connection():
    """Return a trino.dbapi Connection pointed at local Trino Gateway."""
    try:
        from trino.dbapi import connect  # type: ignore
        from trino.auth import BasicAuthentication  # type: ignore
    except ImportError:
        pytest.skip("trino-python-client not installed — pip install trino")

    host = _env("TRINO_HOST", "localhost")
    port = int(_env("TRINO_PORT", "8080"))
    user = _env("TRINO_USER", "admin")
    password = _env("TRINO_PASSWORD", "")

    auth = BasicAuthentication(user, password) if password else None

    conn = connect(
        host=host,
        port=port,
        user=user,
        auth=auth,
        http_scheme="http",
        catalog="iceberg",
        schema="raw",
    )
    yield conn
    conn.close()


@pytest.fixture
def trino_cursor(trino_connection):
    """Fresh cursor per test."""
    cur = trino_connection.cursor()
    yield cur
    cur.cancel()


# ---------------------------------------------------------------------------
# MinIO
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def minio_client():
    """Return a configured Minio Python client."""
    try:
        from minio import Minio  # type: ignore
    except ImportError:
        pytest.skip("minio Python client not installed — pip install minio")

    endpoint = _env("MINIO_ENDPOINT", "localhost:9000")
    access_key = _env("MINIO_ACCESS_KEY", "minioadmin")
    secret_key = _env("MINIO_SECRET_KEY", "minioadmin")

    # Strip http:// / https:// prefix if present
    endpoint = endpoint.replace("http://", "").replace("https://", "")

    client = Minio(endpoint, access_key=access_key, secret_key=secret_key, secure=False)
    return client


# ---------------------------------------------------------------------------
# OpenBao (hvac-compatible)
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def openbao_client():
    """Return an hvac Client authenticated via AppRole to OpenBao."""
    try:
        import hvac  # type: ignore
    except ImportError:
        pytest.skip("hvac not installed — pip install hvac")

    addr = _env("OPENBAO_ADDR", "http://localhost:8200")
    role_id = _env("OPENBAO_ROLE_ID", "")
    secret_id = _env("OPENBAO_SECRET_ID", "")
    root_token = _env("OPENBAO_TOKEN", "")

    client = hvac.Client(url=addr)

    if root_token:
        client.token = root_token
    elif role_id and secret_id:
        resp = client.auth.approle.login(role_id=role_id, secret_id=secret_id)
        client.token = resp["auth"]["client_token"]
    else:
        pytest.skip("OpenBao credentials not configured (set OPENBAO_TOKEN or OPENBAO_ROLE_ID+SECRET_ID)")

    assert client.is_authenticated(), "OpenBao authentication failed"
    return client


# ---------------------------------------------------------------------------
# Ranger
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def ranger_client() -> requests.Session:
    """HTTP session pre-configured for Ranger Admin API."""
    base_url = _env("RANGER_ADMIN_URL", "http://localhost:6080")
    user = _env("RANGER_ADMIN_USER", "admin")
    password = _env("RANGER_ADMIN_PASSWORD", "admin")

    session = _retry_session()
    session.auth = (user, password)
    session.headers.update({"Accept": "application/json", "Content-Type": "application/json"})
    session.base_url = base_url  # type: ignore[attr-defined]
    return session


# ---------------------------------------------------------------------------
# Keycloak OIDC
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def keycloak_token():
    """
    Factory fixture: keycloak_token(username, password) → access_token str.
    Uses Resource Owner Password Credentials (test-only grant type).
    """
    keycloak_url = _env("KEYCLOAK_URL", "http://localhost:9080")
    realm = _env("KEYCLOAK_REALM", "lakehouse")
    client_id = _env("KEYCLOAK_CLIENT_ID", "trino-client")
    client_secret = _env("KEYCLOAK_CLIENT_SECRET", "")

    def _fetch(username: str, password: str) -> str:
        token_url = f"{keycloak_url}/realms/{realm}/protocol/openid-connect/token"
        payload = {
            "grant_type": "password",
            "client_id": client_id,
            "username": username,
            "password": password,
        }
        if client_secret:
            payload["client_secret"] = client_secret

        resp = requests.post(token_url, data=payload, timeout=10)
        resp.raise_for_status()
        return resp.json()["access_token"]

    return _fetch


# ---------------------------------------------------------------------------
# OpenMetadata
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def openmetadata_client():
    """Return an OpenMetadata Python SDK client."""
    try:
        from metadata.ingestion.ometa.ometa_api import OpenMetadata  # type: ignore
        from metadata.generated.schema.entity.services.connections.metadata.openMetadataConnection import (  # type: ignore
            OpenMetadataConnection,
        )
        from metadata.generated.schema.security.client.openMetadataJWTClientConfig import (  # type: ignore
            OpenMetadataJWTClientConfig,
        )
    except ImportError:
        pytest.skip("openmetadata-ingestion not installed")

    host = _env("OPENMETADATA_HOST", "http://localhost:8585")
    jwt_token = _env("OPENMETADATA_JWT_TOKEN", "")

    if not jwt_token:
        pytest.skip("OPENMETADATA_JWT_TOKEN not set")

    server_config = OpenMetadataConnection(
        hostPort=host,
        authProvider="openmetadata",
        securityConfig=OpenMetadataJWTClientConfig(jwtToken=jwt_token),
    )
    client = OpenMetadata(server_config)
    return client


# ---------------------------------------------------------------------------
# Docker services health (pytest-docker)
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def docker_services_project_name():
    return "lakehouse-test"


@pytest.fixture(scope="session")
def docker_compose_file():
    return os.path.join(
        os.path.dirname(os.path.dirname(__file__)),
        "local",
        "docker-compose.yml",
    )


def _wait_for_service(url: str, timeout: int = 120, interval: int = 3) -> bool:
    """Poll URL until it returns 2xx or timeout."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            resp = requests.get(url, timeout=5)
            if resp.status_code < 500:
                return True
        except requests.RequestException:
            pass
        time.sleep(interval)
    return False


@pytest.fixture(scope="session")
def docker_services(request):
    """
    Lightweight alternative to pytest-docker: yield None if services are
    already running (CI / local dev with make dev-up), otherwise skip.
    Tests that truly need services should use this fixture.
    """
    trino_url = f"http://{_env('TRINO_HOST', 'localhost')}:{_env('TRINO_PORT', '8080')}/v1/info"
    if not _wait_for_service(trino_url, timeout=10):
        pytest.skip(
            "Docker services not running — start with `make dev-up` before integration tests"
        )
    yield None


# ---------------------------------------------------------------------------
# Sample data helpers
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def sample_pdf_path(tmp_path_factory):
    """Path to a minimal test PDF (created on-the-fly if not present)."""
    sample_dir = os.path.join(
        os.path.dirname(os.path.dirname(__file__)), "data", "sample", "documents"
    )
    os.makedirs(sample_dir, exist_ok=True)

    pdf_path = os.path.join(sample_dir, "test_document.pdf")
    if not os.path.exists(pdf_path):
        try:
            from reportlab.pdfgen import canvas  # type: ignore
            c = canvas.Canvas(pdf_path)
            c.drawString(72, 750, "Open Lakehouse Platform — Test Document")
            c.drawString(72, 720, "Customer ID: 12345, Region: EAST")
            c.drawString(72, 700, "Order Total: $1,234.56")
            c.save()
        except ImportError:
            # Create minimal valid PDF without reportlab
            with open(pdf_path, "wb") as f:
                f.write(b"%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n"
                        b"2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n"
                        b"3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]>>endobj\n"
                        b"xref\n0 4\n0000000000 65535 f\n"
                        b"trailer<</Size 4/Root 1 0 R>>\nstartxref\n%%EOF\n")
    return pdf_path
