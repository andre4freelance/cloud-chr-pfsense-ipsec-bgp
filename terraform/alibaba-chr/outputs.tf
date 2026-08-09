output "instance_id" {
  value = alicloud_instance.mikrotik.id
}

output "public_ip" {
  description = "Static EIP - the address the remote IPsec peer must be pointed at"
  value       = alicloud_eip_address.chr.ip_address
}

output "public_private_ip" {
  description = "Primary NIC address; this is the IPsec local address, not the EIP"
  value       = alicloud_instance.mikrotik.private_ip
}

output "private_eni_ip" {
  value = alicloud_ecs_network_interface.private.primary_ip_address
}

output "winbox_endpoint" {
  value = "${alicloud_eip_address.chr.ip_address}:${var.winbox_port}"
}

output "ssh_endpoint" {
  value = "${alicloud_eip_address.chr.ip_address}:${var.ssh_port}"
}
