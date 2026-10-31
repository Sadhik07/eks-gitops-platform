# Keyless CI for Azure: GitHub Actions exchanges its OIDC token for an Entra
# token through federated credentials on user-assigned managed identities.
# No client secrets are stored in GitHub.

locals {
  repo   = "${var.github_org}/${var.github_repo}"
  issuer = "https://token.actions.githubusercontent.com"

  identities = {
    acr-push = {
      subjects = { main = "repo:${local.repo}:ref:refs/heads/main" }
      roles    = [{ scope = var.acr_id, role = "AcrPush" }]
    }
    tf-plan = {
      subjects = {
        pr   = "repo:${local.repo}:pull_request"
        main = "repo:${local.repo}:ref:refs/heads/main"
      }
      roles = [
        { scope = var.subscription_scope, role = "Reader" },
        { scope = var.state_storage_account_id, role = "Storage Blob Data Contributor" }, # state lease = lock
      ]
    }
    tf-apply = {
      subjects = { for env in var.apply_environments : env => "repo:${local.repo}:environment:${env}" }
      roles = [
        { scope = var.subscription_scope, role = "Contributor" },
        # Lets Terraform create the workload role assignments, but only for
        # non-privileged roles (see apply_role_condition)
        { scope = var.subscription_scope, role = "Role Based Access Control Administrator" },
        { scope = var.state_storage_account_id, role = "Storage Blob Data Contributor" },
      ]
    }
  }

  credentials = merge([
    for id, cfg in local.identities : {
      for key, subject in cfg.subjects : "${id}-${key}" => { identity = id, subject = subject }
    }
  ]...)

  role_assignments = merge([
    for id, cfg in local.identities : {
      for i, r in cfg.roles : "${id}-${i}" => merge(r, { identity = id })
    }
  ]...)
}

resource "azurerm_user_assigned_identity" "gha" {
  for_each = local.identities

  name                = "id-gha-${var.github_repo}-${each.key}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_federated_identity_credential" "gha" {
  for_each = local.credentials

  name                      = "github-${each.key}"
  user_assigned_identity_id = azurerm_user_assigned_identity.gha[each.value.identity].id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = local.issuer
  subject                   = each.value.subject
}

resource "azurerm_role_assignment" "gha" {
  for_each = local.role_assignments

  scope                = each.value.scope
  role_definition_name = each.value.role
  principal_id         = azurerm_user_assigned_identity.gha[each.value.identity].principal_id
  principal_type       = "ServicePrincipal"

  # The RBAC-admin role may only grant data-plane and AcrPull-style roles, never
  # Owner / User Access Administrator / RBAC Administrator (privilege escalation guard).
  condition_version = each.value.role == "Role Based Access Control Administrator" ? "2.0" : null
  condition         = each.value.role == "Role Based Access Control Administrator" ? local.apply_role_condition : null
}

locals {
  # Built-in role definition ids that the apply identity is NOT allowed to assign
  privileged_roles = [
    "8e3af657-a8ff-443c-a75c-2fe8c4bcb635", # Owner
    "18d7d88d-d35e-4fb5-a5c3-7773c20a72d9", # User Access Administrator
    "f58310d9-a9f6-439a-9e8d-f62e7b41a168", # Role Based Access Control Administrator
  ]
  apply_role_condition = <<-EOT
    (
      (!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'}))
      OR
      (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAllValues:GuidNotEquals {${join(", ", local.privileged_roles)}})
    )
    AND
    (
      (!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'}))
      OR
      (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAllValues:GuidNotEquals {${join(", ", local.privileged_roles)}})
    )
  EOT
}
