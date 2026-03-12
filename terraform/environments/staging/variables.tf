variable "cloud_provider" {
  description = "Fournisseur cloud : aws, gcp, azure"
  type        = string
  default     = "aws"
}

variable "aws_region" {
  description = "Région AWS"
  type        = string
  default     = "eu-west-1"
}

variable "cluster_name" {
  description = "Nom du cluster EKS staging"
  type        = string
  default     = "lakehouse-staging"
}

variable "kubernetes_version" {
  type    = string
  default = "1.29"
}

variable "vpc_cidr" {
  type    = string
  default = "10.10.0.0/16"
}

variable "availability_zones" {
  type    = list(string)
  default = ["eu-west-1a", "eu-west-1b"]
}

variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.10.1.0/24", "10.10.2.0/24"]
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.10.101.0/24", "10.10.102.0/24"]
}

variable "allowed_cidr_blocks" {
  description = "CIDRs autorisés à accéder à l'API server"
  type        = list(string)
  default     = []
}

variable "kms_key_id" {
  description = "ID de la clé KMS AWS pour S3"
  type        = string
  default     = ""
}

variable "kms_key_arn" {
  description = "ARN de la clé KMS AWS pour RDS"
  type        = string
  default     = ""
}

variable "domain" {
  description = "Domaine de base pour les ingress (ex: staging.example.com)"
  type        = string
  default     = "staging.example.com"
}

variable "storage_class" {
  description = "StorageClass K8s à utiliser"
  type        = string
  default     = "gp3"
}

variable "tags" {
  description = "Tags supplémentaires à appliquer aux ressources"
  type        = map(string)
  default     = {}
}
