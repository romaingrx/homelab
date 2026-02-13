# homelab

DNS and TLS infrastructure for `*.internal.romaingrx.com` over Tailscale.

Every Tailscale device automatically gets a DNS name (`<hostname>.internal.romaingrx.com`) and a valid wildcard HTTPS certificate, managed from the UDM Pro.

## Architecture

```
Tailscale API  --->  UDM Pro (controller)  --->  dnsmasq (hosts file)
                         |                            |
                    acme.sh (Let's Encrypt)    Tailscale split DNS
                         |                            |
              +----------+----------+      All tailnet devices resolve
              |          |          |      *.internal.romaingrx.com
           UDM Pro   Proxmox    (future)   via UDM's dnsmasq
         (local)   (Tailscale SSH)
```

DNS resolution:
```
proxmox.internal.romaingrx.com
  -> Tailscale MagicDNS (split DNS rule)
  -> UDM dnsmasq (100.71.235.104:53)
  -> A record: 100.99.206.70
  -> WireGuard tunnel to proxmox
```

## Prerequisites

1. **Tailscale OAuth client** (scope: `devices:read`) — [create here](https://login.tailscale.com/admin/settings/oauth)
2. **Cloudflare API token** (scope: `Zone.DNS:Edit` on `romaingrx.com`) — only for cert issuance, [create here](https://dash.cloudflare.com/profile/api-tokens)
3. **Tailscale SSH** enabled on target hosts: `tailscale set --ssh`
4. **Tailscale split DNS**: Tailscale admin → DNS → add nameserver `100.71.235.104` for `internal.romaingrx.com`

## Setup

```bash
# 1. Clone to UDM
ssh udm
git clone https://github.com/romaingrx/homelab.git /data/homelab
cd /data/homelab

# 2. Configure secrets
cp .env.example .env
chmod 600 .env
nano .env  # fill in all values

# 3. Run bootstrap
sudo ./setup.sh

# 4. Configure Tailscale split DNS (one-time, in admin console)
#    Tailscale admin -> DNS -> Split DNS
#    Add: internal.romaingrx.com -> 100.71.235.104
```

## What it does

### DNS (dnsmasq on Tailscale interface)
A dedicated dnsmasq instance runs on the UDM's Tailscale IP, serving `*.internal.romaingrx.com` records from a hosts file. Tailscale split DNS routes all tailnet devices' queries for this domain to the UDM.

### DNS Sync (every 15 min)
Fetches all Tailscale devices via OAuth API, writes updated hosts file, sends SIGHUP to dnsmasq.

### Cert Renewal (daily 3:30 AM)
Checks if the `*.internal.romaingrx.com` wildcard cert needs renewal (via acme.sh + Cloudflare DNS-01), and if so distributes it to all configured hosts via Tailscale SSH.

## Manual operations

```bash
# Trigger DNS sync now
systemctl start homelab-dns-sync

# Trigger cert renewal + distribution now
systemctl start homelab-cert-renew

# Check services
systemctl status homelab-dnsmasq
systemctl list-timers 'homelab-*'

# View logs
journalctl -u homelab-dnsmasq -e
journalctl -u homelab-dns-sync -e
journalctl -u homelab-cert-renew -e

# Test DNS resolution (from any Tailscale device)
dig proxmox.internal.romaingrx.com
```

## Adding a new device

1. Install Tailscale: `curl -fsSL https://tailscale.com/install.sh | sh && tailscale up --ssh`
2. DNS appears automatically within 15 min (or trigger: `ssh udm systemctl start homelab-dns-sync`)
3. If it needs HTTPS:
   - Add a `deploy-remote.sh` line in `certs/renew-and-distribute.sh`
   - Create a receiver script in `receivers/` (if needed)
   - Push initial cert: `ssh udm /data/homelab/certs/renew-and-distribute.sh`
4. Commit and push

## Verification

```bash
# DNS resolves (from any Tailscale device)
dig proxmox.internal.romaingrx.com

# Cert is valid
openssl x509 -in /data/homelab/certs/fullchain.pem -noout -subject -enddate

# HTTPS works on Proxmox
curl -sI https://proxmox.internal.romaingrx.com:8006

# Services are running
systemctl status homelab-dnsmasq
systemctl list-timers 'homelab-*'
```

## Uninstall

```bash
sudo ./uninstall.sh          # remove services, keep data
sudo ./uninstall.sh --purge  # also remove acme.sh, certs, logs
# Then remove split DNS entry in Tailscale admin
```

## Structure

```
homelab/
  .env.example          # Secrets template
  setup.sh              # One-time bootstrap (idempotent)
  uninstall.sh          # Clean removal
  lib/
    common.sh           # Logging, error handling, secrets
    tailscale.sh        # Tailscale OAuth + device listing
    cloudflare.sh       # Cloudflare DNS CRUD (for cert issuance)
  dns-sync/
    sync.sh             # Tailscale -> dnsmasq hosts file
    config.sh           # Domain suffix, TTL
    dnsmasq.conf        # dnsmasq config (Tailscale interface only)
  certs/
    issue.sh            # First-time wildcard cert issuance
    renew-and-distribute.sh  # Daily renewal + push to hosts
    deploy-local.sh     # Install cert on UDM
    deploy-remote.sh    # SCP cert to remote host via Tailscale SSH
  receivers/
    proxmox.sh          # Post-deploy on Proxmox (pveproxy reload)
    k3s.sh              # Future: k8s TLS secret
    hass.sh             # Future: Home Assistant
  systemd/
    homelab-dnsmasq.service
    homelab-dns-sync.{service,timer}
    homelab-cert-renew.{service,timer}
```
