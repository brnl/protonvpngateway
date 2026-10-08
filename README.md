# protonvpngateway
Solution to route all trafic from network card B through protonvpn on network card A.

A small Debian VM on Proxmox with two NICs that acts as a gateway: everything
that comes in on NIC B is NATed into a ProtonVPN WireGuard tunnel that runs over
NIC A. If the tunnel goes down, client traffic stops instead of leaking.
The VM is configured with an Ansible role, so applying it is repeatable and
re-running it only changes (and restarts) what actually differs.

```
[clients] ── NIC B (LAN, 10.10.10.1) ── [Debian VM] ── NIC A (uplink) ── router/internet
                                           └── wg0 (ProtonVPN, runs over NIC A)
```

## Why a VM (and not an LXC container)
- A VM has its own kernel and network stack, so WireGuard and the kill switch behave
  predictably. In an LXC container `wg-quick` often fails on `src_valid_mark` and you
  need extra device and permission tweaks.
- It is only ~512 MB RAM, 1 vCPU and 4 GB disk.

## Layout
| Path | Purpose |
|---|---|
| `site.yml` | Playbook, applies the `gateway` role to the `gateway` group |
| `roles/gateway/defaults/main.yml` | All variables with documentation |
| `roles/gateway/templates/nftables.conf.j2` | Firewall: NAT, MSS clamp, kill switch |
| `roles/gateway/templates/wg.conf.j2` | WireGuard config (from your Proton values) |
| `roles/gateway/templates/unbound-gateway.conf.j2` | DNS forwarder that resolves through the tunnel |
| `roles/gateway/files/99-gateway.conf` | sysctl: IP forwarding on, IPv6 off |
| `examples/` | Example inventory and variables to copy |
| `docs/interfaces.example` | Network config for both NICs (not managed by the role) |

## Setup
1. **Proxmox:** create a VM with two virtio NICs. `net0` goes on the bridge toward your
   router (NIC A), `net1` on the bridge for the clients (NIC B). Install Debian 12 or 13
   (minimal + SSH server) and make sure you can SSH in and `sudo`.
2. **Network:** configure both NICs as in `docs/interfaces.example`
   (check names with `ip -br link`; on Proxmox they are usually `ens18`/`ens19`).
   The role does not touch interface config, so it can't cut off your SSH session.
3. **Proton config:** at account.protonvpn.com → Downloads → WireGuard configuration,
   pick platform *GNU/Linux* and a server, then download it. You need four values from it:
   `PrivateKey`, `Address`, the peer `PublicKey` and the `Endpoint` (IP and port).
4. **Ansible** on your control node (`sudo apt install ansible` or `pipx install ansible-core`;
   the role only uses `ansible.builtin` modules). Then:
   ```
   git clone https://github.com/brnl/protonvpngateway
   cd protonvpngateway
   cp examples/inventory.yml inventory.yml          # set ansible_host and ansible_user
   cp -r examples/group_vars group_vars             # fill in vars.yml and vault.yml
   ansible-vault encrypt group_vars/gateway/vault.yml
   ansible-playbook site.yml --check --diff --ask-vault-pass --ask-become-pass   # preview
   ansible-playbook site.yml --ask-vault-pass --ask-become-pass
   ```
   `inventory.yml` and `group_vars/` are git-ignored; the private key only ever lives in the
   vault file. To run it on the VM itself, set `ansible_connection: local` in the inventory.
5. **Clients:** use `10.10.10.1` as default gateway and DNS server. The gateway does not
   run a DHCP server, so either use static addresses or let an existing DHCP server on
   NIC B hand out gateway and DNS.

## Managing the gateway
SSH is only open on NIC B by default. Two things to know when you run Ansible:
- **From NIC A:** list your control node's network in `gateway_ssh_wan_allow` (for example
  `["192.168.1.0/24"]`). Otherwise the firewall blocks new SSH connections on NIC A once it
  is applied; a running session survives, but the next run will not connect (use the Proxmox
  console to recover).
- **Routing:** `wg-quick` sends everything except WireGuard's own packets into the tunnel.
  Replies to SSH from a network *behind* your router (not the subnet NIC A is in) would end up
  in the tunnel and get lost. Manage the gateway from NIC B or from the same subnet as NIC A.

## Idempotency
Re-running the playbook is safe: files are only rewritten when they differ, and a service is
reloaded or restarted only when its own config changed. Notably:
- The firewall is reloaded with `nft -f`, which replaces only the `gateway` table. The role
  never runs `systemctl restart nftables`, because its stop action does `nft flush ruleset`
  and would briefly remove the kill switch and NAT.
- The tunnel (`wg-quick@wg0`) is only restarted when `wg0.conf` changed, so clients are not
  disconnected by a no-op run.
- The WireGuard config is installed with `no_log`, so the private key does not show up in
  `--diff` output.

## How the kill switch works
- `wg-quick` routes all traffic through `wg0` and keeps the WireGuard packets themselves on
  NIC A using a firewall mark.
- The `forward` chain only allows `LAN → wg0`. There is no rule from `LAN` to `WAN`, so when
  the tunnel is down, client packets are dropped.
- The `output` chain only allows the gateway itself to use NIC A for WireGuard (UDP to the
  Proton endpoint IP and port) and DHCP. DNS and updates on the gateway always go through
  the tunnel.

## Testing
On the gateway:
```
wg show                     # latest handshake should be recent
curl https://ipinfo.io      # shows a Proton exit IP
```
On a client on NIC B:
```
curl https://ipinfo.io      # same Proton IP
```
Leak test: `systemctl stop wg-quick@wg0` on the gateway. Clients must lose internet access
completely, then regain it after `systemctl start wg-quick@wg0`. Also check for DNS leaks at
dnsleaktest.com.

## Troubleshooting
- **Role fails on a NIC check:** the interface names differ from `ens18`/`ens19`. Set
  `gateway_wan_if` and `gateway_lan_if`.
- **Stalling downloads:** set `gateway_wg_mtu: 1380`. The MSS clamp in the firewall normally
  prevents this.
- **No handshake:** the Proton server or key may be expired; download a new config and update
  the variables. Make sure the uplink has an address and that UDP to the endpoint is not
  blocked upstream.
- **Switching server:** change `gateway_wg_peer_public_key` and `gateway_wg_endpoint_ip` (and
  the private key if it differs) and re-run. Both the firewall and `wg0.conf` are updated.
- **`wg-quick` fails on `::/0`:** IPv6 is disabled on purpose; the role writes only
  `AllowedIPs = 0.0.0.0/0`.
- **Port forwarding (NAT-PMP):** not covered here. If you need it, look at Gluetun, which
  supports it for ProtonVPN.

## Notes
- Never commit your real WireGuard config or key (`.gitignore` blocks `wg0.conf`, `*.key`,
  `inventory.yml` and `group_vars/`).
- LXC is possible if you prefer: WireGuard runs on the Proxmox host kernel, but you need
  to deal with `/dev/net/tun` and `wg-quick` sysctl restrictions. Not tested here.
