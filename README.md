# homelab

DNS and TLS infrastructure for `*.internal.romaingrx.com` over Tailscale.

Every Tailscale device automatically gets a DNS name (`<hostname>.internal.romaingrx.com`) and a valid wildcard HTTPS certificate, managed from the UDM Pro.

## Architecture

```
Tailscale API  --->  UDM Pro (controller)  --->  Cloudflare DNS (A records)
                         |
                    acme.sh (Let's Encrypt wildcard cert)
                         |
              +----------+----------+
              |          |          |
           UDM Pro   Proxmox    (future)
         (local)   (Tailscale SSH)
```

DNS resolution: `proxmox.internal.romaingrx.com` -> Cloudflare A record -> Tailscale IP -> WireGuard tunnel.

## Prerequisites

1. **Tailscale OAuth client** (scope: `devices:read`) — [create here](https://login.tailscale.com/admin/settings/oauth)
2. **Cloudflare API token** (scope: `Zone.DNS:Edit` on `romaingrx.com`) — [create here](https://dash.cloudflare.com/profile/api-tokens)
3. **Tailscale SSH** enabled on target hosts: `tailscale up --ssh`
4. **UDM Pro** with Tailscale installed and SSH access

## Setup

```bash
# 1. Clone to UDM
ssh udm
git clone git@github.com:romaingrx/homelab.git /data/homelab
cd /data/homelab

# 2. Configure secrets
cp .env.example .env
chmod 600 .env
nano .env  # fill in all values

# 3. Run bootstrap
sudo ./setup.sh
```

## What it does

### DNS Sync (every 15 min)
Fetches all Tailscale devices, creates/updates/deletes Cloudflare A records to match.

### Cert Renewal (daily 3:30 AM)
Checks if the `*.internal.romaingrx.com` wildcard cert needs renewal, and if so distributes it to all configured hosts via Tailscale SSH.

## Manual operations

```bash
# Trigger DNS sync now
systemctl start homelab-dns-sync

# Trigger cert renewal + distribution now
systemctl start homelab-cert-renew

# Check timer status
systemctl list-timers 'homelab-*'

# View logs
journalctl -u homelab-dns-sync -e
journalctl -u homelab-cert-renew -e

# Dry-run DNS sync
DRY_RUN=true /data/homelab/dns-sync/sync.sh
```

## Adding a new device

1. Install Tailscale: `curl -fsSL https://tailscale.com/install.sh | sh && tailscale up --ssh`
2. Tag it in Tailscale admin (e.g., `tag:server`)
3. DNS appears automatically within 15 min
4. If it needs HTTPS:
   - Add a `deploy-remote.sh` line in `certs/renew-and-distribute.sh`
   - Create a receiver script in `receivers/` (if needed)
   - Push initial cert: `ssh udm /data/homelab/certs/renew-and-distribute.sh`
5. Commit and push

## Verification

```bash
# DNS works
dig proxmox.internal.romaingrx.com

# Cert is valid
openssl x509 -in /data/homelab/certs/fullchain.pem -noout -subject -enddate

# HTTPS works locally
curl -sI https://udm.internal.romaingrx.com

# HTTPS works on Proxmox
curl -sI https://proxmox.internal.romaingrx.com:8006

# Timers are active
systemctl list-timers 'homelab-*'
```

## Uninstall

```bash
sudo ./uninstall.sh          # remove timers, keep data
sudo ./uninstall.sh --purge  # also remove acme.sh, certs, logs
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
    cloudflare.sh       # Cloudflare DNS CRUD
  dns-sync/
    sync.sh             # Tailscale -> Cloudflare A records
    config.sh           # Domain suffix, TTL
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
    homelab-dns-sync.{service,timer}
    homelab-cert-renew.{service,timer}
```
