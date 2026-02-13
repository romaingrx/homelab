#!/usr/bin/env bash
# Daily cert renewal orchestrator
#
# 1. Run acme.sh --cron to renew if needed (exits 0 even if no renewal)
# 2. If the cert was renewed (mtime changed), distribute to all reachable hosts
#
# Remote hosts are auto-discovered from the Tailscale API. For each host:
#   - Skip if it's the local UDM
#   - Skip if SSH is unreachable (Tailscale SSH not enabled, offline, etc.)
#   - If a matching receiver script exists in receivers/<hostname>.sh, use it
#   - Otherwise just copy the cert files to /etc/homelab-certs/
#
# Called by: homelab-cert-renew.timer (daily 3:30 AM)

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/../lib/tailscale.sh"

load_secrets

ACME_HOME="${HOMELAB_DIR}/.acme.sh"
CERT_DIR="${HOMELAB_DIR}/certs"
DOMAIN="internal.romaingrx.com"
LOCAL_HOSTNAME=$(hostname | tr '[:upper:]' '[:lower:]')

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

failures=0
deployed=0
skipped=0

# --- Deploy to local UDM ---
"${SCRIPT_DIR}/deploy-local.sh" \
    || { log_error "Local deploy failed"; failures=$((failures + 1)); }
deployed=$((deployed + 1))

# --- Auto-discover and deploy to all tag:server devices ---
devices_json=$(ts_list_devices)
server_devices=$(echo "${devices_json}" | jq -c '[.[] | select(.tags | index("tag:server"))]')
server_count=$(echo "${server_devices}" | jq 'length')
log_info "Found ${server_count} devices tagged tag:server"

while IFS= read -r entry; do
    hostname=$(echo "${entry}" | jq -r '.hostname')

    # Skip self
    if [[ "${hostname}" == "${LOCAL_HOSTNAME}" ]]; then
        continue
    fi

    # Check if SSH is reachable (5s timeout)
    if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "${hostname}" "true" &>/dev/null; then
        log_warn "Skipping ${hostname} (SSH not reachable)"
        skipped=$((skipped + 1))
        continue
    fi

    # Use host-specific receiver if it exists, otherwise use generic
    receiver=""
    if [[ -f "${HOMELAB_DIR}/receivers/${hostname}.sh" ]]; then
        receiver="receivers/${hostname}.sh"
    fi

    "${SCRIPT_DIR}/deploy-remote.sh" "${hostname}" ${receiver} \
        || { log_error "Deploy to ${hostname} failed"; failures=$((failures + 1)); continue; }
    deployed=$((deployed + 1))
done < <(echo "${server_devices}" | jq -c '.[]')

log_info "Deployed to ${deployed} hosts, skipped ${skipped}, failed ${failures}"

if [[ "${failures}" -gt 0 ]]; then
    log_error "=== Cert distribution finished with ${failures} failure(s) ==="
    exit 1
fi

log_info "=== Cert renewal and distribution complete ==="
