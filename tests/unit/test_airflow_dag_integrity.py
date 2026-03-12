"""
Unit tests — Airflow DAG integrity checks.

Imports every DAG Python file under airflow/dags/ and verifies:
  - File is importable without errors
  - DAG object is present
  - Required metadata is set (owner, retries, email_on_failure)
  - DAG has no import cycles between tasks
  - start_date is set and is a valid datetime
"""

from __future__ import annotations

import importlib.util
import os
import sys
from pathlib import Path
from types import ModuleType
from typing import Any

import pytest

DAGS_DIR = Path(__file__).parents[2] / "airflow" / "dags"


def _discover_dag_files() -> list[Path]:
    if not DAGS_DIR.exists():
        return []
    return sorted(DAGS_DIR.rglob("*.py"))


def _import_module_from_path(path: Path) -> ModuleType:
    """Import a Python file as a module without adding it to sys.modules permanently."""
    spec = importlib.util.spec_from_file_location(path.stem, path)
    mod = importlib.util.module_from_spec(spec)
    # Add a stub for airflow imports if not available
    spec.loader.exec_module(mod)
    return mod


def _has_airflow() -> bool:
    try:
        from airflow.models import DAG  # noqa: F401
        from airflow.operators.python import PythonOperator  # noqa: F401
        return True
    except (ImportError, AttributeError):
        return False


DAG_FILES = _discover_dag_files()

# ---------------------------------------------------------------------------
# Skip entire module if airflow not installed or dags/ not present
# ---------------------------------------------------------------------------

pytestmark = pytest.mark.skipif(
    not _has_airflow() or not DAGS_DIR.exists(),
    reason="Airflow not installed or airflow/dags/ not found",
)


# ---------------------------------------------------------------------------
# Static analysis (no Airflow required) — YAML / metadata / syntax checks
# ---------------------------------------------------------------------------

class TestDAGFileStaticAnalysis:

    @pytest.fixture(autouse=True)
    def _ensure_dags_exist(self):
        if not DAGS_DIR.exists():
            pytest.skip("airflow/dags/ not found")

    def test_dags_directory_has_files(self):
        files = _discover_dag_files()
        assert len(files) >= 5, f"Expected at least 5 DAG files, found {len(files)}"

    @pytest.mark.parametrize("dag_path", _discover_dag_files())
    def test_python_syntax(self, dag_path: Path):
        """DAG file must have valid Python syntax."""
        import ast
        source = dag_path.read_text(encoding="utf-8")
        try:
            ast.parse(source)
        except SyntaxError as exc:
            pytest.fail(f"{dag_path.name} has syntax error: {exc}")

    @pytest.mark.parametrize("dag_path", _discover_dag_files())
    def test_contains_dag_definition(self, dag_path: Path):
        """File must contain a DAG definition (DAG( or @dag)."""
        content = dag_path.read_text(encoding="utf-8")
        has_dag = "DAG(" in content or "@dag" in content
        assert has_dag, f"{dag_path.name}: no DAG definition found"

    @pytest.mark.parametrize("dag_path", _discover_dag_files())
    def test_has_owner_set(self, dag_path: Path):
        content = dag_path.read_text(encoding="utf-8")
        assert "owner" in content, f"{dag_path.name}: 'owner' not set in default_args"

    @pytest.mark.parametrize("dag_path", _discover_dag_files())
    def test_has_retries_set(self, dag_path: Path):
        content = dag_path.read_text(encoding="utf-8")
        assert "retries" in content, f"{dag_path.name}: 'retries' not set in default_args"

    @pytest.mark.parametrize("dag_path", _discover_dag_files())
    def test_has_start_date(self, dag_path: Path):
        content = dag_path.read_text(encoding="utf-8")
        assert "start_date" in content, f"{dag_path.name}: 'start_date' not set"

    @pytest.mark.parametrize("dag_path", _discover_dag_files())
    def test_email_on_failure_configured(self, dag_path: Path):
        content = dag_path.read_text(encoding="utf-8")
        assert "email_on_failure" in content, (
            f"{dag_path.name}: 'email_on_failure' must be specified in default_args"
        )

    @pytest.mark.parametrize("dag_path", _discover_dag_files())
    def test_no_hardcoded_passwords(self, dag_path: Path):
        """DAGs must not contain plaintext passwords or tokens."""
        content = dag_path.read_text(encoding="utf-8")
        forbidden = ["password=", "secret=", "token=", "api_key="]
        for pattern in forbidden:
            # Allow variable references like password=Variable.get(...)
            if pattern in content.lower():
                # Check it's not a literal string assignment
                import re
                matches = re.findall(
                    rf'{re.escape(pattern)}"[^"{{]', content.lower()
                )
                assert not matches, (
                    f"{dag_path.name}: possible hardcoded credential with pattern '{pattern}'"
                )

    @pytest.mark.parametrize("dag_path", _discover_dag_files())
    def test_uses_variable_or_connection_for_config(self, dag_path: Path):
        """DAGs should pull config from Airflow Variables/Connections or env vars."""
        content = dag_path.read_text(encoding="utf-8")
        uses_config = any(
            kw in content for kw in
            ["Variable.get", "os.environ", "BaseHook.get_connection", "conn_id"]
        )
        # Maintenance/simple DAGs may not need external config — soft check
        if "maintenance" not in str(dag_path):
            assert uses_config, (
                f"{dag_path.name}: should use Airflow Variables/Connections for configuration"
            )


# ---------------------------------------------------------------------------
# Import-time tests (requires Airflow installed)
# ---------------------------------------------------------------------------

class TestDAGImport:

    @pytest.fixture(autouse=True)
    def _require_airflow(self):
        if not _has_airflow():
            pytest.skip("Airflow not installed")
        if not DAGS_DIR.exists():
            pytest.skip("airflow/dags/ not found")

    @pytest.mark.parametrize("dag_path", _discover_dag_files())
    def test_dag_imports_without_error(self, dag_path: Path, monkeypatch):
        """DAG file must be importable — no import errors."""
        # Add dags dir to path so relative imports work
        monkeypatch.syspath_prepend(str(DAGS_DIR))
        try:
            _import_module_from_path(dag_path)
        except Exception as exc:
            pytest.fail(f"{dag_path.name} raised on import: {exc}")

    @pytest.mark.parametrize("dag_path", _discover_dag_files())
    def test_dag_object_is_dag_instance(self, dag_path: Path, monkeypatch):
        """The module must expose at least one airflow.models.DAG instance."""
        from airflow.models import DAG as AirflowDAG

        monkeypatch.syspath_prepend(str(DAGS_DIR))
        try:
            mod = _import_module_from_path(dag_path)
        except Exception as exc:
            pytest.skip(f"Could not import {dag_path.name}: {exc}")

        dag_objects = [v for v in vars(mod).values() if isinstance(v, AirflowDAG)]
        assert dag_objects, f"{dag_path.name}: no DAG object found after import"

    @pytest.mark.parametrize("dag_path", _discover_dag_files())
    def test_dag_has_no_cycle(self, dag_path: Path, monkeypatch):
        """TaskGroup / task graph must be a DAG (no cycles)."""
        from airflow.models import DAG as AirflowDAG

        monkeypatch.syspath_prepend(str(DAGS_DIR))
        try:
            mod = _import_module_from_path(dag_path)
        except Exception as exc:
            pytest.skip(f"Could not import {dag_path.name}: {exc}")

        for attr in vars(mod).values():
            if isinstance(attr, AirflowDAG):
                # Calling test_cycle raises if cycle detected
                try:
                    attr.test_cycle()
                except Exception as exc:
                    pytest.fail(f"{dag_path.name}: cycle detected in DAG '{attr.dag_id}': {exc}")
