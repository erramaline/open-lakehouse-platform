"""
Airflow Secrets Backend — OpenBao (HashiCorp Vault compatible)

Reads Airflow connections and variables from OpenBao KV v2 engine,
providing transparent secret injection for all Airflow components.

Configuration in airflow.cfg (or environment variables):
  [secrets]
  backend = airflow.plugins.openbao_secrets_backend.AirflowOpenBaoSecretsBackend
  backend_kwargs = {
    "vault_addr": "http://openbao:8200",
    "role_id": "airflow-role",
    "secret_id": "...",
    "connections_path": "secret/data/airflow/connections",
    "variables_path": "secret/data/airflow/variables",
    "mount_point": "secret"
  }

Equivalently via environment variables:
  OPENBAO_ADDR       — e.g. http://openbao:8200
  OPENBAO_ROLE_ID    — AppRole role_id
  OPENBAO_SECRET_ID  — AppRole secret_id
  OPENBAO_TOKEN      — Direct token (alternative to AppRole)
"""

from __future__ import annotations

import logging
import os
import time
from typing import Any

from airflow.secrets import BaseSecretsBackend  # type: ignore
from airflow.models import Connection  # type: ignore

log = logging.getLogger(__name__)

# Minimum remaining TTL (seconds) before proactively renewing the token
_TOKEN_RENEW_THRESHOLD_SECONDS = 300  # 5 minutes


class AirflowOpenBaoSecretsBackend(BaseSecretsBackend):
    """
    Airflow Secrets Backend that reads secrets from OpenBao (or HashiCorp Vault)
    KV v2 secret engine using AppRole authentication.

    Secret structure (KV v2):
      connections_path/{conn_id}  →  {"conn_uri": "postgresql://user:pass@host:5432/db"}
                                     or individual fields: conn_type, host, port, login,
                                     password, schema, extra (JSON string)
      variables_path/{key}        →  {"value": "the-variable-value"}
    """

    def __init__(
        self,
        vault_addr: str = "",
        role_id: str = "",
        secret_id: str = "",
        token: str = "",
        connections_path: str = "airflow/connections",
        variables_path: str = "airflow/variables",
        mount_point: str = "secret",
        **kwargs: Any,
    ) -> None:
        super().__init__(**kwargs)
        self.vault_addr = vault_addr or os.environ.get("OPENBAO_ADDR", "http://openbao:8200")
        self.role_id = role_id or os.environ.get("OPENBAO_ROLE_ID", "")
        self.secret_id = secret_id or os.environ.get("OPENBAO_SECRET_ID", "")
        self._static_token = token or os.environ.get("OPENBAO_TOKEN", "")
        self.connections_path = connections_path
        self.variables_path = variables_path
        self.mount_point = mount_point

        self._client: Any = None
        self._token_expire_at: float = 0.0

    # ------------------------------------------------------------------
    # Client lifecycle
    # ------------------------------------------------------------------

    def _ensure_client(self) -> None:
        """
        Ensure the hvac client is authenticated.  Proactively renews the
        token when the remaining TTL drops below _TOKEN_RENEW_THRESHOLD_SECONDS.
        """
        try:
            import hvac  # type: ignore
        except ImportError as exc:
            raise RuntimeError(
                "hvac package is required for AirflowOpenBaoSecretsBackend. "
                "Install it with: pip install hvac"
            ) from exc

        # Initial setup
        if self._client is None:
            self._client = hvac.Client(url=self.vault_addr)

        # Static token path (no renewal needed for root/service tokens)
        if self._static_token:
            if not self._client.is_authenticated():
                self._client.token = self._static_token
            return

        # AppRole path — check TTL and renew if necessary
        now = time.time()
        if now >= self._token_expire_at - _TOKEN_RENEW_THRESHOLD_SECONDS:
            self._login_approle()

    def _login_approle(self) -> None:
        """Perform AppRole login and cache the expiry time."""
        if not self.role_id or not self.secret_id:
            raise RuntimeError(
                "OpenBao AppRole credentials are not configured.  "
                "Set OPENBAO_ROLE_ID and OPENBAO_SECRET_ID (or OPENBAO_TOKEN)."
            )

        try:
            resp = self._client.auth.approle.login(
                role_id=self.role_id,
                secret_id=self.secret_id,
            )
        except Exception as exc:
            raise RuntimeError(f"OpenBao AppRole login failed: {exc}") from exc

        lease_duration = resp["auth"].get("lease_duration", 3600)
        self._token_expire_at = time.time() + lease_duration
        log.info(
            "OpenBao AppRole login succeeded — token valid for %ds", lease_duration
        )

    # ------------------------------------------------------------------
    # KV v2 helper
    # ------------------------------------------------------------------

    def _read_secret(self, path: str) -> dict[str, Any] | None:
        """
        Read a KV v2 secret and return the `data` payload, or None if
        the secret does not exist or is inaccessible.
        """
        self._ensure_client()
        try:
            resp = self._client.secrets.kv.v2.read_secret_version(
                path=path,
                mount_point=self.mount_point,
                raise_on_deleted_version=False,
            )
            return resp["data"]["data"]  # KV v2 nesting: data → data → payload
        except Exception as exc:
            # 403 / 404 are expected when the secret doesn't exist
            log.debug("OpenBao read '%s/%s' returned: %s", self.mount_point, path, exc)
            return None

    # ------------------------------------------------------------------
    # BaseSecretsBackend interface
    # ------------------------------------------------------------------

    def get_connection(self, conn_id: str) -> Connection | None:  # type: ignore[override]
        """
        Retrieve an Airflow Connection from OpenBao.

        Supports two storage formats:
          1. URI format:   {"conn_uri": "postgresql://user:pass@host:5432/db"}
          2. Field format: {"conn_type": "postgres", "host": "...", "port": "5432",
                            "login": "user", "password": "pass", "schema": "db",
                            "extra": "{\"sslmode\": \"require\"}"}
        """
        secret_path = f"{self.connections_path}/{conn_id}"
        data = self._read_secret(secret_path)
        if data is None:
            log.debug("Connection '%s' not found in OpenBao", conn_id)
            return None

        log.info("Loaded connection '%s' from OpenBao", conn_id)

        if "conn_uri" in data:
            return Connection(conn_id=conn_id, uri=data["conn_uri"])

        # Map fields directly to Connection constructor
        return Connection(
            conn_id=conn_id,
            conn_type=data.get("conn_type", "generic"),
            host=data.get("host", ""),
            port=int(data["port"]) if data.get("port") else None,
            login=data.get("login", ""),
            password=data.get("password", ""),
            schema=data.get("schema", ""),
            extra=data.get("extra", ""),
        )

    def get_variable(self, key: str) -> str | None:
        """
        Retrieve an Airflow Variable from OpenBao.

        Expects the secret to have a ``value`` field:
          {"value": "the-variable-value"}
        """
        secret_path = f"{self.variables_path}/{key}"
        data = self._read_secret(secret_path)
        if data is None:
            log.debug("Variable '%s' not found in OpenBao", key)
            return None

        value = data.get("value")
        if value is None:
            log.warning(
                "Variable '%s' found in OpenBao but has no 'value' field.  "
                "Keys present: %s",
                key, list(data.keys()),
            )
            return None

        log.info("Loaded variable '%s' from OpenBao", key)
        return str(value)

    def get_config(self, key: str) -> str | None:
        """
        Retrieve an Airflow config value from OpenBao (optional).

        Convention: secret/data/airflow/config/{key} → {"value": "..."}
        """
        config_path = f"airflow/config/{key}"
        data = self._read_secret(config_path)
        if data is None:
            return None
        return str(data.get("value", "")) or None
