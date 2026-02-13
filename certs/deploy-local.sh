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

# Reload unifi-core to pick up new cert
if systemctl is-active --quiet unifi-core; then
    systemctl restart unifi-core
    log_info "Restarted unifi-core"
else
    log_warn "unifi-core is not running, skipping restart"
fi

log_info "Local deploy complete"
