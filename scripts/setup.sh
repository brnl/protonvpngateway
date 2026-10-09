#!/usr/bin/env bash
# Set up a fresh Debian 12/13 VM as a ProtonVPN gateway (standalone, no Ansible needed).
#   NIC A (WAN_IF): uplink, carries the WireGuard tunnel
#   NIC B (LAN_IF): clients, all their traffic is routed through the VPN
#
# Usage, as root:
#   ./scripts/setup.sh /path/to/proton-wireguard.conf   # first run, or to switch server
#   ./scripts/setup.sh                                  # re-apply, using /etc/wireguard/wg0.conf
#
# Settings (environment variables, all optional):
#   WAN_IF=ens18            NIC A, check with `ip -br link`
#   LAN_IF=ens19            NIC B
#   LAN_ADDR=10.10.10.1     address of this gateway on NIC B (clients' gateway and DNS)
#   LAN_NET=10.10.10.0/24   client network on NIC B
#   SSH_WAN_ALLOW=""        space separated networks on NIC A that may SSH in, e.g. "192.168.1.0/24"
#                           (default: SSH only on NIC B)
#   WG_MTU=""               tunnel MTU (default: wg-quick's 1420)
#
# Safe to re-run: a file is only rewritten when it differs, the firewall is reloaded with
# `nft -f` (never `systemctl restart nftables`, whose stop action flushes the whole ruleset
# and briefly removes the kill switch), and unbound / the tunnel are only restarted when
# their own config changed. Network interfaces are NOT configured here (that could cut off
# your SSH session); see docs/interfaces.example.
#
# The firewall, unbound and WireGuard configs are also in the Ansible role under
# roles/gateway/. Keep the two in sync when you change one.
set -euo pipefail

WAN_IF=${WAN_IF:-ens18}
LAN_IF=${LAN_IF:-ens19}
LAN_ADDR=${LAN_ADDR:-10.10.10.1}
LAN_NET=${LAN_NET:-10.10.10.0/24}
SSH_WAN_ALLOW=${SSH_WAN_ALLOW:-}
SSH_PORT=${SSH_PORT:-22}
WG_IF=${WG_IF:-wg0}
WG_MTU=${WG_MTU:-}
WG_DNS=${WG_DNS:-10.2.0.1}
WG_KEEPALIVE=${WG_KEEPALIVE:-25}
ROOT=${ROOT:-} # test hook: install files under this prefix instead of /
CHANGED=0 # set by write_file

die() {
    echo "Error: $*" >&2
    exit 1
}

# conf_get <key> <file>: value of the first "Key = value" line, whitespace/CR trimmed.
# Base64 keys end in "=", so only the first "=" on the line is the separator.
conf_get() {
    sed -n "/^[[:space:]]*$1[[:space:]]*=/{s/^[^=]*=[[:space:]]*//;s/[[:space:]]*\$//;p;q}" "$2"
}

# read_wg_conf <file>: parse a Proton WireGuard config into PRIVATE_KEY, PEER_KEY, ADDRESS,
# ENDPOINT_IP and ENDPOINT_PORT, or die.
read_wg_conf() {
    local file=$1 endpoint addr part
    local -a parts
    [[ -r $file ]] || die "cannot read $file"
    PRIVATE_KEY=$(conf_get PrivateKey "$file")
    PEER_KEY=$(conf_get PublicKey "$file")
    endpoint=$(conf_get Endpoint "$file")
    addr=$(conf_get Address "$file")

    # "Address = 10.2.0.2/32, 2a07:...::2/128": keep the IPv4 entry, IPv6 is disabled here
    ADDRESS=
    IFS=, read -ra parts <<<"$addr"
    for part in "${parts[@]}"; do
        part=${part//[[:space:]]/}
        if [[ $part =~ ^[0-9]+(\.[0-9]+){3}/[0-9]+$ ]]; then
            ADDRESS=$part
            break
        fi
    done

    [[ -n $PRIVATE_KEY ]] || die "no PrivateKey in $file"
    [[ -n $PEER_KEY ]] || die "no [Peer] PublicKey in $file"
    [[ -n $ADDRESS ]] || die "no IPv4 Address in $file"
    [[ $endpoint =~ ^([0-9]+(\.[0-9]+){3}):([0-9]+)$ ]] || die "Endpoint in $file is not IPv4:port ('$endpoint')"
    ENDPOINT_IP=${BASH_REMATCH[1]}
    ENDPOINT_PORT=${BASH_REMATCH[3]}
}

# write_file <dest> <mode> [validator...]: new content on stdin. Installs it only if it differs
# from what is there (content or mode); the validator, if any, is run as `validator <tmpfile>`
# first. Sets CHANGED to 1 if the file was (re)written, else 0. Don't pipe into it: that
# would run it in a subshell and lose CHANGED (use `write_file ... < <(cmd)`).
write_file() {
    local dest=$1 mode=$2 tmp
    shift 2
    tmp=$(mktemp) || die "mktemp failed"
    cat >"$tmp"
    if [[ $# -gt 0 ]] && ! "$@" "$tmp" >/dev/null; then
        rm -f "$tmp"
        die "validation of the new $dest failed, nothing was changed"
    fi
    if [[ -f $dest && $(stat -c %a "$dest") == "$mode" ]] && cmp -s "$tmp" "$dest"; then
        CHANGED=0
    else
        install -m "$mode" -o root -g root "$tmp" "$dest"
        CHANGED=1
    fi
    rm -f "$tmp"
}

# render: substitute @TOKENS@ in stdin
render() {
    local s
    s=$(cat)
    s=${s//@WAN_IF@/$WAN_IF}
    s=${s//@LAN_IF@/$LAN_IF}
    s=${s//@WG_IF@/$WG_IF}
    s=${s//@LAN_ADDR@/$LAN_ADDR}
    s=${s//@LAN_NET@/$LAN_NET}
    s=${s//@WG_DNS@/$WG_DNS}
    s=${s//@ENDPOINT_IP@/$ENDPOINT_IP}
    s=${s//@ENDPOINT_PORT@/$ENDPOINT_PORT}
    s=${s//@SSH_PORT@/$SSH_PORT}
    s=${s//@SSH_WAN_BLOCK@/$SSH_WAN_BLOCK}
    printf '%s\n' "$s"
}

render_nftables() {
    render <<'EOF'
#!/usr/sbin/nft -f
# Managed by protonvpngateway scripts/setup.sh
#
# ProtonVPN gateway ruleset.
#   WAN = NIC A: uplink, only carries the WireGuard tunnel itself
#   LAN = NIC B: clients whose traffic is routed through the VPN
#   VPN = @WG_IF@: ProtonVPN tunnel
#
# Kill switch: there is no forward rule from LAN to WAN, so when the tunnel is
# down client traffic is dropped instead of leaking out over the uplink.

define WAN = "@WAN_IF@"
define LAN = "@LAN_IF@"
define VPN = "@WG_IF@"
define WG_ENDPOINT = @ENDPOINT_IP@
define WG_PORT = @ENDPOINT_PORT@

# Idempotent reload; leaves tables created by other tools (e.g. wg-quick) alone.
table inet gateway
delete table inet gateway

table inet gateway {
	chain input {
		type filter hook input priority filter; policy drop;

		iifname "lo" accept
		ct state established,related accept
		ct state invalid drop

		# Services for clients on NIC B only: ping, SSH, DNS
		iifname $LAN icmp type echo-request accept
		iifname $LAN tcp dport @SSH_PORT@ accept
		iifname $LAN udp dport 53 accept
		iifname $LAN tcp dport 53 accept
@SSH_WAN_BLOCK@

		# DHCP lease renewal on the uplink
		iifname $WAN udp sport 67 udp dport 68 accept
	}

	chain forward {
		type filter hook forward priority filter; policy drop;

		ct state established,related accept
		ct state invalid drop

		# Clamp MSS to the tunnel MTU so large transfers don't stall
		iifname $LAN oifname $VPN tcp flags syn tcp option maxseg size set rt mtu

		# The only allowed path: clients -> VPN
		iifname $LAN oifname $VPN accept
	}

	chain output {
		type filter hook output priority filter; policy drop;

		oifname "lo" accept
		ct state established,related accept

		# Everything the gateway itself sends (DNS, apt, NTP) goes via the VPN
		oifname $VPN accept

		# The only things allowed out on the uplink: WireGuard to the Proton
		# endpoint, and DHCP
		oifname $WAN ip daddr $WG_ENDPOINT udp dport $WG_PORT accept
		oifname $WAN udp sport 68 udp dport 67 accept

		oifname $LAN accept
	}

	chain postrouting {
		type nat hook postrouting priority srcnat; policy accept;

		oifname $VPN masquerade
	}
}
EOF
}

render_unbound() {
    render <<'EOF'
# Managed by protonvpngateway scripts/setup.sh
#
# DNS forwarder for the clients on NIC B. All queries go to ProtonVPN's resolver
# through the tunnel, so nothing is resolved by the ISP.

server:
    interface: 127.0.0.1
    interface: @LAN_ADDR@
    # NIC B may come up after unbound
    ip-freebind: yes
    access-control: 127.0.0.0/8 allow
    access-control: @LAN_NET@ allow
    do-ip6: no
    hide-identity: yes
    hide-version: yes
    prefetch: yes

forward-zone:
    name: "."
    forward-addr: @WG_DNS@
EOF
}

render_sysctl() {
    cat <<'EOF'
# Managed by protonvpngateway scripts/setup.sh
net.ipv4.ip_forward = 1

# IPv6 is disabled so nothing can bypass the IPv4-only tunnel
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF
}

render_wg_conf() {
    echo "# Managed by protonvpngateway scripts/setup.sh"
    echo "#"
    echo "# No DNS= line: wg-quick would need resolvconf. DNS is handled by unbound, which"
    echo "# forwards to $WG_DNS through the tunnel."
    echo
    echo "[Interface]"
    echo "PrivateKey = $PRIVATE_KEY"
    echo "Address = $ADDRESS"
    if [[ -n $WG_MTU ]]; then
        echo "MTU = $WG_MTU"
    fi
    echo
    echo "[Peer]"
    echo "PublicKey = $PEER_KEY"
    echo "# IPv4 only: IPv6 is disabled on the gateway, and a ::/0 route would make wg-quick fail."
    echo "AllowedIPs = 0.0.0.0/0"
    echo "Endpoint = $ENDPOINT_IP:$ENDPOINT_PORT"
    echo "PersistentKeepalive = $WG_KEEPALIVE"
}

# build_ssh_wan_block: nft rule opening SSH on the uplink for SSH_WAN_ALLOW, or nothing
build_ssh_wan_block() {
    local -a nets
    local net joined
    read -ra nets <<<"$SSH_WAN_ALLOW"
    SSH_WAN_BLOCK=
    [[ ${#nets[@]} -gt 0 ]] || return 0
    for net in "${nets[@]}"; do
        [[ $net =~ ^[0-9]+(\.[0-9]+){3}(/[0-9]+)?$ ]] || die "SSH_WAN_ALLOW: '$net' is not an IPv4 address or network"
    done
    printf -v joined '%s, ' "${nets[@]}"
    SSH_WAN_BLOCK=$'\n\t\t# SSH from these uplink networks (management)\n'
    SSH_WAN_BLOCK+="		iifname \$WAN ip saddr { ${joined%, } } tcp dport $SSH_PORT accept"
}

# set_service <unit> <changed>: enable it and (re)start only when its config changed
set_service() {
    systemctl enable "$1" >/dev/null 2>&1
    if (($2)); then
        systemctl restart "$1"
    else
        systemctl start "$1"
    fi
}

main() {
    local proton_conf=${1:-}
    local nic pkg
    local -a missing=()
    local wg_changed=0 nft_changed=0 unbound_changed=0

    [[ $EUID -eq 0 ]] || die "run as root"
    [[ $# -le 1 ]] || die "usage: $0 [proton-wireguard.conf]"

    for nic in "$WAN_IF" "$LAN_IF"; do
        ip link show "$nic" >/dev/null 2>&1 || die "interface $nic not found; set WAN_IF/LAN_IF (see: ip -br link)"
    done
    [[ $WAN_IF != "$LAN_IF" ]] || die "WAN_IF and LAN_IF must be different NICs"
    [[ $LAN_ADDR =~ ^[0-9]+(\.[0-9]+){3}$ ]] || die "LAN_ADDR '$LAN_ADDR' is not an IPv4 address"
    [[ $LAN_NET =~ ^[0-9]+(\.[0-9]+){3}/[0-9]+$ ]] || die "LAN_NET '$LAN_NET' is not an IPv4 network (a.b.c.d/n)"
    build_ssh_wan_block

    # Validate the Proton config before touching anything
    local wg_conf="$ROOT/etc/wireguard/$WG_IF.conf"
    if [[ -n $proton_conf ]]; then
        read_wg_conf "$proton_conf"
    elif [[ -f $wg_conf ]]; then
        read_wg_conf "$wg_conf"
    else
        die "no $wg_conf yet: pass your Proton WireGuard config, ./scripts/setup.sh /path/to/proton.conf"
    fi

    for pkg in wireguard-tools nftables unbound; do
        dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
    done
    if ((${#missing[@]})); then
        apt-get update
        apt-get install -y "${missing[@]}"
    fi

    # Forwarding on, IPv6 off
    write_file "$ROOT/etc/sysctl.d/99-gateway.conf" 644 < <(render_sysctl)
    if ((CHANGED)); then
        sysctl --system >/dev/null
    fi

    # WireGuard config, only when a Proton config was passed in
    install -d -m 700 "$ROOT/etc/wireguard"
    if [[ -n $proton_conf ]]; then
        write_file "$wg_conf" 600 < <(render_wg_conf)
        wg_changed=$CHANGED
    else
        chmod 600 "$wg_conf"
    fi

    # Firewall, validated before it is installed
    write_file "$ROOT/etc/nftables.conf" 755 nft -c -f < <(render_nftables)
    nft_changed=$CHANGED

    # DNS forwarder for the clients
    write_file "$ROOT/etc/unbound/unbound.conf.d/gateway.conf" 644 unbound-checkconf < <(render_unbound)
    unbound_changed=$CHANGED

    # Reload (not restart!) the firewall first, then bring up unbound and the tunnel
    if ((nft_changed)); then
        nft -f "$ROOT/etc/nftables.conf"
    fi
    set_service nftables 0
    set_service unbound "$unbound_changed"
    set_service "wg-quick@$WG_IF" "$wg_changed"

    # The gateway resolves through its own unbound (and so the tunnel); the firewall
    # blocks DNS to the ISP's resolver anyway
    local dhclient_conf="$ROOT/etc/dhcp/dhclient.conf"
    if [[ -f $dhclient_conf ]] && ! grep -qxF 'supersede domain-name-servers 127.0.0.1;' "$dhclient_conf"; then
        sed -i '/^supersede domain-name-servers/d' "$dhclient_conf"
        echo 'supersede domain-name-servers 127.0.0.1;' >>"$dhclient_conf"
    fi
    if [[ ! -L $ROOT/etc/resolv.conf ]]; then
        write_file "$ROOT/etc/resolv.conf" 644 <<<'nameserver 127.0.0.1'
    fi

    echo
    echo "Done."
    echo "  Clients on $LAN_IF: gateway and DNS $LAN_ADDR."
    if [[ -n $SSH_WAN_ALLOW ]]; then
        echo "  SSH is open on $LAN_IF and, from $SSH_WAN_ALLOW, on $WAN_IF."
    else
        echo "  SSH is only open on $LAN_IF (set SSH_WAN_ALLOW to also allow it on $WAN_IF)."
        echo "  Locked out? On the Proxmox console: nft insert rule inet gateway input tcp dport $SSH_PORT accept"
    fi
    echo "  Check the tunnel with: wg show $WG_IF"
}

# Allow sourcing for tests without running anything
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
