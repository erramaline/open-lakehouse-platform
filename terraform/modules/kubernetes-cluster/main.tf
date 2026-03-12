terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 3.80"
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

# ── AWS EKS ──────────────────────────────────────────────────────────────────
module "eks" {
  count   = var.cloud_provider == "aws" ? 1 : 0
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.kubernetes_version

  vpc_id     = module.networking[0].vpc_id
  subnet_ids = module.networking[0].private_subnet_ids

  cluster_endpoint_public_access       = var.cluster_endpoint_public_access
  cluster_endpoint_public_access_cidrs = var.allowed_cidr_blocks

  enable_cluster_creator_admin_permissions = true

  cluster_addons = {
    coredns            = { most_recent = true }
    kube-proxy         = { most_recent = true }
    vpc-cni            = { most_recent = true }
    aws-ebs-csi-driver = { most_recent = true }
  }

  eks_managed_node_groups = {
    system = {
      name           = "${var.cluster_name}-system"
      instance_types = [var.system_node_instance_type]
      min_size       = 2
      max_size       = 4
      desired_size   = 2
      labels = {
        role = "system"
      }
      taints = [{
        key    = "system"
        value  = "true"
        effect = "NO_SCHEDULE"
      }]
    }

    data = {
      name           = "${var.cluster_name}-data"
      instance_types = [var.data_node_instance_type]
      min_size       = var.data_nodes_min
      max_size       = var.data_nodes_max
      desired_size   = var.data_nodes_desired
      disk_size      = var.data_node_disk_gb
      labels = {
        role = "data"
      }
    }

    storage = {
      name           = "${var.cluster_name}-storage"
      instance_types = [var.storage_node_instance_type]
      min_size       = var.storage_nodes_min
      max_size       = var.storage_nodes_max
      desired_size   = var.storage_nodes_desired
      disk_size      = var.storage_node_disk_gb
      labels = {
        role                          = "storage"
        "topology.kubernetes.io/zone" = data.aws_availability_zones.available[0].names[0]
      }
    }
  }

  tags = var.tags
}

# ── GKE ──────────────────────────────────────────────────────────────────────
resource "google_container_cluster" "main" {
  count    = var.cloud_provider == "gcp" ? 1 : 0
  name     = var.cluster_name
  location = var.gcp_region

  remove_default_node_pool = true
  initial_node_count       = 1

  network    = var.gcp_network
  subnetwork = var.gcp_subnetwork

  workload_identity_config {
    workload_pool = "${var.gcp_project}.svc.id.goog"
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  master_authorized_networks_config {
    dynamic "cidr_blocks" {
      for_each = var.allowed_cidr_blocks
      content {
        cidr_block = cidr_blocks.value
      }
    }
  }

  min_master_version = var.kubernetes_version

  resource_labels = var.tags
}

resource "google_container_node_pool" "data" {
  count      = var.cloud_provider == "gcp" ? 1 : 0
  name       = "${var.cluster_name}-data"
  cluster    = google_container_cluster.main[0].id
  node_count = var.data_nodes_desired

  autoscaling {
    min_node_count = var.data_nodes_min
    max_node_count = var.data_nodes_max
  }

  node_config {
    machine_type = var.gcp_data_machine_type
    disk_size_gb = var.data_node_disk_gb
    disk_type    = "pd-ssd"
    labels = {
      role = "data"
    }
    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }
}

# ── AKS ──────────────────────────────────────────────────────────────────────
resource "azurerm_kubernetes_cluster" "main" {
  count               = var.cloud_provider == "azure" ? 1 : 0
  name                = var.cluster_name
  location            = var.azure_location
  resource_group_name = var.azure_resource_group
  dns_prefix          = var.cluster_name
  kubernetes_version  = var.kubernetes_version

  default_node_pool {
    name            = "system"
    node_count      = 2
    vm_size         = var.azure_system_vm_size
    os_disk_size_gb = 128
    type            = "VirtualMachineScaleSets"
    node_labels = {
      role = "system"
    }
    # node_taints are managed via azurerm_kubernetes_cluster_node_pool for non-default pools
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin    = "azure"
    load_balancer_sku = "standard"
  }

  tags = var.tags
}

resource "azurerm_kubernetes_cluster_node_pool" "data" {
  count                 = var.cloud_provider == "azure" ? 1 : 0
  name                  = "data"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.main[0].id
  vm_size               = var.azure_data_vm_size
  node_count            = var.data_nodes_desired
  min_count             = var.data_nodes_min
  max_count             = var.data_nodes_max
  auto_scaling_enabled  = true
  os_disk_size_gb       = var.data_node_disk_gb
  node_labels = {
    role = "data"
  }
  tags = var.tags
}

data "aws_availability_zones" "available" {
  count = var.cloud_provider == "aws" ? 1 : 0
  state = "available"
}

# ── Locally scoped networking module reference ────────────────────────────────
module "networking" {
  count          = var.cloud_provider == "aws" ? 1 : 0
  source         = "../networking"
  cloud_provider = var.cloud_provider
  cluster_name   = var.cluster_name
  vpc_cidr       = var.vpc_cidr
  tags           = var.tags
}
