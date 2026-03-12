output "endpoint" {
  description = "Endpoint de connexion PostgreSQL"
  value = coalesce(
    try(aws_db_instance.main[0].endpoint, ""),
    try(aws_rds_cluster.aurora[0].endpoint, ""),
    try(google_sql_database_instance.main[0].connection_name, ""),
    try(azurerm_postgresql_flexible_server.main[0].fqdn, "")
  )
  sensitive = true
}

output "port" {
  description = "Port PostgreSQL"
  value       = 5432
}

output "database_name" {
  description = "Nom de la base initiale créée"
  value       = var.initial_database
}

output "generated_password" {
  description = "Mot de passe généré (si manage_password=true)"
  value       = var.manage_password ? random_password.pg_password[0].result : null
  sensitive   = true
}
