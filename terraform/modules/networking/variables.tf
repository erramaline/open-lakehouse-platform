variable "cloud_provider" {
  type = string
}
variable "cluster_name" {
  type = string
}
variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}
variable "availability_zones" {
  type    = list(string)
  default = []
}
variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}
variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
}
variable "high_availability_nat" {
  type    = bool
  default = true
}
variable "gcp_project" {
  type    = string
  default = ""
}
variable "gcp_region" {
  type    = string
  default = "europe-west1"
}
variable "gcp_pods_cidr" {
  type    = string
  default = "10.1.0.0/16"
}
variable "gcp_services_cidr" {
  type    = string
  default = "10.2.0.0/20"
}
variable "azure_location" {
  type    = string
  default = "westeurope"
}
variable "azure_resource_group" {
  type    = string
  default = ""
}
variable "azure_nodes_subnet_cidr" {
  type    = string
  default = "10.0.1.0/24"
}
variable "tags" {
  type    = map(string)
  default = {}
}
