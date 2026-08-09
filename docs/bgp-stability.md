# Why the BGP session kept dropping — three separate causes

The session would establish, exchange prefixes, then reset. Routes vanished
with it, so end-to-end pings worked only intermittently. It turned out to be
three unrelated faults stacked on top of each other, which is why fixing any
one of them only changed the frequency.

The two ends reported different reasons, and that mattered:

| Side | Message |
|---|---|
| pfSense (FRR) | `No path to specified Neighbor` |
| CHR (RouterOS) | `HoldTimer expired` |

They are not two views of one event. The RouterOS message is the primary fault;
the FRR message is what it logs when it retries against a peer that has already
gone `Idle`.

## Cause 1 — GRE keepalive nobody answers

RouterOS's GRE has `keepalive=10s,3` by default: it sends GRE keepalive packets
and marks the interface **down** after three go unanswered.

**FreeBSD's `gre(4)`, which pfSense uses, never answers GRE keepalives.** So the
CHR declared the link dead every few seconds, BGP lost its nexthop, and the
session reset — roughly once a minute.

```
/interface gre set [find name=gre-azure] !keepalive
```

`keepalive=none` is rejected; the property has to be unset. Liveness is already
covered by the BGP hold timer and IPsec DPD, so nothing is lost.

This was the largest single contributor. Flap rate went from ~1/minute to
~1/6 minutes — which then exposed the next cause.

## Cause 2 — the peer's supernet contains the tunnel's own endpoint

pfSense's GRE tunnels to the CHR's **private** WAN address, and BGP learns the
CHR's VPC **supernet**, which contains that address. The moment the route
installs, reaching the tunnel endpoint requires the tunnel.

Recursion: nexthop lost → session drops → route withdrawn → tunnel recovers →
session up → route installs → breaks again.

The fix is a more-specific route so longest-prefix always wins:

```
ip route <peer private WAN>/32 <wan interface>
```

The same trap exists in the other direction and is worse there: pfSense's
public address is a local VIP, so `redistribute connected` advertised it, the
CHR routed the GRE destination through the GRE, and the instance ended up
stopped. Hence explicit `network` statements on one side and an inbound reject
on the other.

## Cause 3 — the firewall blocked its own SYN-ACK

With the first two fixed the session still dropped every few minutes. What
finally identified it was `pflog`, not reasoning:

```
169.254.100.1.179 > 169.254.100.2.35873: Flags [S.]     <- BLOCKED, outbound
```

The peer opens the BGP connection, FRR accepts it and generates a SYN-ACK, and
**pf drops that SYN-ACK on the way out** under the default deny. The peer never
gets an answer, retransmits, gives up, picks a new source port, repeats.

The cause is a detail in pfSense's generated ruleset. The
"let out anything from firewall host itself" rule for a tunnel interface reads:

```
pass out route-to (gre0 <peer>) inet from <self> to ! <tunnel /30>
```

It **excludes the tunnel subnet** — precisely where the BGP peer lives. Traffic
the firewall originates towards its own peer matches no pass rule at all.

Two counter readings make this diagnosable without packet captures:

```
pass in quick on gre0 ...   [ Evaluations: 10998  Packets: 0  States: 0 ]
block drop out log inet all [ Packets: 10216 ]
```

A pass rule evaluated thousands of times that passes **zero** packets, sitting
next to a default-deny counting thousands outbound, says the traffic is being
generated and dropped on egress.

Fix: a floating **outbound** pass rule on the tunnel interface — with two
details that decide whether it works at all:

- pfSense writes user rules with `flags S/SA`, which matches only a pure SYN.
  A SYN-ACK carries both S and A and never matches. The rule looks correct and
  does nothing.
- Use **sloppy state**. Strict state tracking does not hold for a flow the
  firewall itself originates over a tunnel.

Result: from dropping every 3–6 minutes to **34 minutes and counting with zero
drops**, and LAN-to-LAN pings at 100/100, 0% loss in both directions.

## Two changes that made it worse

Recorded so they are not tried again.

**Floating pf states** (`system/statepolicy = floating`). Intended to stop
if-bound states breaking across IPsec reattribution. It killed the outbound
direction entirely — the SA installed, decrypted inbound, and sent nothing —
even though the policy, the VIP and the tunnel source were all correct.
Reverting restored traffic immediately.

**Setting the pfSense side `passive`.** The session then never came up at all.
That failure was still informative: it proved pfSense had always been the side
opening the TCP connection.

## Diagnosing this class of fault

The ordering that worked, cheapest first:

1. `swanctl --list-sas` — is the SA up, and are **both** direction counters
   moving? `INSTALLED` with `out: 0 packets` is a policy mismatch, not a
   network problem.
2. Ping the two /30 addresses. If that works and LAN-to-LAN does not, suspect
   **source NAT** before firewall rules — a parenthesised address in
   `pfctl -ss` is proof the source is being rewritten.
3. Long ping, 200 packets. Loss here means a real path problem; 0% loss with a
   flapping TCP session means the fault is in the session.
4. Compare the two ends' reset reasons. They are usually different, and the
   less obvious one is usually the cause.
5. `pfctl -vsr` counters. A pass rule with many evaluations and zero packets is
   the signature of traffic being caught elsewhere.
6. `tcpdump -ni pflog0` — what is actually being dropped, and in which
   direction.
