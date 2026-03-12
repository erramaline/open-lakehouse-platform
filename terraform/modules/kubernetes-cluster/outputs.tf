output "cluster_name" {
  description = "Nom du cluster Kubernetes"
  value       = var.cluster_name
}

output "cluster_endpoint" {
  description = "Endpoint de l'API server Kubernetes"
  value = coalesce(
    try(module.eks[0].cluster_endpoint, ""),
    try(google_container_cluster.main[0].endpoint, ""),
    try(azurerm_kubernetes_cluster.main[0].kube_config[0].host, "")
  )
  sensitive = true
}

output "cluster_ca_certificate" {
  description = "Certificat CA du cluster"
  value = coalesce(
    try(module.eks[0].cluster_certificate_authority_data, ""),
    try(google_container_cluster.main[0].master_auth[0].cluster_ca_certificate, ""),
    try(azurerm_kubernetes_cluster.main[0].kube_config[0].cluster_ca_certificate, "")
  )
  sensitive = true
}

output "kubeconfig_command" {
  description = "Commande pour récupérer le kubeconfig"
  value = var.cloud_provider == "aws" ? (
    "aws eks update-kubeconfig --region ${try(module.eks[0].cluster_region, "")} --name ${var.cluster_name}"
  ) : var.cloud_provider == "gcp" ? (
    "gcloud container clusters get-credentials ${var.cluster_name} --region ${var.gcp_region} --project ${var.gcp_project}"
  ) : (
    "az aks get-credentials --resource-group ${var.azure_resource_group} --name ${var.cluster_name}"
  )
}

output "node_groups" {
  description = "Groupes de nœuds créés (AWS EKS)"
  value       = try(module.eks[0].eks_managed_node_groups, {})
}
