terraform {
  required_version = ">= 1.6"

  backend "s3" {
    # Configurer via terraform init -backend-config=backend.hcl
    # bucket         = "my-terraform-state-bucket"
    # key            = "lakehouse/staging/terraform.tfstate"
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
  # In Helm provider v3+, kubernetes config is inherited from the kubernetes provider.
  # No inline kubernetes {} block is supported.
}

locals {
  environment = "staging"
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
  high_availability_nat = false  # staging : un seul NAT GW
  tags                  = local.common_tags
}

# ── Cluster Kubernetes ────────────────────────────────────────────────────────
module "kubernetes_cluster" {
  source               = "../../modules/kubernetes-cluster"
  cloud_provider       = var.cloud_provider
  cluster_name         = var.cluster_name
  kubernetes_version   = var.kubernetes_version
  vpc_cidr             = var.vpc_cidr
  # Staging : nœuds data plus petits
  data_node_instance_type    = "r5.xlarge"
  data_nodes_min             = 1
  data_nodes_max             = 5
  data_nodes_desired         = 2
  data_node_disk_gb          = 100
  # Stockage MinIO réduit en staging
  storage_node_instance_type = "i3.xlarge"
  storage_nodes_min          = 1
  storage_nodes_max          = 4
  storage_nodes_desired      = 2
  storage_node_disk_gb       = 500
  allowed_cidr_blocks        = var.allowed_cidr_blocks
  tags                       = local.common_tags
}

# ── Stockage objet ────────────────────────────────────────────────────────────
module "object_storage" {
  source                   = "../../modules/object-storage"
  cloud_provider           = var.cloud_provider
  bucket_name              = "${var.cluster_name}-lakehouse-staging"
  aws_kms_key_id           = var.kms_key_id
  s3_ia_transition_days    = 30
  s3_glacier_transition_days = 90
  tags                     = local.common_tags
}

# ── PostgreSQL ────────────────────────────────────────────────────────────────
module "postgresql" {
  source              = "../../modules/postgresql"
  cloud_provider      = var.cloud_provider
  identifier          = "${var.cluster_name}-pg-staging"
  postgres_version    = "16"
  instance_class      = "db.r6g.large"
  storage_gb          = 100
  max_storage_gb      = 500
  multi_az            = false  # pas de HA en staging
  backup_retention_days = 7
  deletion_protection = false  # staging peut être supprimé
  subnet_ids          = module.networking.private_subnet_ids
  aws_kms_key_arn     = var.kms_key_arn
  manage_password     = true
  tags                = local.common_tags
}

# ── Helm: lakehouse-core ──────────────────────────────────────────────────────
resource "helm_release" "lakehouse_core" {
  name             = "lakehouse-core"
  chart            = "${path.module}/../../../helm/charts/lakehouse-core"
  namespace        = "lakehouse-system"
  create_namespace = true
  timeout          = 600
  wait             = true

  values = [
    file("${path.module}/../../../helm/charts/lakehouse-core/values.yaml"),
    file("${path.module}/../../../helm/charts/lakehouse-core/values.staging.yaml")
  ]

  set = [
    {
      name  = "global.storageClass"
      value = var.storage_class
    },
    {
      name  = "global.domain"
      value = var.domain
    }
  ]

  depends_on = [module.kubernetes_cluster]
}

# ── Helm: observability ───────────────────────────────────────────────────────
resource "helm_release" "observability" {
  name             = "observability"
  chart            = "${path.module}/../../../helm/charts/observability"
  namespace        = "lakehouse-obs"
  create_namespace = true
  timeout          = 300

  values = [
    file("${path.module}/../../../helm/charts/observability/values.yaml")
  ]

  set = [
    {
      name  = "global.storageClass"
      value = var.storage_class
    }
  ]

  depends_on = [helm_release.lakehouse_core]
}
