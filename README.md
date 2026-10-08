# protonvpngateway
Solution to route all trafic from network card B through protonvpn on network card A.

A small Debian VM on Proxmox with two NICs that acts as a gateway: everything
that comes in on NIC B is NATed into a ProtonVPN WireGuard tunnel that runs over
NIC A. If the tunnel goes down, client traffic stops instead of leaking.

```
[clients] ── NIC B (LAN, 10.10.10.1) ── [Debian VM] ── NIC A (uplink) ── router/internet
                                           └── wg0 (ProtonVPN, runs over NIC A)
```

## Why a VM (and not an LXC container)
- A VM has its own kernel and network stack, so WireGuard and the kill switch behave
  predictably. In an LXC container `wg-quick` often fails on `src_valid_mark` and you
  need extra device and permission tweaks.
- It is only ~512 MB RAM, 1 vCPU and 4 GB disk.

## Components
| File | Purpose |
|---|---|
| `config/wg0.conf.example` | WireGuard config template (fill in from your Proton download) |
| `config/nftables.conf` | Firewall: NAT, MSS clamp, kill switch |
| `config/unbound-gateway.conf` | DNS forwarder that resolves through the tunnel (10.2.0.1) |
| `config/sysctl.d/99-gateway.conf` | IP forwarding on, IPv6 off |
| `config/interfaces.example` | Network config for both NICs |
| `scripts/setup.sh` | Installs and configures all of the above |

## Setup
1. **Proxmox:** create a VM with two virtio NICs. `net0` goes on the bridge toward your
   router (NIC A), `net1` on the bridge for the clients (NIC B). Install Debian 12 or 13
   (minimal + SSH server).
2. **Proton config:** at account.protonvpn.com → Downloads → WireGuard configuration,
   pick platform *GNU/Linux* and a server, then download it. Copy it to
   `/etc/wireguard/wg0.conf` on the VM. Remove the `DNS =` line, and use only
   `AllowedIPs = 0.0.0.0/0` (see `config/wg0.conf.example`).
3. **Network:** configure both NICs as in `config/interfaces.example`
   (check names with `ip -br link`; on Proxmox they are usually `ens18`/`ens19`).
4. **Run the setup:**
   ```
   git clone https://github.com/brnl/protonvpngateway
   cd protonvpngateway
   sudo WAN_IF=ens18 LAN_IF=ens19 LAN_ADDR=10.10.10.1 LAN_NET=10.10.10.0/24 ./scripts/setup.sh
   ```
5. **Clients:** use `10.10.10.1` as default gateway and DNS server. The gateway does not
   run a DHCP server, so either use static addresses or let an existing DHCP server on
   NIC B hand out gateway and DNS.

## How the kill switch works
- `wg-quick` routes all traffic through `wg0` and keeps the WireGuard packets themselves on
  NIC A using a firewall mark.
- The `forward` chain only allows `LAN → wg0`. There is no rule from `LAN` to `WAN`, so when
  the tunnel is down, client packets are dropped.
- The `output` chain only allows the gateway itself to use NIC A for WireGuard (UDP 51820)
  and DHCP. DNS and updates on the gateway always go through the tunnel.

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
- **Interface names:** if `setup.sh` complains about an interface, pass the right
  `WAN_IF`/`LAN_IF`.
- **Stalling downloads:** lower the tunnel MTU in `wg0.conf` (`MTU = 1380`). The MSS clamp
  in `nftables.conf` normally prevents this.
- **No handshake:** the Proton server or key may be expired; generate a new config. Make
  sure the uplink has an address and that UDP 51820 is not blocked upstream.
- **`wg-quick` fails on `::/0`:** IPv6 is disabled on purpose; keep `AllowedIPs = 0.0.0.0/0`.
- **Port forwarding (NAT-PMP):** not covered here. If you need it, look at Gluetun, which
  supports it for ProtonVPN.

## Notes
- Never commit your real `wg0.conf`; it contains your private key (`.gitignore` blocks it).
- LXC is possible if you prefer: WireGuard runs on the Proxmox host kernel, but you need
  to deal with `/dev/net/tun` and `wg-quick` sysctl restrictions. Not tested here.
