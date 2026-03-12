##
## Open Lakehouse Platform — Root Makefile
##
## Usage:
##   make dev-up          Start full local dev stack + run all bootstrap scripts
##   make dev-down        Stop and remove all containers + volumes
##   make dev-logs        Tail logs from all services
##   make seed            Seed sample Iceberg tables
##   make health          Check health of all services
##   make test            Run all test suites (unit + integration + e2e)
##   make test-unit       Run unit tests only
##   make test-integration Run integration tests only
##   make test-e2e        Run end-to-end tests only
##   make lint            Run linters (Python: ruff + black; YAML; shell)
##   make clean           Full teardown — removes containers, volumes, TLS certs
##

SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

COMPOSE_FILE := local/docker-compose.yml
COMPOSE      := docker compose -f $(COMPOSE_FILE)
BOOTSTRAP    := scripts/bootstrap
ENV_FILE     := local/.env

# Colour helpers
BOLD := \033[1m
RESET := \033[0m
GREEN := \033[32m
YELLOW := \033[33m
RED := \033[31m

# ─── Guards ───────────────────────────────────────────────────────────────────
.PHONY: _require-env
_require-env:
	@if [ ! -f "$(ENV_FILE)" ]; then \
		echo "$(RED)ERROR: $(ENV_FILE) not found.$(RESET)"; \
		echo "Copy local/.env.example → local/.env and fill in secrets."; \
		exit 1; \
	fi

# ─── dev-up ───────────────────────────────────────────────────────────────────
.PHONY: dev-up
dev-up: _require-env  ## Start the full local dev stack
	@echo "$(BOLD)$(GREEN)▶  Starting Open Lakehouse Platform...$(RESET)"
	@echo ""

	@# Ensure all bootstrap scripts are executable
	@chmod +x $(BOOTSTRAP)/0*.sh

	@# Step 0 — Generate TLS certs (idempotent)
	@echo "$(YELLOW)──[ Step 0/7 ] TLS certificate generation$(RESET)"
	@$(BOOTSTRAP)/00-init-tls.sh
	@echo ""

	@# Bring core infrastructure up (deps-only first pass)
	@echo "$(YELLOW)──[ Compose ] Starting infrastructure services...$(RESET)"
	$(COMPOSE) up -d \
		postgresql pgbouncer \
		minio-1 minio-2 minio-3 minio-4 \
		openbao-1 openbao-2 openbao-3
	@echo ""

	@# Step 1 — OpenBao init (Raft cluster + secrets)
	@echo "$(YELLOW)──[ Step 1/7 ] OpenBao Raft init + secrets$(RESET)"
	@$(BOOTSTRAP)/01-init-openbao.sh
	@echo ""

	@# Bring Keycloak and remaining services up
	@echo "$(YELLOW)──[ Compose ] Starting identity + catalog services...$(RESET)"
	$(COMPOSE) up -d keycloak solr
	@echo ""

	@# Step 2 — Keycloak realm
	@echo "$(YELLOW)──[ Step 2/7 ] Keycloak realm + OIDC clients$(RESET)"
	@$(BOOTSTRAP)/02-init-keycloak.sh
	@echo ""

	@# Step 3 — MinIO buckets + service accounts
	@echo "$(YELLOW)──[ Step 3/7 ] MinIO buckets + service accounts$(RESET)"
	@$(BOOTSTRAP)/03-init-minio.sh
	@echo ""

	@# Bring Polaris + Nessie + Ranger
	@echo "$(YELLOW)──[ Compose ] Starting catalog + security services...$(RESET)"
	$(COMPOSE) up -d polaris nessie ranger-admin
	@echo ""

	@# Step 4 — Polaris catalog + principals
	@echo "$(YELLOW)──[ Step 4/7 ] Polaris catalog setup$(RESET)"
	@$(BOOTSTRAP)/04-init-polaris.sh
	@echo ""

	@# Step 5 — Ranger plugin + policies
	@echo "$(YELLOW)──[ Step 5/7 ] Ranger plugin + access policies$(RESET)"
	@$(BOOTSTRAP)/05-init-ranger.sh
	@echo ""

	@# Bring Trino cluster + gateway
	@echo "$(YELLOW)──[ Compose ] Starting Trino cluster...$(RESET)"
	$(COMPOSE) up -d \
		trino-coordinator trino-worker-1 trino-worker-2 trino-worker-3 \
		trino-gateway
	@echo ""

	@# Bring remaining services
	@echo "$(YELLOW)──[ Compose ] Starting remaining services...$(RESET)"
	$(COMPOSE) up -d \
		elasticsearch redis \
		openmetadata-server openmetadata-ingestion \
		airflow-webserver airflow-scheduler airflow-worker \
		docling-api \
		prometheus alertmanager grafana loki promtail otel-collector
	@echo ""

	@# Step 6 — OpenMetadata connectors
	@echo "$(YELLOW)──[ Step 6/7 ] OpenMetadata connectors$(RESET)"
	@$(BOOTSTRAP)/06-init-openmetadata.sh
	@echo ""

	@# Step 7 — Seed Iceberg tables
	@echo "$(YELLOW)──[ Step 7/7 ] Seed sample Iceberg tables$(RESET)"
	@$(BOOTSTRAP)/07-seed-data.sh
	@echo ""

	@echo "$(BOLD)$(GREEN)✓  Open Lakehouse Platform is up!$(RESET)"
	@echo ""
	@echo "Service endpoints:"
	@echo "  Trino Gateway    : http://localhost:8080"
	@echo "  Trino UI         : http://localhost:8090"
	@echo "  Ranger Admin     : http://localhost:6080"
	@echo "  Keycloak Admin   : http://localhost:8080/admin  (admin / \$$KEYCLOAK_ADMIN_PASSWORD)"
	@echo "  MinIO Console    : http://localhost:9001       (\$$MINIO_ROOT_USER / \$$MINIO_ROOT_PASSWORD)"
	@echo "  Polaris API      : http://localhost:8181"
	@echo "  Nessie API       : http://localhost:19120"
	@echo "  OpenMetadata     : http://localhost:8585"
	@echo "  Airflow          : http://localhost:8091"
	@echo "  Docling          : http://localhost:5001"
	@echo "  Grafana          : http://localhost:3000       (admin / \$$GRAFANA_ADMIN_PASSWORD)"
	@echo "  Prometheus       : http://localhost:9092"
	@echo "  Alertmanager     : http://localhost:9093"
	@echo "  Loki             : http://localhost:3100"
	@echo "  OpenBao API      : http://localhost:8200"

# ─── dev-down ─────────────────────────────────────────────────────────────────
.PHONY: dev-down
dev-down:  ## Stop all containers and remove volumes
	@echo "$(BOLD)$(RED)▶  Stopping Open Lakehouse Platform...$(RESET)"
	$(COMPOSE) down --remove-orphans -v
	@echo "$(GREEN)✓  All containers and volumes removed.$(RESET)"

# ─── dev-restart ──────────────────────────────────────────────────────────────
.PHONY: dev-restart
dev-restart: dev-down dev-up  ## Full restart (down + up)

# ─── dev-logs ─────────────────────────────────────────────────────────────────
.PHONY: dev-logs
dev-logs:  ## Tail logs from all services (Ctrl-C to stop)
	$(COMPOSE) logs -f --tail=100

.PHONY: dev-logs-%
dev-logs-%:  ## Tail logs from a specific service, e.g. make dev-logs-trino-coordinator
	$(COMPOSE) logs -f --tail=200 $*

# ─── seed ─────────────────────────────────────────────────────────────────────
.PHONY: seed
seed: _require-env  ## Re-seed sample Iceberg tables
	@chmod +x $(BOOTSTRAP)/07-seed-data.sh
	@$(BOOTSTRAP)/07-seed-data.sh

# ─── health ───────────────────────────────────────────────────────────────────
.PHONY: health
health:  ## Check health status of all compose services
	@echo "$(BOLD)Service health check:$(RESET)"
	@$(COMPOSE) ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}"

# ─── ps ───────────────────────────────────────────────────────────────────────
.PHONY: ps
ps:  ## Show running containers
	@$(COMPOSE) ps

# ─── Tests ────────────────────────────────────────────────────────────────────
.PHONY: test
test: test-unit test-integration test-e2e  ## Run all test suites

.PHONY: test-unit
test-unit:  ## Run unit tests
	@echo "$(BOLD)Running unit tests...$(RESET)"
	@if [ -d tests/unit ]; then \
		python -m pytest tests/unit/ -v --tb=short; \
	else \
		echo "No unit tests found in tests/unit/"; \
	fi

.PHONY: test-integration
test-integration: _require-env  ## Run integration tests (requires running stack)
	@echo "$(BOLD)Running integration tests...$(RESET)"
	@if [ -d tests/integration ]; then \
		python -m pytest tests/integration/ -v --tb=short \
			--timeout=120 \
			--env-file local/.env; \
	else \
		echo "No integration tests found in tests/integration/"; \
	fi

.PHONY: test-e2e
test-e2e: _require-env  ## Run end-to-end tests (requires running stack)
	@echo "$(BOLD)Running e2e tests...$(RESET)"
	@if [ -d tests/e2e ]; then \
		python -m pytest tests/e2e/ -v --tb=short \
			--timeout=300 \
			--env-file local/.env; \
	else \
		echo "No e2e tests found in tests/e2e/"; \
	fi

# ─── Linting ──────────────────────────────────────────────────────────────────
.PHONY: lint
lint: lint-python lint-yaml lint-shell  ## Run all linters

.PHONY: lint-python
lint-python:  ## Lint Python files with ruff + black
	@echo "$(BOLD)Linting Python...$(RESET)"
	@if command -v ruff &>/dev/null; then \
		ruff check . --fix; \
	else \
		echo "ruff not found — skipping. Install: pip install ruff"; \
	fi
	@if command -v black &>/dev/null; then \
		black --check .; \
	else \
		echo "black not found — skipping. Install: pip install black"; \
	fi

.PHONY: lint-yaml
lint-yaml:  ## Lint YAML files with yamllint
	@echo "$(BOLD)Linting YAML...$(RESET)"
	@if command -v yamllint &>/dev/null; then \
		yamllint -d relaxed local/volumes/ local/docker-compose*.yml; \
	else \
		echo "yamllint not found — skipping. Install: pip install yamllint"; \
	fi

.PHONY: lint-shell
lint-shell:  ## Lint shell scripts with shellcheck
	@echo "$(BOLD)Linting shell scripts...$(RESET)"
	@if command -v shellcheck &>/dev/null; then \
		find scripts/ -name '*.sh' -exec shellcheck -S warning {} +; \
	else \
		echo "shellcheck not found — skipping. Install: apt install shellcheck"; \
	fi

# ─── clean ────────────────────────────────────────────────────────────────────
.PHONY: clean
clean:  ## Full teardown — containers, volumes, TLS certs, temp files
	@echo "$(BOLD)$(RED)▶  Full clean (containers + volumes + TLS certs)$(RESET)"
	@echo "This will destroy ALL local data. Are you sure? [y/N] " && read ans && [ $${ans:-N} = y ]
	$(COMPOSE) down --remove-orphans -v 2>/dev/null || true
	@echo "Removing TLS certs..."
	@rm -rf local/volumes/tls/
	@echo "Removing OpenBao init output..."
	@rm -f .openbao-init-output.json
	@echo "Removing mc alias..."
	@rm -f ~/.mc/config.json 2>/dev/null || true
	@echo "Removing downloaded binaries..."
	@rm -rf .bin/
	@echo "Removing Python caches..."
	@find . -type d -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true
	@find . -name '*.pyc' -delete 2>/dev/null || true
	@echo "$(GREEN)✓  Clean complete.$(RESET)"

.PHONY: clean-certs
clean-certs:  ## Regenerate TLS certificates only
	@echo "Removing TLS certs..."
	@rm -rf local/volumes/tls/
	@chmod +x $(BOOTSTRAP)/00-init-tls.sh
	@$(BOOTSTRAP)/00-init-tls.sh

# ─── Docker helpers ───────────────────────────────────────────────────────────
.PHONY: pull
pull:  ## Pull all Docker images defined in docker-compose.yml
	$(COMPOSE) pull

.PHONY: build
build:  ## Build any custom images (no-op if using only upstream images)
	$(COMPOSE) build

# ─── Observability override ───────────────────────────────────────────────────
.PHONY: observability-up
observability-up: _require-env  ## Start observability stack standalone
	docker compose \
		-f local/docker-compose.yml \
		-f local/docker-compose.observability.yml \
		up -d prometheus alertmanager grafana loki promtail otel-collector

.PHONY: observability-down
observability-down:  ## Stop observability stack
	docker compose \
		-f local/docker-compose.yml \
		-f local/docker-compose.observability.yml \
		down --remove-orphans

# ─── Quick-access shells ─────────────────────────────────────────────────────
.PHONY: shell-%
shell-%:  ## Open a shell in a running container, e.g. make shell-postgresql
	$(COMPOSE) exec $* /bin/bash 2>/dev/null || $(COMPOSE) exec $* /bin/sh

.PHONY: trino-cli
trino-cli:  ## Connect to Trino via CLI
	$(COMPOSE) exec trino-coordinator trino --server http://localhost:8080 --user admin

.PHONY: psql
psql:  ## Open psql connected to PostgreSQL
	$(COMPOSE) exec postgresql psql -U postgres

# ─── Validation deployment (Oracle Cloud Always Free) ───────────────────────────
.PHONY: validate-up
validate-up:  ## Deploy full stack on a single ARM64 node (Oracle Cloud Always Free)
	@echo "$(BOLD)$(GREEN)▶  Deploying validation stack on k3s...$(RESET)"
	k3s kubectl create namespace lakehouse-system 2>/dev/null || true
	helm install lakehouse ./helm/charts/lakehouse-core \
		--namespace lakehouse-system \
		--values helm/charts/lakehouse-core/values.yaml \
		--values helm/charts/lakehouse-core/values.validation.yaml \
		--timeout 10m --wait
	@echo "$(GREEN)✓  Validation stack deployed.$(RESET)"

.PHONY: validate-test
validate-test:  ## Run unit + integration tests against the validation stack
	@echo "$(BOLD)Running unit + integration tests...$(RESET)"
	python -m pytest tests/unit/ tests/integration/ -v \
		--timeout=120 \
		--ignore=tests/performance/

.PHONY: validate-e2e
validate-e2e:  ## Run e2e tests against the validation stack (excludes DR tests)
	@echo "$(BOLD)Running e2e tests...$(RESET)"
	python -m pytest tests/e2e/ -v \
		--timeout=300 \
		--ignore=tests/e2e/test_disaster_recovery.py

.PHONY: validate-dr
validate-dr:  ## Run disaster-recovery e2e tests (long-running, opt-in)
	@echo "$(BOLD)Running DR tests...$(RESET)"
	python -m pytest tests/e2e/test_disaster_recovery.py -v --run-dr

.PHONY: validate-all
validate-all: validate-test validate-e2e  ## Run all validation test suites (unit + integration + e2e)

# ─── help ─────────────────────────────────────────────────────────────────────
.PHONY: help
help:  ## Show this help message
	@echo "$(BOLD)Open Lakehouse Platform — available targets:$(RESET)"
	@echo ""
	@grep -E '^[a-zA-Z_%-]+:.*##' $(MAKEFILE_LIST) | \
		sed 's/\(.*\):.*##\s*/  make \1\t/' | \
		column -t -s $$'\t' | \
		sort
	@echo ""
