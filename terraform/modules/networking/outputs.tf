output "vpc_id" {
  value = try(module.vpc[0].vpc_id, try(google_compute_network.main[0].id, try(azurerm_virtual_network.main[0].id, "")))
}

output "private_subnet_ids" {
  value = try(module.vpc[0].private_subnets, [])
}

output "public_subnet_ids" {
  value = try(module.vpc[0].public_subnets, [])
}

output "cluster_security_group_id" {
  value = try(aws_security_group.cluster_sg[0].id, "")
}

output "gcp_subnetwork_self_link" {
  value = try(google_compute_subnetwork.main[0].self_link, "")
}

output "azure_subnet_id" {
  value = try(azurerm_subnet.nodes[0].id, "")
}
