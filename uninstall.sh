#!/usr/bin/env bash
# Clean removal of homelab infrastructure from UDM
#
# What it does:
#   1. Stops and disables systemd timers
#   2. Removes systemd unit files
#   3. Optionally removes acme.sh and certs
#
# Does NOT:
#   - Delete Cloudflare DNS records (run dns-sync with empty device list if desired)
#   - Remove the repo itself
#
# Usage: sudo ./uninstall.sh [--purge]
#   --purge: also remove .acme.sh directory and cached tokens

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

SYSTEMD_DIR="/etc/systemd/system"
PURGE=false

[[ "$(id -u)" -eq 0 ]] || die "This script must be run as root"

for arg in "$@"; do
    case "${arg}" in
        --purge) PURGE=true ;;
        *) die "Unknown argument: ${arg}" ;;
    esac
done

# --- Stop and disable timers ---
log_info "Stopping and disabling systemd timers..."
for unit in homelab-dns-sync.timer homelab-cert-renew.timer; do
    if systemctl is-active --quiet "${unit}" 2>/dev/null; then
        systemctl stop "${unit}"
        log_info "Stopped ${unit}"
    fi
    if systemctl is-enabled --quiet "${unit}" 2>/dev/null; then
        systemctl disable "${unit}"
        log_info "Disabled ${unit}"
    fi
done

# --- Remove unit files ---
log_info "Removing systemd unit files..."
for unit in homelab-dns-sync.service homelab-dns-sync.timer homelab-cert-renew.service homelab-cert-renew.timer; do
    rm -f "${SYSTEMD_DIR}/${unit}"
done
systemctl daemon-reload
log_info "Systemd units removed"

# --- Purge optional data ---
if [[ "${PURGE}" == "true" ]]; then
    log_info "Purging acme.sh and cached data..."
    rm -rf "${HOMELAB_DIR}/.acme.sh"
    rm -f  "${HOMELAB_DIR}/.ts_token"
    rm -rf "${HOMELAB_DIR}/certs/"*.pem "${HOMELAB_DIR}/certs/"*.key
    rm -rf "${HOMELAB_DIR}/logs"
    log_info "Purge complete"
else
    log_info "Skipping purge (use --purge to remove .acme.sh, certs, and logs)"
fi

log_info "Uninstall complete. The repo at ${HOMELAB_DIR} has been preserved."
