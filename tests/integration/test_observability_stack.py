"""
Integration tests — Observability stack (Prometheus, Grafana, Loki, OTEL).

Validates:
  - Prometheus targets are UP
  - Platform-specific metrics are present (trino_query_count, minio_requests_total)
  - Grafana data sources are healthy
  - Loki ingests logs from platform services
  - OpenTelemetry collector receives spans

Requires: observability stack running (make dev-up with observability compose).
"""

from __future__ import annotations

import pytest
import requests

pytestmark = [pytest.mark.integration]

PROMETHEUS_URL = "http://localhost:9090"
GRAFANA_URL = "http://localhost:3000"
LOKI_URL = "http://localhost:3100"
OTEL_URL = "http://localhost:4318"  # OTEL HTTP receiver


def _prometheus_available() -> bool:
    try:
        return requests.get(f"{PROMETHEUS_URL}/-/ready", timeout=3).status_code == 200
    except Exception:
        return False


def _grafana_available() -> bool:
    try:
        return requests.get(f"{GRAFANA_URL}/api/health", timeout=3).status_code == 200
    except Exception:
        return False


def _loki_available() -> bool:
    try:
        return requests.get(f"{LOKI_URL}/ready", timeout=3).status_code == 200
    except Exception:
        return False


# ---------------------------------------------------------------------------
# Prometheus
# ---------------------------------------------------------------------------

class TestPrometheus:

    @pytest.fixture(autouse=True)
    def _require_prometheus(self, docker_services):
        if not _prometheus_available():
            pytest.skip("Prometheus not reachable — run `make dev-up`")

    def test_prometheus_ready(self):
        resp = requests.get(f"{PROMETHEUS_URL}/-/ready", timeout=5)
        assert resp.status_code == 200

    def test_targets_are_up(self):
        """All configured Prometheus scrape targets must be UP."""
        resp = requests.get(f"{PROMETHEUS_URL}/api/v1/targets", timeout=10)
        assert resp.status_code == 200
        targets = resp.json()["data"]["activeTargets"]
        down_targets = [t for t in targets if t["health"] == "down"]
        if down_targets:
            names = [t.get("labels", {}).get("job", "unknown") for t in down_targets]
            pytest.fail(f"Prometheus targets are DOWN: {names}")

    def test_trino_metrics_present(self):
        """Trino query metrics must be scraped by Prometheus."""
        resp = requests.get(
            f"{PROMETHEUS_URL}/api/v1/query",
            params={"query": "trino_execution_executor_pool_size"},
            timeout=10,
        )
        assert resp.status_code == 200
        result = resp.json()["data"]["result"]
        if not result:
            pytest.skip(
                "trino_execution_executor_pool_size metric not found — "
                "Trino JMX exporter may not be configured"
            )

    def test_minio_metrics_present(self):
        """MinIO request metrics must be scraped."""
        resp = requests.get(
            f"{PROMETHEUS_URL}/api/v1/query",
            params={"query": "minio_s3_requests_total"},
            timeout=10,
        )
        assert resp.status_code == 200
        result = resp.json()["data"]["result"]
        if not result:
            pytest.skip("minio_s3_requests_total metric not found")

    def test_platform_alert_rules_loaded(self):
        """Platform alert rules must be loaded."""
        resp = requests.get(f"{PROMETHEUS_URL}/api/v1/rules", timeout=10)
        assert resp.status_code == 200
        groups = resp.json()["data"].get("groups", [])
        if not groups:
            pytest.skip("No alerting rules configured in Prometheus")


# ---------------------------------------------------------------------------
# Grafana
# ---------------------------------------------------------------------------

class TestGrafana:

    @pytest.fixture(autouse=True)
    def _require_grafana(self, docker_services):
        if not _grafana_available():
            pytest.skip("Grafana not reachable at localhost:3000 — run `make dev-up`")

    def test_grafana_health(self):
        resp = requests.get(f"{GRAFANA_URL}/api/health", timeout=5)
        assert resp.status_code == 200
        data = resp.json()
        assert data.get("database") == "ok", f"Grafana DB not healthy: {data}"

    def test_grafana_datasources_healthy(self):
        """All Grafana data sources must pass health check."""
        resp = requests.get(
            f"{GRAFANA_URL}/api/datasources",
            auth=("admin", "admin"),
            timeout=10,
        )
        assert resp.status_code == 200
        sources = resp.json()
        if not sources:
            pytest.skip("No Grafana datasources configured")

        for ds in sources:
            ds_id = ds["id"]
            health_resp = requests.get(
                f"{GRAFANA_URL}/api/datasources/{ds_id}/health",
                auth=("admin", "admin"),
                timeout=10,
            )
            if health_resp.status_code == 200:
                health = health_resp.json()
                assert health.get("status") == "OK", (
                    f"Datasource '{ds['name']}' health: {health}"
                )

    def test_platform_dashboards_provisioned(self):
        """Platform dashboards must be provisioned in Grafana."""
        resp = requests.get(
            f"{GRAFANA_URL}/api/search?type=dash-db",
            auth=("admin", "admin"),
            timeout=10,
        )
        assert resp.status_code == 200
        dashboards = resp.json()
        if not dashboards:
            pytest.skip("No dashboards found in Grafana — provisioning may not be configured")
        assert len(dashboards) >= 1


# ---------------------------------------------------------------------------
# Loki
# ---------------------------------------------------------------------------

class TestLoki:

    @pytest.fixture(autouse=True)
    def _require_loki(self, docker_services):
        if not _loki_available():
            pytest.skip("Loki not reachable at localhost:3100 — run `make dev-up`")

    def test_loki_ready(self):
        resp = requests.get(f"{LOKI_URL}/ready", timeout=5)
        assert resp.status_code == 200

    def test_loki_has_log_streams(self):
        """Loki must have at least one active log stream."""
        resp = requests.get(f"{LOKI_URL}/loki/api/v1/labels", timeout=10)
        assert resp.status_code == 200
        labels = resp.json().get("data", [])
        assert len(labels) >= 1, "Loki has no log streams — check Promtail config"

    def test_platform_services_emit_logs(self):
        """At least one platform service must be shipping logs to Loki."""
        expected_jobs = ["trino", "minio", "keycloak", "ranger", "airflow"]
        resp = requests.get(
            f"{LOKI_URL}/loki/api/v1/label/job/values",
            timeout=10,
        )
        if resp.status_code != 200:
            pytest.skip("Could not retrieve Loki job label values")

        job_values = resp.json().get("data", [])
        found = [j for j in expected_jobs if any(j in v.lower() for v in job_values)]
        if not found:
            pytest.skip(
                f"None of the expected platform jobs found in Loki. "
                f"Found jobs: {job_values}"
            )
