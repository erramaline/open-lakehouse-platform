variable "cloud_provider" {
  description = "Fournisseur cloud : aws, gcp, azure"
  type        = string
}

variable "bucket_name" {
  description = "Nom du bucket/container de stockage objet"
  type        = string
}

variable "gcp_project" {
  type    = string
  default = ""
}

variable "gcp_region" {
  type    = string
  default = "europe-west1"
}

variable "gcp_kms_key_name" {
  description = "Clé KMS GCP pour le chiffrement du bucket"
  type        = string
  default     = ""
}

variable "gcp_labels" {
  type    = map(string)
  default = {}
}

variable "aws_kms_key_id" {
  description = "ARN de la clé KMS AWS pour le chiffrement S3"
  type        = string
  default     = ""
}

variable "s3_ia_transition_days" {
  description = "Jours avant transition vers IA/NearLine"
  type        = number
  default     = 90
}

variable "s3_glacier_transition_days" {
  description = "Jours avant transition vers Glacier/ColdLine"
  type        = number
  default     = 365
}

variable "azure_resource_group" {
  type    = string
  default = ""
}

variable "azure_location" {
  type    = string
  default = "westeurope"
}

variable "azure_container_name" {
  description = "Nom du container Blob Azure"
  type        = string
  default     = "lakehouse"
}

variable "tags" {
  type    = map(string)
  default = {}
}
