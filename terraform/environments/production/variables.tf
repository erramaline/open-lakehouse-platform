variable "cloud_provider" { type = string; default = "aws" }
variable "aws_region" { type = string; default = "eu-west-1" }
variable "cluster_name" { type = string; default = "lakehouse-production" }
variable "kubernetes_version" { type = string; default = "1.29" }
variable "vpc_cidr" { type = string; default = "10.20.0.0/16" }
variable "availability_zones" { type = list(string); default = ["eu-west-1a", "eu-west-1b", "eu-west-1c"] }
variable "private_subnet_cidrs" { type = list(string); default = ["10.20.1.0/24", "10.20.2.0/24", "10.20.3.0/24"] }
variable "public_subnet_cidrs" { type = list(string); default = ["10.20.101.0/24", "10.20.102.0/24", "10.20.103.0/24"] }
variable "allowed_cidr_blocks" { type = list(string); default = [] }
variable "kms_key_id" { type = string; default = "" }
variable "kms_key_arn" { type = string; default = "" }
variable "domain" { type = string; default = "example.com" }
variable "storage_class" { type = string; default = "gp3" }
variable "tags" { type = map(string); default = {} }
