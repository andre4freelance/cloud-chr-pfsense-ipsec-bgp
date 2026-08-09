# Multi-cloud tunnel: MikroTik CHR ↔ pfSense, routed with BGP

A working site-to-site link between two public clouds, built with appliances
rather than the managed VPN products: **IPsec** for transport, a **GRE tunnel**
carrying a point-to-point /30, and **eBGP** over that /30 exchanging each
cloud's prefixes dynamically.

The end state is ordinary routing. A VM on one cloud's private subnet reaches a
VM on the other's by its real address, with no NAT in between, and both still
reach the internet through their local appliance.

```
   Cloud A (Alibaba)                          Cloud B (Azure)
   ┌────────────────────┐                  ┌────────────────────┐
   │ MikroTik CHR       │                  │ pfSense            │
   │ ether1  public  ───┼── IPsec/NAT-T ───┼─── hn0  public     │
   │ ether2  private    │   UDP 500/4500   │    hn1  private    │
   │                    │                  │                    │
   │  gre-tunnel ───────┼── GRE, /30 P2P ──┼──── gre0           │
   │  AS 64513          │◄───── eBGP ─────►│    AS 64512        │
   └────────┬───────────┘                  └─────────┬──────────┘
            │ default route                          │ default route
   ┌────────┴───────────┐                  ┌─────────┴──────────┐
   │ private subnet     │                  │ private subnet     │
   │ (no public IPs)    │                  │ (no public IPs)    │
   └────────────────────┘                  └────────────────────┘
```

## Why this is harder than it looks

**Neither appliance owns its public address.** Both clouds present the public IP
through 1:1 NAT — the interface only ever carries a private address. Almost
every non-obvious part of this configuration follows from that one fact, and it
is why copying a standard site-to-site recipe does not work.

The other recurring theme: **three firewalls, not one.** Each hop has its own —
the cloud security group on each side, and the appliance's own ruleset in the
middle. The middle one is invisible from outside and accounts for most of the
time lost.

## What is here

| Path | |
|---|---|
| `routeros/chr-tunnel.rsc.tmpl` | RouterOS side, templated |
| `pfsense/apply-tunnel.php` | pfSense side, idempotent, writes config only |
| `apply.sh` | Renders the templates from `vars.env` and pushes them |
| `docs/bgp-stability.md` | Why the BGP session flapped, and the three unrelated causes behind it |

Infrastructure (VMs, NICs, cloud firewalls, route tables) is assumed to exist.
This repo configures what runs inside the appliances.

## Build it

```bash
cp vars.env.example vars.env      # fill in, including a real IPSEC_PSK
./apply.sh render                 # inspect what will be sent; the PSK is redacted
CHR_SSH=user@<chr-ip> ./apply.sh chr
PF_SSH=admin@<pf-ip>  ./apply.sh pfsense
ssh admin@<pf-ip> reboot          # pfSense applies on boot, deliberately
```

Verify in this order — each step makes the next one worth attempting:

```bash
swanctl --list-sas                        # SA up, and BOTH direction counters moving
ping <peer tunnel ip>                     # the /30 works
vtysh -c "show bgp summary"               # established, prefixes received
ping -S <local private> <peer private>    # the actual goal
```

## The things that cost the most time

Every item below was a real failure, not a hypothetical.

**Open UDP 500 and 4500 — nothing else.** Behind NAT, IKE always negotiates
NAT-T and every ESP packet is UDP-encapsulated. A rule for ESP (IP protocol 50)
never matches a single packet.

**The SA can establish, decrypt perfectly, and send nothing.** If one side's GRE
sources from its private address while the peer's policy names its public one,
the selectors do not mirror and egress matches no policy. The signature is
unmistakable once you know it:

```
in  1872 bytes,  39 packets     <- decrypts fine
out    0 bytes,   0 packets     <- sends nothing, no error anywhere
```

The fix is to give the appliance its own public address as a virtual IP and
source the tunnel from it. Read the per-direction counters early; an
`INSTALLED` SA proves nothing about traffic.

**Never advertise the tunnel's own transport.** `redistribute connected` picked
up that virtual IP — the very address the peer's tunnel points at. The peer
installed a route to the tunnel endpoint *through the tunnel*, and the link
collapsed. Use explicit `network` statements, and filter it inbound at the peer
as well.

**`network X` advertises nothing unless X is in the routing table.** Neither
cloud gives you a connected route for the whole VPC/VNet, only the per-subnet
prefixes. A `network` statement with no matching route is accepted in silence
and advertises nothing — in `show bgp` the prefix appears without the `*>`
valid marker, which is easy to skim past. Add a static route for the supernet,
with an **interface** next-hop so the config travels between environments.

**Outbound NAT will quietly rewrite the tunnel's replies.** pfSense's automatic
outbound NAT covers every interface, tunnel included. Replies leave with their
source rewritten to the tunnel address, the far end receives an answer from a
host it never contacted, and drops it. The tell: pings to and from the *tunnel*
addresses work while LAN-to-LAN does not. A parenthesised address in
`pfctl -ss` is the proof.

**A GRE keepalive nobody answers.** RouterOS marks a GRE interface down after
three unanswered keepalives. FreeBSD's `gre(4)` never answers them, so the
tunnel flapped every few seconds and took BGP with it. Unset it — the BGP hold
timer and IPsec DPD already cover liveness.

**pfSense filter rules use `address` for a literal CIDR, not `network`.**
`network` means an interface name or alias. A filter rule using `network` with a
CIDR is skipped silently by the generator: present in `config.xml`, absent from
`pfctl -sr`, no error anywhere. (NAT rules are the exception, where `network`
does take a CIDR — which is what makes this so easy to get wrong.)

There is a longer write-up of the BGP session that dropped every few minutes,
and the three separate causes behind it, in
[docs/bgp-stability.md](docs/bgp-stability.md). One of them was the firewall
dropping its own SYN-ACK to the peer.

## Secrets

`vars.env` holds the pre-shared key and is gitignored, as are rendered configs
and device backups. Take backups with:

```bash
ssh <pfsense> 'cat /cf/conf/config.xml' > pfsense-config.xml
ssh <routeros> '/export'                > routeros-export.rsc
chmod 600 *.xml *.rsc
```

Both contain pre-shared keys and password hashes. Keep them out of any repo.

## License

MIT — see [LICENSE](LICENSE).
