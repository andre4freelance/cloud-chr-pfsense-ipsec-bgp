variable "subscription_id" {
  description = "Azure subscription the lab is deployed into (managed-service, not production)"
  type        = string
}

variable "location" {
  description = "Must match the existing VNet's region - a NIC cannot cross regions"
  type        = string
  default     = "indonesiacentral"
}

# --- Pre-existing infrastructure, referenced only, never created here --------
# The signed-in identity is Contributor on these resource groups ONLY, with no
# subscription-scope role. That means `azurerm_resource_group` cannot be
# created at all, so the lab lives inside the groups that already exist.

variable "network_resource_group" {
  description = "Existing resource group holding the VNet, subnets and NSGs"
  type        = string
}

variable "compute_resource_group" {
  description = "Existing resource group the VM and its disk go into"
  type        = string
}

variable "vnet_name" {
  description = "Existing VNet name"
  type        = string
}

variable "public_subnet_name" {
  description = "Existing public subnet - carries the WAN NIC and the public IP"
  type        = string
}

variable "private_subnet_name" {
  description = "Existing private subnet - carries the LAN NIC"
  type        = string
}

variable "public_subnet_nsg_name" {
  description = <<-EOT
    Shared NSG already attached to the public subnet. Inbound traffic is
    filtered by the SUBNET NSG before the NIC NSG, so management rules must be
    present here too or the NIC-level rules never take effect. Rules are added
    as standalone resources; the NSG itself belongs to another Terraform state
    and is never imported here.
  EOT
  type        = string
}

# --- pfSense instance -------------------------------------------------------

variable "vm_size" {
  description = <<-EOT
    Cheapest size that is actually deployable here, which is not the cheapest
    size that exists. Three constraints stack up, and the binding one is quota:

      1. 2 NICs are required, and no 1-vCPU size in this region offers
         MaxNetworkInterfaces >= 2, so 2 vCPU is the floor.
      2. Every v2 B-series family (Bas_v2, Bsv2) has a core quota of ZERO on
         this subscription - so Standard_B2ats_v2 (~$7.81/mo) fails at create
         time with a 409, not at plan time.
      3. B-series v1, the one cheap family that does have quota (10 cores), is
         not offered in indonesiacentral at all.

    That leaves the Dals_v6 family at ~$66/mo. Re-check with
    `az vm list-usage -l <region>` before assuming a cheaper size will work;
    availability and quota are separate gates and both are per-region.
    Side effect worth keeping: 4 GiB removes the RAM risk that 1 GiB carried.
  EOT
  type        = string
  default     = "Standard_D2als_v6"
}

variable "vm_name" {
  type    = string
  default = "pfsense-lab"
}

variable "admin_username" {
  description = <<-EOT
    Azure rejects reserved names here ("admin", "administrator", "root", ...),
    so this cannot be pfSense's own `admin` account. This user is what the
    Azure agent provisions for SSH; the pfSense WebGUI keeps its own separate
    `admin` login.
  EOT
  type        = string
  default     = "pfadmin"
}

variable "ssh_public_key_path" {
  description = "Public half of a keypair dedicated to this lab (not shared with other systems)"
  type        = string
  default     = "~/.ssh/pfsense-azure.pub"
}

variable "os_disk_type" {
  description = "Standard_LRS (HDD) keeps the lab cheap; pfSense is not IO-bound here"
  type        = string
  default     = "Standard_LRS"
}

# --- Marketplace image ------------------------------------------------------
# This image carries a `plan`, so the subscription must have accepted its
# marketplace terms. The signed-in identity cannot read or accept them
# (AuthorizationFailed on Microsoft.MarketplaceOrdering, which is
# subscription-scope). See the note in main.tf.

variable "image_publisher" {
  type    = string
  default = "netgate"
}

variable "image_offer" {
  type    = string
  default = "pfsense-plus-public-cloud-fw-vpn-router"
}

variable "image_sku" {
  description = "TAC Lite is the entry tier. ent/pro exist and cost more."
  type        = string
  default     = "pfsense-public-lite-2511"
}

variable "image_version" {
  description = "Pinned, not 'latest' - a silent image bump would force-replace the VM"
  type        = string
  default     = "26.03.1"
}

# --- Management access ------------------------------------------------------

variable "admin_ip_cidr" {
  description = "The only source allowed to reach management. A /32; do not widen."
  type        = string

  validation {
    condition     = can(cidrnetmask(var.admin_ip_cidr))
    error_message = "admin_ip_cidr must be valid CIDR notation, e.g. 203.0.113.10/32."
  }
}

variable "web_port" {
  description = <<-EOT
    pfSense WebGUI port as reached from outside. Starts at 443 because that is
    what a fresh image listens on - the NSG has to match reality before the
    box is reconfigured, otherwise there is no way in to reconfigure it.
    Change to 7880 only AFTER pfSense itself has been moved to that port.
  EOT
  type        = number
  default     = 443
}

variable "ssh_port" {
  description = "Same staging logic as web_port: 22 first, 7822 after pfSense is moved."
  type        = number
  default     = 22
}

variable "ipsec_peer_ip_cidr" {
  description = <<-EOT
    Public address of the remote IPsec peer, as a /32. Empty disables the
    IPsec openings entirely.

    Only UDP 500 and 4500 are opened - deliberately not ESP (IP protocol 50).
    Both peers sit behind 1:1 NAT (the public address is not on either
    interface), so IKE negotiates NAT-T and every ESP packet is encapsulated
    in UDP 4500. Opening bare ESP would be pointless here: no ESP packet ever
    reaches the wire.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.ipsec_peer_ip_cidr == "" || can(cidrnetmask(var.ipsec_peer_ip_cidr))
    error_message = "ipsec_peer_ip_cidr must be empty or valid CIDR, e.g. 203.0.113.10/32."
  }
}

variable "legacy_mgmt_ports" {
  description = <<-EOT
    Ports to keep open ALONGSIDE web_port/ssh_port while management is being
    moved. Exists to make the move non-destructive: opening the new ports
    before the guest listens on them is harmless, whereas closing the old ones
    first locks you out of the box you still need in order to reconfigure it.

    Sequence:
      1. set this to the current ports (e.g. [443, 22]) and apply
      2. change the ports inside pfSense
      3. verify the new ports answer with a real protocol handshake
      4. set this back to [] and apply

    Leaving values here after step 4 is a silent security hole - the whole
    point of the move is that the old ports stop being reachable.
  EOT
  type        = list(number)
  default     = []
}

# --- Private-subnet routing ---------------------------------------------------

variable "peer_cidr" {
  description = <<-EOT
    Remote cloud's supernet (the Alibaba VPC), reached through the appliance.
    Traffic to this prefix must NOT be NAT'd - the far side needs to see real
    source addresses for return routing to work.
  EOT
  type        = string
  default     = ""
}

variable "manage_private_routing" {
  description = <<-EOT
    Create a route table for the private subnet, sending its default route and
    the remote-cloud prefix through the appliance.

    The association writes to the SUBNET object, which belongs to another
    Terraform state. There is no way around that: an unassociated route table
    has no effect at all. It is a deliberate, recorded change.
  EOT
  type        = bool
  default     = false
}

variable "wan_private_ip" {
  description = <<-EOT
    Static private address for the WAN NIC. Pinned rather than dynamic because
    the peer's configuration references it directly - it is the phase 2 remote
    selector and the /32 that keeps the tunnel transport off the tunnel. A
    silent change on the cloud side would break the tunnel with no local edit.
  EOT
  type        = string
}

variable "lan_private_ip" {
  description = <<-EOT
    Static private address for the LAN NIC. An Azure user-defined route with a
    VirtualAppliance next hop can only point at an IP ADDRESS - there is no
    option to reference the NIC itself. If this address moved, every route in
    the private subnet's table would point at nothing until Terraform ran
    again. (Alibaba is immune to this: its route entries reference the ENI ID.)
  EOT
  type        = string
}

variable "nat_port_range" {
  description = <<-EOT
    Port range reserved for port-forwards into the private subnet, e.g.
    "20000-20999". Opened on the WAN from the admin IP only; pfSense then
    translates each port to a private host's SSH.

    A range rather than one rule per host: the NSG is shared infrastructure, so
    every added rule is drift against another Terraform state. Reserving a
    block once means adding a private host later is a pfSense-side change with
    no cloud-side edit at all.

    Empty disables it.
  EOT
  type        = string
  default     = ""
}

variable "private_subnet_nsg_name" {
  description = "Shared NSG on the private subnet; peer-network rules are added to it as standalone resources"
  type        = string
  default     = ""
}

variable "allow_peer_all" {
  description = <<-EOT
    Allow everything from the remote cloud's supernet, on both the public and
    private NSGs.

    Deliberately broad: the tunnel is already authenticated and encrypted, and
    a per-port allow-list across two clouds becomes its own debugging problem.
    Narrow it later if this stops being a lab.
  EOT
  type        = bool
  default     = false
}
