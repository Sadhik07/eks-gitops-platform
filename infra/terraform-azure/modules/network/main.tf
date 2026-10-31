# VNet for AKS with Azure CNI Overlay: nodes take VNet IPs, pods get IPs from a
# private overlay range, so a /20 node subnet is plenty.

resource "azurerm_virtual_network" "this" {
  name                = "vnet-${var.name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  address_space       = [var.cidr]
  tags                = var.tags
}

resource "azurerm_subnet" "nodes" {
  name                 = "snet-aks-nodes"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [cidrsubnet(var.cidr, 4, 0)]
}

# Default-deny inbound from the internet; AKS adds the rules its load balancers need
resource "azurerm_network_security_group" "nodes" {
  name                = "nsg-${var.name}-nodes"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_subnet_network_security_group_association" "nodes" {
  subnet_id                 = azurerm_subnet.nodes.id
  network_security_group_id = azurerm_network_security_group.nodes.id
}
