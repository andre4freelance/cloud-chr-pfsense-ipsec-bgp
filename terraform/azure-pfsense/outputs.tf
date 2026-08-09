output "public_ip" {
  description = "WAN address - management and the pfSense WebGUI are reached here"
  value       = azurerm_public_ip.wan.ip_address
}

output "wan_private_ip" {
  value = azurerm_network_interface.wan.private_ip_address
}

output "lan_private_ip" {
  value = azurerm_network_interface.lan.private_ip_address
}

output "ssh_command" {
  description = "Reflects the currently applied ssh_port, so it stays correct after the port move"
  value       = "ssh -i ~/.ssh/pfsense-azure -p ${var.ssh_port} ${var.admin_username}@${azurerm_public_ip.wan.ip_address}"
}

output "web_url" {
  description = "Scheme follows the port: 443 is the image default (HTTPS), 7880 is plain HTTP by request"
  value       = var.web_port == 443 ? "https://${azurerm_public_ip.wan.ip_address}" : "http://${azurerm_public_ip.wan.ip_address}:${var.web_port}"
}

output "allowed_admin_cidr" {
  description = "Confirms what the NSG actually permits - check this after changing networks"
  value       = var.admin_ip_cidr
}
