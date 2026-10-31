output "cluster_name" {
  value = module.aks.name
}

output "resource_group" {
  value = azurerm_resource_group.this.name
}

output "kubeconfig_command" {
  value = "az aks get-credentials -g ${azurerm_resource_group.this.name} -n ${module.aks.name} && kubelogin convert-kubeconfig -l azurecli"
}

output "servicebus_fqdn" {
  description = "SERVICEBUS_NAMESPACE in deploy/overlays/azure-<env>"
  value       = "${azurerm_servicebus_namespace.this.name}.servicebus.windows.net"
}

output "key_vault_url" {
  value = azurerm_key_vault.this.vault_uri
}

output "velero_storage_account" {
  value = azurerm_storage_account.velero.name
}

output "node_resource_group" {
  value = module.aks.node_resource_group
}

output "workload_client_ids" {
  description = "Written into the service account annotations by scripts/azure-sync-outputs.sh"
  value       = module.workload_identity.client_ids
}
