#!/usr/bin/env bash
# Render and apply the tunnel configuration to both appliances.
#
#   ./apply.sh render          # render templates only, print what would be sent
#   ./apply.sh chr             # apply the RouterOS side
#   ./apply.sh pfsense         # apply the pfSense side (then REBOOT it)
#
# Reads vars.env. Never prints the PSK.
set -euo pipefail
cd "$(dirname "$0")"
[ -f vars.env ] || { echo "vars.env missing - copy vars.env.example"; exit 1; }
set -a; . ./vars.env; set +a
: "${IPSEC_PSK:?}"; [ "$IPSEC_PSK" = "CHANGE_ME" ] && { echo "set a real IPSEC_PSK"; exit 1; }

OUT=$(mktemp -d); trap 'rm -rf "$OUT"' EXIT

render_chr() {
  sed -e "s|@@CHR_PUBLIC_IP@@|$CHR_PUBLIC_IP|g" \
      -e "s|@@CHR_PRIVATE_IP@@|$CHR_PRIVATE_IP|g" \
      -e "s|@@CHR_SSH_PORT@@|$CHR_SSH_PORT|g" \
      -e "s|@@CHR_WINBOX_PORT@@|$CHR_WINBOX_PORT|g" \
      -e "s|@@CHR_TUNNEL_IP@@|$CHR_TUNNEL_IP|g" \
      -e "s|@@PEER_PUBLIC_IP@@|$PEER_PUBLIC_IP|g" \
      -e "s|@@PEER_TUNNEL_IP@@|$PEER_TUNNEL_IP|g" \
      -e "s|@@TUNNEL_NETWORK@@|$TUNNEL_NETWORK|g" \
      -e "s|@@TUNNEL_MTU@@|$TUNNEL_MTU|g" \
      -e "s|@@LOCAL_ASN@@|$LOCAL_ASN|g" \
      -e "s|@@PEER_ASN@@|$PEER_ASN|g" \
      -e "s|@@LOCAL_PUBLIC_SUBNET@@|$LOCAL_PUBLIC_SUBNET|g" \
      -e "s|@@LOCAL_PRIVATE_SUBNET@@|$LOCAL_PRIVATE_SUBNET|g" \
      -e "s|@@VPC_SUPERNET@@|$VPC_SUPERNET|g" \
      -e "s|@@TIMEZONE@@|$TIMEZONE|g" \
      -e "s|@@IPSEC_PSK@@|$IPSEC_PSK|g" \
      routeros/chr-tunnel.rsc.tmpl
}

pf_vars() {
  cat <<JSON
{ "peer_public_ip":"$CHR_PUBLIC_IP", "peer_private_ip":"$CHR_PRIVATE_IP",
  "local_public_ip":"$PEER_PUBLIC_IP", "local_private_ip":"$PEER_PRIVATE_IP",
  "local_tunnel_ip":"$PEER_TUNNEL_IP", "peer_tunnel_ip":"$CHR_TUNNEL_IP",
  "ipsec_psk":"$IPSEC_PSK", "local_asn":$PEER_ASN, "peer_asn":$LOCAL_ASN,
  "vnet_supernet":"$VNET_SUPERNET", "local_public_subnet":"$PEER_PUBLIC_SUBNET",
  "local_private_subnet":"$PEER_PRIVATE_SUBNET", "tunnel_mtu":$TUNNEL_MTU,
  "wan_if":"${PF_WAN_IF:-hn0}", "lan_if":"${PF_LAN_IF:-hn1}", "tunnel_if":"${PF_TUNNEL_IF:-gre0}" }
JSON
}

case "${1:-}" in
  render)
    render_chr | sed "s|$IPSEC_PSK|<PSK-REDACTED>|g"
    echo "--- pfsense vars ---"
    pf_vars | sed "s|$IPSEC_PSK|<PSK-REDACTED>|g"
    ;;
  chr)
    : "${CHR_SSH:?set CHR_SSH, e.g. user@1.2.3.4}"
    render_chr > "$OUT/chr.rsc"
    echo "removing objects this template re-adds (so re-running is safe)..."
    ssh -p "${CHR_SSH_PORT}" "$CHR_SSH" \
      '/routing/bgp/connection remove [find name=pfsense-azure];
       /routing/bgp/instance remove [find name=aliyun];
       /routing/bgp/template remove [find name=aliyun];
       /routing/filter/rule remove [find chain~"azure"];
       /ip/ipsec/policy remove [find peer=azure];
       /ip/ipsec/identity remove [find peer=azure];
       /ip/ipsec/peer remove [find name=azure];
       /ip/ipsec/proposal remove [find name=azure];
       /ip/ipsec/profile remove [find name=azure];
       /ip/address remove [find interface=gre-azure];
       /interface/gre remove [find name=gre-azure];
       /ip/route remove [find comment="vpc network"];
       /ip/dhcp-client remove [find];' 2>/dev/null || true
    scp -P "${CHR_SSH_PORT}" "$OUT/chr.rsc" "$CHR_SSH:/chr-tunnel.rsc"
    ssh -p "${CHR_SSH_PORT}" "$CHR_SSH" '/import file-name=chr-tunnel.rsc; /file remove [find name=chr-tunnel.rsc]'
    echo "CHR applied."
    ;;
  pfsense)
    : "${PF_SSH:?set PF_SSH, e.g. admin@1.2.3.4}"
    pf_vars > "$OUT/vars.json"
    scp -P "${PF_SSH_PORT:-22}" "$OUT/vars.json" pfsense/apply-tunnel.php "$PF_SSH:/tmp/"
    ssh -p "${PF_SSH_PORT:-22}" "$PF_SSH" 'php -f /tmp/apply-tunnel.php /tmp/vars.json && rm -f /tmp/vars.json'
    echo "pfSense config written. REBOOT it to apply: ssh $PF_SSH reboot"
    ;;
  *) sed -n '2,9p' "$0"; exit 1 ;;
esac
