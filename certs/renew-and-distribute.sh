#!/usr/bin/env bash
# Daily cert renewal orchestrator
#
# 1. Run acme.sh --cron to renew if needed (exits 0 even if no renewal)
# 2. If the cert was renewed (mtime changed), distribute to all reachable hosts
#
# Hosts are discovered from the Tailscale API and addressed by Tailscale IP
# (the UDM cannot resolve bare hostnames). Each tag:server device: skip self
# and unreachable hosts; run a local receiver on the UDM if one exists (marked
# '# local-receiver'), else deploy over Tailscale SSH.
#
# Called by: homelab-cert-renew.timer (daily 3:30 AM)

set -eo pipefail

CERTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${CERTS_DIR}/../lib/common.sh"
source "${CERTS_DIR}/../lib/tailscale.sh"

load_secrets

ACME_HOME="${HOMELAB_DIR}/.acme.sh"
CERT_DIR="${HOMELAB_DIR}/certs"
DOMAIN="internal.romaingrx.com"
LOCAL_HOSTNAME=$(hostname | tr '[:upper:]' '[:lower:]')

require_cmd "${ACME_HOME}/acme.sh"

log_info "=== Cert renewal check starting ==="

# Record the cert content hash before renewal. mtime is useless here: acme.sh
# --install-cert rewrites the files on every run (bumping mtime) even when no
# renewal happened, so only a content hash distinguishes a real renewal from a
# no-op reinstall.
before_hash=""
[[ -f "${CERT_DIR}/fullchain.pem" ]] && before_hash=$(sha256 "${CERT_DIR}/fullchain.pem")

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

# Distribute only if the cert content actually changed
after_hash=""
[[ -f "${CERT_DIR}/fullchain.pem" ]] && after_hash=$(sha256 "${CERT_DIR}/fullchain.pem")

if [[ "${before_hash}" == "${after_hash}" ]] && [[ -n "${before_hash}" ]]; then
    log_info "Certificate unchanged, skipping distribution"
    log_info "=== Cert renewal check complete (no renewal) ==="
    exit 0
fi

log_info "Certificate renewed, distributing to all hosts..."

failures=0
deployed=0
skipped=0

# --- Deploy to local UDM ---
"${CERTS_DIR}/deploy-local.sh" \
    || { log_error "Local deploy failed"; failures=$((failures + 1)); }
deployed=$((deployed + 1))

# --- Auto-discover and deploy to all tag:server devices ---
devices_json=$(ts_list_devices)
server_devices=$(echo "${devices_json}" | jq -c '[.[] | select(.tags | index("tag:server"))]')
server_count=$(echo "${server_devices}" | jq 'length')
log_info "Found ${server_count} devices tagged tag:server"

# Self is matched by IP: the UDM's Linux hostname differs from its Tailscale
# hostname, so a hostname comparison would never match.
self_ip=$(ts_self_ip)
[[ -n "${self_ip}" ]] && log_info "This node's Tailscale IP: ${self_ip}"

# Read from FD 3, not stdin: ssh inside the loop would otherwise drain the
# piped device list and truncate iteration after the first host it connects to.
while IFS= read -r entry <&3; do
    hostname=$(echo "${entry}" | jq -r '.hostname')
    ipv4=$(echo "${entry}" | jq -r '.ipv4')

    # Skip self (by IP; hostname fallback if self IP unknown)
    if { [[ -n "${self_ip}" ]] && [[ "${ipv4}" == "${self_ip}" ]]; } \
        || [[ "${hostname}" == "${LOCAL_HOSTNAME}" ]]; then
        log_info "Skipping self (${hostname}/${ipv4})"
        continue
    fi

    # Skip unreachable hosts (a skip, not a failure)
    if ! host_reachable "${ipv4}"; then
        log_warn "Skipping ${hostname} (${ipv4}): unreachable"
        skipped=$((skipped + 1))
        continue
    fi

    receiver_file="${HOMELAB_DIR}/receivers/${hostname}.sh"

    # Local receiver runs on the UDM; pass the target IP so it needn't resolve names.
    if [[ -f "${receiver_file}" ]] && head -5 "${receiver_file}" | grep -q '# local-receiver'; then
        log_info "Running local receiver for ${hostname} (target ${ipv4})..."
        if TS_TARGET_IP="${ipv4}" bash "${receiver_file}"; then
            deployed=$((deployed + 1))
        else
            log_error "Local deploy to ${hostname} failed"
            failures=$((failures + 1))
        fi
        continue
    fi

    # Remote deploy over Tailscale SSH; skip hosts that don't accept SSH
    if ! ssh "${SSH_OPTS[@]}" "${ipv4}" "true" &>/dev/null; then
        log_warn "Skipping ${hostname} (${ipv4}): SSH not reachable"
        skipped=$((skipped + 1))
        continue
    fi

    # Host-specific receiver if present, else generic copy
    receiver=""
    [[ -f "${receiver_file}" ]] && receiver="receivers/${hostname}.sh"

    if "${CERTS_DIR}/deploy-remote.sh" "${ipv4}" ${receiver}; then
        deployed=$((deployed + 1))
    else
        log_error "Deploy to ${hostname} (${ipv4}) failed"
        failures=$((failures + 1))
    fi
done 3< <(echo "${server_devices}" | jq -c '.[]')

log_info "Deployed to ${deployed} hosts, skipped ${skipped}, failed ${failures}"

if [[ "${failures}" -gt 0 ]]; then
    log_error "=== Cert distribution finished with ${failures} failure(s) ==="
    exit 1
fi

log_info "=== Cert renewal and distribution complete ==="
