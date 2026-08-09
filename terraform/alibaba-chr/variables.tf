variable "profile" {
  description = "Profile name from `aliyun configure` (~/.aliyun/config.json)"
  type        = string
  default     = "default"
}

variable "region" {
  type    = string
  default = "ap-southeast-5"
}

variable "zone_id" {
  description = "Must match the zone of both vswitches"
  type        = string
  default     = "ap-southeast-5a"
}

# --- Pre-existing infrastructure, referenced only ----------------------------

variable "resource_group_id" {
  type = string
}

variable "public_vswitch_id" {
  description = "Public vswitch - primary NIC, carries the EIP"
  type        = string
}

variable "private_vswitch_id" {
  description = "Private vswitch - secondary ENI"
  type        = string
}

variable "public_security_group_id" {
  description = "Shared public SG; ingress rules are added to it as standalone resources"
  type        = string
}

variable "private_security_group_id" {
  description = "Shared private SG, attached as-is to the secondary ENI"
  type        = string
}

# --- Instance ----------------------------------------------------------------

variable "instance_name" {
  type    = string
  default = "mikrotik-chr-lab"
}

variable "image_id" {
  description = <<-EOT
    Custom CHR image, x86_64. Do NOT use an arm64 CHR build: it imports and
    launches without error but the instance stops itself ~20s after every
    start, with no console output to explain why (CHR is headless, so VNC
    shows nothing either way).
  EOT
  type        = string
}

variable "instance_type" {
  description = "Cheap burstable x86_64 is plenty; CHR is not CPU-bound here"
  type        = string
  default     = "ecs.t6-c1m1.large"
}

variable "system_disk_category" {
  description = <<-EOT
    Availability is zone AND instance-type specific, not merely regional.
    Check before changing:
      aliyun ecs DescribeAvailableResource --ZoneId <z> \
        --DestinationResource SystemDisk --InstanceType <type>
  EOT
  type        = string
  default     = "cloud_efficiency"
}

variable "system_disk_size" {
  type    = number
  default = 20
}

variable "eip_bandwidth" {
  description = <<-EOT
    Peak rate cap in Mbit/s. Under PayByTraffic this is NOT a billed
    commitment - billing is per GB of egress, so raising it adds no fixed
    cost and the console shows no price estimate when you change it.
    Ceiling is 200 for PayByTraffic + PostPaid (500 for PayByBandwidth).
  EOT
  type        = string
  default     = "100"
}

# --- Access ------------------------------------------------------------------

variable "admin_ip_cidr" {
  description = "Only source allowed to reach management. A /32."
  type        = string

  validation {
    condition     = can(cidrnetmask(var.admin_ip_cidr))
    error_message = "admin_ip_cidr must be CIDR notation, e.g. 203.0.113.10/32."
  }
}

variable "winbox_port" {
  description = "Must match /ip service winbox on the device"
  type        = number
  default     = 8291
}

variable "ssh_port" {
  description = "Must match /ip service ssh on the device"
  type        = number
  default     = 22
}

variable "ipsec_peer_ip_cidr" {
  description = "Public address of the remote tunnel peer, as a /32. Empty disables the IPsec openings."
  type        = string
  default     = ""

  validation {
    condition     = var.ipsec_peer_ip_cidr == "" || can(cidrnetmask(var.ipsec_peer_ip_cidr))
    error_message = "ipsec_peer_ip_cidr must be empty or CIDR notation."
  }
}

# --- Routing -----------------------------------------------------------------

variable "vpc_id" {
  description = "VPC the custom route table is created in"
  type        = string
}

variable "peer_cidr" {
  description = <<-EOT
    Remote cloud's supernet (the Azure VNet), reached through the appliance.
    Traffic to this prefix must NOT be NAT'd - the far side needs to see real
    source addresses for return routing to work.
  EOT
  type        = string
  default     = ""
}

variable "manage_private_routing" {
  description = <<-EOT
    Create a custom route table for the private vswitch and move it there.

    Why a custom table: the VPC ships a single System route table shared by
    EVERY vswitch, public ones included. A default route added there would also
    apply to the public vswitch that holds the appliance's own uplink, pointing
    its default at its own secondary NIC - a loop. Scoping the default route to
    the private subnet requires a table of its own.

    Note this RE-ASSOCIATES the vswitch, an object owned by another Terraform
    state. It is a deliberate, recorded change.
  EOT
  type        = bool
  default     = false
}

variable "public_private_ip" {
  description = <<-EOT
    Static address for the primary NIC. Pinned because the peer references it:
    it is the IPsec local address, the GRE local address, and the /32 the peer
    routes out of its WAN to keep the transport off the tunnel.
  EOT
  type        = string
  default     = ""
}

variable "private_eni_ip" {
  description = <<-EOT
    Static address for the secondary ENI. Less critical than the Azure side -
    Alibaba route entries reference the ENI ID, not an address, so routing
    survives a change - but pinning it keeps a rebuild reproducible.
  EOT
  type        = string
  default     = ""
}

variable "nat_port_range" {
  description = <<-EOT
    Port range reserved for port-forwards into the private vswitch, written
    Alibaba-style as "20000/20999". Opened on the public security group from
    the admin IP only; the appliance then dst-nats each port to a private
    host's SSH.

    A range rather than one rule per host: the security group is shared
    infrastructure, so every added rule is drift against another Terraform
    state. Reserving a block once means adding a private host later is an
    appliance-side change with no cloud-side edit.

    Empty disables it.
  EOT
  type        = string
  default     = ""
}

variable "allow_peer_into_private_sg" {
  description = <<-EOT
    Allow the remote cloud's supernet into the PRIVATE security group.

    Without this the tunnel works but only in one direction for hosts: the
    private security group typically permits just the local VPC range, so a
    packet arriving from the remote cloud's address space is dropped before it
    reaches the host. The reverse direction succeeds, which makes it look like
    an asymmetric routing fault rather than a firewall rule.

    Adds a rule to a security group owned by another Terraform state - the same
    deliberate drift as the public-side rules.
  EOT
  type        = bool
  default     = false
}
