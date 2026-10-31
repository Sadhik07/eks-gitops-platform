output "vnet_id" {
  value = azurerm_virtual_network.this.id
}

output "node_subnet_id" {
  value = azurerm_subnet.nodes.id
}
