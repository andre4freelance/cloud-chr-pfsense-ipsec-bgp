# 2026-08-10 00:46:50 by RouterOS 7.23.3
# system id = MpJr8eXU+kA
#
/interface ethernet
set [ find default-name=ether1 ] disable-running-check=no
set [ find default-name=ether2 ] disable-running-check=no
/interface gre
add allow-fast-path=no !keepalive local-address=10.151.64.84 mtu=1388 name=\
    gre-azure remote-address=48.193.46.116
/ip ipsec profile
add dh-group=modp2048 enc-algorithm=aes-256 hash-algorithm=sha256 lifetime=8h \
    name=azure
/ip ipsec peer
add address=48.193.46.116/32 exchange-mode=ike2 local-address=10.151.64.84 \
    name=azure profile=azure
/ip ipsec proposal
add auth-algorithms=sha256 enc-algorithms=aes-256-cbc,aes-256-ctr,aes-256-gcm \
    lifetime=1h name=azure pfs-group=modp2048
/routing bgp instance
add as=64513 disabled=no name=aliyun router-id=10.151.64.84
/routing bgp template
add as=64513 name=aliyun
/ip settings
set ipv4-high-fragment-thresh=16.0MiB
/ip address
add address=169.254.100.2/30 interface=gre-azure network=169.254.100.0
/ip dhcp-client
add interface=ether1 name=client1
add add-default-route=no default-route-tables=main interface=ether2 name=\
    client2 use-peer-dns=no use-peer-ntp=no
/ip firewall mangle
add action=change-mss chain=forward comment=\
    "clamp tcp mss to measured path mtu 1388" new-mss=1348 out-interface=\
    gre-azure protocol=tcp tcp-flags=syn
add action=change-mss chain=forward comment=\
    "clamp tcp mss to measured path mtu 1388" in-interface=gre-azure new-mss=\
    1348 protocol=tcp tcp-flags=syn
/ip firewall nat
add action=dst-nat chain=dstnat comment="natfwd: SSH to k8s-master" \
    dst-address=10.151.64.84 dst-port=20022 protocol=tcp to-addresses=\
    10.151.74.240 to-ports=22
add action=masquerade chain=srcnat comment=\
    "NAT private subnet to the internet, never to the peer" dst-address=\
    !10.126.64.0/18 out-interface=ether1 src-address=10.151.74.0/24
add action=dst-nat chain=dstnat comment="natfwd: podinfo nodeport" \
    dst-address=10.151.64.84 dst-port=20081 protocol=tcp to-addresses=\
    10.151.74.240 to-ports=30081
add action=dst-nat chain=dstnat comment="natfwd: whoami nodeport" \
    dst-address=10.151.64.84 dst-port=20080 protocol=tcp to-addresses=\
    10.151.74.240 to-ports=30080
add action=dst-nat chain=dstnat comment="natfwd: k8s apiserver" dst-address=\
    10.151.64.84 dst-port=20643 protocol=tcp to-addresses=10.151.74.240 \
    to-ports=6443
add action=masquerade chain=srcnat comment=\
    "natfwd hairpin: whoami nodeport, public ingress only" dst-address=\
    10.151.74.240 dst-port=30080 in-interface=ether1 out-interface=ether2 \
    protocol=tcp
add action=masquerade chain=srcnat comment=\
    "natfwd hairpin: k8s apiserver, public ingress only" dst-address=\
    10.151.74.240 dst-port=6443 in-interface=ether1 out-interface=ether2 \
    protocol=tcp
add action=masquerade chain=srcnat comment=\
    "natfwd hairpin: podinfo nodeport, public ingress only" dst-address=\
    10.151.74.240 dst-port=30081 in-interface=ether1 out-interface=ether2 \
    protocol=tcp
add action=masquerade chain=srcnat comment=\
    "natfwd hairpin: source from the appliance so the cloud SG accepts it" \
    dst-address=10.151.74.240 dst-port=22 out-interface=ether2 protocol=tcp
/ip ipsec identity
add my-id=address:147.139.142.199 peer=azure remote-id=address:48.193.46.116
/ip ipsec policy
add dst-address=48.193.46.116/32 peer=azure proposal=azure protocol=gre \
    src-address=10.151.64.84/32 tunnel=yes
/ip route
add comment="vpc network" distance=1 dst-address=10.151.64.0/18 gateway=\
    ether2
/ip service
set ftp disabled=yes
set telnet disabled=yes
set www disabled=yes
set reverse-proxy disabled=yes
set ssh port=7822
set winbox port=7881
set api disabled=yes
set api-ssl disabled=yes
/routing bgp connection
add as=64513 disabled=no input.filter=azure-in instance=aliyun local.address=\
    169.254.100.2 .role=ebgp name=pfsense-azure output.filter-chain=azure-out \
    .redistribute=connected,static remote.address=169.254.100.1/32 .as=64512 \
    routing-table=main templates=aliyun
/routing filter rule
add chain=azure-out rule="if (dst == 10.151.64.0/24 || dst == 10.151.74.0/24 |\
    | dst == 10.151.64.0/18) { accept } reject"
add chain=azure-in rule=\
    "if (dst == 0.0.0.0/0 || dst in 48.193.46.116/32) { reject } accept"
/system clock
set time-zone-name=Asia/Jakarta
