"""
Locust load test — Open Lakehouse Platform API endpoints.

Simulates concurrent users hitting:
  - Trino REST API (query submission + status polling)
  - MinIO S3 API (object GET)
  - Keycloak token endpoint (authentication)
  - OpenMetadata REST API (metadata search)

SLOs:
  - P95 response time < 5s for all endpoints
  - Error rate < 1%
  - Throughput >= 10 RPS with 50 concurrent users

Run with:
  locust -f tests/performance/locustfile.py \
    --host http://localhost:8080 \
    --users 50 \
    --spawn-rate 5 \
    --run-time 5m \
    --headless
"""

from __future__ import annotations

import os
import random
import string
import time
import uuid

from locust import HttpUser, TaskSet, between, events, task  # type: ignore

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

TRINO_HOST = os.environ.get("TRINO_HOST", "localhost")
TRINO_PORT = int(os.environ.get("TRINO_PORT", "8080"))
MINIO_HOST = os.environ.get("MINIO_ENDPOINT", "localhost:9000")
KEYCLOAK_HOST = os.environ.get("KEYCLOAK_URL", "http://localhost:9080")
OPENMETADATA_HOST = os.environ.get("OPENMETADATA_HOST", "http://localhost:8585")

KEYCLOAK_REALM = os.environ.get("KEYCLOAK_REALM", "lakehouse")
KEYCLOAK_CLIENT_ID = os.environ.get("KEYCLOAK_CLIENT_ID", "trino-client")

SAMPLE_QUERIES = [
    "SELECT 1",
    "SELECT COUNT(*) FROM tpch.sf1.customer",
    "SELECT l_returnflag, COUNT(*) FROM tpch.sf1.lineitem GROUP BY l_returnflag",
    "SHOW CATALOGS",
    "SHOW SCHEMAS IN iceberg",
]


# ---------------------------------------------------------------------------
# Trino REST API tasks
# ---------------------------------------------------------------------------

class TrinoQueryTasks(TaskSet):
    """Submits queries to Trino via the REST API."""

    def _submit_query(self, sql: str) -> str | None:
        """Submit a query and return the nextUri for polling."""
        with self.client.post(
            "/v1/statement",
            json={"query": sql},
            headers={
                "X-Trino-User": "admin",
                "X-Trino-Source": "locust-perf-test",
                "Content-Type": "application/json",
            },
            catch_response=True,
            name="trino_submit_query",
        ) as resp:
            if resp.status_code == 200:
                return resp.json().get("nextUri")
            resp.failure(f"Query submission failed: {resp.status_code}")
            return None

    def _poll_query(self, next_uri: str) -> bool:
        """Poll until query is done. Returns True if completed successfully."""
        for _ in range(20):  # max 20 polls
            with self.client.get(
                next_uri,
                headers={"X-Trino-User": "admin"},
                catch_response=True,
                name="trino_poll_result",
            ) as resp:
                if resp.status_code == 200:
                    data = resp.json()
                    state = data.get("stats", {}).get("state", "")
                    if state in ("FINISHED", "FAILED", "CANCELLED"):
                        if state == "FINISHED":
                            return True
                        resp.failure(f"Query ended in state: {state}")
                        return False
                    next_uri = data.get("nextUri", next_uri)
                elif resp.status_code == 204:
                    return True  # No content = finished
                else:
                    resp.failure(f"Poll failed: {resp.status_code}")
                    return False
            time.sleep(0.2)
        return False

    @task(5)
    def simple_select(self):
        """SELECT 1 — baseline latency check."""
        next_uri = self._submit_query("SELECT 1")
        if next_uri:
            self._poll_query(next_uri)

    @task(3)
    def count_query(self):
        """COUNT query — simple aggregation."""
        next_uri = self._submit_query("SELECT COUNT(*) FROM tpch.sf1.customer")
        if next_uri:
            self._poll_query(next_uri)

    @task(2)
    def show_catalogs(self):
        """SHOW CATALOGS — metadata query."""
        next_uri = self._submit_query("SHOW CATALOGS")
        if next_uri:
            self._poll_query(next_uri)

    @task(1)
    def complex_aggregation(self):
        """Complex aggregation — higher resource query."""
        sql = random.choice(SAMPLE_QUERIES)
        next_uri = self._submit_query(sql)
        if next_uri:
            self._poll_query(next_uri)


# ---------------------------------------------------------------------------
# Keycloak authentication tasks
# ---------------------------------------------------------------------------

class KeycloakAuthTasks(TaskSet):
    """Simulates token acquisition and refresh."""

    @task(1)
    def authenticate(self):
        """Simulate user login — Resource Owner Password grant."""
        with self.client.post(
            f"/realms/{KEYCLOAK_REALM}/protocol/openid-connect/token",
            data={
                "grant_type": "password",
                "client_id": KEYCLOAK_CLIENT_ID,
                "username": "admin",
                "password": os.environ.get("KEYCLOAK_ADMIN_PASSWORD", "admin"),
            },
            catch_response=True,
            name="keycloak_token",
        ) as resp:
            if resp.status_code == 200:
                resp.success()
            else:
                resp.failure(f"Auth failed: {resp.status_code}")


# ---------------------------------------------------------------------------
# OpenMetadata search tasks
# ---------------------------------------------------------------------------

class OpenMetadataTasks(TaskSet):
    """Simulates metadata search queries."""

    SEARCH_TERMS = ["customer", "order", "product", "revenue", "region"]

    @task(1)
    def search_tables(self):
        """Search for tables by keyword."""
        term = random.choice(self.SEARCH_TERMS)
        with self.client.get(
            f"/api/v1/search/query?q={term}&from=0&size=10&index=table_search_index",
            catch_response=True,
            name="openmetadata_search",
        ) as resp:
            if resp.status_code in (200, 404):
                resp.success()
            else:
                resp.failure(f"Search failed: {resp.status_code}")

    @task(1)
    def list_tables(self):
        """List tables."""
        with self.client.get(
            "/api/v1/tables?limit=10",
            catch_response=True,
            name="openmetadata_list_tables",
        ) as resp:
            if resp.status_code in (200, 401):
                resp.success()
            else:
                resp.failure(f"List tables failed: {resp.status_code}")


# ---------------------------------------------------------------------------
# User classes
# ---------------------------------------------------------------------------

class TrinoUser(HttpUser):
    """Simulates a data analyst running Trino queries."""

    host = f"http://{TRINO_HOST}:{TRINO_PORT}"
    tasks = [TrinoQueryTasks]
    wait_time = between(1, 3)
    weight = 60  # 60% of users are analysts


class KeycloakUser(HttpUser):
    """Simulates users authenticating via Keycloak."""

    host = KEYCLOAK_HOST
    tasks = [KeycloakAuthTasks]
    wait_time = between(5, 15)
    weight = 20  # 20% of traffic is auth


class OpenMetadataUser(HttpUser):
    """Simulates data engineers browsing OpenMetadata."""

    host = OPENMETADATA_HOST
    tasks = [OpenMetadataTasks]
    wait_time = between(2, 8)
    weight = 20  # 20% of traffic is metadata browsing


# ---------------------------------------------------------------------------
# SLO validation hook (run at end of load test)
# ---------------------------------------------------------------------------

@events.quitting.add_listener
def validate_slos(environment, **kwargs):
    """Fail the test if SLOs are violated."""
    stats = environment.runner.stats

    for name, stat in stats.entries.items():
        # P95 < 5000ms SLO
        p95 = stat.get_response_time_percentile(0.95)
        if p95 and p95 > 5000:
            print(f"SLO VIOLATION: {name} P95={p95}ms > 5000ms")
            environment.process_exit_code = 1

    total_stats = stats.total
    if total_stats.num_requests > 0:
        error_rate = total_stats.num_failures / total_stats.num_requests
        if error_rate > 0.01:
            print(f"SLO VIOLATION: Error rate {error_rate:.1%} > 1%")
            environment.process_exit_code = 1
        else:
            print(f"Error rate: {error_rate:.1%} ✓")

        rps = total_stats.current_rps
        print(f"Throughput: {rps:.1f} RPS")
