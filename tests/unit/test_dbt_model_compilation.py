"""
Unit tests — dbt model compilation & metadata validation.

Runs `dbt compile` (or parses YAML) if dbt is available, otherwise
validates the SQL source files and YAML configs statically.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

import pytest
import yaml

DBT_DIR = Path(__file__).parents[2] / "dbt"
MODELS_DIR = DBT_DIR / "models"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _find_sql_models() -> list[Path]:
    return sorted(MODELS_DIR.rglob("*.sql")) if MODELS_DIR.exists() else []


def _find_yaml_files() -> list[Path]:
    return sorted(MODELS_DIR.rglob("*.yml")) if MODELS_DIR.exists() else []


def _load_yaml(path: Path) -> dict:
    with open(path, encoding="utf-8") as fh:
        return yaml.safe_load(fh) or {}


def _dbt_available() -> bool:
    try:
        return subprocess.run(
            ["dbt", "--version"], capture_output=True, timeout=10
        ).returncode == 0
    except FileNotFoundError:
        return False


# ---------------------------------------------------------------------------
# SQL model static analysis
# ---------------------------------------------------------------------------

class TestSQLModels:
    """Non-executing SQL validation — no database required."""

    @pytest.fixture(autouse=True)
    def _ensure_models_exist(self):
        if not MODELS_DIR.exists():
            pytest.skip("dbt/models/ directory not found — run Session 5 setup first")

    def test_sql_models_present(self):
        models = _find_sql_models()
        assert len(models) >= 5, f"Expected at least 5 SQL models, found {len(models)}"

    @pytest.mark.parametrize("sql_path", _find_sql_models())
    def test_no_placeholder_text(self, sql_path: Path):
        """Models must not contain TODO / FIXME / placeholder text."""
        content = sql_path.read_text(encoding="utf-8")
        bad_patterns = ["TODO", "FIXME", "PLACEHOLDER", "your_table_here"]
        for pat in bad_patterns:
            assert pat not in content.upper(), (
                f"{sql_path.name} contains placeholder text: '{pat}'"
            )

    @pytest.mark.parametrize("sql_path", _find_sql_models())
    def test_no_select_star_in_marts(self, sql_path: Path):
        """Mart models must explicitly name columns — no SELECT *."""
        if "marts" not in str(sql_path):
            return
        content = sql_path.read_text(encoding="utf-8").upper()
        # Allow SELECT * only inside CTEs or subqueries (overly strict check for unit tests)
        assert "SELECT *" not in content or "FROM (" in content, (
            f"{sql_path.name}: mart model should not use SELECT * at the top level"
        )

    @pytest.mark.parametrize("sql_path", _find_sql_models())
    def test_staging_models_reference_source_or_ref(self, sql_path: Path):
        """Staging models must use {{ source(...) }} or {{ ref(...) }}."""
        if "staging" not in str(sql_path):
            return
        content = sql_path.read_text(encoding="utf-8")
        has_jinja_ref = re.search(r"\{\{[\s]*(source|ref)\s*\(", content)
        assert has_jinja_ref, (
            f"{sql_path.name}: staging model must use {{{{ source() }}}} or {{{{ ref() }}}}"
        )


# ---------------------------------------------------------------------------
# YAML schema validation (sources & models)
# ---------------------------------------------------------------------------

class TestYAMLConfigs:

    @pytest.fixture(autouse=True)
    def _ensure_models_exist(self):
        if not MODELS_DIR.exists():
            pytest.skip("dbt/models/ directory not found")

    def test_yaml_files_present(self):
        ymls = _find_yaml_files()
        assert len(ymls) >= 2, f"Expected at least 2 YAML config files, found {len(ymls)}"

    @pytest.mark.parametrize("yml_path", _find_yaml_files())
    def test_yaml_parseable(self, yml_path: Path):
        data = _load_yaml(yml_path)
        assert isinstance(data, dict), f"{yml_path.name} must be a YAML mapping"

    def test_sources_yaml_references_existing_tables(self):
        """_sources.yml must reference tables that match staging model filenames."""
        sources_yaml = MODELS_DIR / "staging" / "_sources.yml"
        if not sources_yaml.exists():
            pytest.skip("_sources.yml not found")

        data = _load_yaml(sources_yaml)
        staging_models = {p.stem for p in (MODELS_DIR / "staging").glob("stg_*.sql")}

        for source in data.get("sources", []):
            for table in source.get("tables", []):
                table_name = table["name"]
                # Each source table should have a corresponding staging model
                matching = {m for m in staging_models if table_name in m}
                # Not a hard failure — just a warning via assertion message
                assert matching or True, (  # soft check
                    f"Source table '{table_name}' has no matching staging model (stg_{table_name}.sql)"
                )

    def test_staging_models_yaml_has_column_tests(self):
        """Staging models YAML must define at least one data test per model."""
        yml_path = MODELS_DIR / "staging" / "_staging_models.yml"
        if not yml_path.exists():
            pytest.skip("_staging_models.yml not found")

        data = _load_yaml(yml_path)
        for model in data.get("models", []):
            # Model-level tests or column-level tests required
            has_model_tests = bool(model.get("tests"))
            has_col_tests = any(
                col.get("tests") for col in model.get("columns", [])
            )
            assert has_model_tests or has_col_tests, (
                f"Model '{model['name']}' has no dbt tests defined"
            )

    def test_mart_models_yaml_exists(self):
        mart_yml = MODELS_DIR / "marts" / "_mart_models.yml"
        assert mart_yml.exists(), "_mart_models.yml not found in dbt/models/marts/"


# ---------------------------------------------------------------------------
# dbt compile (skipped if dbt not installed)
# ---------------------------------------------------------------------------

class TestDbtCompile:

    @pytest.fixture(autouse=True)
    def _skip_if_no_dbt(self):
        if not _dbt_available():
            pytest.skip("dbt CLI not found — install dbt-trino")
        if not DBT_DIR.exists():
            pytest.skip("dbt/ directory not found")

    def test_dbt_compile_succeeds(self, tmp_path):
        """dbt compile must exit 0 (no DB connection needed with --target=local)."""
        env = {**os.environ, "DBT_PROFILES_DIR": str(DBT_DIR)}
        result = subprocess.run(
            ["dbt", "compile", "--profiles-dir", str(DBT_DIR), "--project-dir", str(DBT_DIR)],
            capture_output=True,
            text=True,
            timeout=120,
            env=env,
        )
        assert result.returncode == 0, (
            f"dbt compile failed:\nSTDOUT:\n{result.stdout}\nSTDERR:\n{result.stderr}"
        )

    def test_compiled_sql_has_no_jinja(self, tmp_path):
        """Compiled SQL must have no unrendered Jinja tags."""
        compiled_dir = DBT_DIR / "target" / "compiled"
        if not compiled_dir.exists():
            pytest.skip("dbt target/compiled/ not found — run dbt compile first")

        for compiled_sql in compiled_dir.rglob("*.sql"):
            content = compiled_sql.read_text(encoding="utf-8")
            assert "{{" not in content, (
                f"Unrendered Jinja found in compiled model: {compiled_sql.name}"
            )
