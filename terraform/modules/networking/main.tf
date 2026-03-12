terraform {
  required_version = ">= 1.6"
  required_providers {
    aws     = { source = "hashicorp/aws", version = ">= 5.0" }
    google  = { source = "hashicorp/google", version = ">= 5.0" }
    azurerm = { source = "hashicorp/azurerm", version = ">= 3.80" }
  }
}

# ── AWS VPC ───────────────────────────────────────────────────────────────────
module "vpc" {
  count   = var.cloud_provider == "aws" ? 1 : 0
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = var.cluster_name
  cidr = var.vpc_cidr

  azs             = var.availability_zones
  private_subnets = var.private_subnet_cidrs
  public_subnets  = var.public_subnet_cidrs

  enable_nat_gateway   = true
  single_nat_gateway   = !var.high_availability_nat
  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                    = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"           = "1"
  }

  tags = var.tags
}

# Security group pour le cluster
resource "aws_security_group" "cluster_sg" {
  count       = var.cloud_provider == "aws" ? 1 : 0
  name        = "${var.cluster_name}-cluster-sg"
  description = "Security group for Lakehouse cluster nodes"
  vpc_id      = module.vpc[0].vpc_id

  ingress {
    description = "Intra-cluster communication"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.cluster_name}-cluster-sg" })
}

# ── GCP VPC ───────────────────────────────────────────────────────────────────
resource "google_compute_network" "main" {
  count                   = var.cloud_provider == "gcp" ? 1 : 0
  name                    = var.cluster_name
  auto_create_subnetworks = false
  project                 = var.gcp_project
}

resource "google_compute_subnetwork" "main" {
  count         = var.cloud_provider == "gcp" ? 1 : 0
  name          = "${var.cluster_name}-nodes"
  ip_cidr_range = var.vpc_cidr
  region        = var.gcp_region
  network       = google_compute_network.main[0].id
  project       = var.gcp_project

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = var.gcp_pods_cidr
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = var.gcp_services_cidr
  }
}

# ── Azure VNet ────────────────────────────────────────────────────────────────
resource "azurerm_virtual_network" "main" {
  count               = var.cloud_provider == "azure" ? 1 : 0
  name                = var.cluster_name
  location            = var.azure_location
  resource_group_name = var.azure_resource_group
  address_space       = [var.vpc_cidr]
  tags                = var.tags
}

resource "azurerm_subnet" "nodes" {
  count                = var.cloud_provider == "azure" ? 1 : 0
  name                 = "${var.cluster_name}-nodes"
  resource_group_name  = var.azure_resource_group
  virtual_network_name = azurerm_virtual_network.main[0].name
  address_prefixes     = [var.azure_nodes_subnet_cidr]
}
