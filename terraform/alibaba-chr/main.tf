##############################################################################
# MikroTik CHR on Alibaba Cloud — Alibaba end of the multi-cloud tunnel
#
# Two NICs: the primary sits on the public vswitch and carries an EIP, the
# secondary on the private vswitch. The VPC, vswitches and security groups
# already exist and belong to a DIFFERENT Terraform state — they are read
# through variables and never created or modified here.
#
# Scope note: this builds the INFRASTRUCTURE only. RouterOS itself (IPsec, GRE,
# BGP) is configured by the scripts in the companion config repo; a CHR that
# boots from here has working management access and nothing else.
##############################################################################

resource "alicloud_instance" "mikrotik" {
  instance_name        = var.instance_name
  host_name            = var.instance_name
  image_id             = var.image_id
  instance_type        = var.instance_type
  availability_zone    = var.zone_id
  security_groups      = [var.public_security_group_id]
  vswitch_id           = var.public_vswitch_id
  instance_charge_type = "PostPaid"
  resource_group_id    = var.resource_group_id
  system_disk_category = var.system_disk_category
  system_disk_size     = var.system_disk_size
  private_ip           = var.public_private_ip != "" ? var.public_private_ip : null

  # No instance-level public IP: an EIP is attached below instead. The
  # instance-level address is dynamic and is lost on stop/start, which breaks
  # every IPsec peer and firewall rule pinned to it.
  internet_max_bandwidth_out = 0

  lifecycle {
    # RouterOS credentials are managed on the device, not from here. Without
    # this, an imported instance shows a perpetual diff on `password`, which
    # the API never returns.
    ignore_changes = [password, image_id]
  }
}

# --- Static public address ---------------------------------------------------
# An existing instance-level address can be converted in place, keeping the
# same IP, with:
#   aliyun ecs ConvertNatPublicIpToEip --RegionId <r> --InstanceId <id>
# which works while the instance is running. For a fresh build the EIP below
# is simply allocated and attached.
resource "alicloud_eip_address" "chr" {
  address_name         = "${var.instance_name}-eip"
  internet_charge_type = "PayByTraffic"
  bandwidth            = var.eip_bandwidth
  resource_group_id    = var.resource_group_id
  payment_type         = "PayAsYouGo"
}

resource "alicloud_eip_association" "chr" {
  allocation_id = alicloud_eip_address.chr.id
  instance_id   = alicloud_instance.mikrotik.id
  instance_type = "EcsInstance"
}

# --- Private-side NIC --------------------------------------------------------
# Hot-plug is instance-family specific: it works on some families and fails on
# the burstable t6 family with InvalidOperation.HotPlugNotSupport. Terraform's
# attachment resource also has a poll timeout shorter than the attach sometimes
# needs — if it reports failure, confirm with DescribeNetworkInterfaces before
# retrying, because the attach usually did happen.
resource "alicloud_ecs_network_interface" "private" {
  network_interface_name = "${var.instance_name}-private-eni"
  vswitch_id             = var.private_vswitch_id
  security_group_ids     = [var.private_security_group_id]
  description            = "CHR private-side NIC"
  resource_group_id      = var.resource_group_id
  primary_ip_address     = var.private_eni_ip != "" ? var.private_eni_ip : null
}

resource "alicloud_ecs_network_interface_attachment" "private" {
  network_interface_id = alicloud_ecs_network_interface.private.id
  instance_id          = alicloud_instance.mikrotik.id
}

# --- Ingress on the shared public security group ------------------------------
# Declared as standalone rules. The security group itself belongs to another
# Terraform state and is never imported here, so the two states cannot fight
# over the same object.
locals {
  mgmt_rules = {
    winbox = { port = var.winbox_port, cidr = var.admin_ip_cidr, protocol = "tcp", descr = "Winbox from the admin IP" }
    ssh    = { port = var.ssh_port, cidr = var.admin_ip_cidr, protocol = "tcp", descr = "SSH from the admin IP" }
  }

  # UDP only. Both tunnel endpoints sit behind 1:1 NAT, so IKE always
  # negotiates NAT-T and ESP is carried inside UDP 4500 — a bare ESP rule
  # would never match a single packet.
  ipsec_rules = var.ipsec_peer_ip_cidr == "" ? {} : {
    ike  = { port = 500, cidr = var.ipsec_peer_ip_cidr, protocol = "udp", descr = "IPsec IKE from the tunnel peer" }
    natt = { port = 4500, cidr = var.ipsec_peer_ip_cidr, protocol = "udp", descr = "IPsec NAT-T from the tunnel peer" }
  }

  # Port-forward block into the private vswitch. Admin IP only - this is a
  # door into hosts that have no public address of their own.
  nat_rules = var.nat_port_range == "" ? {} : {
    natfwd = { range = var.nat_port_range, cidr = var.admin_ip_cidr, protocol = "tcp", descr = "Port-forwards to private hosts, from the admin IP only" }
  }

  all_rules = merge(local.mgmt_rules, local.ipsec_rules)
}

resource "alicloud_security_group_rule" "ingress" {
  for_each = local.all_rules

  type              = "ingress"
  ip_protocol       = each.value.protocol
  nic_type          = "intranet"
  policy            = "accept"
  priority          = 1
  port_range        = "${each.value.port}/${each.value.port}"
  security_group_id = var.public_security_group_id
  cidr_ip           = each.value.cidr
  description       = each.value.descr
}

# --- Private-subnet routing ---------------------------------------------------

resource "alicloud_route_table" "private" {
  count = var.manage_private_routing ? 1 : 0

  vpc_id           = var.vpc_id
  route_table_name = "${var.instance_name}-private-rt"
  description      = "Private subnet egress via the appliance"
  associate_type   = "VSwitch"
}

resource "alicloud_route_table_attachment" "private" {
  count = var.manage_private_routing ? 1 : 0

  vswitch_id     = var.private_vswitch_id
  route_table_id = alicloud_route_table.private[0].id
}

# Default route: everything the private subnet cannot reach locally goes to the
# appliance, which NATs it out of its own public interface.
resource "alicloud_route_entry" "private_default" {
  count = var.manage_private_routing ? 1 : 0

  route_table_id        = alicloud_route_table.private[0].id
  destination_cidrblock = "0.0.0.0/0"
  nexthop_type          = "NetworkInterface"
  nexthop_id            = alicloud_ecs_network_interface.private.id

  depends_on = [alicloud_ecs_network_interface_attachment.private]
}

# Remote cloud: same next hop, but the appliance must NOT NAT this traffic -
# see the masquerade exclusion in the companion config repo.
resource "alicloud_route_entry" "private_to_peer" {
  count = var.manage_private_routing && var.peer_cidr != "" ? 1 : 0

  route_table_id        = alicloud_route_table.private[0].id
  destination_cidrblock = var.peer_cidr
  nexthop_type          = "NetworkInterface"
  nexthop_id            = alicloud_ecs_network_interface.private.id

  depends_on = [alicloud_ecs_network_interface_attachment.private]
}

# Port-forward range. Separate from `ingress` because its port_range is already
# a range, not a single port doubled.
resource "alicloud_security_group_rule" "natfwd" {
  for_each = local.nat_rules

  type              = "ingress"
  ip_protocol       = each.value.protocol
  nic_type          = "intranet"
  policy            = "accept"
  priority          = 1
  port_range        = each.value.range
  security_group_id = var.public_security_group_id
  cidr_ip           = each.value.cidr
  description       = each.value.descr
}

# Remote cloud into the private security group. See the variable's description
# for why the tunnel appears to work one-way without it.
resource "alicloud_security_group_rule" "peer_into_private" {
  count = var.allow_peer_into_private_sg && var.peer_cidr != "" ? 1 : 0

  type              = "ingress"
  ip_protocol       = "all"
  nic_type          = "intranet"
  policy            = "accept"
  priority          = 1
  port_range        = "-1/-1"
  security_group_id = var.private_security_group_id
  cidr_ip           = var.peer_cidr
  description       = "Remote cloud over the tunnel"
}

# Same for the public security group, so the remote cloud can also reach hosts
# on the public vswitch (the appliance itself included).
resource "alicloud_security_group_rule" "peer_into_public" {
  count = var.allow_peer_into_private_sg && var.peer_cidr != "" ? 1 : 0

  type              = "ingress"
  ip_protocol       = "all"
  nic_type          = "intranet"
  policy            = "accept"
  priority          = 1
  port_range        = "-1/-1"
  security_group_id = var.public_security_group_id
  cidr_ip           = var.peer_cidr
  description       = "Remote cloud over the tunnel"
}
