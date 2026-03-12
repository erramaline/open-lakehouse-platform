# ADR-010: Multi-Tenancy Model — Namespace Isolation in Trino, Ranger, and Polaris

| Field | Value |
|---|---|
| **Status** | Accepted |
| **Date** | 2026-03-12 |
| **Deciders** | Principal Data Platform Architect, Data Engineering Lead, Security Lead, Data Governance Lead |
| **Tags** | multi-tenancy, rbac, isolation, governance, trino, ranger, polaris |

---

## Context

The platform serves multiple organizational tenants (business units, departments, or external client organizations) from a shared infrastructure. "Tenant" is defined as an organizational entity with its own:

- Data domain (tables and schemas they own)
- Access control boundary (they should not see data from other tenants by default)
- Compute quota (a runaway query from Tenant A should not starve Tenant B)
- Audit identity (all actions must be attributable to a specific tenant + user)

The platform must enforce **logical multi-tenancy** (shared infrastructure, isolated data access) rather than physical multi-tenancy (dedicated cluster per tenant), which would be uneconomical.

Three isolation layers must work in concert:
- **Apache Polaris:** Catalog-level isolation (which tables/warehouses exist per tenant)
- **Apache Ranger:** Authorization isolation (which users/groups can access which tables/columns/rows)
- **Trino:** Compute isolation (which cluster/resource group a tenant's queries run in)

---

## Decision

**We implement three-layer logical multi-tenancy:**

1. **Polaris:** One Warehouse per tenant; namespaces within are tenant-owned.
2. **Ranger:** Row-level filters + column masking + tag-based policies per tenant; no cross-tenant table access without explicit grant.
3. **Trino:** Resource groups per tenant; queries inherit tenant from JWT `tenant_id` claim.

---

## Layer 1: Polaris — Warehouse-per-Tenant

```
Apache Polaris
├── Warehouse: tenant_a
│   ├── Namespace: tenant_a.raw
│   ├── Namespace: tenant_a.staging
│   ├── Namespace: tenant_a.intermediate
│   └── Namespace: tenant_a.marts
│
├── Warehouse: tenant_b
│   ├── Namespace: tenant_b.raw
│   └── Namespace: tenant_b.marts
│
└── Warehouse: shared
    └── Namespace: shared.reference  (cross-tenant reference data — explicitly shared)
```

**Polaris Principal Roles:**

| Principal Role | Warehouse Access | Operations |
|---|---|---|
| `tenant_a_admin` | `tenant_a` W | CREATE/DROP namespace, table; manage roles |
| `tenant_a_engineer` | `tenant_a` W | CREATE/DROP table; read all namespaces in warehouse |
| `tenant_a_analyst` | `tenant_a.marts` R | SELECT metadata only (data access via Ranger) |
| `tenant_b_admin` | `tenant_b` W | Same as above, scoped to tenant_b |
| `platform_admin` | ALL warehouses | Full privileges |

**Storage isolation:** Each tenant warehouse is backed by a dedicated MinIO path prefix (`s3://lakehouse-data/tenant-a/`) with a dedicated MinIO service account. Polaris credentials vending returns tenant-specific S3 credentials. Trino workers use these credentials to access only the tenant's data — cross-tenant S3 path access is blocked at the MinIO policy level.

---

## Layer 2: Ranger — Fine-Grained Access Control

**Ranger policy structure per tenant:**

### Resource-Based Policies

```
Policy: tenant_a_marts_select
  Resources:
    catalog: trino
    schema: tenant_a.marts
    table: *  (or specific tables)
  Access Type: SELECT
  Allow Conditions:
    Groups: [tenant_a_analysts, tenant_a_engineers]
  Deny Conditions:
    Groups: [tenant_b_analysts]  (explicit deny overrides)
```

### Row-Level Filters

Applied per table where cross-tenant rows co-exist in a shared table (e.g., a shared events table):

```
Policy: row_filter_events_by_tenant
  Resource: catalog=trino, schema=shared, table=events
  Row Filter:
    Condition: tenant_id = CURRENT_USER_ATTR('tenant_id')
    Groups: [all — except platform_admins]
```

The `tenant_id` is injected by Trino from the JWT claim `tenant_id` (see ADR-007). Ranger evaluates the filter expression at query time — each user automatically filters to their own tenant's rows without any query modification by the user.

### Column Masking

PII columns are masked per data classification tag:

```
Policy: mask_pii_for_non_privileged
  Tags: PII_HIGH (applied in OpenMetadata, synced to Ranger)
  Mask Type: NULLIFY (for analysts)
             PARTIAL_MASK (last 4 chars visible for support tier)
             NO_MASK (for platform_admins, data_stewards with explicit grant)
  Groups:
    - data_analysts: NULLIFY
    - support_tier: PARTIAL_MASK
    - data_stewards: NO_MASK
```

### Deny-First Default

All Ranger policies default to **deny**. A resource must have at least one explicit ALLOW policy to be accessible. No "default allow" exists.

---

## Layer 3: Trino — Resource Groups and Compute Isolation

### Resource Group Configuration

```json
{
  "rootGroups": [
    {
      "name": "tenant_a",
      "maxQueued": 100,
      "hardConcurrencyLimit": 20,
      "softMemoryLimit": "40%",
      "schedulingPolicy": "fair",
      "subGroups": [
        { "name": "interactive", "hardConcurrencyLimit": 15, "softMemoryLimit": "30%" },
        { "name": "etl", "hardConcurrencyLimit": 5, "softMemoryLimit": "10%", "schedulingPolicy": "fifo" }
      ]
    },
    {
      "name": "tenant_b",
      "maxQueued": 50,
      "hardConcurrencyLimit": 10,
      "softMemoryLimit": "20%",
      "schedulingPolicy": "fair"
    },
    {
      "name": "shared",
      "maxQueued": 20,
      "hardConcurrencyLimit": 5,
      "softMemoryLimit": "10%"
    }
  ]
}
```

**Resource group selector:** Queries are assigned to a resource group based on the JWT `tenant_id` claim (passed to Trino via `X-Trino-User-Context` or via a custom `ResourceGroupSelector` implementation that reads from JWT claims stored in the session).

**Why resource groups instead of separate clusters per tenant?**
- Dedicated clusters per tenant would require N × (coordinator + worker pool), multiplying infrastructure cost by N.
- Resource groups provide fair-share scheduling within a shared cluster — Tenant B's heavy ETL job cannot starve Tenant A's interactive queries.
- At scale (> 10 tenants), dedicated clusters may be warranted for top-tier tenants; Trino Gateway can route by tenant to dedicated clusters if/when needed (configuration change, no architectural rework).

---

## Cross-Tenant Access Model

**Default:** No cross-tenant access. Ranger denies all cross-tenant resource access by default.

**Controlled sharing via explicit grants:**

```
Scenario: Tenant A wants to share their reference_products table with Tenant B analysts

1. Tenant A's data owner submits a sharing request (OpenMetadata governance workflow).
2. Platform admin creates:
   - Polaris: GRANT SELECT on tenant_a.marts.reference_products TO principal_role tenant_b_analyst
   - Ranger: New policy:
       Resource: trino:tenant_a.marts.reference_products
       Allow: Groups [tenant_b_analysts]
       Row Filter: none (full table shared)
       Column Mask: PII columns still masked for tenant_b_analysts
3. Data owner approves in OpenMetadata.
4. Sharing event logged in audit trail (ADR-009).
```

---

## Tenant Lifecycle Management

| Event | Polaris | Ranger | Trino | MinIO | Keycloak |
|---|---|---|---|---|---|
| **Tenant onboarding** | Create warehouse + namespaces | Create policies + groups | Add resource group | Create bucket prefix + service account | Create groups + assign realm roles |
| **User onboarding** | Assign principal roles | Add to groups (auto-synced) | N/A (JWT-based) | N/A (service accounts only) | Create user account |
| **User offboarding** | N/A (role auto-revoked) | Auto-synced from Keycloak | Active sessions expire within 15 min | N/A | Disable account → invalidate sessions |
| **Tenant offboarding** | Drop warehouse (soft delete → export) | Archive policies | Remove resource group | Tag objects for retention expiry | Disable group |

---

## Consequences

### Positive
- **True isolation without physical separation:** Three-layer enforcement makes it extremely difficult for a misconfigured query to expose cross-tenant data. Even if Polaris RBAC is misconfigured, Ranger row-level filters provide a second enforcement layer.
- **Audit traceability:** Every query carries `tenant_id` in the JWT; every Ranger decision logs tenant context. Cross-tenant access is immediately detectable.
- **Compute fairness:** Trino resource groups guarantee no tenant can monopolize the query engine.
- **Self-service within bounds:** Tenant admins can manage their own namespace tables in Polaris without touching other tenants. Data engineers have autonomy within their tenant boundary.

### Negative
- **Operational complexity:** Three systems must be kept in sync (Polaris grants, Ranger policies, Keycloak group assignments). A dedicated "identity orchestrator" DAG in Airflow automates this on group membership changes.
- **Cross-tenant sharing complexity:** Every sharing event requires changes in two systems (Polaris + Ranger). Mitigated by an OpenMetadata governance workflow that submits both changes in a single approved request.
- **JWT claim enforcement requires trust in Trino:** Row-level filter enforcement depends on Trino correctly passing the `tenant_id` claim to Ranger. If Trino misconfigures the claim extraction, filters could be bypassed. Mitigated by: integration tests asserting Ranger denies cross-tenant access; Ranger plugin configured to deny if `tenant_id` is absent/null.

### Neutral
- Ranger tag-based policies integrate with OpenMetadata tag propagation — PII tags assigned in OpenMetadata automatically activate masking policies in Ranger (via Ranger-OpenMetadata tag sync plugin).

---

## Alternatives Considered

### Physical multi-tenancy (dedicated cluster per tenant)
- **Rejected for base model:** N times the infrastructure cost; impractical for > 5 tenants. Available as an opt-in upgrade path for high-compliance tenants via Trino Gateway routing.

### Schema-level isolation only (no row-level filters)
- **Rejected:** Insufficient for shared tables (audit logs, reference data). Schema isolation alone cannot handle cases where tenants legitimately share a table with subset access.

### Policy-as-Code (OPA + Rego) instead of Ranger
- **Evaluated as a future option:** OPA provides more flexible policy expression. Current blocker: OPA has limited native Trino plugin integration; Ranger has a mature, tested Trino plugin. OPA may replace Ranger in a future ADR if Trino-OPA plugin matures.

---

## References
- [Apache Ranger documentation](https://ranger.apache.org/documentation.html)
- [Apache Polaris RBAC model](https://polaris.apache.org/in-dev/security/)
- [Trino resource groups](https://trino.io/docs/current/admin/resource-groups.html)
- [Trino row-level security via Ranger](https://ranger.apache.org/trino-plugin.html)
- ADR-001 — Apache Polaris (warehouse-per-tenant design)
- ADR-007 — Keycloak OIDC (`tenant_id` JWT claim)
- ADR-009 — Audit trail (cross-tenant access logging)
