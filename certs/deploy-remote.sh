#!/usr/bin/env bash
# Deploy wildcard cert to a remote host via Tailscale SSH
#
# Usage: deploy-remote.sh <tailscale-ip|host> [receiver-script]
#
# Prefer a Tailscale IP — the UDM cannot resolve bare MagicDNS names.
# Examples:
#   deploy-remote.sh 100.99.206.70 receivers/proxmox.sh  # host-specific receiver
#   deploy-remote.sh 100.67.170.31                       # generic: copies to /etc/homelab-certs/
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

[[ $# -ge 1 ]] || { echo "Usage: $0 <tailscale-ip|host> [receiver-script]"; exit 1; }
TARGET_HOST="$1"
RECEIVER="${2:-}"

for f in fullchain.pem key.pem; do
    [[ -f "${CERT_DIR}/${f}" ]] || die "Missing ${CERT_DIR}/${f}"
done

rsh()  { ssh "${SSH_OPTS[@]}" "${TARGET_HOST}" "$@"; }
push() { scp "${SSH_OPTS[@]}" -q "$@"; }

log_info "Deploying cert to ${TARGET_HOST} via Tailscale SSH..."

rsh "mkdir -p ${REMOTE_TMP}" || die "Cannot SSH to ${TARGET_HOST}"

# Tear down the remote temp dir on exit, even if a later step fails
trap 'rsh "rm -rf ${REMOTE_TMP}" 2>/dev/null || true' EXIT

push "${CERT_DIR}/fullchain.pem" "${CERT_DIR}/key.pem" "${TARGET_HOST}:${REMOTE_TMP}/" \
    || die "Failed to SCP cert files to ${TARGET_HOST}"

if [[ -n "${RECEIVER}" ]]; then
    local_receiver="${HOMELAB_DIR}/${RECEIVER}"
    [[ -f "${local_receiver}" ]] || die "Receiver script not found: ${local_receiver}"

    push "${local_receiver}" "${TARGET_HOST}:${REMOTE_TMP}/receiver.sh" \
        || die "Failed to SCP receiver script to ${TARGET_HOST}"

    rsh "chmod +x ${REMOTE_TMP}/receiver.sh && ${REMOTE_TMP}/receiver.sh ${REMOTE_TMP}" \
        || die "Receiver script failed on ${TARGET_HOST}"
else
    rsh "mkdir -p ${REMOTE_CERT_DIR} && \
        cp ${REMOTE_TMP}/fullchain.pem ${REMOTE_CERT_DIR}/fullchain.pem && \
        cp ${REMOTE_TMP}/key.pem ${REMOTE_CERT_DIR}/key.pem && \
        chmod 644 ${REMOTE_CERT_DIR}/fullchain.pem && \
        chmod 600 ${REMOTE_CERT_DIR}/key.pem" \
        || die "Failed to install certs on ${TARGET_HOST}"
fi

log_info "Remote deploy to ${TARGET_HOST} complete"
