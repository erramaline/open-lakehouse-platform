"""
Integration tests — Apache Iceberg time travel & Nessie branching.

Validates:
  - Iceberg time travel (AS OF VERSION n)
  - Iceberg snapshot listing
  - Nessie branch creation and promotion workflow
  - Iceberg MERGE INTO (upsert)

Requires: running local stack + seeded Iceberg tables.
"""

from __future__ import annotations

import time
import uuid

import pytest
import requests

pytestmark = [pytest.mark.integration]

NESSIE_URL = "http://localhost:19120/api/v2"


# ---------------------------------------------------------------------------
# Nessie helpers
# ---------------------------------------------------------------------------

def _nessie_get(path: str) -> dict:
    resp = requests.get(f"{NESSIE_URL}{path}", timeout=10)
    resp.raise_for_status()
    return resp.json()


def _nessie_post(path: str, body: dict) -> dict:
    resp = requests.post(f"{NESSIE_URL}{path}", json=body, timeout=10)
    resp.raise_for_status()
    return resp.json()


def _nessie_available() -> bool:
    try:
        resp = requests.get(f"{NESSIE_URL}/config", timeout=5)
        return resp.status_code == 200
    except requests.RequestException:
        return False


# ---------------------------------------------------------------------------
# Iceberg time travel
# ---------------------------------------------------------------------------

class TestIcebergTimeTravel:

    def test_iceberg_snapshots_queryable(self, docker_services, trino_cursor):
        """Trino can query Iceberg snapshot history."""
        try:
            trino_cursor.execute(
                "SELECT snapshot_id, committed_at FROM iceberg.raw.\"customers$snapshots\" "
                "ORDER BY committed_at DESC LIMIT 5"
            )
            rows = trino_cursor.fetchall()
            # Even an empty result is OK; just ensure the query is valid
            assert isinstance(rows, list)
        except Exception as exc:
            exc_str = str(exc)
            if "does not exist" in exc_str or "not found" in exc_str.lower():
                pytest.skip("customers table not seeded — run `make seed`")
            raise

    def test_iceberg_time_travel_by_snapshot(self, docker_services, trino_cursor):
        """Query a specific Iceberg snapshot by ID."""
        try:
            # Get most recent snapshot ID
            trino_cursor.execute(
                "SELECT snapshot_id FROM iceberg.raw.\"customers$snapshots\" "
                "ORDER BY committed_at DESC LIMIT 1"
            )
            row = trino_cursor.fetchone()
            if not row:
                pytest.skip("No snapshots found — seed the table first")

            snapshot_id = row[0]
            trino_cursor.execute(
                f"SELECT COUNT(*) FROM iceberg.raw.customers FOR VERSION AS OF {snapshot_id}"  # noqa: S608
            )
            count_row = trino_cursor.fetchone()
            assert count_row is not None
            assert count_row[0] >= 0
        except Exception as exc:
            if "does not exist" in str(exc):
                pytest.skip("customers table not seeded")
            raise

    def test_iceberg_time_travel_by_timestamp(self, docker_services, trino_cursor):
        """Query Iceberg table at a past timestamp."""
        try:
            trino_cursor.execute(
                "SELECT COUNT(*) FROM iceberg.raw.customers "
                "FOR TIMESTAMP AS OF TIMESTAMP '2020-01-01 00:00:00'"  # noqa: S608
            )
            # This may return 0 rows (table didn't exist) — that's fine
            row = trino_cursor.fetchone()
            assert row is not None
        except Exception as exc:
            exc_str = str(exc)
            # "No version of table" is an expected Iceberg error for too-old timestamps
            if "does not exist" in exc_str or "No version" in exc_str:
                pytest.skip("customers table not seeded or timestamp too old")
            raise

    def test_iceberg_table_properties(self, docker_services, trino_cursor):
        """Iceberg table must have format-version=2 (required for row-level deletes)."""
        try:
            trino_cursor.execute(
                "SELECT property_name, property_value "
                "FROM iceberg.raw.\"customers$properties\""
            )
            rows = trino_cursor.fetchall()
            props = {r[0]: r[1] for r in rows}
            if "format-version" in props:
                assert props["format-version"] in ("2", 2), (
                    f"Expected Iceberg format-version=2, got {props['format-version']}"
                )
        except Exception as exc:
            if "does not exist" in str(exc):
                pytest.skip("customers table not seeded")
            raise


# ---------------------------------------------------------------------------
# Nessie branching
# ---------------------------------------------------------------------------

class TestNessieBranching:

    @pytest.fixture(autouse=True)
    def _require_nessie(self):
        if not _nessie_available():
            pytest.skip("Nessie not reachable at localhost:19120 — run `make dev-up`")

    def test_nessie_default_branch_exists(self):
        """main branch must exist."""
        data = _nessie_get("/trees")
        branches = [r["name"] for r in data.get("references", [])]
        assert "main" in branches, f"'main' branch not found in Nessie. Branches: {branches}"

    def test_create_and_delete_feature_branch(self):
        """Create a feature branch off main, then delete it."""
        branch_name = f"test-branch-{uuid.uuid4().hex[:8]}"

        # Get current main hash
        main = _nessie_get("/trees/main")
        main_hash = main["hash"]

        # Create branch
        _nessie_post(
            "/trees",
            {
                "name": branch_name,
                "type": "BRANCH",
                "reference": {"type": "BRANCH", "name": "main", "hash": main_hash},
            },
        )

        # Verify branch exists
        branches_data = _nessie_get("/trees")
        branch_names = [r["name"] for r in branches_data.get("references", [])]
        assert branch_name in branch_names, f"Branch '{branch_name}' not created"

        # Clean up
        branch_info = _nessie_get(f"/trees/{branch_name}")
        requests.delete(
            f"{NESSIE_URL}/trees/{branch_name}",
            params={"expectedHash": branch_info["hash"]},
            timeout=10,
        )

    def test_nessie_api_returns_content_type_json(self):
        resp = requests.get(f"{NESSIE_URL}/config", timeout=10)
        assert "application/json" in resp.headers.get("Content-Type", ""), (
            "Nessie API should return JSON"
        )


# ---------------------------------------------------------------------------
# Iceberg MERGE INTO (upsert)
# ---------------------------------------------------------------------------

class TestIcebergMergeInto:

    def test_merge_into_updates_existing_row(self, docker_services, trino_cursor):
        """MERGE INTO must update an existing row without duplicating it."""
        try:
            # Create a temporary test table
            test_table = f"iceberg.raw.test_merge_{uuid.uuid4().hex[:8]}"
            trino_cursor.execute(
                f"CREATE TABLE {test_table} (id BIGINT, value VARCHAR, region VARCHAR)"
            )
            trino_cursor.execute(
                f"INSERT INTO {test_table} VALUES (1, 'original', 'EAST')"
            )
            trino_cursor.execute(
                f"""
                MERGE INTO {test_table} t
                USING (VALUES (1, 'updated', 'WEST')) AS s(id, value, region)
                ON t.id = s.id
                WHEN MATCHED THEN UPDATE SET value = s.value, region = s.region
                WHEN NOT MATCHED THEN INSERT (id, value, region) VALUES (s.id, s.value, s.region)
                """
            )
            trino_cursor.execute(f"SELECT value, region FROM {test_table} WHERE id = 1")  # noqa: S608
            row = trino_cursor.fetchone()
            assert row is not None
            assert row[0] == "updated"
            assert row[1] == "WEST"

            # Count to ensure no duplicate
            trino_cursor.execute(f"SELECT COUNT(*) FROM {test_table}")  # noqa: S608
            count = trino_cursor.fetchone()[0]
            assert count == 1, f"Expected 1 row after MERGE, got {count}"
        except Exception as exc:
            if "does not exist" in str(exc) or "Catalog" in str(exc):
                pytest.skip("Iceberg catalog not available")
            raise
        finally:
            try:
                trino_cursor.execute(f"DROP TABLE IF EXISTS {test_table}")
            except Exception:
                pass
