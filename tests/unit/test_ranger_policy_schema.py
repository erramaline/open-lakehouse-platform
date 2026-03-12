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
    # NONE = passthrough (no masking) — used for privileged groups
    "NONE",
}

# Each file is a single Ranger policy object (not a list wrapper).
# Required keys for any individual policy.
REQUIRED_POLICY_KEYS = {"policyName", "serviceType", "policyType"}


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
    """Every policy file must have policyName, serviceType, and policyType."""
    data = load_policy(filename)
    missing = REQUIRED_POLICY_KEYS - data.keys()
    assert not missing, f"{filename} is missing keys: {missing}"


@pytest.mark.parametrize("filename", policy_files())
def test_policy_name_non_empty(filename: str):
    data = load_policy(filename)
    assert data.get("policyName", "").strip(), f"'policyName' is empty in {filename}"


# ---------------------------------------------------------------------------
# Column-mask policy (policyType == 1)
# ---------------------------------------------------------------------------

class TestIcebergColumnMask:
    FILE = "iceberg-column-mask.json"

    def setup_method(self):
        self.data = load_policy(self.FILE)

    def test_has_policies(self):
        assert self.data.get("policyType") == 1, "column mask must have policyType=1"

    def test_each_policy_has_name(self):
        assert self.data.get("policyName", "").strip(), "column mask must have a non-empty policyName"

    def test_mask_types_are_valid(self):
        for info in self.data.get("dataMaskPolicyItems", []):
            mask_type = info.get("dataMaskInfo", {}).get("dataMaskType", "")
            if mask_type:
                assert mask_type in VALID_MASK_TYPES, (
                    f"Unknown mask type '{mask_type}' in {self.FILE}"
                )

    def test_at_least_one_masked_column(self):
        """Column-mask policy must reference a column resource."""
        assert "column" in self.data.get("resources", {}), (
            "No column-level resource found in column-mask policy"
        )


# ---------------------------------------------------------------------------
# Row-filter policy (policyType == 2)
# ---------------------------------------------------------------------------

class TestIcebergRowFilter:
    FILE = "iceberg-row-filter.json"

    def setup_method(self):
        self.data = load_policy(self.FILE)

    def test_has_policies(self):
        assert self.data.get("policyType") == 2, "row filter must have policyType=2"

    def test_row_filter_expressions_non_empty(self):
        # Privileged groups (engineers, admins) use empty filterExpr = no restriction.
        # At least ONE item must have a real filter expression.
        items = self.data.get("rowFilterPolicyItems", [])
        assert items, f"No rowFilterPolicyItems found in {self.FILE}"
        non_empty = [it for it in items if it.get("rowFilterInfo", {}).get("filterExpr", "").strip()]
        assert non_empty, (
            f"All rowFilterPolicyItems have empty filterExpr in {self.FILE}. "
            "At least one restricted group must have a non-empty filter."
        )

    def test_row_filter_is_valid_sql_fragment(self):
        """Non-empty filter expressions must look like SQL (non-trivial length)."""
        items = self.data.get("rowFilterPolicyItems", [])
        for item in items:
            expr = item.get("rowFilterInfo", {}).get("filterExpr", "")
            if expr.strip():  # skip empty (passthrough for privileged groups)
                assert len(expr) > 2, f"Suspiciously short filter expression: '{expr}'"


# ---------------------------------------------------------------------------
# Audit policy
# ---------------------------------------------------------------------------

class TestAuditPolicy:
    FILE = "audit-policy.json"

    def setup_method(self):
        self.data = load_policy(self.FILE)

    def test_has_policies(self):
        assert self.data.get("policyName", "").strip(), "audit policy must have a policyName"

    def test_audit_logging_enabled(self):
        assert self.data.get("isAuditEnabled", False) is True, (
            f"isAuditEnabled must be true in {self.FILE}"
        )


# ---------------------------------------------------------------------------
# Schema-access policy
# ---------------------------------------------------------------------------

class TestSchemaAccess:
    FILE = "schema-access.json"

    def setup_method(self):
        self.data = load_policy(self.FILE)

    def test_has_policies(self):
        assert self.data.get("policyName", "").strip(), "schema-access must have a policyName"

    def test_access_types_defined(self):
        for item in self.data.get("policyItems", []):
            for acc in item.get("accesses", []):
                assert "type" in acc, f"Access item missing 'type' in {self.FILE}: {acc}"
                assert isinstance(acc.get("isAllowed"), bool), (
                    f"'isAllowed' must be bool in {self.FILE}"
                )


# ---------------------------------------------------------------------------
# General: no policy has an empty name
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("filename", policy_files())
def test_no_policy_with_empty_name(filename: str):
    data = load_policy(filename)
    name = data.get("policyName", "").strip()
    assert name, f"{filename}: policyName is empty or missing"
