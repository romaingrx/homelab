#!/usr/bin/env bash
# Deploy wildcard cert to the local UDM (unifi-core / nginx)
#
# UniFi OS uses:
#   /data/unifi-core/config/unifi-core.crt  (fullchain)
#   /data/unifi-core/config/unifi-core.key  (private key)
# After copying, reload the UniFi web service.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

CERT_DIR="${HOMELAB_DIR}/certs"
UNIFI_CERT_DIR="/data/unifi-core/config"

for f in fullchain.pem key.pem; do
    [[ -f "${CERT_DIR}/${f}" ]] || die "Missing ${CERT_DIR}/${f}"
done

log_info "Deploying cert to local unifi-core..."

cp "${CERT_DIR}/fullchain.pem" "${UNIFI_CERT_DIR}/unifi-core.crt"
cp "${CERT_DIR}/key.pem"       "${UNIFI_CERT_DIR}/unifi-core.key"
chmod 600 "${UNIFI_CERT_DIR}/unifi-core.key"

# Reload nginx to pick up new cert (do NOT restart unifi-core — it regenerates its own cert)
nginx -s reload
log_info "Reloaded nginx"

log_info "Local deploy complete"
