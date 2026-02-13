#!/usr/bin/env bash
# Deploy wildcard cert to a remote host via Tailscale SSH
#
# Usage: deploy-remote.sh <hostname> [receiver-script]
#
# Examples:
#   deploy-remote.sh proxmox receivers/proxmox.sh   # with host-specific receiver
#   deploy-remote.sh carl                            # generic: copies to /etc/homelab-certs/
#
# This will:
#   1. SCP fullchain.pem and key.pem to the target
#   2. If a receiver script is given, run it on the target
#   3. Otherwise, install certs to /etc/homelab-certs/ on the target

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

CERT_DIR="${HOMELAB_DIR}/certs"
REMOTE_TMP="/tmp/homelab-cert"
REMOTE_CERT_DIR="/etc/homelab-certs"

[[ $# -ge 1 ]] || { echo "Usage: $0 <tailscale-hostname> [receiver-script]"; exit 1; }
TARGET_HOST="$1"
RECEIVER="${2:-}"

for f in fullchain.pem key.pem; do
    [[ -f "${CERT_DIR}/${f}" ]] || die "Missing ${CERT_DIR}/${f}"
done

log_info "Deploying cert to ${TARGET_HOST} via Tailscale SSH..."

# Create temp dir on remote
ssh -o ConnectTimeout=5 -o BatchMode=yes "${TARGET_HOST}" "mkdir -p ${REMOTE_TMP}" \
    || die "Cannot SSH to ${TARGET_HOST}"

# Copy cert files
scp -q "${CERT_DIR}/fullchain.pem" "${CERT_DIR}/key.pem" "${TARGET_HOST}:${REMOTE_TMP}/" \
    || die "Failed to SCP cert files to ${TARGET_HOST}"

if [[ -n "${RECEIVER}" ]]; then
    # Run host-specific receiver script
    local_receiver="${HOMELAB_DIR}/${RECEIVER}"
    [[ -f "${local_receiver}" ]] || die "Receiver script not found: ${local_receiver}"

    scp -q "${local_receiver}" "${TARGET_HOST}:${REMOTE_TMP}/receiver.sh" \
        || die "Failed to SCP receiver script to ${TARGET_HOST}"

    ssh "${TARGET_HOST}" "chmod +x ${REMOTE_TMP}/receiver.sh && ${REMOTE_TMP}/receiver.sh ${REMOTE_TMP}" \
        || die "Receiver script failed on ${TARGET_HOST}"
else
    # Generic install: copy to standard location
    ssh "${TARGET_HOST}" "mkdir -p ${REMOTE_CERT_DIR} && \
        cp ${REMOTE_TMP}/fullchain.pem ${REMOTE_CERT_DIR}/fullchain.pem && \
        cp ${REMOTE_TMP}/key.pem ${REMOTE_CERT_DIR}/key.pem && \
        chmod 644 ${REMOTE_CERT_DIR}/fullchain.pem && \
        chmod 600 ${REMOTE_CERT_DIR}/key.pem" \
        || die "Failed to install certs on ${TARGET_HOST}"
fi

# Clean up
ssh "${TARGET_HOST}" "rm -rf ${REMOTE_TMP}"

log_info "Remote deploy to ${TARGET_HOST} complete"
