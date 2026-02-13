#!/usr/bin/env bash
# Daily cert renewal orchestrator
#
# 1. Run acme.sh --cron to renew if needed (exits 0 even if no renewal)
# 2. If the cert was renewed (mtime changed), distribute to all hosts
#
# Called by: homelab-cert-renew.timer (daily 3:30 AM)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

load_secrets

ACME_HOME="${HOMELAB_DIR}/.acme.sh"
CERT_DIR="${HOMELAB_DIR}/certs"
DOMAIN="internal.romaingrx.com"

require_cmd "${ACME_HOME}/acme.sh"

log_info "=== Cert renewal check starting ==="

# Record mtime before renewal attempt
before_mtime=0
if [[ -f "${CERT_DIR}/fullchain.pem" ]]; then
    before_mtime=$(stat -c '%Y' "${CERT_DIR}/fullchain.pem" 2>/dev/null \
        || stat -f '%m' "${CERT_DIR}/fullchain.pem")
fi

# acme.sh uses CF_Token
export CF_Token="${CF_API_TOKEN}"

# Run renewal
"${ACME_HOME}/acme.sh" --cron \
    --home "${ACME_HOME}" \
    || log_warn "acme.sh --cron exited with non-zero (may be normal if no renewal needed)"

# Re-install cert (acme.sh --cron handles this via install-cert config, but be explicit)
if [[ -d "${ACME_HOME}/${DOMAIN}_ecc" ]]; then
    "${ACME_HOME}/acme.sh" --install-cert \
        --domain "${DOMAIN}" \
        --ecc \
        --cert-file      "${CERT_DIR}/cert.pem" \
        --key-file       "${CERT_DIR}/key.pem" \
        --fullchain-file "${CERT_DIR}/fullchain.pem" \
        --home "${ACME_HOME}"
fi

# Check if cert actually changed
after_mtime=0
if [[ -f "${CERT_DIR}/fullchain.pem" ]]; then
    after_mtime=$(stat -c '%Y' "${CERT_DIR}/fullchain.pem" 2>/dev/null \
        || stat -f '%m' "${CERT_DIR}/fullchain.pem")
fi

if [[ "${before_mtime}" == "${after_mtime}" ]] && [[ "${before_mtime}" != "0" ]]; then
    log_info "Certificate unchanged, skipping distribution"
    log_info "=== Cert renewal check complete (no renewal) ==="
    exit 0
fi

log_info "Certificate renewed, distributing to all hosts..."

# --- Deploy to local UDM ---
"${SCRIPT_DIR}/deploy-local.sh"

# --- Deploy to remote hosts ---
# Add new hosts here as they are set up:
"${SCRIPT_DIR}/deploy-remote.sh" proxmox receivers/proxmox.sh

# Future hosts (uncomment when ready):
# "${SCRIPT_DIR}/deploy-remote.sh" carl receivers/proxmox.sh
# "${SCRIPT_DIR}/deploy-remote.sh" k3s receivers/k3s.sh
# "${SCRIPT_DIR}/deploy-remote.sh" hass receivers/hass.sh

log_info "=== Cert renewal and distribution complete ==="
