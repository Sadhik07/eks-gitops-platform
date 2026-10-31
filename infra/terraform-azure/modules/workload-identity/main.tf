# One user-assigned managed identity per Kubernetes service account, trusted
# through the cluster's OIDC issuer (Entra Workload ID). Each identity gets
# only the role assignments it needs.

locals {
  # Flatten {workload => [roles]} into one map entry per role assignment
  role_assignments = merge([
    for name, w in var.workloads : {
      for i, r in w.roles : "${name}-${i}" => merge(r, { workload = name })
    }
  ]...)
}

resource "azurerm_user_assigned_identity" "this" {
  for_each = var.workloads

  name                = "id-${var.cluster_name}-${each.key}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_federated_identity_credential" "this" {
  for_each = var.workloads

  name                      = "k8s-${each.value.namespace}-${each.value.service_account}"
  user_assigned_identity_id = azurerm_user_assigned_identity.this[each.key].id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = var.oidc_issuer_url
  subject                   = "system:serviceaccount:${each.value.namespace}:${each.value.service_account}"
}

resource "azurerm_role_assignment" "this" {
  for_each = local.role_assignments

  scope                = each.value.scope
  role_definition_name = each.value.role
  principal_id         = azurerm_user_assigned_identity.this[each.value.workload].principal_id
  principal_type       = "ServicePrincipal"
}
