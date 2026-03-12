variable "cluster_name" {
  description = "Nom du cluster Kubernetes"
  type        = string
}

variable "cloud_provider" {
  description = "Fournisseur cloud cible : aws, gcp, azure"
  type        = string
  validation {
    condition     = contains(["aws", "gcp", "azure"], var.cloud_provider)
    error_message = "Valeurs acceptées : aws, gcp, azure."
  }
}

variable "kubernetes_version" {
  description = "Version Kubernetes à déployer"
  type        = string
  default     = "1.29"
}

variable "cluster_endpoint_public_access" {
  description = "Activer l'accès public à l'API server (AWS EKS)"
  type        = bool
  default     = false
}

variable "allowed_cidr_blocks" {
  description = "CIDRs autorisés à accéder à l'API server"
  type        = list(string)
  default     = []
}

variable "vpc_cidr" {
  description = "CIDR du VPC (AWS)"
  type        = string
  default     = "10.0.0.0/16"
}

variable "system_node_instance_type" {
  description = "Type d'instance pour les nœuds système (AWS)"
  type        = string
  default     = "m5.xlarge"
}

variable "data_node_instance_type" {
  description = "Type d'instance pour les nœuds data/compute (AWS)"
  type        = string
  default     = "r5.2xlarge"
}

variable "storage_node_instance_type" {
  description = "Type d'instance pour les nœuds storage MinIO (AWS)"
  type        = string
  default     = "i3en.xlarge"
}

variable "data_nodes_min" {
  description = "Nombre minimum de nœuds data"
  type        = number
  default     = 2
}

variable "data_nodes_max" {
  description = "Nombre maximum de nœuds data"
  type        = number
  default     = 10
}

variable "data_nodes_desired" {
  description = "Nombre de nœuds data souhaité au démarrage"
  type        = number
  default     = 3
}

variable "data_node_disk_gb" {
  description = "Taille disque nœud data (GB)"
  type        = number
  default     = 200
}

variable "storage_nodes_min" {
  description = "Nombre minimum de nœuds storage"
  type        = number
  default     = 4
}

variable "storage_nodes_max" {
  description = "Nombre maximum de nœuds storage"
  type        = number
  default     = 8
}

variable "storage_nodes_desired" {
  description = "Nombre de nœuds storage souhaité"
  type        = number
  default     = 4
}

variable "storage_node_disk_gb" {
  description = "Taille disque nœud storage en GB (local NVMe pour MinIO)"
  type        = number
  default     = 2000
}

# ── GCP ──────────────────────────────────────────────────────────────────────
variable "gcp_project" {
  description = "ID du projet GCP"
  type        = string
  default     = ""
}

variable "gcp_region" {
  description = "Région GCP"
  type        = string
  default     = "europe-west1"
}

variable "gcp_network" {
  description = "Réseau VPC GCP"
  type        = string
  default     = "default"
}

variable "gcp_subnetwork" {
  description = "Sous-réseau GCP"
  type        = string
  default     = "default"
}

variable "gcp_data_machine_type" {
  description = "Type de machine GCP pour les nœuds data"
  type        = string
  default     = "n2-highmem-8"
}

# ── Azure ─────────────────────────────────────────────────────────────────────
variable "azure_location" {
  description = "Région Azure"
  type        = string
  default     = "westeurope"
}

variable "azure_resource_group" {
  description = "Resource group Azure"
  type        = string
  default     = ""
}

variable "azure_system_vm_size" {
  description = "Taille VM Azure pour nœuds système"
  type        = string
  default     = "Standard_D4s_v3"
}

variable "azure_data_vm_size" {
  description = "Taille VM Azure pour nœuds data"
  type        = string
  default     = "Standard_E16s_v3"
}

variable "tags" {
  description = "Tags à appliquer aux ressources cloud"
  type        = map(string)
  default     = {}
}
