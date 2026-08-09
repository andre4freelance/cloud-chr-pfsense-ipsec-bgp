##############################################################################
# pfSense Plus firewall on Azure - two-NIC lab
#
# Mirrors the Aliyun MikroTik CHR lab: one NIC on the public subnet holding a
# public IP (WAN), one NIC on the private subnet (LAN), management locked to a
# single admin IP. The pre-existing VNet/subnets belong to another Terraform
# state, so they are read through data sources and never modified.
#
# MARKETPLACE TERMS
# The image has a `plan`. Deploying it requires the subscription to have
# accepted Netgate's marketplace terms. That is a subscription-scope operation
# and this identity has only per-resource-group Contributor, so the terms can
# be neither read nor accepted from here. `azurerm_marketplace_agreement` is
# therefore intentionally NOT declared - adding it would fail on read even if
# the terms are already accepted. If `apply` fails with a message about terms
# or a missing plan/purchase agreement, someone with subscription-scope rights
# must run:
#   az vm image terms accept --publisher netgate \
#     --offer pfsense-plus-public-cloud-fw-vpn-router \
#     --plan pfsense-public-lite-2511
##############################################################################

# --- Existing infrastructure (read-only) ------------------------------------

data "azurerm_resource_group" "network" {
  name = var.network_resource_group
}

data "azurerm_resource_group" "compute" {
  name = var.compute_resource_group
}

data "azurerm_virtual_network" "main" {
  name                = var.vnet_name
  resource_group_name = data.azurerm_resource_group.network.name
}

data "azurerm_subnet" "public" {
  name                 = var.public_subnet_name
  virtual_network_name = data.azurerm_virtual_network.main.name
  resource_group_name  = data.azurerm_resource_group.network.name
}

data "azurerm_subnet" "private" {
  name                 = var.private_subnet_name
  virtual_network_name = data.azurerm_virtual_network.main.name
  resource_group_name  = data.azurerm_resource_group.network.name
}

locals {
  tags = {
    ManagedBy = "terraform"
    Project   = "pfsense-lab"
    Stack     = "azure-pfsense"
  }

  # Keyed by role rather than port number so that changing a port edits the
  # existing rule in place instead of leaving the old one orphaned.
  mgmt_rules = {
    web = { port = var.web_port, priority = 100 }
    ssh = { port = var.ssh_port, priority = 110 }
  }

  # Transitional only - see the legacy_mgmt_ports variable. Keyed by port so
  # that emptying the list removes exactly the rules it added.
  legacy_rules = {
    for idx, p in var.legacy_mgmt_ports :
    tostring(p) => { port = p, priority = 200 + idx }
  }

  # Port-forward block into the private subnet. Admin IP only - this is a
  # door into hosts that have no public address of their own.
  nat_rules = var.nat_port_range == "" ? {} : {
    natfwd = { range = var.nat_port_range, priority = 400 }
  }

  # UDP only, on purpose - see ipsec_peer_ip_cidr.
  ipsec_rules = var.ipsec_peer_ip_cidr == "" ? {} : {
    ike  = { port = 500, priority = 300 }
    natt = { port = 4500, priority = 310 }
  }
}

# --- Public IP --------------------------------------------------------------

# Static: a dynamic address would change on every stop/deallocate, silently
# invalidating anything pinned to it. Standard SKU because Basic is retired.
resource "azurerm_public_ip" "wan" {
  name                = "${var.vm_name}-wan-pip"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.network.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

# --- Management NSG ---------------------------------------------------------

# A dedicated NSG bound to the WAN NIC, rather than rules bolted onto the
# subnet-wide one. Two reasons: the subnet NSG is shared with anything else
# later placed in that subnet, and it is owned by a different Terraform state -
# writing into it is exactly the drift already causing trouble on the Aliyun
# side of this lab.
#
# Necessary but NOT sufficient on its own - see the subnet-level rules below.
resource "azurerm_network_security_group" "wan" {
  name                = "${var.vm_name}-wan-nsg"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.network.name
  tags                = local.tags
}

resource "azurerm_network_security_rule" "mgmt" {
  for_each = local.mgmt_rules

  name                        = "allow-${each.key}"
  description                 = "Management ${each.key} from the admin IP only"
  priority                    = each.value.priority
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = tostring(each.value.port)
  source_address_prefix       = var.admin_ip_cidr
  destination_address_prefix  = "*"
  resource_group_name         = data.azurerm_resource_group.network.name
  network_security_group_name = azurerm_network_security_group.wan.name
}

# Everything else inbound is denied by the NSG default rules; no explicit deny
# is declared here, since a custom deny would only shadow them at extra cost of
# clarity.

# --- Subnet-level NSG: mandatory second copy of the same rules --------------
#
# Azure evaluates INBOUND traffic against the SUBNET NSG first and only then
# against the NIC NSG. The public subnet already carries a shared NSG with no
# allow rules, so it answers DenyAllInBound and the NIC NSG above never gets to
# vote. A dedicated NIC NSG therefore cannot open a port on its own - both
# layers must allow the same flow.
#
# Confirmed rather than assumed, with:
#   az network watcher test-ip-flow --direction Inbound --protocol TCP \
#     --local <nic-private-ip>:<port> --remote <src-ip>:54321
# which reported Deny / defaultSecurityRules/DenyAllInBound while the NIC NSG
# already had a matching Allow. That command is the reliable way to settle
# "is Azure blocking this, or the guest?" - it reads the effective ruleset
# instead of probing the network.
#
# Note the tradeoff this forces: these rules live in an NSG owned by a
# different Terraform state. They are declared as standalone rule resources
# (never by importing the NSG itself) so the two states do not fight over the
# same object, but this is still drift - the shared NSG now has rules that its
# owning state does not know about.
resource "azurerm_network_security_rule" "mgmt_subnet" {
  for_each = local.mgmt_rules

  name                        = "allow-pfsense-${each.key}"
  description                 = "pfSense lab management ${each.key} from the admin IP only"
  priority                    = each.value.priority
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = tostring(each.value.port)
  source_address_prefix       = var.admin_ip_cidr
  destination_address_prefix  = data.azurerm_subnet.public.address_prefixes[0]
  resource_group_name         = data.azurerm_resource_group.network.name
  network_security_group_name = var.public_subnet_nsg_name
}

# --- Transitional rules, both layers ---------------------------------------

resource "azurerm_network_security_rule" "legacy_nic" {
  for_each = local.legacy_rules

  name                        = "allow-legacy-${each.key}"
  description                 = "TEMPORARY during the management port move - remove once verified"
  priority                    = each.value.priority
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = tostring(each.value.port)
  source_address_prefix       = var.admin_ip_cidr
  destination_address_prefix  = "*"
  resource_group_name         = data.azurerm_resource_group.network.name
  network_security_group_name = azurerm_network_security_group.wan.name
}

# --- IPsec peer, both layers ------------------------------------------------

resource "azurerm_network_security_rule" "ipsec_nic" {
  for_each = local.ipsec_rules

  name                        = "allow-ipsec-${each.key}"
  description                 = "IPsec ${each.key} from the remote peer"
  priority                    = each.value.priority
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Udp"
  source_port_range           = "*"
  destination_port_range      = tostring(each.value.port)
  source_address_prefix       = var.ipsec_peer_ip_cidr
  destination_address_prefix  = "*"
  resource_group_name         = data.azurerm_resource_group.network.name
  network_security_group_name = azurerm_network_security_group.wan.name
}

resource "azurerm_network_security_rule" "ipsec_subnet" {
  for_each = local.ipsec_rules

  name                        = "allow-pfsense-ipsec-${each.key}"
  description                 = "IPsec ${each.key} from the remote peer"
  priority                    = each.value.priority
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Udp"
  source_port_range           = "*"
  destination_port_range      = tostring(each.value.port)
  source_address_prefix       = var.ipsec_peer_ip_cidr
  destination_address_prefix  = data.azurerm_subnet.public.address_prefixes[0]
  resource_group_name         = data.azurerm_resource_group.network.name
  network_security_group_name = var.public_subnet_nsg_name
}

resource "azurerm_network_security_rule" "legacy_subnet" {
  for_each = local.legacy_rules

  name                        = "allow-pfsense-legacy-${each.key}"
  description                 = "TEMPORARY during the management port move - remove once verified"
  priority                    = each.value.priority
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = tostring(each.value.port)
  source_address_prefix       = var.admin_ip_cidr
  destination_address_prefix  = data.azurerm_subnet.public.address_prefixes[0]
  resource_group_name         = data.azurerm_resource_group.network.name
  network_security_group_name = var.public_subnet_nsg_name
}

# --- NICs -------------------------------------------------------------------

# ip_forwarding_enabled is what makes this a firewall rather than a host:
# without it Azure silently drops any packet whose source/destination is not
# the NIC's own IP, so routed traffic disappears with no error anywhere.
resource "azurerm_network_interface" "wan" {
  name                  = "${var.vm_name}-wan-nic"
  location              = var.location
  resource_group_name   = data.azurerm_resource_group.network.name
  ip_forwarding_enabled = true
  tags                  = local.tags

  ip_configuration {
    name                          = "wan"
    subnet_id                     = data.azurerm_subnet.public.id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.wan_private_ip
    public_ip_address_id          = azurerm_public_ip.wan.id
    primary                       = true
  }
}

resource "azurerm_network_interface" "lan" {
  name                  = "${var.vm_name}-lan-nic"
  location              = var.location
  resource_group_name   = data.azurerm_resource_group.network.name
  ip_forwarding_enabled = true
  tags                  = local.tags

  ip_configuration {
    name                          = "lan"
    subnet_id                     = data.azurerm_subnet.private.id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.lan_private_ip
  }
}

resource "azurerm_network_interface_security_group_association" "wan" {
  network_interface_id      = azurerm_network_interface.wan.id
  network_security_group_id = azurerm_network_security_group.wan.id
}

# The LAN NIC deliberately gets no NSG association: it inherits the private
# subnet's existing nsg-private, which is the behaviour the surrounding
# environment already assumes.

# --- Virtual machine --------------------------------------------------------

resource "azurerm_linux_virtual_machine" "pfsense" {
  name                = var.vm_name
  computer_name       = var.vm_name
  location            = var.location
  resource_group_name = data.azurerm_resource_group.compute.name
  size                = var.vm_size
  admin_username      = var.admin_username
  tags                = local.tags

  # Order matters: the first NIC becomes the primary, and pfSense assigns WAN
  # to the first interface it sees.
  network_interface_ids = [
    azurerm_network_interface.wan.id,
    azurerm_network_interface.lan.id,
  ]

  admin_ssh_key {
    username   = var.admin_username
    public_key = file(pathexpand(var.ssh_public_key_path))
  }

  disable_password_authentication = true

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = var.os_disk_type
  }

  source_image_reference {
    publisher = var.image_publisher
    offer     = var.image_offer
    sku       = var.image_sku
    version   = var.image_version
  }

  # Required for any image sold through the marketplace; the three values must
  # match the image reference exactly or the API rejects the create.
  plan {
    name      = var.image_sku
    product   = var.image_offer
    publisher = var.image_publisher
  }

  # pfSense is an appliance OS - if it fails to come up there is no other way
  # to see why. This is the Azure equivalent of the console access CHR never
  # had, and it costs nothing when unused.
  boot_diagnostics {}
}

# --- Private-subnet routing ---------------------------------------------------

resource "azurerm_route_table" "private" {
  count = var.manage_private_routing ? 1 : 0

  name                = "${var.vm_name}-private-rt"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.network.name
  tags                = local.tags

  # Keeps the table deterministic: nothing learned by a VNet gateway can be
  # propagated in. There is no gateway here today, but if one is ever added it
  # must not silently start competing with the appliance routes below.
  # (Azure's built-in system routes are always present regardless; the UDR
  # entries below override them by longest-prefix and by being user-defined.)
  bgp_route_propagation_enabled = false
}

# Everything not local leaves through the appliance, which NATs it.
resource "azurerm_route" "private_default" {
  count = var.manage_private_routing ? 1 : 0

  name                   = "default-via-appliance"
  resource_group_name    = data.azurerm_resource_group.network.name
  route_table_name       = azurerm_route_table.private[0].name
  address_prefix         = "0.0.0.0/0"
  next_hop_type          = "VirtualAppliance"
  next_hop_in_ip_address = azurerm_network_interface.lan.private_ip_address
}

# Remote cloud: same next hop, but the appliance must NOT NAT this traffic -
# see the outbound-NAT exclusion in the companion config repo.
resource "azurerm_route" "private_to_peer" {
  count = var.manage_private_routing && var.peer_cidr != "" ? 1 : 0

  name                   = "remote-cloud-via-appliance"
  resource_group_name    = data.azurerm_resource_group.network.name
  route_table_name       = azurerm_route_table.private[0].name
  address_prefix         = var.peer_cidr
  next_hop_type          = "VirtualAppliance"
  next_hop_in_ip_address = azurerm_network_interface.lan.private_ip_address
}

resource "azurerm_subnet_route_table_association" "private" {
  count = var.manage_private_routing ? 1 : 0

  subnet_id      = data.azurerm_subnet.private.id
  route_table_id = azurerm_route_table.private[0].id
}

# --- Port-forward range into the private subnet, both layers ------------------

resource "azurerm_network_security_rule" "natfwd_nic" {
  for_each = local.nat_rules

  name                        = "allow-natfwd"
  description                 = "Port-forwards to private hosts, from the admin IP only"
  priority                    = each.value.priority
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = each.value.range
  source_address_prefix       = var.admin_ip_cidr
  destination_address_prefix  = "*"
  resource_group_name         = data.azurerm_resource_group.network.name
  network_security_group_name = azurerm_network_security_group.wan.name
}

resource "azurerm_network_security_rule" "natfwd_subnet" {
  for_each = local.nat_rules

  name                        = "allow-pfsense-natfwd"
  description                 = "Port-forwards to private hosts, from the admin IP only"
  priority                    = each.value.priority
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = each.value.range
  source_address_prefix       = var.admin_ip_cidr
  destination_address_prefix  = data.azurerm_subnet.public.address_prefixes[0]
  resource_group_name         = data.azurerm_resource_group.network.name
  network_security_group_name = var.public_subnet_nsg_name
}

# --- Allow the remote cloud wholesale ----------------------------------------
# Traffic from the peer arrives already authenticated and encrypted by IPsec;
# the NSG is not the control that matters for it.
locals {
  peer_all_nsgs = var.allow_peer_all && var.peer_cidr != "" ? merge(
    { nic = azurerm_network_security_group.wan.name },
    var.public_subnet_nsg_name != "" ? { pub = var.public_subnet_nsg_name } : {},
    var.private_subnet_nsg_name != "" ? { priv = var.private_subnet_nsg_name } : {},
  ) : {}
}

resource "azurerm_network_security_rule" "peer_all" {
  for_each = local.peer_all_nsgs

  name                        = "allow-peer-cloud-all"
  description                 = "Everything from the remote cloud over the tunnel"
  priority                    = 500
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = var.peer_cidr
  destination_address_prefix  = "*"
  resource_group_name         = data.azurerm_resource_group.network.name
  network_security_group_name = each.value
}
