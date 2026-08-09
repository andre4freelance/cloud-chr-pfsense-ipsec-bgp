<?php
/*
 * pfSense — Azure end of the multi-cloud tunnel.
 *
 * Writes configuration ONLY. Nothing is applied in-process: calling pfSense's
 * service functions from a script is how a previous attempt threw inside
 * write_config() mid-reconfigure and ran a chown -R with an empty chroot path
 * over ~130k files, killing PAM and every SSH login. Apply by rebooting.
 *
 * Idempotent: every section replaces its own objects by identifier, so running
 * this twice produces the same configuration.
 *
 * Usage:  php -f apply-tunnel.php /path/to/vars.json
 */
require_once("config.inc");
require_once("util.inc");
require_once("/usr/local/pkg/frr.inc");

$varsfile = $argv[1] ?? '/tmp/tunnel-vars.json';
$v = json_decode(file_get_contents($varsfile), true);
if (!is_array($v)) {
    fwrite(STDERR, "cannot read vars from {$varsfile}\n");
    exit(1);
}
foreach (['peer_public_ip','peer_private_ip','local_public_ip','local_private_ip',
          'local_tunnel_ip','peer_tunnel_ip','ipsec_psk','local_asn','peer_asn',
          'vnet_supernet','local_public_subnet','local_private_subnet',
          'tunnel_mtu','wan_if','lan_if','tunnel_if','peer_supernet'] as $k) {
    if (!isset($v[$k])) { fwrite(STDERR, "missing var: {$k}\n"); exit(1); }
}
$IKEID = 1;

/* ---------------------------------------------------------------- IPsec ---
 * Identities are the PUBLIC addresses: Azure 1:1-NATs, so the address on the
 * interface is private and the peer would never match it.
 * Phase 2 selectors mirror the RouterOS policy exactly - local is this box's
 * PUBLIC address, remote is the peer's PRIVATE one.
 */
config_set_path('ipsec/phase1', array(array(
    'ikeid'                 => $IKEID,
    'iketype'               => 'ikev2',
    'interface'             => 'wan',
    'remote-gateway'        => $v['peer_public_ip'],
    'protocol'              => 'inet',
    'myid_type'             => 'address',
    'myid_data'             => $v['local_public_ip'],
    'peerid_type'           => 'address',
    'peerid_data'           => $v['peer_public_ip'],
    'authentication_method' => 'pre_shared_key',
    'pre-shared-key'        => $v['ipsec_psk'],
    'descr'                 => 'Multi-cloud tunnel peer',
    'nat_traversal'         => 'on',
    'mobike'                => 'off',
    'startaction'           => 'start',
    'closeaction'           => 'none',
    'lifetime'              => 28800,
    'rekey_time'            => 25200,
    'dpd_enable'            => true,
    'dpd_delay'             => 10,
    'dpd_maxfail'           => 5,
    'encryption'            => array('item' => array(array(
        'encryption-algorithm' => array('name' => 'aes', 'keylen' => 256),
        'hash-algorithm'       => 'sha256',
        'dhgroup'              => 14,
    ))),
)));

config_set_path('ipsec/phase2', array(array(
    'ikeid'                       => $IKEID,
    'uniqid'                      => uniqid(),
    'mode'                        => 'tunnel',
    'localid'                     => array('type' => 'address', 'address' => $v['local_public_ip']),
    'remoteid'                    => array('type' => 'address', 'address' => $v['peer_private_ip']),
    'protocol'                    => 'esp',
    'encryption-algorithm-option' => array(array('name' => 'aes', 'keylen' => 256)),
    'hash-algorithm-option'       => array('hmac_sha256'),
    'pfsgroup'                    => 14,
    'lifetime'                    => 3600,
    'descr'                       => 'GRE transport',
)));
config_set_path('ipsec/enable', true);

/* ------------------------------------------------------------------ VIP ---
 * The public address must exist locally so the GRE can SOURCE from it.
 * Without this the SA installs, decrypts inbound perfectly and sends nothing
 * (out: 0 packets), because egress never matches the policy.
 */
$vips = array_values(array_filter(config_get_path('virtualip/vip', array()),
    fn($x) => ($x['subnet'] ?? '') !== $v['local_public_ip']));
$vipid = uniqid();
$vips[] = array(
    'mode' => 'ipalias', 'interface' => 'wan', 'type' => 'single',
    'subnet_bits' => '32', 'subnet' => $v['local_public_ip'],
    'descr' => 'Public IP for GRE source (cloud 1:1 NAT)', 'uniqid' => $vipid,
);
config_set_path('virtualip/vip', $vips);

/* ------------------------------------------------------------------ GRE ---
 * pfSense's "GIF" is IPIP and does NOT interoperate with a RouterOS GRE.
 * MTU lives here; an `ifconfig mtu` is runtime only and silently reverts.
 */
config_set_path('gres/gre', array(array(
    'if'                 => '_vip' . $vipid,
    'greif'              => $v['tunnel_if'],
    'remote-addr'        => $v['peer_private_ip'],
    'tunnel-local-addr'  => $v['local_tunnel_ip'],
    'tunnel-remote-addr' => $v['peer_tunnel_ip'],
    'tunnel-remote-net'  => '30',
    'mtu'                => (string)$v['tunnel_mtu'],
    'descr'              => 'Tunnel to the remote cloud',
)));

/* Assign it so it can carry rules and a BGP session. */
$ifs = config_get_path('interfaces', array());
$ifs['opt1'] = array('if' => $v['tunnel_if'], 'descr' => 'TUNNEL', 'enable' => '', 'ipaddr' => '');
config_set_path('interfaces', $ifs);

/* ------------------------------------------------------------- firewall ---
 * Three rules, and the OUTBOUND one is the non-obvious requirement.
 *
 * pfSense's generated "let out anything from firewall host itself" rule reads
 * `to ! <tunnel /30>` - it EXCLUDES the tunnel subnet, which is exactly where
 * the BGP peer lives. Without an explicit outbound pass, the firewall drops
 * its own SYN-ACK to the peer, the peer's connection is never answered, and
 * BGP flaps every few minutes. Sloppy state is required: pfSense writes user
 * rules with `flags S/SA`, which matches a pure SYN and never a SYN-ACK.
 */
$rules = array_values(array_filter(config_get_path('filter/rule', array()),
    fn($r) => !in_array(($r['interface'] ?? ''), array('opt1', 'enc0'), true)));

$rules[] = array(
    'type' => 'pass', 'interface' => 'opt1', 'ipprotocol' => 'inet',
    'floating' => 'yes', 'direction' => 'out', 'quick' => 'yes',
    'statetype' => 'sloppy state', 'tcpflags_any' => true,
    'source' => array('any' => ''), 'destination' => array('any' => ''),
    'descr' => 'Allow firewall traffic out over the tunnel',
);
$rules[] = array(
    'type' => 'pass', 'interface' => 'opt1', 'ipprotocol' => 'inet',
    'source' => array('any' => ''), 'destination' => array('any' => ''),
    'descr' => 'Allow all across the tunnel',
);
$rules[] = array(
    'type' => 'pass', 'interface' => 'enc0', 'ipprotocol' => 'inet',
    'source' => array('any' => ''), 'destination' => array('any' => ''),
    'descr' => 'Allow all decrypted IPsec traffic',
);
config_set_path('filter/rule', $rules);

/* ----------------------------------------------------------------- NAT ---
 * Automatic outbound NAT covers every interface, tunnel included, and would
 * rewrite the source of replies leaving over the tunnel to the tunnel address.
 * The far end then receives an answer from a host it never contacted and drops
 * it: pings to and from the tunnel addresses work while LAN-to-LAN does not.
 */
config_set_path('nat/outbound/mode', 'hybrid');
$nat = array_values(array_filter(config_get_path('nat/outbound/rule', array()),
    fn($r) => ($r['descr'] ?? '') !== 'No NAT over the site-to-site tunnel'));
array_unshift($nat, array(
    'interface' => 'opt1',
    'source' => array('any' => ''), 'destination' => array('any' => ''),
    'nonat' => '', 'descr' => 'No NAT over the site-to-site tunnel',
));

/* The private subnet routes its default through this appliance, so it needs
 * source NAT on the way out of WAN. The negated destination is the important
 * part: traffic to the REMOTE CLOUD must keep its real source, because the far
 * side routes replies back by that address. */
$nat[] = array(
    'interface'   => 'wan',
    'source'      => array('network' => $v['local_private_subnet']),
    'destination' => array('network' => $v['peer_supernet'], 'not' => true),
    'target'      => '',
    'descr'       => 'NAT private subnet to the internet, never to the peer',
);
config_set_path('nat/outbound/rule', $nat);

/* ----------------------------------------------------------------- FRR ---
 * Static routes and BGP go in the `frr` raw key, which the package uses
 * verbatim as the integrated config. The per-daemon `staticd`/`zebra` keys are
 * NOT assembled into frr.conf - a route placed there works until the next
 * restart and then silently disappears, taking the supernet advertisement with
 * it. The value is stored base64-encoded, as the package expects.
 *
 * The /32 to the peer's private address out of WAN is essential: the peer
 * advertises a supernet that CONTAINS its own tunnel endpoint, and without a
 * more-specific route the transport gets routed through the tunnel it carries.
 */
$frr = "frr defaults traditional\n" .
       "hostname " . config_get_path('system/hostname', 'pfsense') . "\n" .
       "service integrated-vtysh-config\n!\n" .
       "ip route {$v['peer_tunnel_ip']}/32 {$v['tunnel_if']}\n" .
       "ip route {$v['peer_private_ip']}/32 {$v['wan_if']}\n" .
       "ip route {$v['vnet_supernet']} {$v['lan_if']}\n!\n" .
       "router bgp {$v['local_asn']}\n" .
       " bgp router-id {$v['local_private_ip']}\n" .
       " no bgp ebgp-requires-policy\n" .
       " neighbor {$v['peer_tunnel_ip']} remote-as {$v['peer_asn']}\n" .
       " neighbor {$v['peer_tunnel_ip']} description remote-cloud-peer\n" .
       " address-family ipv4 unicast\n" .
       "  network {$v['local_public_subnet']}\n" .
       "  network {$v['local_private_subnet']}\n" .
       "  network {$v['vnet_supernet']}\n" .
       "  neighbor {$v['peer_tunnel_ip']} activate\n" .
       "  neighbor {$v['peer_tunnel_ip']} soft-reconfiguration inbound\n" .
       " exit-address-family\n!\nline vty\n!\n";

config_set_path('installedpackages/frr/config', array(array(
    'enable' => 'on', 'pkgloglevel' => 'normal', 'ignoreipsecrestart' => 'on',
)));
/* bgpd is enabled from this structured key, NOT from the raw config. */
config_set_path('installedpackages/frrbgp/config', array(array('enable' => 'on')));
config_set_path('installedpackages/frrglobalraw/config', array(array(
    'frr'  => base64_encode($frr),
    'bgpd' => base64_encode("router bgp {$v['local_asn']}\n"),
)));

write_config("Multi-cloud tunnel: IPsec + GRE + BGP (config only, apply by reboot)");
frr_generate_config();
frr_generate_config_rcfile();

echo "written. REBOOT to apply.\n";
