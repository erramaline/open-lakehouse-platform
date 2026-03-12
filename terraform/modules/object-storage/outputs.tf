output "bucket_name" {
  description = "Nom du bucket créé"
  value = coalesce(
    try(aws_s3_bucket.lakehouse[0].bucket, ""),
    try(google_storage_bucket.lakehouse[0].name, ""),
    try(azurerm_storage_container.lakehouse[0].name, "")
  )
}

output "bucket_endpoint" {
  description = "Endpoint d'accès au stockage objet"
  value = var.cloud_provider == "aws" ? (
    "https://${try(aws_s3_bucket.lakehouse[0].bucket_regional_domain_name, "")}"
    ) : var.cloud_provider == "gcp" ? (
    "https://storage.googleapis.com/${try(google_storage_bucket.lakehouse[0].name, "")}"
    ) : (
    try(azurerm_storage_account.lakehouse[0].primary_blob_endpoint, "")
  )
}

output "bucket_arn_or_id" {
  description = "ARN (AWS) ou self_link (GCP) ou ID (Azure) du bucket"
  value = coalesce(
    try(aws_s3_bucket.lakehouse[0].arn, ""),
    try(google_storage_bucket.lakehouse[0].self_link, ""),
    try(azurerm_storage_account.lakehouse[0].id, "")
  )
}
