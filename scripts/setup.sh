#!/usr/bin/env bash
# Set up a fresh Debian 12/13 VM as a ProtonVPN gateway.
#   NIC A (WAN_IF): uplink, carries the WireGuard tunnel
#   NIC B (LAN_IF): clients, all their traffic is routed through the VPN
#
# Usage (as root, from the repo root):
#   WAN_IF=ens18 LAN_IF=ens19 LAN_ADDR=10.10.10.1 LAN_NET=10.10.10.0/24 ./scripts/setup.sh
#
# Network interfaces are NOT configured here (that could cut off your SSH
# session); see config/interfaces.example. Put your Proton WireGuard config at
# /etc/wireguard/wg0.conf before running this, or enable wg-quick@wg0 afterwards.
set -euo pipefail

WAN_IF=${WAN_IF:-ens18}
LAN_IF=${LAN_IF:-ens19}
LAN_ADDR=${LAN_ADDR:-10.10.10.1}
LAN_NET=${LAN_NET:-10.10.10.0/24}

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

if [[ $EUID -ne 0 ]]; then
    echo "Run as root." >&2
    exit 1
fi

for nic in "$WAN_IF" "$LAN_IF"; do
    if ! ip link show "$nic" >/dev/null 2>&1; then
        echo "Interface $nic not found. Set WAN_IF/LAN_IF (see: ip -br link)." >&2
        exit 1
    fi
done

apt-get update
apt-get install -y wireguard-tools nftables unbound

# Forwarding on, IPv6 off
install -m 644 "$repo_dir/config/sysctl.d/99-gateway.conf" /etc/sysctl.d/99-gateway.conf
sysctl --system >/dev/null

# Firewall: interface names are the only thing that needs adapting
sed -e "s|^define WAN = .*|define WAN = \"$WAN_IF\"|" \
    -e "s|^define LAN = .*|define LAN = \"$LAN_IF\"|" \
    "$repo_dir/config/nftables.conf" > /etc/nftables.conf
chmod 755 /etc/nftables.conf
nft -c -f /etc/nftables.conf

# DNS forwarder for the clients
sed -e "s|10\.10\.10\.1|$LAN_ADDR|g" \
    -e "s|10\.10\.10\.0/24|$LAN_NET|g" \
    "$repo_dir/config/unbound-gateway.conf" > /etc/unbound/unbound.conf.d/gateway.conf
unbound-checkconf

# The gateway resolves through its own unbound, not the ISP's DNS handed out by DHCP
if ! grep -q '^supersede domain-name-servers 127.0.0.1;' /etc/dhcp/dhclient.conf 2>/dev/null; then
    echo 'supersede domain-name-servers 127.0.0.1;' >> /etc/dhcp/dhclient.conf
fi

systemctl enable nftables unbound
systemctl restart nftables unbound

if [[ -f /etc/wireguard/wg0.conf ]]; then
    chmod 600 /etc/wireguard/wg0.conf
    systemctl enable wg-quick@wg0
    systemctl restart wg-quick@wg0
    echo "wg0 started:"
    wg show wg0
else
    echo "No /etc/wireguard/wg0.conf yet. Copy your Proton config there, then run:"
    echo "  chmod 600 /etc/wireguard/wg0.conf && systemctl enable --now wg-quick@wg0"
fi

echo "Done. Point clients on $LAN_IF at gateway and DNS $LAN_ADDR."
