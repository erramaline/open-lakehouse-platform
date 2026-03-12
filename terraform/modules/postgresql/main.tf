terraform {
  required_version = ">= 1.6"
  required_providers {
    aws      = { source = "hashicorp/aws",      version = ">= 5.0" }
    google   = { source = "hashicorp/google",   version = ">= 5.0" }
    azurerm  = { source = "hashicorp/azurerm",  version = ">= 3.80" }
    random   = { source = "hashicorp/random",   version = ">= 3.5" }
  }
}

resource "random_password" "pg_password" {
  count   = var.manage_password ? 1 : 0
  length  = 32
  special = true
}

# ── AWS RDS PostgreSQL ────────────────────────────────────────────────────────
resource "aws_db_subnet_group" "main" {
  count      = var.cloud_provider == "aws" ? 1 : 0
  name       = "${var.identifier}-subnet-group"
  subnet_ids = var.subnet_ids
  tags       = var.tags
}

resource "aws_db_instance" "main" {
  count                      = var.cloud_provider == "aws" && !var.use_aurora ? 1 : 0
  identifier                 = var.identifier
  engine                     = "postgres"
  engine_version             = var.postgres_version
  instance_class             = var.instance_class
  allocated_storage          = var.storage_gb
  max_allocated_storage      = var.max_storage_gb
  storage_type               = "gp3"
  storage_encrypted          = true
  kms_key_id                 = var.aws_kms_key_arn
  db_name                    = var.initial_database
  username                   = var.username
  password                   = var.manage_password ? random_password.pg_password[0].result : var.password
  db_subnet_group_name       = aws_db_subnet_group.main[0].name
  vpc_security_group_ids     = var.vpc_security_group_ids
  multi_az                   = var.multi_az
  backup_retention_period    = var.backup_retention_days
  deletion_protection        = var.deletion_protection
  skip_final_snapshot        = !var.deletion_protection
  final_snapshot_identifier  = var.deletion_protection ? "${var.identifier}-final-snapshot" : null
  performance_insights_enabled = true
  monitoring_interval        = 60
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]
  auto_minor_version_upgrade = true
  tags                       = var.tags
}

resource "aws_rds_cluster" "aurora" {
  count                  = var.cloud_provider == "aws" && var.use_aurora ? 1 : 0
  cluster_identifier     = var.identifier
  engine                 = "aurora-postgresql"
  engine_version         = var.postgres_version
  database_name          = var.initial_database
  master_username        = var.username
  master_password        = var.manage_password ? random_password.pg_password[0].result : var.password
  db_subnet_group_name   = aws_db_subnet_group.main[0].name
  vpc_security_group_ids = var.vpc_security_group_ids
  storage_encrypted      = true
  kms_key_id             = var.aws_kms_key_arn
  backup_retention_period = var.backup_retention_days
  deletion_protection    = var.deletion_protection
  skip_final_snapshot    = !var.deletion_protection
  final_snapshot_identifier = var.deletion_protection ? "${var.identifier}-aurora-final" : null
  tags                   = var.tags
}

resource "aws_rds_cluster_instance" "aurora_instances" {
  count              = var.cloud_provider == "aws" && var.use_aurora ? var.aurora_replica_count : 0
  identifier         = "${var.identifier}-${count.index}"
  cluster_identifier = aws_rds_cluster.aurora[0].id
  instance_class     = var.instance_class
  engine             = aws_rds_cluster.aurora[0].engine
  engine_version     = aws_rds_cluster.aurora[0].engine_version
  performance_insights_enabled = true
  monitoring_interval = 60
  tags               = var.tags
}

# ── GCP Cloud SQL ─────────────────────────────────────────────────────────────
resource "google_sql_database_instance" "main" {
  count            = var.cloud_provider == "gcp" ? 1 : 0
  name             = var.identifier
  database_version = "POSTGRES_${replace(var.postgres_version, ".", "_")}"
  region           = var.gcp_region
  project          = var.gcp_project

  settings {
    tier              = var.gcp_tier
    disk_size         = var.storage_gb
    disk_autoresize   = true
    disk_type         = "PD_SSD"
    availability_type = var.multi_az ? "REGIONAL" : "ZONAL"

    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = true
      backup_retention_settings {
        retained_backups = var.backup_retention_days
      }
    }

    ip_configuration {
      ipv4_enabled    = false
      private_network = var.gcp_network
      ssl_mode        = "ENCRYPTED_ONLY"
    }

    database_flags {
      name  = "log_min_duration_statement"
      value = "1000"
    }
  }

  deletion_protection = var.deletion_protection
}

resource "google_sql_database" "initial" {
  count    = var.cloud_provider == "gcp" ? 1 : 0
  name     = var.initial_database
  instance = google_sql_database_instance.main[0].name
  project  = var.gcp_project
}

resource "google_sql_user" "main" {
  count    = var.cloud_provider == "gcp" ? 1 : 0
  name     = var.username
  instance = google_sql_database_instance.main[0].name
  password = var.manage_password ? random_password.pg_password[0].result : var.password
  project  = var.gcp_project
}

# ── Azure Database for PostgreSQL Flexible Server ─────────────────────────────
resource "azurerm_postgresql_flexible_server" "main" {
  count                         = var.cloud_provider == "azure" ? 1 : 0
  name                          = var.identifier
  resource_group_name           = var.azure_resource_group
  location                      = var.azure_location
  version                       = split(".", var.postgres_version)[0]
  administrator_login           = var.username
  administrator_password        = var.manage_password ? random_password.pg_password[0].result : var.password
  sku_name                      = var.azure_sku_name
  storage_mb                    = var.storage_gb * 1024
  backup_retention_days         = var.backup_retention_days
  geo_redundant_backup_enabled  = var.multi_az
  zone                          = "1"
  tags                          = var.tags
}

resource "azurerm_postgresql_flexible_server_database" "initial" {
  count     = var.cloud_provider == "azure" ? 1 : 0
  name      = var.initial_database
  server_id = azurerm_postgresql_flexible_server.main[0].id
  collation = "en_US.utf8"
  charset   = "utf8"
}
