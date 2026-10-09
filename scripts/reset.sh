#!/usr/bin/env bash
# Undo scripts/setup.sh (or the Ansible role): take this VM back to a plain Debian host.
#
# Usage, as root:
#   ./scripts/reset.sh --dry-run    # show what would be removed, change nothing
#   ./scripts/reset.sh              # show the plan, ask for confirmation, then do it
#   ./scripts/reset.sh --yes        # no confirmation (required when not run from a terminal)
#
# Options:
#   -n, --dry-run       only show the plan
#   -y, --yes           don't ask for confirmation
#   --keep-wg-conf      keep /etc/wireguard/wg0.conf (it holds your Proton private key)
#   --purge-packages    also purge wireguard-tools and unbound (nftables is left installed)
#   -h, --help
#
# Settings (environment variables, all optional):
#   WAN_IF=ens18    NIC A: where the DNS servers are read from (its last DHCP lease)
#   WG_IF=wg0       name of the tunnel interface
#   DNS_SERVERS=""  space separated DNS servers for /etc/resolv.conf, instead of the lease's
#
# What it undoes: the tunnel (wg-quick@wg0) and its config, the `gateway` nftables table and
# /etc/nftables.conf (replaced by Debian's stock one), the unbound forwarder config, the
# sysctl file (forwarding off, IPv6 on again), and the DNS settings (dhclient.conf, resolv.conf).
# A file is only touched if it still carries this project's marker text, so a config you made
# yourself is left alone. Not touched: network interface config, installed packages (unless
# --purge-packages), this repo and your Proton download. Clients lose their internet access
# (no forwarding, no NAT), they don't leak. A reboot afterwards makes sure IPv6 is fully back.
# Set up again with ./scripts/setup.sh proton.conf.
set -euo pipefail

WAN_IF=${WAN_IF:-ens18}
WG_IF=${WG_IF:-wg0}
DNS_SERVERS=${DNS_SERVERS:-}
ROOT=${ROOT:-} # test hook: look for files under this prefix instead of /

DRY_RUN=0
ASSUME_YES=0
KEEP_WG=0
PURGE=0

# Text that only our own generated files contain (the script and the role write the same)
MARK_NFT='# ProtonVPN gateway ruleset.'
MARK_UNBOUND='DNS forwarder for the clients on NIC B'
MARK_SYSCTL='IPv6 is disabled so nothing can bypass the IPv4-only tunnel'
MARK_WG='# No DNS= line: wg-quick would need resolvconf.'
DHCLIENT_LINE='supersede domain-name-servers 127.0.0.1;'

DRY=1 # 1 while only printing the plan
STEPS=0
FAILED=0
LAST_OK=1 # did the last do_step succeed
TUNNEL_FAILED=0 # the tunnel could not be stopped, so its config must stay

die() {
    echo "Error: $*" >&2
    exit 1
}

usage() {
    sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# is_ours <file> <marker>: the file exists and still carries our marker text
is_ours() {
    [[ -f $1 ]] && grep -qF -- "$2" "$1"
}

# do_step <description> <command...>: print the step and, unless this is the plan pass, run it.
# A failing step is reported but doesn't stop the others.
do_step() {
    local desc=$1
    shift
    echo "  - $desc"
    STEPS=$((STEPS + 1))
    LAST_OK=1
    if ((!DRY)); then
        if ! "$@" >/dev/null; then
            echo "    FAILED: $desc" >&2
            FAILED=$((FAILED + 1))
            LAST_OK=0
        fi
    fi
}

wipe_file() {
    if command -v shred >/dev/null 2>&1; then
        shred -u "$1"
    else
        rm -f "$1"
    fi
}

write_default_nft() {
    cat >"$1" <<'EOF'
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
	chain input {
		type filter hook input priority filter;
	}
	chain forward {
		type filter hook forward priority filter;
	}
	chain output {
		type filter hook output priority filter;
	}
}
EOF
    chmod 755 "$1"
}

# resolv_servers: the DNS servers to restore: DNS_SERVERS, else from WAN_IF's last DHCP lease
resolv_servers() {
    local lease="$ROOT/var/lib/dhcp/dhclient.$WAN_IF.leases"
    if [[ -n $DNS_SERVERS ]]; then
        echo "$DNS_SERVERS"
    elif [[ -r $lease ]]; then
        sed -n 's/^[[:space:]]*option domain-name-servers[[:space:]]*\(.*\);[[:space:]]*$/\1/p' "$lease" | tail -n 1 | tr ',' ' '
    fi
}

# valid_servers <list>: a non-empty list of IPv4 addresses
valid_servers() {
    local s
    [[ -n ${1// /} ]] || return 1
    for s in $1; do
        [[ $s =~ ^[0-9]+(\.[0-9]+){3}$ ]] || return 1
    done
}

write_resolv() {
    local s
    : >"$ROOT/etc/resolv.conf"
    for s in $1; do
        echo "nameserver $s" >>"$ROOT/etc/resolv.conf"
    done
}

# resolv_is_ours: /etc/resolv.conf is the plain file setup.sh / the role wrote
resolv_is_ours() {
    local r="$ROOT/etc/resolv.conf"
    [[ -f $r && ! -L $r && $(cat "$r") == 'nameserver 127.0.0.1' ]]
}

step_tunnel() {
    local unit="wg-quick@$WG_IF"
    if systemctl is-enabled --quiet "$unit" 2>/dev/null || systemctl is-active --quiet "$unit" 2>/dev/null; then
        do_step "stop and disable $unit (takes the tunnel down)" systemctl disable --now "$unit"
        if ((!LAST_OK)); then
            TUNNEL_FAILED=1
        fi
    fi
}

step_firewall() {
    local conf="$ROOT/etc/nftables.conf"
    if nft list table inet gateway >/dev/null 2>&1; then
        do_step "remove the 'gateway' nftables table (NAT and kill switch)" nft delete table inet gateway
    fi
    if is_ours "$conf" "$MARK_NFT"; then
        do_step "put Debian's stock ruleset back in $conf" write_default_nft "$conf"
    fi
}

step_unbound() {
    local conf="$ROOT/etc/unbound/unbound.conf.d/gateway.conf"
    if is_ours "$conf" "$MARK_UNBOUND"; then
        do_step "remove $conf" rm -f "$conf"
        if ((!PURGE)); then
            do_step "restart unbound (back to its default config)" systemctl try-restart unbound
        fi
    fi
}

step_sysctl() {
    local conf="$ROOT/etc/sysctl.d/99-gateway.conf"
    if is_ours "$conf" "$MARK_SYSCTL"; then
        do_step "remove $conf" rm -f "$conf"
        do_step "turn IP forwarding off and IPv6 back on" \
            sysctl -w net.ipv4.ip_forward=0 net.ipv6.conf.all.disable_ipv6=0 net.ipv6.conf.default.disable_ipv6=0
    fi
}

step_dns() {
    local dhclient_conf="$ROOT/etc/dhcp/dhclient.conf" resolv="$ROOT/etc/resolv.conf" servers
    if [[ -f $dhclient_conf ]] && grep -qxF "$DHCLIENT_LINE" "$dhclient_conf"; then
        do_step "remove the '$DHCLIENT_LINE' line from $dhclient_conf" \
            sed -i "/^supersede domain-name-servers 127\\.0\\.0\\.1;\$/d" "$dhclient_conf"
    fi
    if resolv_is_ours; then
        servers=$(resolv_servers)
        if valid_servers "$servers"; then
            do_step "point $resolv back at the DNS servers $servers" write_resolv "$servers"
        else
            echo "  (leaving $resolv on 127.0.0.1: no DNS servers found in a DHCP lease for $WAN_IF; set DNS_SERVERS to change that)"
        fi
    fi
}

step_wg_conf() {
    local conf="$ROOT/etc/wireguard/$WG_IF.conf"
    if [[ -f $conf ]]; then
        if ((KEEP_WG)); then
            echo "  (keeping $conf as requested)"
        elif ((TUNNEL_FAILED)); then
            echo "  (keeping $conf: the tunnel could not be stopped and wg-quick needs it to take it down)"
        elif is_ours "$conf" "$MARK_WG"; then
            do_step "delete $conf (it holds your Proton private key)" wipe_file "$conf"
        else
            echo "  (not touching $conf: it wasn't written by this project)"
        fi
    fi
}

step_packages() {
    local pkg
    ((PURGE)) || return 0
    for pkg in unbound wireguard-tools; do
        if dpkg -s "$pkg" >/dev/null 2>&1; then
            do_step "purge the package $pkg" apt-get purge -y "$pkg"
        fi
    done
}

# Order matters: the tunnel goes down first (wg-quick needs its config for that), the config
# is deleted afterwards, and DNS is repaired before unbound can be purged.
steps() {
    STEPS=0
    TUNNEL_FAILED=0
    step_tunnel
    step_firewall
    step_unbound
    step_sysctl
    step_dns
    step_wg_conf
    step_packages
}

# Refuse before changing anything if purging unbound would leave the VM without DNS
preflight() {
    if ((PURGE)) && resolv_is_ours && ! valid_servers "$(resolv_servers)"; then
        die "--purge-packages would leave this VM without DNS: no DNS servers found in a DHCP lease for $WAN_IF. Set DNS_SERVERS=\"1.2.3.4\" or drop --purge-packages."
    fi
}

confirm() {
    local answer
    ((ASSUME_YES)) && return 0
    [[ -t 0 ]] || die "not a terminal: pass --yes to confirm, or --dry-run to only see the plan"
    read -r -p "Apply these changes? Type 'yes' to continue: " answer
    [[ $answer == yes ]] || die "aborted, nothing was changed"
}

main() {
    while [[ $# -gt 0 ]]; do
        case $1 in
        -n | --dry-run) DRY_RUN=1 ;;
        -y | --yes) ASSUME_YES=1 ;;
        --keep-wg-conf) KEEP_WG=1 ;;
        --purge-packages) PURGE=1 ;;
        -h | --help)
            usage
            exit 0
            ;;
        *) die "unknown option '$1' (see --help)" ;;
        esac
        shift
    done

    [[ $EUID -eq 0 ]] || die "run as root"
    preflight

    echo "Plan:"
    DRY=1
    steps
    if ((STEPS == 0)); then
        echo "Nothing to reset: no traces of the setup found."
        exit 0
    fi
    if ((DRY_RUN)); then
        echo
        echo "Dry run, nothing was changed."
        exit 0
    fi

    echo
    confirm
    echo
    echo "Resetting:"
    DRY=0
    FAILED=0
    steps

    echo
    if ((FAILED)); then
        die "$FAILED step(s) failed, see above; run again to retry, the finished steps are skipped"
    fi
    echo "Done. Reboot to make sure IPv6 and the DNS settings are fully back to normal."
    echo "Set up again with: ./scripts/setup.sh /path/to/proton.conf"
}

# Allow sourcing for tests without running anything
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
