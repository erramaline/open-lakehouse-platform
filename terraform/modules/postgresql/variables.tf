variable "cloud_provider" {
  type = string
}
variable "identifier" {
  description = "Nom/ID de l'instance PostgreSQL"
  type        = string
}
variable "postgres_version" {
  type    = string
  default = "16"
}
variable "instance_class" {
  type    = string
  default = "db.r6g.xlarge"
}
variable "storage_gb" {
  type    = number
  default = 100
}
variable "max_storage_gb" {
  type    = number
  default = 1000
}
variable "initial_database" {
  type    = string
  default = "postgres"
}
variable "username" {
  type    = string
  default = "postgres"
}
variable "password" {
  type      = string
  default   = ""
  sensitive = true
}
variable "manage_password" {
  description = "Générer le mot de passe via Terraform random"
  type        = bool
  default     = false
}
variable "multi_az" {
  type    = bool
  default = true
}
variable "backup_retention_days" {
  type    = number
  default = 14
}
variable "deletion_protection" {
  type    = bool
  default = true
}
variable "subnet_ids" {
  type    = list(string)
  default = []
}
variable "vpc_security_group_ids" {
  type    = list(string)
  default = []
}
variable "aws_kms_key_arn" {
  type    = string
  default = ""
}
variable "use_aurora" {
  type    = bool
  default = false
}
variable "aurora_replica_count" {
  type    = number
  default = 2
}
variable "gcp_project" {
  type    = string
  default = ""
}
variable "gcp_region" {
  type    = string
  default = "europe-west1"
}
variable "gcp_tier" {
  type    = string
  default = "db-perf-optimized-N-4"
}
variable "gcp_network" {
  type    = string
  default = ""
}
variable "azure_resource_group" {
  type    = string
  default = ""
}
variable "azure_location" {
  type    = string
  default = "westeurope"
}
variable "azure_sku_name" {
  type    = string
  default = "MO_Standard_D4s_v3"
}
variable "tags" {
  type    = map(string)
  default = {}
}
