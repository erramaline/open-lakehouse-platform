# Définitions SLO — Open Lakehouse Platform

## Vue d'ensemble

Ce document définit les **Service Level Objectives (SLOs)** de la plateforme, associés aux **SLIs (Indicators)** Prometheus correspondants et aux **Error Budgets** résultants.

Les SLOs sont exprimés sur une fenêtre glissante de **28 jours** (conforme aux meilleures pratiques Google SRE).

---

## 1. Catalogue SLO

### SLO-01 — Disponibilité Trino Query Engine

| Attribut | Valeur |
|----------|--------|
| **SLO** | 99,5 % de requêtes Trino terminées avec succès |
| **Fenêtre** | 28 jours glissants |
| **Error Budget** | 0,5 % = ~3h 21min d'indisponibilité/28j |
| **Seuil d'alerte** | Consommation > 50 % du budget sur 1h → PagerDuty |

**SLI — Taux de succès des requêtes :**
```promql
# Requêtes réussies / total requêtes
sum(rate(trino_query_completed_total{state="finished"}[5m]))
/
sum(rate(trino_query_completed_total[5m]))
```

**Recording rule :**
```yaml
- record: slo:trino_query_success_rate:ratio_rate5m
  expr: |
    sum(rate(trino_query_completed_total{state="finished"}[5m]))
    /
    sum(rate(trino_query_completed_total[5m]))
```

---

### SLO-02 — Latence Trino P99

| Attribut | Valeur |
|----------|--------|
| **SLO** | 95 % des requêtes Trino < 60 s (P99 < 120 s) |
| **Fenêtre** | 28 jours glissants |
| **Error Budget** | 5 % des requêtes peuvent dépasser 60 s |

**SLI — Ratio requêtes dans le budget de latence :**
```promql
# Requêtes terminées sous 60s / total
sum(rate(trino_query_execution_time_bucket{le="60000"}[5m]))
/
sum(rate(trino_query_execution_time_count[5m]))
```

**Recording rule :**
```yaml
- record: slo:trino_query_latency_p99:ratio_rate5m
  expr: |
    histogram_quantile(0.99,
      sum(rate(trino_query_execution_time_bucket[5m])) by (le)
    ) / 1000  # convertir en secondes
```

---

### SLO-03 — Disponibilité Polaris Catalog API

| Attribut | Valeur |
|----------|--------|
| **SLO** | 99,9 % de disponibilité des endpoints REST Iceberg REST Catalog |
| **Fenêtre** | 28 jours glissants |
| **Error Budget** | 0,1 % = ~43 min/28j |

**SLI :**
```promql
# Taux de succès HTTP (2xx) sur l'API catalog
sum(rate(http_server_requests_seconds_count{status=~"2..",service="polaris"}[5m]))
/
sum(rate(http_server_requests_seconds_count{service="polaris"}[5m]))
```

**Recording rule :**
```yaml
- record: slo:polaris_api_availability:ratio_rate5m
  expr: |
    sum(rate(http_server_requests_seconds_count{status=~"2..",service="polaris"}[5m]))
    /
    sum(rate(http_server_requests_seconds_count{service="polaris"}[5m]))
```

---

### SLO-04 — Disponibilité MinIO (Object Storage)

| Attribut | Valeur |
|----------|--------|
| **SLO** | 99,99 % de disponibilité des opérations GET/PUT S3 |
| **Fenêtre** | 28 jours glissants |
| **Error Budget** | 0,01 % = ~4 min/28j |

**SLI :**
```promql
# Opérations S3 réussies / total
(
  sum(rate(minio_s3_requests_total{type=~"putObject|getObject"}[5m]))
  -
  sum(rate(minio_s3_requests_errors_total{type=~"putObject|getObject"}[5m]))
)
/
sum(rate(minio_s3_requests_total{type=~"putObject|getObject"}[5m]))
```

**Recording rule :**
```yaml
- record: slo:minio_s3_availability:ratio_rate5m
  expr: |
    1 - (
      sum(rate(minio_s3_requests_errors_total{type=~"putObject|getObject"}[5m]))
      /
      sum(rate(minio_s3_requests_total{type=~"putObject|getObject"}[5m]))
    )
```

---

### SLO-05 — Disponibilité Keycloak (Authentification)

| Attribut | Valeur |
|----------|--------|
| **SLO** | 99,9 % de disponibilité des endpoints d'authentification OIDC |
| **Fenêtre** | 28 jours glissants |
| **Error Budget** | 0,1 % = ~43 min/28j |

**SLI :**
```promql
# Taux de succès des requêtes token
sum(rate(keycloak_request_duration_count{outcome="success", uri="/realms/lakehouse/protocol/openid-connect/token"}[5m]))
/
sum(rate(keycloak_request_duration_count{uri="/realms/lakehouse/protocol/openid-connect/token"}[5m]))
```

---

### SLO-06 — Fraîcheur des Données (Data Freshness)

| Attribut | Valeur |
|----------|--------|
| **SLO** | 95 % des tables Iceberg de la couche staging mises à jour dans les 4h suivant l'ingestion dans raw |
| **Fenêtre** | 28 jours glissants |

**SLI :**
```promql
# Délai moyen raw → staging (via labels Airflow)
avg(
  airflow_dag_duration_seconds{dag_id=~".*raw_to_staging.*", state="success"}
) < 14400  # 4h en secondes
```

---

### SLO-07 — Disponibilité PostgreSQL

| Attribut | Valeur |
|----------|--------|
| **SLO** | 99,95 % de disponibilité des connexions PostgreSQL |
| **Fenêtre** | 28 jours glissants |
| **Error Budget** | 0,05 % = ~21 min/28j |

**SLI :**
```promql
# Ratio de connexions établies avec succès
1 - (
  sum(rate(pg_stat_database_xact_rollback[5m]))
  /
  (sum(rate(pg_stat_database_xact_commit[5m])) + sum(rate(pg_stat_database_xact_rollback[5m])))
)
```

---

## 2. Règles d'enregistrement (Recording Rules) — Prometheus

```yaml
# helm/charts/observability/templates/prometheus/recording-rules.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: lakehouse-slo-recording-rules
  namespace: lakehouse-obs
  labels:
    prometheus: kube-prometheus
    role: alert-rules
spec:
  groups:
    - name: slo_recording_rules
      interval: 30s
      rules:
        # SLO-01 : Trino availability
        - record: slo:trino_query_success_rate:ratio_rate5m
          expr: |
            sum(rate(trino_query_completed_total{state="finished"}[5m]))
            /
            sum(rate(trino_query_completed_total[5m]))

        - record: slo:trino_query_success_rate:ratio_rate1h
          expr: |
            sum(rate(trino_query_completed_total{state="finished"}[1h]))
            /
            sum(rate(trino_query_completed_total[1h]))

        - record: slo:trino_query_success_rate:ratio_rate6h
          expr: |
            sum(rate(trino_query_completed_total{state="finished"}[6h]))
            /
            sum(rate(trino_query_completed_total[6h]))

        # SLO-02 : Trino P99 latency
        - record: slo:trino_query_p99_latency_seconds:rate5m
          expr: |
            histogram_quantile(0.99,
              sum(rate(trino_query_execution_time_bucket[5m])) by (le)
            ) / 1000

        # SLO-03 : Polaris API availability
        - record: slo:polaris_api_availability:ratio_rate5m
          expr: |
            sum(rate(http_server_requests_seconds_count{status=~"2..",service="polaris"}[5m]))
            /
            sum(rate(http_server_requests_seconds_count{service="polaris"}[5m]))

        # SLO-04 : MinIO availability
        - record: slo:minio_s3_availability:ratio_rate5m
          expr: |
            1 - (
              sum(rate(minio_s3_requests_errors_total{type=~"putObject|getObject"}[5m]))
              /
              (sum(rate(minio_s3_requests_total{type=~"putObject|getObject"}[5m])) + 1)
            )

        # Error budget burn rates (multi-window multi-burn)
        - record: slo:trino_error_budget_burn_rate:ratio_rate1h
          expr: |
            (1 - slo:trino_query_success_rate:ratio_rate1h) / 0.005

        - record: slo:trino_error_budget_burn_rate:ratio_rate6h
          expr: |
            (1 - slo:trino_query_success_rate:ratio_rate6h) / 0.005
```

---

## 3. Alertes SLO (Multi-Burn Rate)

La stratégie **multi-window multi-burn** permet de détecter rapidement les incidents graves tout en évitant les fausse alertes sur des événements courts.

```yaml
  groups:
    - name: slo_alerts
      rules:
        # ----------------------------------------------------------------
        # SLO-01 Trino — Alerte critique (burn rate élevé)
        # Consomme 2% du budget sur 1h → page immédiate
        # ----------------------------------------------------------------
        - alert: TrinoCriticalErrorBudgetBurn
          expr: |
            slo:trino_error_budget_burn_rate:ratio_rate1h > 14.4
            and
            slo:trino_error_budget_burn_rate:ratio_rate6h > 14.4
          for: 2m
          labels:
            severity: critical
            slo: trino-query-availability
          annotations:
            summary: "Trino SLO critique — taux d'erreur trop élevé"
            description: |
              Le burn rate du budget d'erreur Trino est {{ $value }}x
              au-dessus du seuil normal sur 1h et 6h.
              Budget restant estimé : moins de 1h.
            runbook_url: "https://github.com/org/repo/blob/main/docs/runbooks/trino-troubleshooting.md"

        # Alerte warning : burn rate modéré
        - alert: TrinoWarningErrorBudgetBurn
          expr: |
            slo:trino_error_budget_burn_rate:ratio_rate1h > 6
            and
            slo:trino_error_budget_burn_rate:ratio_rate6h > 6
          for: 15m
          labels:
            severity: warning
            slo: trino-query-availability
          annotations:
            summary: "Trino SLO dégradé — burn rate modéré"
            description: |
              Le budget d'erreur Trino est consommé {{ $value }}x plus vite que prévu.

        # ----------------------------------------------------------------
        # SLO-02 Trino — Latence P99
        # ----------------------------------------------------------------
        - alert: TrinoP99LatencyViolation
          expr: slo:trino_query_p99_latency_seconds:rate5m > 120
          for: 10m
          labels:
            severity: warning
            slo: trino-query-latency
          annotations:
            summary: "Latence Trino P99 > 120s"
            description: "P99 = {{ $value | humanizeDuration }}"

        # ----------------------------------------------------------------
        # SLO-04 MinIO
        # ----------------------------------------------------------------
        - alert: MinIOAvailabilityDegraded
          expr: slo:minio_s3_availability:ratio_rate5m < 0.9999
          for: 5m
          labels:
            severity: critical
            slo: minio-s3-availability
          annotations:
            summary: "MinIO S3 availability SLO violated"
            description: "Availability = {{ $value | humanizePercentage }}"
            runbook_url: "https://github.com/org/repo/blob/main/docs/runbooks/storage-recovery.md"
```

---

## 4. Tableau de bord SLO — Grafana

Importer le dashboard **SLO Overview** (ID recommandé) avec les panels :

| Panel | Query | Seuil visuel |
|-------|-------|-------------|
| Trino Availability (28j) | `avg_over_time(slo:trino_query_success_rate:ratio_rate5m[28d])` | Vert > 99,5% |
| Trino P99 Latency | `slo:trino_query_p99_latency_seconds:rate5m` | Jaune > 60s, Rouge > 120s |
| Error Budget Remaining | `1 - (1 - avg_over_time(...[28d])) / 0.005` | Jaune < 50%, Rouge < 10% |
| MinIO Availability | `avg_over_time(slo:minio_s3_availability:ratio_rate5m[28d])` | Vert > 99,99% |

---

## 5. Révision des SLOs

| Fréquence | Activité |
|-----------|----------|
| Hebdomadaire | Revue du burn rate par l'équipe de garde |
| Mensuelle | Rapport SLO vs error budget consommé |
| Trimestrielle | Réévaluation des objectifs selon l'évolution de l'usage |
| Post-incident | Mise à jour des alert thresholds si nécessaire |

### Escalade

| Budget restant | Action |
|----------------|--------|
| > 50% | Normal — aucune action requise |
| 25-50% | Réunion d'examen hebdomadaire, freeze des changements risqués |
| 10-25% | Feature freeze complet, focus stabilité |
| < 10% | Incident déclaré, war room, rollback possible |
| 0% | SLO breach — revue post-mortem obligatoire, communication client |
