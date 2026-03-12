# =============================================================================
# OpenBao — Raft HA Cluster Configuration Template
# This file is used by all 3 nodes (openbao-1, openbao-2, openbao-3).
# The node_id is substituted at container startup via entrypoint:
#   sed "s/__NODE_ID__/${OPENBAO_NODE_ID}/" config.hcl > /tmp/config.hcl
#   exec bao server -config=/tmp/config.hcl
# =============================================================================

# ─── Storage — Integrated Raft ───────────────────────────────────────────────
storage "raft" {
  path    = "/openbao/data"
  node_id = "__NODE_ID__"

  # All 3 nodes retry-join each other on startup
  retry_join {
    leader_api_addr = "http://openbao-1:8200"
  }
  retry_join {
    leader_api_addr = "http://openbao-2:8200"
  }
  retry_join {
    leader_api_addr = "http://openbao-3:8200"
  }
}

# ─── API Listener ─────────────────────────────────────────────────────────────
listener "tcp" {
  address       = "0.0.0.0:8200"
  cluster_address = "0.0.0.0:8201"

  # TLS is disabled for local dev (traffic stays within lakehouse-net bridge network)
  # In K8s staging/prod: enable tls_cert_file + tls_key_file from cert-manager
  tls_disable = true
}

# ─── Cluster address (used in HA heartbeats) ─────────────────────────────────
# Each node advertises its own hostname to the cluster:
# openbao-1 → http://openbao-1:8201
# The __NODE_ID__ also maps to the container hostname in docker-compose.
cluster_addr = "http://__NODE_ID__:8201"
api_addr     = "http://__NODE_ID__:8200"

# ─── UI ──────────────────────────────────────────────────────────────────────
ui = true

# ─── Telemetry ───────────────────────────────────────────────────────────────
telemetry {
  prometheus_retention_time = "10m"
  disable_hostname          = false
}

# ─── Log level ────────────────────────────────────────────────────────────────
log_level = "info"
