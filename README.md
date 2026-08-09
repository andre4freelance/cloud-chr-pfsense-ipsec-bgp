# Multi-cloud tunnel — MikroTik CHR (Alibaba) ↔ pfSense (Azure)

A routed site-to-site link between two clouds: IPsec transport, a GRE tunnel
carrying a point-to-point /30, and eBGP over that /30 exchanging each cloud's
prefixes. End state is that a host on one cloud's private subnet can reach a
host on the other's, by address, with no NAT in between.

This repo holds the **appliance configuration**. The infrastructure lives in a
separate Terraform repo (`terraform/aliyun-vm` and `terraform/azure-pfsense`).
The split is deliberate: Terraform builds the machines and the cloud firewalls,
these scripts configure what runs inside them.

```
   Alibaba Cloud                              Azure
   ┌──────────────────┐                    ┌──────────────────┐
   │ CHR              │                    │ pfSense          │
   │ ether1  public   │◄── IPsec/NAT-T ───►│ hn0  public      │
   │ ether2  private  │    UDP 500/4500    │ hn1  private     │
   │                  │                    │                  │
   │   gre-azure ─────┼── GRE, /30 P2P ────┼───── gre0        │
   │   AS 64513       │◄──── eBGP ────────►│   AS 64512       │
   └──────────────────┘                    └──────────────────┘
```

**Neither appliance owns its public address.** Both clouds do 1:1 NAT, so the
interface carries a private address and the public one exists only outside.
Almost every non-obvious part of this configuration follows from that.

## Building it from nothing

1. **Infrastructure** — in the Terraform repo, one stack per cloud:
   ```bash
   cd terraform/aliyun-vm     && terraform init && terraform apply
   cd terraform/azure-pfsense && terraform init && terraform apply
   ```
   Each takes a `terraform.tfvars` (see the `.example` next to it) naming the
   pre-existing VPC/VNet, subnets and security groups. Note the outputs: the
   two public addresses and the two private WAN addresses.

2. **Cross-reference the peers.** Put each side's public address into the
   other's tfvars as `ipsec_peer_ip_cidr` and re-apply, so both cloud firewalls
   open UDP 500 and 4500 to the peer. Only UDP — see below.

3. **Configure the appliances**:
   ```bash
   cp vars.env.example vars.env    # fill in, including a real IPSEC_PSK
   ./apply.sh render               # inspect what will be sent, PSK redacted
   CHR_SSH=user@<chr-ip> ./apply.sh chr
   PF_SSH=admin@<pf-ip>  ./apply.sh pfsense
   ssh admin@<pf-ip> reboot        # pfSense applies on boot, deliberately
   ```

4. **Verify** in this order — each step proves the one below it is worth doing:
   ```bash
   swanctl --list-sas                  # SA established, and BOTH directions counting
   ping <peer tunnel ip>               # the /30 works
   vtysh -c "show bgp summary"         # established, prefixes received
   ping -S <local private> <peer private>   # the actual goal
   ```

## Things that will not be obvious later

**Only UDP 500 and 4500 need opening.** Both ends are behind NAT, so IKE always
negotiates NAT-T and every ESP packet is encapsulated in UDP. A rule for ESP
(IP protocol 50) would never match a packet.

**On Azure, inbound is filtered twice** — the subnet NSG is evaluated before
the NIC NSG, and both must allow the flow. A NIC-level NSG alone can never
open a port. `az network watcher test-ip-flow` reads the effective verdict and
settles "is it the cloud or the guest?" in one command.

**pfSense must own its public address as a VIP.** The GRE has to source from it
so that egress matches the IPsec policy the peer mirrors. Skip this and the SA
establishes, decrypts inbound perfectly, and sends nothing — `out: 0 packets`,
no error anywhere.

**Never advertise the tunnel's own transport.** `redistribute connected` picks
up that VIP; the peer then routes the GRE destination through the GRE, and the
link collapses. Use explicit `network` statements, and filter it inbound on the
other side too.

**A `network X` statement advertises nothing unless X is in the routing table.**
Neither cloud gives you a connected route for the VPC/VNet supernet, only the
per-subnet prefixes — so each side carries a static route for its own supernet,
with an **interface** next-hop rather than a gateway address so the config
travels.

**Apply pfSense configuration by rebooting.** Calling its service functions from
a script once threw inside `write_config()` mid-reconfigure and ran a
`chown -R` with an empty chroot path across ~130k files, killing PAM and every
SSH login on the box. `apply-tunnel.php` therefore only writes.

For why the BGP session used to drop every few minutes — and the three separate
causes behind it — see [docs/bgp-stability.md](docs/bgp-stability.md).

## Secrets

`vars.env` holds the PSK and is gitignored, as are rendered configs and device
backups. Take backups with:

```bash
ssh admin@<pf-ip> 'cat /cf/conf/config.xml' > ~/backups/pfsense-config.xml
ssh user@<chr-ip> '/export'                 > ~/backups/chr-export.rsc
chmod 600 ~/backups/*
```

Both contain pre-shared keys and password hashes. Keep them out of any repo.
