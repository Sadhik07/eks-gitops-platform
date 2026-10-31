output "client_ids" {
  description = "Set as GitHub repository variables (AZURE_ACR_PUSH_CLIENT_ID, AZURE_TF_PLAN_CLIENT_ID, AZURE_TF_APPLY_CLIENT_ID)"
  value       = { for k, id in azurerm_user_assigned_identity.gha : k => id.client_id }
}
