output "client_ids" {
  description = "Annotate each service account with azure.workload.identity/client-id"
  value       = { for k, id in azurerm_user_assigned_identity.this : k => id.client_id }
}
