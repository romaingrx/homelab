#!/usr/bin/env bash
# Proxmox VE receiver: install wildcard cert for pveproxy
#
# Called by deploy-remote.sh with: ./receiver.sh /tmp/homelab-cert
#
# Proxmox expects:
#   /etc/pve/local/pveproxy-ssl.pem  (fullchain)
#   /etc/pve/local/pveproxy-ssl.key  (private key)

set -euo pipefail

CERT_SRC="${1:?Usage: $0 <cert-dir>}"

echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] Installing cert to Proxmox..."

cp "${CERT_SRC}/fullchain.pem" /etc/pve/local/pveproxy-ssl.pem
cp "${CERT_SRC}/key.pem"       /etc/pve/local/pveproxy-ssl.key
chmod 640 /etc/pve/local/pveproxy-ssl.key

# Reload pveproxy to pick up the new certificate
systemctl reload pveproxy

echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] Proxmox cert deployed, pveproxy reloaded"
