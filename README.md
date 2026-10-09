# protonvpngateway
Solution to route all trafic from network card B through protonvpn on network card A.

A small Debian VM on Proxmox with two NICs that acts as a gateway: everything
that comes in on NIC B is NATed into a ProtonVPN WireGuard tunnel that runs over
NIC A. If the tunnel goes down, client traffic stops instead of leaking.
The VM is configured with either a standalone shell script (quickest) or an Ansible
role. Both are repeatable: re-running them only changes (and restarts) what actually differs.

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
| `scripts/setup.sh` | Standalone setup script (Option A): installs and configures everything |
| `scripts/reset.sh` | Undoes the setup (script or role): back to a plain Debian host |
| `site.yml` | Playbook, applies the `gateway` role to the `vpngateway` group (Option B) |
| `roles/gateway/defaults/main.yml` | All variables with documentation |
| `roles/gateway/templates/nftables.conf.j2` | Firewall: NAT, MSS clamp, kill switch |
| `roles/gateway/templates/wg.conf.j2` | WireGuard config (from your Proton values) |
| `roles/gateway/templates/unbound-gateway.conf.j2` | DNS forwarder that resolves through the tunnel |
| `roles/gateway/files/99-gateway.conf` | sysctl: IP forwarding on, IPv6 off |
| `examples/` | Example inventory and variables to copy |
| `docs/interfaces.example` | Network config for both NICs (not managed by the script or the role) |

## Setup
1. **Proxmox:** create a VM with two virtio NICs. `net0` goes on the bridge toward your
   router (NIC A), `net1` on the bridge for the clients (NIC B). Install Debian 12 or 13
   (minimal + SSH server) and make sure you can SSH in and `sudo`.
2. **Network:** configure both NICs as in `docs/interfaces.example`
   (check names with `ip -br link`; on Proxmox they are usually `ens18`/`ens19`).
   Neither the script nor the role touches interface config, so they can't cut off your SSH
   session.
3. **Proton config:** at account.protonvpn.com → Downloads → WireGuard configuration,
   pick platform *GNU/Linux* and a server, then download it. The script reads this file as is;
   for Ansible you need four values from it: `PrivateKey`, `Address`, the peer `PublicKey` and
   the `Endpoint` (IP and port).
4. **Apply the configuration**, with either option:

   **Option A: shell script** (no extra tools, run on the VM). Copy the Proton file to the VM
   (for example `scp proton.conf debian@<vm>:`), then:
   ```
   git clone https://github.com/brnl/protonvpngateway
   cd protonvpngateway
   sudo WAN_IF=ens18 LAN_IF=ens19 ./scripts/setup.sh ~/proton.conf
   ```
   The script has defaults for everything (see the header of `scripts/setup.sh` for
   `LAN_ADDR`, `LAN_NET`, `SSH_WAN_ALLOW`, `WG_MTU`). It rejects a broken Proton config or bad
   settings before it changes anything. Re-apply with `sudo ./scripts/setup.sh` (it keeps using
   `/etc/wireguard/wg0.conf`), or pass a new Proton file to switch servers.

   **Option B: Ansible**, from a control node (`sudo apt install ansible` or
   `pipx install ansible-core`; the role only uses `ansible.builtin` modules):
   ```
   git clone https://github.com/brnl/protonvpngateway
   cd protonvpngateway
   cp examples/inventory.yml inventory.yml          # set ansible_host and ansible_user
   cp -r examples/group_vars group_vars             # fill in vars.yml and vault.yml
   ansible-vault encrypt group_vars/vpngateway/vault.yml
   ansible-playbook site.yml --check --diff --ask-vault-pass --ask-become-pass   # preview
   ansible-playbook site.yml --ask-vault-pass --ask-become-pass
   ```
   `inventory.yml` and `group_vars/` are git-ignored; the private key only ever lives in the
   vault file. To run it on the VM itself, set `ansible_connection: local` in the inventory.
5. **Clients:** use `10.10.10.1` as default gateway and DNS server. The gateway does not
   run a DHCP server, so either use static addresses or let an existing DHCP server on
   NIC B hand out gateway and DNS.

## Managing the gateway
SSH is only open on NIC B by default. Two things to know when you manage the VM over SSH:
- **From NIC A:** list your network in `gateway_ssh_wan_allow` (Ansible, for example
  `["192.168.1.0/24"]`) or `SSH_WAN_ALLOW="192.168.1.0/24"` (script). Otherwise the firewall
  blocks new SSH connections on NIC A once it is applied; a running session survives, but the
  next one will not connect (use the Proxmox console to recover).
- **Routing:** `wg-quick` sends everything except WireGuard's own packets into the tunnel.
  Replies to SSH from a network *behind* your router (not the subnet NIC A is in) would end up
  in the tunnel and get lost. Manage the gateway from NIC B or from the same subnet as NIC A.

### Locked out over SSH?
On the Proxmox console, type:
```
nft insert rule inet gateway input tcp dport 22 accept
```
SSH works again straight away and the kill switch and NAT stay in place. This is temporary
(gone after a reboot, a firewall reload or another `setup.sh` run) and opens SSH to everyone on
NIC A until then, so follow up by setting `SSH_WAN_ALLOW` / `gateway_ssh_wan_allow` and
re-applying. If you are in a different subnet than NIC A, the firewall isn't the (only)
problem, see "Routing" above: `systemctl stop wg-quick@wg0` makes SSH work from anywhere
(clients on NIC B then have no internet, but don't leak); start it again afterwards.

## Idempotency
Re-running the script or the playbook is safe: files are only rewritten when they differ, and a
service is reloaded or restarted only when its own config changed. Notably:
- The firewall is reloaded with `nft -f`, which replaces only the `gateway` table. Neither
  option runs `systemctl restart nftables`, because its stop action does `nft flush ruleset`
  and would briefly remove the kill switch and NAT.
- The tunnel (`wg-quick@wg0`) is only restarted when `wg0.conf` changed, so clients are not
  disconnected by a no-op run.
- The private key is never printed: the role installs `wg0.conf` with `no_log` (so it is not in
  `--diff` output either), and the script doesn't echo it.

## Reset
`scripts/reset.sh` takes the VM back to a plain Debian host, whether you used the script or the
Ansible role:
```
sudo ./scripts/reset.sh --dry-run      # show what it would do, change nothing
sudo ./scripts/reset.sh                # show the plan, ask for confirmation, then do it
```
It stops the tunnel and deletes `wg0.conf` (your Proton private key; `--keep-wg-conf` keeps it),
removes the `gateway` nftables table and puts Debian's stock `/etc/nftables.conf` back, removes the
unbound forwarder config and the sysctl file (forwarding off, IPv6 on), and restores the DNS
settings (the servers come from the last DHCP lease of NIC A, or `DNS_SERVERS="1.2.3.4"`).
`--purge-packages` also purges `wireguard-tools` and `unbound` (not `nftables`).

- It only touches files that still carry this project's marker text, so a config you wrote
  yourself is left alone and mentioned.
- It does not touch network interface config, the repo or your Proton download. Clients lose
  their internet (no forwarding, no NAT); they don't leak.
- Running it again is a no-op ("Nothing to reset"). If a step fails the others still run and the
  exit code is non-zero; if the tunnel can't be stopped, `wg0.conf` is kept so `wg-quick` can take
  it down. Reboot afterwards to make sure IPv6 is fully back.
- Set up again with `./scripts/setup.sh proton.conf`. Re-running the Ansible playbook does the
  same.

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
- **NIC check fails:** the interface names differ from `ens18`/`ens19`. Set `WAN_IF` and
  `LAN_IF` (script) or `gateway_wan_if` and `gateway_lan_if` (Ansible).
- **Stalling downloads:** set `gateway_wg_mtu: 1380`. The MSS clamp in the firewall normally
  prevents this.
- **No handshake:** the Proton server or key may be expired; download a new config and update
  the variables. Make sure the uplink has an address and that UDP to the endpoint is not
  blocked upstream.
- **Switching server:** pass the new Proton file to the script, or change
  `gateway_wg_peer_public_key` and `gateway_wg_endpoint_ip` (and the private key if it differs)
  in Ansible, and re-run. Both the firewall and `wg0.conf` are updated.
- **`wg-quick` fails on `::/0`:** IPv6 is disabled on purpose; the role writes only
  `AllowedIPs = 0.0.0.0/0`.
- **Port forwarding (NAT-PMP):** not covered here. If you need it, look at Gluetun, which
  supports it for ProtonVPN.

## Notes
- The firewall, unbound and WireGuard configs exist twice: in `scripts/setup.sh` and in the
  role's templates. When you change one, change the other (their rendered output was checked
  to be equivalent).
- Never commit your real WireGuard config or key (`.gitignore` blocks `wg0.conf`, `*.key`,
  `inventory.yml` and `group_vars/`).
- LXC is possible if you prefer: WireGuard runs on the Proxmox host kernel, but you need
  to deal with `/dev/net/tun` and `wg-quick` sysctl restrictions. Not tested here.
