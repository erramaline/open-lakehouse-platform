terraform {
  required_version = ">= 1.6"
  required_providers {
    aws     = { source = "hashicorp/aws", version = ">= 5.0" }
    google  = { source = "hashicorp/google", version = ">= 5.0" }
    azurerm = { source = "hashicorp/azurerm", version = ">= 3.80" }
    random  = { source = "hashicorp/random", version = ">= 3.5" }
  }
}

# ── AWS S3 ───────────────────────────────────────────────────────────────────
resource "aws_s3_bucket" "lakehouse" {
  count  = var.cloud_provider == "aws" ? 1 : 0
  bucket = var.bucket_name
  tags   = var.tags
}

resource "aws_s3_bucket_versioning" "lakehouse" {
  count  = var.cloud_provider == "aws" ? 1 : 0
  bucket = aws_s3_bucket.lakehouse[0].id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "lakehouse" {
  count  = var.cloud_provider == "aws" ? 1 : 0
  bucket = aws_s3_bucket.lakehouse[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.aws_kms_key_id
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "lakehouse" {
  count                   = var.cloud_provider == "aws" ? 1 : 0
  bucket                  = aws_s3_bucket.lakehouse[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "lakehouse" {
  count  = var.cloud_provider == "aws" ? 1 : 0
  bucket = aws_s3_bucket.lakehouse[0].id

  rule {
    id     = "archive-old-data"
    status = "Enabled"
    filter {}
    transition {
      days          = var.s3_ia_transition_days
      storage_class = "STANDARD_IA"
    }
    transition {
      days          = var.s3_glacier_transition_days
      storage_class = "GLACIER"
    }
    noncurrent_version_transition {
      noncurrent_days = 30
      storage_class   = "STANDARD_IA"
    }
    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }
}

# Sous-buckets par zone de données (prefixes via tags)
resource "aws_s3_object" "prefixes" {
  for_each = var.cloud_provider == "aws" ? toset(["raw/", "staging/", "curated/", "audit/"]) : toset([])
  bucket   = aws_s3_bucket.lakehouse[0].id
  key      = each.key
  content  = ""
}

# ── GCS ──────────────────────────────────────────────────────────────────────
resource "google_storage_bucket" "lakehouse" {
  count         = var.cloud_provider == "gcp" ? 1 : 0
  name          = var.bucket_name
  location      = var.gcp_region
  storage_class = "STANDARD"
  project       = var.gcp_project

  versioning { enabled = true }

  encryption {
    default_kms_key_name = var.gcp_kms_key_name
  }

  lifecycle_rule {
    action {
      type          = "SetStorageClass"
      storage_class = "NEARLINE"
    }
    condition { age = var.s3_ia_transition_days }
  }

  lifecycle_rule {
    action {
      type          = "SetStorageClass"
      storage_class = "COLDLINE"
    }
    condition { age = var.s3_glacier_transition_days }
  }

  uniform_bucket_level_access = true
  labels                      = var.gcp_labels
}

# ── Azure Blob ────────────────────────────────────────────────────────────────
resource "azurerm_storage_account" "lakehouse" {
  count                           = var.cloud_provider == "azure" ? 1 : 0
  name                            = replace(var.bucket_name, "-", "")
  resource_group_name             = var.azure_resource_group
  location                        = var.azure_location
  account_tier                    = "Standard"
  account_replication_type        = "ZRS"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false

  blob_properties {
    versioning_enabled = true
  }

  tags = var.tags
}

resource "azurerm_storage_container" "lakehouse" {
  count                 = var.cloud_provider == "azure" ? 1 : 0
  name                  = var.azure_container_name
  storage_account_name  = azurerm_storage_account.lakehouse[0].name
  container_access_type = "private"
}
