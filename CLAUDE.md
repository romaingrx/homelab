# CLAUDE.md

## What is this repo?

Homelab infrastructure automation running on a **UniFi Dream Machine Pro (UDM Pro)**. Provides automatic DNS and TLS certificate management for all Tailscale devices under `*.internal.romaingrx.com`.

## Architecture

- **UDM Pro** (`ssh udm`, `/data/homelab/`) — runs all services: dnsmasq, DNS sync timer, cert renewal timer
- **Tailscale** — mesh VPN connecting all devices; MagicDNS split DNS routes `internal.romaingrx.com` queries to UDM's dnsmasq
- **dnsmasq** — listens on the UDM's Tailscale IP (`100.71.235.104:53`), serves `<hostname>.internal.romaingrx.com` -> Tailscale IP mappings
- **acme.sh** — issues/renews wildcard cert `*.internal.romaingrx.com` via Let's Encrypt DNS-01 (Cloudflare)
- **Cert distribution** — auto-discovers `tag:server` Tailscale devices and deploys certs via SSH or local receivers

## Key paths

| Path | Description |
|------|-------------|
| `lib/common.sh` | Shared utilities: logging, secrets loading, HTTP helpers |
| `lib/tailscale.sh` | Tailscale OAuth API: token management, device listing |
| `lib/cloudflare.sh` | Cloudflare DNS API: CRUD for A records |
| `dns-sync/sync.sh` | Tailscale devices -> dnsmasq records (runs every 15 min) |
| `dns-sync/config.sh` | DNS domain suffix and TTL config |
| `dns-sync/dnsmasq.conf` | dnsmasq config (Tailscale interface only) |
| `certs/issue.sh` | One-time wildcard cert issuance |
| `certs/renew-and-distribute.sh` | Daily renewal + distribution orchestrator |
| `certs/deploy-local.sh` | Deploy cert to UDM (unifi-core/nginx) |
| `certs/deploy-remote.sh` | Deploy cert to remote host via Tailscale SSH |
| `receivers/*.sh` | Host-specific cert installation scripts |
| `systemd/` | Service and timer unit files |
| `setup.sh` | One-time bootstrap (idempotent, run as root) |
| `uninstall.sh` | Clean removal (`--purge` for full cleanup) |

## Receiver types

There are two types of receivers in `receivers/`:

- **Remote receivers** (default) — SCP'd to the target host and executed via Tailscale SSH. Example: `proxmox.sh`
- **Local receivers** — run on the UDM directly, for hosts where SSH doesn't work (e.g. containerized Tailscale). Marked with `# local-receiver` on line 2. Example: `truenas.sh` (uses TrueNAS REST API)

## Secrets

All secrets are in `.env` (gitignored). Template: `.env.example`. Required:
- `TS_OAUTH_CLIENT_ID` / `TS_OAUTH_CLIENT_SECRET` — Tailscale OAuth (scope: `devices:read`)
- `CF_API_TOKEN` — Cloudflare API token (scope: `Zone.DNS:Edit`)
- `CF_ZONE_ID` — Cloudflare zone ID for `romaingrx.com`
- `ACME_EMAIL` — Let's Encrypt registration email
- `TRUENAS_API_KEY` — TrueNAS API key (only needed for the TrueNAS local receiver)

## Conventions

- All scripts use `set -eo pipefail` and source `lib/common.sh`
- Logging via `log_info`, `log_warn`, `log_error`, `die`
- HTTP calls via `http_get`, `http_post`, etc. (curl with retries)
- Secrets loaded via `load_secrets` which validates `.env` permissions (600) and required vars
- Device discovery uses Tailscale API with `tag:server` filter
- Hardcoded domain: `internal.romaingrx.com`

## Current infrastructure

| Host | Role | Cert receiver | Notes |
|------|------|---------------|-------|
| UDM Pro | Controller, DNS, certs | `deploy-local.sh` | Runs all services |
| Proxmox | Hypervisor | `proxmox.sh` (remote) | Tailscale SSH, pveproxy reload |
| TrueNAS | NAS (VM on Proxmox) | `truenas.sh` (local) | REST API, read-only rootfs |
| k3s | Kubernetes (future) | `k3s.sh` (placeholder) | Not yet implemented |
| Home Assistant | Smart home (future) | `hass.sh` (placeholder) | Not yet implemented |

## TrueNAS specifics

TrueNAS Scale has a **read-only root filesystem** — no native package installs. Tailscale runs as a **container app** (not on the host), so Tailscale SSH connects to the container, not the host. The cert receiver uses the **TrueNAS REST API** (`http://truenas/api/v2.0`) instead of SSH. The TrueNAS middleware API (`midclt call`) is the primary way to manage the system when SSH'd in as `truenas_admin`.

## Common tasks

```bash
# Test from UDM
ssh udm
systemctl start homelab-dns-sync       # force DNS sync
systemctl start homelab-cert-renew     # force cert renewal + distribution
journalctl -u homelab-cert-renew -e    # check cert logs

# Deploy cert to a single host manually
cd /data/homelab
bash certs/deploy-remote.sh proxmox receivers/proxmox.sh
bash receivers/truenas.sh              # local receiver, runs on UDM

# Check services
systemctl status homelab-dnsmasq
systemctl list-timers 'homelab-*'
```

## Gotchas

- UDM's own DNS resolver does NOT use the local dnsmasq — use Tailscale MagicDNS hostnames (e.g. `truenas`) or IPs when scripting on the UDM
- TrueNAS certificate API is async — `POST /certificate` returns a job ID, must poll `/core/get_jobs` until complete
- TrueNAS cert delete is also async and must complete before re-importing with the same name
- `truenas_admin` user on TrueNAS cannot use passwordless sudo — use `midclt call` instead for privileged operations
- acme.sh uses `CF_Token` (not `CF_API_TOKEN`) — the scripts re-export as needed
