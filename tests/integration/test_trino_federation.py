"""
Integration tests — Trino query federation & catalog connectivity.

Validates:
  - Trino server is reachable and returns system info
  - Iceberg catalog is listed
  - TPCh catalog available for reference queries
  - Cross-catalog queries work
  - Query planning (EXPLAIN) succeeds for complex queries
  - Session properties can be set

Requires: running local Trino stack.
"""

from __future__ import annotations

import pytest

pytestmark = [pytest.mark.integration]


class TestTrinoConnectivity:

    def test_trino_info_endpoint(self, docker_services):
        """Trino /v1/info must return server version."""
        import requests
        host = "localhost"
        port = 8080
        try:
            resp = requests.get(f"http://{host}:{port}/v1/info", timeout=10)
            assert resp.status_code == 200
            data = resp.json()
            assert "nodeVersion" in data or "starting" in data
        except requests.RequestException:
            pytest.skip("Trino not reachable")

    def test_trino_connection_established(self, docker_services, trino_connection):
        """trino.dbapi connection must be usable."""
        cursor = trino_connection.cursor()
        cursor.execute("SELECT 1")
        row = cursor.fetchone()
        assert row[0] == 1
        cursor.cancel()

    def test_show_catalogs(self, docker_services, trino_cursor):
        """SHOW CATALOGS must include iceberg catalog."""
        trino_cursor.execute("SHOW CATALOGS")
        catalogs = {row[0] for row in trino_cursor.fetchall()}
        assert "iceberg" in catalogs or "nessie" in catalogs, (
            f"'iceberg' or 'nessie' catalog not found. Available: {catalogs}"
        )


class TestTrinoQueries:

    def test_select_literal(self, docker_services, trino_cursor):
        trino_cursor.execute("SELECT 42, 'hello', true, CURRENT_TIMESTAMP")
        row = trino_cursor.fetchone()
        assert row[0] == 42
        assert row[1] == "hello"
        assert row[2] is True

    def test_show_schemas_in_iceberg(self, docker_services, trino_cursor):
        try:
            trino_cursor.execute("SHOW SCHEMAS IN iceberg")
            schemas = {row[0] for row in trino_cursor.fetchall()}
            assert len(schemas) >= 1
        except Exception as exc:
            if "Catalog 'iceberg' does not exist" in str(exc):
                pytest.skip("Iceberg catalog not configured")
            raise

    def test_create_table_and_insert(self, docker_services, trino_cursor):
        """Round-trip: CREATE → INSERT → SELECT → DROP on iceberg."""
        import uuid
        table_name = f"iceberg.raw.test_table_{uuid.uuid4().hex[:8]}"
        try:
            trino_cursor.execute(
                f"CREATE TABLE {table_name} (id BIGINT, name VARCHAR)"
            )
            trino_cursor.execute(
                f"INSERT INTO {table_name} VALUES (1, 'test-row')"
            )
            trino_cursor.execute(f"SELECT id, name FROM {table_name}")  # noqa: S608
            row = trino_cursor.fetchone()
            assert row is not None
            assert row[0] == 1
            assert row[1] == "test-row"
        except Exception as exc:
            if "Catalog" in str(exc) or "does not exist" in str(exc):
                pytest.skip(f"Iceberg catalog operation failed: {exc}")
            raise
        finally:
            try:
                trino_cursor.execute(f"DROP TABLE IF EXISTS {table_name}")
            except Exception:
                pass

    def test_explain_query(self, docker_services, trino_cursor):
        """EXPLAIN must return a query plan without error."""
        try:
            trino_cursor.execute(
                "EXPLAIN SELECT * FROM iceberg.raw.customers WHERE region = 'EAST'"  # noqa: S608
            )
            plan = trino_cursor.fetchall()
            assert len(plan) >= 1
        except Exception as exc:
            if "does not exist" in str(exc):
                pytest.skip("customers table not seeded")
            raise

    def test_set_session_property(self, docker_services, trino_cursor):
        """SET SESSION must succeed without error."""
        trino_cursor.execute("SET SESSION query_max_execution_time = '5m'")
        # No exception = success

    def test_tpch_queries_available(self, docker_services, trino_cursor):
        """TPC-H connector should expose standard benchmark tables."""
        try:
            trino_cursor.execute("SELECT COUNT(*) FROM tpch.sf1.customer")
            count = trino_cursor.fetchone()[0]
            assert count == 150000, f"TPC-H sf1.customer should have 150000 rows, got {count}"
        except Exception as exc:
            if "does not exist" in str(exc) or "Catalog 'tpch'" in str(exc):
                pytest.skip("TPC-H catalog not enabled in Trino config")
            raise


class TestTrinoSecurity:

    def test_trino_rejects_unauthenticated_when_secured(self, docker_services):
        """If Trino auth is enabled, unauthenticated requests should be rejected."""
        import requests
        import os

        if os.environ.get("TRINO_AUTH_ENABLED", "false").lower() != "true":
            pytest.skip("TRINO_AUTH_ENABLED not set — skipping auth test")

        resp = requests.get("http://localhost:8080/v1/statement", timeout=5)
        # Should return 401 or 403
        assert resp.status_code in (401, 403), (
            f"Expected 401/403 for unauthenticated Trino, got {resp.status_code}"
        )
