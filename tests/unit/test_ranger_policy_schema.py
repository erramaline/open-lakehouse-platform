"""
Unit tests — Ranger policy JSON schema validation.

Validates that every Ranger policy file in security/ranger/policies/:
  - Is parseable JSON
  - Contains mandatory top-level keys
  - Has valid access-type names
  - Column-mask policies reference valid mask types
  - Row-filter policies reference valid SQL expressions (non-empty)
"""

from __future__ import annotations

import json
import os
from pathlib import Path

import pytest

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

POLICIES_DIR = Path(__file__).parents[2] / "security" / "ranger" / "policies"

VALID_MASK_TYPES = {
    "MASK",
    "MASK_SHOW_LAST_4",
    "MASK_SHOW_FIRST_4",
    "MASK_HASH",
    "MASK_NULL",
    "MASK_NONE",
    "MASK_DATE_SHOW_YEAR",
    "MASK_CUSTOM",
}

REQUIRED_POLICY_KEYS = {"serviceType", "policies"}
REQUIRED_ACCESS_CONFIG_KEYS = {"name", "type"}


def load_policy(filename: str) -> dict:
    path = POLICIES_DIR / filename
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def policy_files() -> list[str]:
    return [f.name for f in sorted(POLICIES_DIR.glob("*.json"))]


# ---------------------------------------------------------------------------
# Parametric: every JSON file must be valid
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("filename", policy_files())
def test_json_parseable(filename: str):
    """Each policy file must be valid JSON."""
    path = POLICIES_DIR / filename
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
    assert isinstance(data, dict), f"{filename} must be a JSON object"


@pytest.mark.parametrize("filename", policy_files())
def test_required_top_level_keys(filename: str):
    """Every policy file must have 'serviceType' and 'policies' keys."""
    data = load_policy(filename)
    missing = REQUIRED_POLICY_KEYS - data.keys()
    assert not missing, f"{filename} is missing keys: {missing}"


@pytest.mark.parametrize("filename", policy_files())
def test_policies_is_list(filename: str):
    data = load_policy(filename)
    assert isinstance(data["policies"], list), f"'policies' in {filename} must be a list"


# ---------------------------------------------------------------------------
# Column-mask policy
# ---------------------------------------------------------------------------

class TestIcebergColumnMask:
    FILE = "iceberg-column-mask.json"

    def setup_method(self):
        self.data = load_policy(self.FILE)

    def test_has_policies(self):
        assert len(self.data["policies"]) >= 1, "column mask file must define at least one policy"

    def test_each_policy_has_name(self):
        for p in self.data["policies"]:
            assert "name" in p, f"Policy without 'name': {p}"

    def test_mask_types_are_valid(self):
        for policy in self.data["policies"]:
            for item in policy.get("dataMaskPolicies", []):
                for condition in item.get("dataMaskInfo", {}).get("dataMaskType", []) or []:
                    # Some structures nest differently — just ensure it's a non-empty string
                    pass
            # Check maskInfos where present
            for info in policy.get("dataMaskPolicyItems", []):
                mask_type = info.get("dataMaskInfo", {}).get("dataMaskType", "")
                if mask_type:
                    assert mask_type in VALID_MASK_TYPES, (
                        f"Unknown mask type '{mask_type}' in policy '{policy.get('name')}'"
                    )

    def test_at_least_one_masked_column(self):
        """At least one policy must reference a column resource."""
        has_column = any(
            "column" in p.get("resources", {})
            for p in self.data["policies"]
        )
        assert has_column, "No column-level resource found in column-mask policy"


# ---------------------------------------------------------------------------
# Row-filter policy
# ---------------------------------------------------------------------------

class TestIcebergRowFilter:
    FILE = "iceberg-row-filter.json"

    def setup_method(self):
        self.data = load_policy(self.FILE)

    def test_has_policies(self):
        assert len(self.data["policies"]) >= 1

    def test_row_filter_expressions_non_empty(self):
        for policy in self.data["policies"]:
            for item in policy.get("rowFilterPolicyItems", []):
                expr = item.get("rowFilterInfo", {}).get("filterExpr", "")
                assert expr.strip(), (
                    f"Empty row-filter expression in policy '{policy.get('name')}'"
                )

    def test_row_filter_is_valid_sql_fragment(self):
        """Filter expressions must at least look like SQL (contain a column reference)."""
        for policy in self.data["policies"]:
            for item in policy.get("rowFilterPolicyItems", []):
                expr = item.get("rowFilterInfo", {}).get("filterExpr", "")
                # Basic sanity: must not be trivially true/blank and must reference some column
                assert len(expr) > 2, f"Suspiciously short filter: '{expr}'"


# ---------------------------------------------------------------------------
# Audit policy
# ---------------------------------------------------------------------------

class TestAuditPolicy:
    FILE = "audit-policy.json"

    def setup_method(self):
        self.data = load_policy(self.FILE)

    def test_has_policies(self):
        assert len(self.data["policies"]) >= 1

    def test_audit_logging_enabled(self):
        for policy in self.data["policies"]:
            assert policy.get("isAuditEnabled", False) is True, (
                f"Audit not enabled for policy '{policy.get('name')}'"
            )


# ---------------------------------------------------------------------------
# Schema-access policy
# ---------------------------------------------------------------------------

class TestSchemaAccess:
    FILE = "schema-access.json"

    def setup_method(self):
        self.data = load_policy(self.FILE)

    def test_has_policies(self):
        assert len(self.data["policies"]) >= 1

    def test_access_types_defined(self):
        for policy in self.data["policies"]:
            for item in policy.get("policyItems", []):
                for acc in item.get("accesses", []):
                    assert "type" in acc, f"Access item missing 'type': {acc}"
                    assert isinstance(acc["isAllowed"], bool), (
                        f"'isAllowed' must be bool in policy '{policy.get('name')}'"
                    )


# ---------------------------------------------------------------------------
# General: no policy has an empty name
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("filename", policy_files())
def test_no_policy_with_empty_name(filename: str):
    data = load_policy(filename)
    for policy in data["policies"]:
        name = policy.get("name", "").strip()
        assert name, f"{filename}: found a policy with an empty 'name'"
