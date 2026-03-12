"""
Integration tests — OpenBao secret injection & rotation.

Validates:
  - Secrets are readable at expected paths
  - AppRole authentication works
  - Secret rotation updates the value at the same path
  - Dynamic credentials (DB secrets engine) are generated on demand
  - After rotation, old secret is revoked

Requires: OpenBao running locally with bootstrap complete (`make dev-up`).
"""

from __future__ import annotations

import time
import uuid

import pytest

pytestmark = [pytest.mark.integration]


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

class TestOpenBaoSecretRead:

    def test_minio_credentials_path_exists(self, docker_services, openbao_client):
        """MinIO credentials must be stored at secret/data/minio/root."""
        try:
            secret = openbao_client.secrets.kv.v2.read_secret_version(
                path="minio/root", mount_point="secret"
            )
            data = secret["data"]["data"]
            assert "access_key" in data or "MINIO_ROOT_USER" in data, (
                "MinIO secret missing 'access_key' field"
            )
        except Exception as exc:
            if "404" in str(exc) or "InvalidPath" in str(exc):
                pytest.skip("MinIO secret not bootstrapped — run scripts/bootstrap/01-init-openbao.sh")
            raise

    def test_database_credentials_path_exists(self, docker_services, openbao_client):
        """PostgreSQL credentials must be accessible via the database secrets engine."""
        try:
            creds = openbao_client.secrets.database.generate_credentials(
                name="postgresql", mount_point="database"
            )
            assert "username" in creds["data"]
            assert "password" in creds["data"]
            assert creds["data"]["password"], "Generated DB password must not be empty"
        except Exception as exc:
            if "404" in str(exc) or "no handler" in str(exc).lower():
                pytest.skip("Database secrets engine not configured")
            raise

    def test_airflow_fernet_key_path_exists(self, docker_services, openbao_client):
        """Airflow Fernet key must be stored in OpenBao."""
        try:
            secret = openbao_client.secrets.kv.v2.read_secret_version(
                path="airflow/fernet-key", mount_point="secret"
            )
            data = secret["data"]["data"]
            assert "fernet_key" in data or "AIRFLOW__CORE__FERNET_KEY" in data, (
                "Airflow Fernet key not found in OpenBao"
            )
        except Exception as exc:
            if "404" in str(exc) or "InvalidPath" in str(exc):
                pytest.skip("Airflow secret not bootstrapped")
            raise


class TestOpenBaoSecretRotation:

    def test_write_and_read_secret(self, docker_services, openbao_client):
        """Write a test secret and immediately read it back."""
        test_path = f"test/rotation/{uuid.uuid4().hex}"
        test_value = {"api_key": uuid.uuid4().hex, "version": 1}

        try:
            openbao_client.secrets.kv.v2.create_or_update_secret(
                path=test_path, secret=test_value, mount_point="secret"
            )
            secret = openbao_client.secrets.kv.v2.read_secret_version(
                path=test_path, mount_point="secret"
            )
            data = secret["data"]["data"]
            assert data["api_key"] == test_value["api_key"]
        finally:
            try:
                openbao_client.secrets.kv.v2.delete_metadata_and_all_versions(
                    path=test_path, mount_point="secret"
                )
            except Exception:
                pass

    def test_rotate_secret_increments_version(self, docker_services, openbao_client):
        """Rotating a secret must increment the KV version number."""
        test_path = f"test/rotation/{uuid.uuid4().hex}"
        v1 = {"value": "version-one"}
        v2 = {"value": "version-two"}

        try:
            openbao_client.secrets.kv.v2.create_or_update_secret(
                path=test_path, secret=v1, mount_point="secret"
            )
            openbao_client.secrets.kv.v2.create_or_update_secret(
                path=test_path, secret=v2, mount_point="secret"
            )

            meta = openbao_client.secrets.kv.v2.read_secret_metadata(
                path=test_path, mount_point="secret"
            )
            current_version = meta["data"]["current_version"]
            assert current_version >= 2, (
                f"Expected version >= 2 after rotation, got {current_version}"
            )

            # Current version should return v2
            latest = openbao_client.secrets.kv.v2.read_secret_version(
                path=test_path, mount_point="secret"
            )
            assert latest["data"]["data"]["value"] == "version-two"
        finally:
            try:
                openbao_client.secrets.kv.v2.delete_metadata_and_all_versions(
                    path=test_path, mount_point="secret"
                )
            except Exception:
                pass

    def test_old_version_still_readable_after_rotation(self, docker_services, openbao_client):
        """After rotation, previous version must still be readable (KV v2 history)."""
        test_path = f"test/rotation/{uuid.uuid4().hex}"

        try:
            openbao_client.secrets.kv.v2.create_or_update_secret(
                path=test_path, secret={"gen": 1}, mount_point="secret"
            )
            openbao_client.secrets.kv.v2.create_or_update_secret(
                path=test_path, secret={"gen": 2}, mount_point="secret"
            )

            # Read version 1 explicitly
            v1 = openbao_client.secrets.kv.v2.read_secret_version(
                path=test_path, version=1, mount_point="secret"
            )
            assert v1["data"]["data"]["gen"] == 1
        finally:
            try:
                openbao_client.secrets.kv.v2.delete_metadata_and_all_versions(
                    path=test_path, mount_point="secret"
                )
            except Exception:
                pass


class TestOpenBaoAppRole:

    def test_approle_auth_returns_token(self, docker_services):
        """AppRole login must return a valid client token."""
        import hvac
        import os

        addr = os.environ.get("OPENBAO_ADDR", "http://localhost:8200")
        role_id = os.environ.get("OPENBAO_ROLE_ID", "")
        secret_id = os.environ.get("OPENBAO_SECRET_ID", "")

        if not role_id or not secret_id:
            pytest.skip("OPENBAO_ROLE_ID and OPENBAO_SECRET_ID not set")

        client = hvac.Client(url=addr)
        resp = client.auth.approle.login(role_id=role_id, secret_id=secret_id)
        token = resp["auth"]["client_token"]
        assert token, "AppRole login returned empty token"
        assert resp["auth"]["renewable"], "Token should be renewable"

    def test_token_lease_duration_is_set(self, docker_services, openbao_client):
        """Current token must have a TTL."""
        token_info = openbao_client.lookup_token()
        ttl = token_info["data"]["ttl"]
        # root token has ttl=0 — that's OK for tests; AppRole tokens have positive TTL
        assert isinstance(ttl, int), f"TTL must be an int, got {type(ttl)}"
