#!/usr/bin/env bash
# Deploy wildcard cert to a remote host via Tailscale SSH
#
# Usage: deploy-remote.sh <hostname> [receiver-script]
#
# Example:
#   deploy-remote.sh proxmox receivers/proxmox.sh
#
# This will:
#   1. SCP fullchain.pem and key.pem to /tmp/homelab-cert/ on the target
#   2. SCP and execute the receiver script (if provided) on the target
#   3. Clean up the temp dir on the target

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

CERT_DIR="${HOMELAB_DIR}/certs"
REMOTE_TMP="/tmp/homelab-cert"

usage() {
    echo "Usage: $0 <tailscale-hostname> [receiver-script]"
    echo "  receiver-script: path relative to homelab/ (e.g., receivers/proxmox.sh)"
    exit 1
}

[[ $# -ge 1 ]] || usage
TARGET_HOST="$1"
RECEIVER="${2:-}"

for f in fullchain.pem key.pem; do
    [[ -f "${CERT_DIR}/${f}" ]] || die "Missing ${CERT_DIR}/${f}"
done

log_info "Deploying cert to ${TARGET_HOST} via Tailscale SSH..."

# Create temp dir on remote
ssh "${TARGET_HOST}" "mkdir -p ${REMOTE_TMP}" \
    || die "Cannot SSH to ${TARGET_HOST}. Is Tailscale SSH enabled?"

# Copy cert files
scp -q "${CERT_DIR}/fullchain.pem" "${CERT_DIR}/key.pem" "${TARGET_HOST}:${REMOTE_TMP}/" \
    || die "Failed to SCP cert files to ${TARGET_HOST}"

# Run receiver script if specified
if [[ -n "${RECEIVER}" ]]; then
    local_receiver="${HOMELAB_DIR}/${RECEIVER}"
    [[ -f "${local_receiver}" ]] || die "Receiver script not found: ${local_receiver}"

    scp -q "${local_receiver}" "${TARGET_HOST}:${REMOTE_TMP}/receiver.sh" \
        || die "Failed to SCP receiver script to ${TARGET_HOST}"

    ssh "${TARGET_HOST}" "chmod +x ${REMOTE_TMP}/receiver.sh && ${REMOTE_TMP}/receiver.sh ${REMOTE_TMP}" \
        || die "Receiver script failed on ${TARGET_HOST}"
fi

# Clean up
ssh "${TARGET_HOST}" "rm -rf ${REMOTE_TMP}"

log_info "Remote deploy to ${TARGET_HOST} complete"
