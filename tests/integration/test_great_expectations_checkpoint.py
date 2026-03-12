"""
Integration tests — Great Expectations checkpoint execution.

Runs GE checkpoints against live data (or uses the json suites to
validate structure if GE is not installed / data not seeded).

Requires: running local stack + seeded Iceberg tables.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

pytestmark = [pytest.mark.integration]

EXPECTATIONS_DIR = Path(__file__).parents[2] / "data" / "quality" / "expectations"
CHECKPOINTS_DIR = Path(__file__).parents[2] / "data" / "quality" / "checkpoints"


def _has_great_expectations() -> bool:
    try:
        import great_expectations  # noqa: F401
        return True
    except ImportError:
        return False


# ---------------------------------------------------------------------------
# Static checkpoint configuration tests
# ---------------------------------------------------------------------------

class TestGECheckpointConfig:

    @pytest.fixture(autouse=True)
    def _ensure_suites_exist(self):
        if not EXPECTATIONS_DIR.exists():
            pytest.skip("data/quality/expectations/ not found")

    def test_all_layers_have_expectation_suites(self):
        """raw_layer, staging_layer, and curated_layer suites must exist."""
        expected = {"raw_layer.json", "staging_layer.json", "curated_layer.json"}
        found = {f.name for f in EXPECTATIONS_DIR.glob("*.json")}
        missing = expected - found
        assert not missing, f"Missing expectation suites: {missing}"

    def test_suites_have_expectations(self):
        for suite_path in EXPECTATIONS_DIR.glob("*.json"):
            with open(suite_path) as fh:
                data = json.load(fh)
            count = len(data.get("expectations", []))
            assert count >= 1, f"{suite_path.name}: must have at least 1 expectation"


# ---------------------------------------------------------------------------
# Live GE checkpoint runs (skipped if GE not installed or DB not available)
# ---------------------------------------------------------------------------

class TestGECheckpointRun:

    @pytest.fixture(autouse=True)
    def _require_ge_and_db(self, docker_services):
        if not _has_great_expectations():
            pytest.skip("great-expectations not installed — pip install great-expectations")

    def test_raw_layer_checkpoint_passes(self, trino_cursor):
        """GE checkpoint for raw_layer must return success=True."""
        try:
            import great_expectations as gx  # type: ignore

            context = gx.get_context()
            # The checkpoint name must match what's configured in GE project
            checkpoint_name = "raw_layer_checkpoint"
            if checkpoint_name not in [cp["name"] for cp in context.list_checkpoints()]:
                pytest.skip(
                    f"Checkpoint '{checkpoint_name}' not configured — "
                    "run GE init or the great_expectations DAG"
                )

            result = context.run_checkpoint(checkpoint_name=checkpoint_name)
            assert result.success, (
                f"GE checkpoint '{checkpoint_name}' failed. "
                f"Results: {result.list_validation_results()}"
            )
        except Exception as exc:
            if "does not exist" in str(exc) or "not found" in str(exc).lower():
                pytest.skip(f"GE context or checkpoint not configured: {exc}")
            raise

    def test_staging_layer_checkpoint_passes(self, trino_cursor):
        """GE checkpoint for staging_layer must return success=True."""
        try:
            import great_expectations as gx  # type: ignore

            context = gx.get_context()
            checkpoint_name = "staging_layer_checkpoint"
            if checkpoint_name not in [cp["name"] for cp in context.list_checkpoints()]:
                pytest.skip(f"Checkpoint '{checkpoint_name}' not configured")

            result = context.run_checkpoint(checkpoint_name=checkpoint_name)
            assert result.success, f"GE checkpoint '{checkpoint_name}' failed"
        except Exception as exc:
            if "not found" in str(exc).lower() or "does not exist" in str(exc):
                pytest.skip(str(exc))
            raise


# ---------------------------------------------------------------------------
# GE expectation validation against Trino data
# ---------------------------------------------------------------------------

class TestGEExpectationValues:

    def test_raw_customers_row_count_in_bounds(self, docker_services, trino_cursor):
        """raw.customers row count must be within expected bounds."""
        try:
            trino_cursor.execute("SELECT COUNT(*) FROM raw.customers")  # noqa: S608
            count = trino_cursor.fetchone()[0]

            # Load expected bounds from suite
            suite_path = EXPECTATIONS_DIR / "raw_layer.json"
            if not suite_path.exists():
                pytest.skip("raw_layer.json not found")

            with open(suite_path) as fh:
                suite = json.load(fh)

            row_count_exp = next(
                (e for e in suite["expectations"]
                 if e["expectation_type"] == "expect_table_row_count_to_be_between"),
                None,
            )
            if row_count_exp:
                min_val = row_count_exp["kwargs"].get("min_value", 0)
                max_val = row_count_exp["kwargs"].get("max_value", float("inf"))
                assert min_val <= count <= max_val, (
                    f"raw.customers row count {count} outside expected range [{min_val}, {max_val}]"
                )
        except Exception as exc:
            if "does not exist" in str(exc):
                pytest.skip("raw.customers table not seeded")
            raise

    def test_staging_customers_no_null_ids(self, docker_services, trino_cursor):
        """stg_customers must not have null customer_id values."""
        try:
            trino_cursor.execute(
                "SELECT COUNT(*) FROM staging.stg_customers WHERE customer_id IS NULL"  # noqa: S608
            )
            null_count = trino_cursor.fetchone()[0]
            assert null_count == 0, (
                f"staging.stg_customers has {null_count} rows with null customer_id"
            )
        except Exception as exc:
            if "does not exist" in str(exc):
                pytest.skip("staging.stg_customers table not seeded")
            raise
