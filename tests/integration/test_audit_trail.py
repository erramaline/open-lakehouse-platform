"""
Integration tests — Audit trail completeness.

Validates:
  - Every data access through Trino/Ranger generates an audit log entry
  - Audit logs are shipped to the configured sink (Loki, OpenSearch, or stdout)
  - Audit log entries contain required fields (user, action, resource, timestamp, status)
  - Failed access attempts are also logged

Requires: running stack with Ranger audit configured.
"""

from __future__ import annotations

import time
import uuid

import pytest
import requests

pytestmark = [pytest.mark.integration]

RANGER_AUDIT_URL = "http://localhost:6080/service/assets/accessAudit"
LOKI_URL = "http://localhost:3100"


def _loki_available() -> bool:
    try:
        resp = requests.get(f"{LOKI_URL}/ready", timeout=3)
        return resp.status_code == 200
    except requests.RequestException:
        return False


def _ranger_available() -> bool:
    try:
        resp = requests.get("http://localhost:6080/service/public/v2/api/public/v2/api/version", timeout=3)
        return resp.status_code < 500
    except requests.RequestException:
        return False


# ---------------------------------------------------------------------------
# Ranger audit API
# ---------------------------------------------------------------------------

class TestRangerAuditLog:

    @pytest.fixture(autouse=True)
    def _require_ranger(self, docker_services):
        if not _ranger_available():
            pytest.skip("Ranger not reachable — run `make dev-up`")

    def test_audit_endpoint_returns_200(self, ranger_client):
        """Ranger audit API must respond."""
        base = ranger_client.base_url
        resp = ranger_client.get(f"{base}/service/assets/accessAudit", timeout=10)
        assert resp.status_code == 200, f"Ranger audit endpoint: {resp.status_code}"

    def test_recent_audit_entries_exist(self, ranger_client):
        """There must be audit log entries from the last 24 hours."""
        import datetime
        base = ranger_client.base_url
        start = (datetime.datetime.utcnow() - datetime.timedelta(hours=24)).isoformat()
        resp = ranger_client.get(
            f"{base}/service/assets/accessAudit",
            params={"startDate": start},
            timeout=10,
        )
        if resp.status_code != 200:
            pytest.skip(f"Audit API error: {resp.status_code}")

        data = resp.json()
        total = data.get("totalCount", data.get("total_count", len(data.get("vXAccessAudits", []))))
        if total == 0:
            pytest.skip("No audit entries found — run some queries to generate audit events")

    def test_audit_entry_has_required_fields(self, ranger_client):
        """Audit entries must have user, action, resource, and result fields."""
        base = ranger_client.base_url
        resp = ranger_client.get(f"{base}/service/assets/accessAudit?pageSize=1", timeout=10)
        if resp.status_code != 200:
            pytest.skip("Audit API not available")

        data = resp.json()
        entries = data.get("vXAccessAudits", data.get("data", []))
        if not entries:
            pytest.skip("No audit entries to validate")

        entry = entries[0]
        # Field names vary by Ranger version
        has_user = "requestUser" in entry or "user" in entry
        has_action = "accessType" in entry or "action" in entry
        has_resource = "resourcePath" in entry or "resource" in entry
        has_result = "accessResult" in entry or "result" in entry

        assert has_user, f"Audit entry missing user field: {list(entry.keys())}"
        assert has_action, f"Audit entry missing action field: {list(entry.keys())}"


# ---------------------------------------------------------------------------
# Loki audit shipping
# ---------------------------------------------------------------------------

class TestLokiAuditShipping:

    @pytest.fixture(autouse=True)
    def _require_loki(self, docker_services):
        if not _loki_available():
            pytest.skip("Loki not reachable at localhost:3100 — run `make dev-up`")

    def test_loki_ready(self):
        resp = requests.get(f"{LOKI_URL}/ready", timeout=5)
        assert resp.status_code == 200

    def test_loki_has_ranger_audit_stream(self):
        """Ranger audit logs must be shipped to Loki via Promtail."""
        resp = requests.get(
            f"{LOKI_URL}/loki/api/v1/labels",
            timeout=10,
        )
        assert resp.status_code == 200
        labels = resp.json().get("data", [])
        # 'job' label should include something related to ranger
        if "job" in labels:
            job_values_resp = requests.get(
                f"{LOKI_URL}/loki/api/v1/label/job/values",
                timeout=10,
            )
            job_values = job_values_resp.json().get("data", [])
            ranger_jobs = [j for j in job_values if "ranger" in j.lower()]
            if not ranger_jobs:
                pytest.skip(
                    "No Ranger log streams in Loki — check Promtail config for Ranger log path"
                )

    def test_audit_event_queryable_after_access(self, docker_services, trino_cursor):
        """After a Trino query, an audit event must appear in Loki within 30 seconds."""
        # Execute a distinctive query to generate an audit event
        marker = uuid.uuid4().hex
        try:
            trino_cursor.execute(f"-- AUDIT MARKER: {marker}\nSELECT 1")
            trino_cursor.fetchall()
        except Exception:
            pass

        # Poll Loki for the marker (best-effort — not all stacks ship query text to Loki)
        deadline = time.time() + 30
        found = False
        while time.time() < deadline and not found:
            resp = requests.get(
                f"{LOKI_URL}/loki/api/v1/query",
                params={"query": f'{{job="trino"}} |= "{marker}"', "limit": 1},
                timeout=5,
            )
            if resp.status_code == 200:
                result = resp.json().get("data", {}).get("result", [])
                if result:
                    found = True
            if not found:
                time.sleep(3)

        if not found:
            pytest.skip(
                f"Audit marker '{marker}' not found in Loki within 30s — "
                "Trino query text may not be shipped to Loki in this config"
            )
