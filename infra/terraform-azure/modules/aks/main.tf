data "azurerm_client_config" "current" {}

resource "azurerm_kubernetes_cluster" "this" {
  #checkov:skip=CKV_AZURE_4:Metrics and logs go to the in-cluster Prometheus/Loki stack instead of Azure Monitor
  #checkov:skip=CKV_AZURE_116:Kyverno (platform/policies) enforces admission policy instead of Azure Policy
  #checkov:skip=CKV_AZURE_115:A private cluster needs a VPN or jump host for kubectl; the API is restricted by authorized IPs and Entra ID, and ArgoCD pulls from Git so CI never calls it
  #checkov:skip=CKV_AZURE_117:Customer-managed disk encryption keys are out of scope for the lab
  #checkov:skip=CKV_AZURE_226:Ephemeral OS disks need larger VM sizes than the lab uses
  #checkov:skip=CKV_AZURE_227:Host encryption needs a subscription feature registration; documented in setup-azure.md
  #checkov:skip=CKV_AZURE_170:Free tier keeps the lab cheap; use Standard tier (uptime SLA) for production
  #checkov:skip=CKV_AZURE_172:Secrets come from Key Vault via External Secrets, not the CSI driver
  #checkov:skip=CKV_AZURE_168:System pool runs a few add-on pods; NAP-provisioned pools use the default max pods
  name                = var.name
  location            = var.location
  resource_group_name = var.resource_group_name
  dns_prefix          = var.name
  kubernetes_version  = var.kubernetes_version
  sku_tier            = "Free"

  automatic_upgrade_channel = "patch"
  node_os_upgrade_channel   = "NodeImage"

  # Workload Identity: pods exchange their service account token for an Entra
  # token (the Azure equivalent of EKS Pod Identity / IRSA).
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  # Entra ID only: no static kubeconfig admin credentials exist
  local_account_disabled            = true
  role_based_access_control_enabled = true
  azure_active_directory_role_based_access_control {
    azure_rbac_enabled     = true
    tenant_id              = data.azurerm_client_config.current.tenant_id
    admin_group_object_ids = var.admin_group_object_ids
  }

  api_server_access_profile {
    authorized_ip_ranges = var.api_authorized_ip_ranges
  }

  image_cleaner_enabled        = true
  image_cleaner_interval_hours = 48

  # Small, tainted pool for cluster-critical add-ons (CoreDNS, ArgoCD).
  # Application capacity comes from Node Auto-Provisioning (Karpenter on AKS).
  default_node_pool {
    name                         = "system"
    vm_size                      = var.system_vm_size
    node_count                   = var.system_node_count
    vnet_subnet_id               = var.node_subnet_id
    only_critical_addons_enabled = true
    os_sku                       = "AzureLinux"
    zones                        = var.zones
    temporary_name_for_rotation  = "systemtmp"
    node_labels = {
      "node-role" = "system"
    }
    upgrade_settings {
      max_surge = "33%"
    }
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_data_plane  = "cilium" # eBPF dataplane, also enforces NetworkPolicies
    network_policy      = "cilium"
    pod_cidr            = "192.168.0.0/16"
    outbound_type       = "loadBalancer"
  }

  node_provisioning_profile {
    mode = "Auto"
  }

  tags = var.tags
}

# Whoever runs Terraform can administer the cluster through Entra ID
resource "azurerm_role_assignment" "deployer_cluster_admin" {
  scope                = azurerm_kubernetes_cluster.this.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = data.azurerm_client_config.current.object_id
}
