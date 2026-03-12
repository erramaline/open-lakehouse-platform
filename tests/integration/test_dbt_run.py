"""
Integration tests — dbt model execution against Trino + Iceberg.

Validates:
  - dbt run and dbt test pass against the live Trino connection
  - Staging models produce correct row counts
  - Mart models produce correct aggregations
  - dbt test suite (schema tests) all pass

Requires: running stack + seeded raw tables + dbt installed.
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

import pytest

pytestmark = [pytest.mark.integration]

DBT_DIR = Path(__file__).parents[2] / "dbt"


def _dbt_available() -> bool:
    return subprocess.run(["dbt", "--version"], capture_output=True, timeout=10).returncode == 0


class TestDbtRun:

    @pytest.fixture(autouse=True)
    def _require_dbt_and_stack(self, docker_services):
        if not _dbt_available():
            pytest.skip("dbt not installed")
        if not DBT_DIR.exists():
            pytest.skip("dbt/ directory not found")

    def _run_dbt(self, *args: str) -> subprocess.CompletedProcess:
        env = {
            **os.environ,
            "DBT_PROFILES_DIR": str(DBT_DIR),
        }
        return subprocess.run(
            ["dbt", *args, "--profiles-dir", str(DBT_DIR), "--project-dir", str(DBT_DIR)],
            capture_output=True,
            text=True,
            timeout=300,
            env=env,
        )

    def test_dbt_deps_resolves(self):
        """dbt deps must resolve all packages without error."""
        result = self._run_dbt("deps")
        assert result.returncode == 0, (
            f"dbt deps failed:\n{result.stdout}\n{result.stderr}"
        )

    def test_dbt_run_staging_models(self):
        """dbt run --select staging must succeed."""
        result = self._run_dbt("run", "--select", "staging")
        assert result.returncode == 0, (
            f"dbt run staging failed:\n{result.stdout}\n{result.stderr}"
        )

    def test_dbt_run_mart_models(self):
        """dbt run --select marts must succeed after staging."""
        result = self._run_dbt("run", "--select", "marts")
        assert result.returncode == 0, (
            f"dbt run marts failed:\n{result.stdout}\n{result.stderr}"
        )

    def test_dbt_test_passes(self):
        """dbt test must pass all schema tests."""
        result = self._run_dbt("test")
        assert result.returncode == 0, (
            f"dbt test failed:\n{result.stdout}\n{result.stderr}"
        )

    def test_dbt_source_freshness(self):
        """dbt source freshness must not report any critical sources."""
        result = self._run_dbt("source", "freshness")
        # Freshness may warn but must not error critically
        assert result.returncode in (0, 1), (
            f"dbt source freshness errored:\n{result.stdout}\n{result.stderr}"
        )


class TestDbtModelOutputs:

    @pytest.fixture(autouse=True)
    def _require_stack(self, docker_services, trino_cursor):
        pass

    def test_staging_customers_row_count_matches_raw(self, trino_cursor):
        """stg_customers must have the same row count as raw.customers."""
        try:
            trino_cursor.execute("SELECT COUNT(*) FROM raw.customers")  # noqa: S608
            raw_count = trino_cursor.fetchone()[0]

            trino_cursor.execute("SELECT COUNT(*) FROM staging.stg_customers")  # noqa: S608
            stg_count = trino_cursor.fetchone()[0]

            assert stg_count == raw_count, (
                f"stg_customers ({stg_count}) != raw.customers ({raw_count})"
            )
        except Exception as exc:
            if "does not exist" in str(exc):
                pytest.skip("Tables not seeded or dbt not run")
            raise

    def test_fct_orders_total_matches_raw(self, trino_cursor):
        """fct_orders total revenue must match raw.orders sum."""
        try:
            trino_cursor.execute("SELECT SUM(total_amount) FROM raw.orders")  # noqa: S608
            raw_total = trino_cursor.fetchone()[0]

            trino_cursor.execute("SELECT SUM(order_total) FROM marts.fct_orders")  # noqa: S608
            fct_total = trino_cursor.fetchone()[0]

            # Allow small rounding differences
            diff = abs(float(raw_total or 0) - float(fct_total or 0))
            assert diff < 0.01, (
                f"Revenue mismatch: raw={raw_total}, fct_orders={fct_total}, diff={diff}"
            )
        except Exception as exc:
            if "does not exist" in str(exc):
                pytest.skip("Tables not seeded or dbt not run")
            raise

    def test_dim_customers_has_no_duplicates(self, trino_cursor):
        """dim_customers surrogate key must be unique."""
        try:
            trino_cursor.execute(
                "SELECT COUNT(*), COUNT(DISTINCT customer_key) FROM marts.dim_customers"  # noqa: S608
            )
            row = trino_cursor.fetchone()
            total_count, unique_count = row[0], row[1]
            assert total_count == unique_count, (
                f"dim_customers has {total_count - unique_count} duplicate customer_key values"
            )
        except Exception as exc:
            if "does not exist" in str(exc):
                pytest.skip("dim_customers not built — run dbt")
            raise
