terraform {
  required_version = ">= 1.6"

  backend "s3" {
    # Configurer via terraform init -backend-config=backend.hcl
    # bucket         = "my-terraform-state-bucket"
    # key            = "lakehouse/production/terraform.tfstate"
    # region         = "eu-west-1"
    # encrypt        = true
    # dynamodb_table = "terraform-state-lock"
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.24"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.12"
    }
  }
}

provider "aws" {
  region = var.aws_region
  default_tags { tags = local.common_tags }
}

provider "kubernetes" {
  host                   = module.kubernetes_cluster.cluster_endpoint
  cluster_ca_certificate = base64decode(module.kubernetes_cluster.cluster_ca_certificate)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", var.cluster_name]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.kubernetes_cluster.cluster_endpoint
    cluster_ca_certificate = base64decode(module.kubernetes_cluster.cluster_ca_certificate)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", var.cluster_name]
    }
  }
}

locals {
  environment = "production"
  common_tags = merge(var.tags, {
    Environment = local.environment
    Project     = "open-lakehouse"
    ManagedBy   = "terraform"
  })
}

# ── Réseau ────────────────────────────────────────────────────────────────────
module "networking" {
  source         = "../../modules/networking"
  cloud_provider = var.cloud_provider
  cluster_name   = var.cluster_name
  vpc_cidr       = var.vpc_cidr
  availability_zones    = var.availability_zones
  private_subnet_cidrs  = var.private_subnet_cidrs
  public_subnet_cidrs   = var.public_subnet_cidrs
  high_availability_nat = true  # HA en production : NAT GW par AZ
  tags                  = local.common_tags
}

# ── Cluster Kubernetes ────────────────────────────────────────────────────────
module "kubernetes_cluster" {
  source               = "../../modules/kubernetes-cluster"
  cloud_provider       = var.cloud_provider
  cluster_name         = var.cluster_name
  kubernetes_version   = var.kubernetes_version
  vpc_cidr             = var.vpc_cidr
  # Production : nœuds data haute capacité
  data_node_instance_type    = "r5.4xlarge"
  data_nodes_min             = 3
  data_nodes_max             = 15
  data_nodes_desired         = 5
  data_node_disk_gb          = 500
  # Stockage MinIO haute densité (NVMe)
  storage_node_instance_type = "i3en.2xlarge"
  storage_nodes_min          = 4
  storage_nodes_max          = 8
  storage_nodes_desired      = 4
  storage_node_disk_gb       = 7500
  allowed_cidr_blocks        = var.allowed_cidr_blocks
  tags                       = local.common_tags
}

# ── Stockage objet ────────────────────────────────────────────────────────────
module "object_storage" {
  source                     = "../../modules/object-storage"
  cloud_provider             = var.cloud_provider
  bucket_name                = "${var.cluster_name}-lakehouse"
  aws_kms_key_id             = var.kms_key_id
  s3_ia_transition_days      = 90
  s3_glacier_transition_days = 365
  tags                       = local.common_tags
}

# ── PostgreSQL Aurora (HA production) ─────────────────────────────────────────
module "postgresql" {
  source                = "../../modules/postgresql"
  cloud_provider        = var.cloud_provider
  identifier            = "${var.cluster_name}-pg"
  postgres_version      = "16"
  instance_class        = "db.r6g.2xlarge"
  storage_gb            = 500
  max_storage_gb        = 10000
  multi_az              = true
  backup_retention_days = 14
  deletion_protection   = true
  subnet_ids            = module.networking.private_subnet_ids
  aws_kms_key_arn       = var.kms_key_arn
  use_aurora            = true
  aurora_replica_count  = 2
  manage_password       = true
  tags                  = local.common_tags
}

# ── Helm: lakehouse-core ──────────────────────────────────────────────────────
resource "helm_release" "lakehouse_core" {
  name             = "lakehouse-core"
  chart            = "${path.module}/../../helm/charts/lakehouse-core"
  namespace        = "lakehouse-system"
  create_namespace = true
  timeout          = 900
  wait             = true
  atomic           = true

  values = [
    file("${path.module}/../../helm/charts/lakehouse-core/values.yaml"),
    file("${path.module}/../../helm/charts/lakehouse-core/values.production.yaml")
  ]

  set {
    name  = "global.storageClass"
    value = var.storage_class
  }

  set {
    name  = "global.domain"
    value = var.domain
  }

  set {
    name  = "openbao.autoUnseal.kmsKeyId"
    value = var.kms_key_id
  }

  depends_on = [module.kubernetes_cluster]
}

# ── Helm: observability ───────────────────────────────────────────────────────
resource "helm_release" "observability" {
  name             = "observability"
  chart            = "${path.module}/../../helm/charts/observability"
  namespace        = "lakehouse-obs"
  create_namespace = true
  timeout          = 600
  wait             = true
  atomic           = true

  values = [
    file("${path.module}/../../helm/charts/observability/values.yaml")
  ]

  set {
    name  = "global.storageClass"
    value = var.storage_class
  }

  set {
    name  = "prometheus.storage.size"
    value = "500Gi"
  }

  set {
    name  = "loki.storage.size"
    value = "200Gi"
  }

  depends_on = [helm_release.lakehouse_core]
}
