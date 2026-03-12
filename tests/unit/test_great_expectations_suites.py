"""
Unit tests — Great Expectations suite structure validation.

Validates the GE expectation suite JSON files under
data/quality/expectations/ without connecting to a datasource.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import pytest

EXPECTATIONS_DIR = Path(__file__).parents[2] / "data" / "quality" / "expectations"

# GE built-in expectation type prefixes (not exhaustive — major ones)
VALID_EXPECTATION_PREFIXES = (
    "expect_column_",
    "expect_table_",
    "expect_compound_columns_to_be_unique",
    "expect_multicolumn_",
    "expect_select_column_values_",
)

REQUIRED_SUITE_KEYS = {"expectation_suite_name", "expectations", "ge_cloud_id", "meta"}
# ge_cloud_id and meta may be missing in some versions; use minimal set
MINIMAL_SUITE_KEYS = {"expectation_suite_name", "expectations"}


def _load_suite(path: Path) -> dict[str, Any]:
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def _suite_files() -> list[Path]:
    if not EXPECTATIONS_DIR.exists():
        return []
    return sorted(EXPECTATIONS_DIR.glob("*.json"))


# ---------------------------------------------------------------------------
# Parametric file-level tests
# ---------------------------------------------------------------------------

@pytest.fixture(autouse=True, scope="module")
def _check_dir_exists():
    if not EXPECTATIONS_DIR.exists():
        pytest.skip(f"Expectations directory not found: {EXPECTATIONS_DIR}")


@pytest.mark.parametrize("suite_path", _suite_files())
def test_suite_parseable(suite_path: Path):
    """Each .json file must be valid JSON."""
    data = _load_suite(suite_path)
    assert isinstance(data, dict), f"{suite_path.name} must be a JSON object"


@pytest.mark.parametrize("suite_path", _suite_files())
def test_suite_has_required_keys(suite_path: Path):
    """Expectation suites must have 'expectation_suite_name' and 'expectations'."""
    data = _load_suite(suite_path)
    missing = MINIMAL_SUITE_KEYS - data.keys()
    assert not missing, f"{suite_path.name} missing keys: {missing}"


@pytest.mark.parametrize("suite_path", _suite_files())
def test_suite_name_matches_filename(suite_path: Path):
    """Suite name must match the filename prefix."""
    data = _load_suite(suite_path)
    suite_name = data["expectation_suite_name"]
    # The suite name should be derivable from the filename
    stem = suite_path.stem  # e.g. "raw_layer"
    assert stem in suite_name or suite_name.endswith(stem), (
        f"{suite_path.name}: suite name '{suite_name}' does not match filename stem '{stem}'"
    )


@pytest.mark.parametrize("suite_path", _suite_files())
def test_expectations_is_list(suite_path: Path):
    data = _load_suite(suite_path)
    assert isinstance(data["expectations"], list), (
        f"{suite_path.name}: 'expectations' must be a list"
    )


@pytest.mark.parametrize("suite_path", _suite_files())
def test_at_least_one_expectation(suite_path: Path):
    data = _load_suite(suite_path)
    assert len(data["expectations"]) >= 1, (
        f"{suite_path.name}: expectation suite must have at least one expectation"
    )


@pytest.mark.parametrize("suite_path", _suite_files())
def test_expectation_types_are_valid(suite_path: Path):
    """Every expectation type must be a known GE pattern."""
    data = _load_suite(suite_path)
    for exp in data["expectations"]:
        exp_type = exp.get("expectation_type", "")
        is_valid = any(exp_type.startswith(prefix) for prefix in VALID_EXPECTATION_PREFIXES)
        assert is_valid, (
            f"{suite_path.name}: unknown expectation type '{exp_type}'"
        )


@pytest.mark.parametrize("suite_path", _suite_files())
def test_expectations_have_kwargs(suite_path: Path):
    """Every expectation must have a 'kwargs' dict."""
    data = _load_suite(suite_path)
    for i, exp in enumerate(data["expectations"]):
        assert "kwargs" in exp, (
            f"{suite_path.name}[{i}]: expectation missing 'kwargs'"
        )
        assert isinstance(exp["kwargs"], dict), (
            f"{suite_path.name}[{i}]: 'kwargs' must be a dict"
        )


# ---------------------------------------------------------------------------
# Layer-specific checks
# ---------------------------------------------------------------------------

class TestRawLayerSuite:
    FILENAME = "raw_layer.json"

    @pytest.fixture(autouse=True)
    def _load(self):
        path = EXPECTATIONS_DIR / self.FILENAME
        if not path.exists():
            pytest.skip(f"{self.FILENAME} not found")
        self.data = _load_suite(path)

    def test_has_table_row_count_expectation(self):
        exp_types = [e["expectation_type"] for e in self.data["expectations"]]
        assert "expect_table_row_count_to_be_between" in exp_types, (
            "Raw layer should validate row count bounds"
        )

    def test_has_not_null_expectations(self):
        exp_types = [e["expectation_type"] for e in self.data["expectations"]]
        assert "expect_column_values_to_not_be_null" in exp_types, (
            "Raw layer should have not-null checks"
        )


class TestStagingLayerSuite:
    FILENAME = "staging_layer.json"

    @pytest.fixture(autouse=True)
    def _load(self):
        path = EXPECTATIONS_DIR / self.FILENAME
        if not path.exists():
            pytest.skip(f"{self.FILENAME} not found")
        self.data = _load_suite(path)

    def test_has_uniqueness_check(self):
        exp_types = [e["expectation_type"] for e in self.data["expectations"]]
        uniqueness_types = {"expect_column_values_to_be_unique", "expect_compound_columns_to_be_unique"}
        assert uniqueness_types & set(exp_types), (
            "Staging layer should have uniqueness constraints"
        )


class TestCuratedLayerSuite:
    FILENAME = "curated_layer.json"

    @pytest.fixture(autouse=True)
    def _load(self):
        path = EXPECTATIONS_DIR / self.FILENAME
        if not path.exists():
            pytest.skip(f"{self.FILENAME} not found")
        self.data = _load_suite(path)

    def test_has_value_set_or_regex_expectations(self):
        exp_types = [e["expectation_type"] for e in self.data["expectations"]]
        curated_types = {
            "expect_column_values_to_be_in_set",
            "expect_column_values_to_match_regex",
            "expect_column_values_to_be_between",
        }
        assert curated_types & set(exp_types), (
            "Curated layer should have value-quality constraints"
        )
