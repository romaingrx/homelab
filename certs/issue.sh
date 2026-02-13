#!/usr/bin/env bash
# First-time issuance of wildcard cert for *.internal.romaingrx.com
# Uses acme.sh with Cloudflare DNS-01 validation
#
# Run once during setup. Renewals are handled by renew-and-distribute.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

load_secrets

ACME_HOME="${HOMELAB_DIR}/.acme.sh"
DOMAIN="internal.romaingrx.com"
CERT_DIR="${HOMELAB_DIR}/certs"

require_cmd "${ACME_HOME}/acme.sh"
mkdir -p "${CERT_DIR}"

log_info "Issuing wildcard certificate for *.${DOMAIN}..."

# acme.sh uses CF_Token (not CF_API_TOKEN)
export CF_Token="${CF_API_TOKEN}"

"${ACME_HOME}/acme.sh" --issue \
    --dns dns_cf \
    --domain "${DOMAIN}" \
    --domain "*.${DOMAIN}" \
    --server letsencrypt \
    --keylength ec-256 \
    --home "${ACME_HOME}"

# Install cert to our certs/ directory
"${ACME_HOME}/acme.sh" --install-cert \
    --domain "${DOMAIN}" \
    --ecc \
    --cert-file      "${CERT_DIR}/cert.pem" \
    --key-file       "${CERT_DIR}/key.pem" \
    --fullchain-file "${CERT_DIR}/fullchain.pem" \
    --home "${ACME_HOME}"

log_info "Certificate issued and installed to ${CERT_DIR}/"
log_info "Subject: $(openssl x509 -in "${CERT_DIR}/fullchain.pem" -noout -subject 2>/dev/null || echo 'n/a')"
log_info "Expiry:  $(openssl x509 -in "${CERT_DIR}/fullchain.pem" -noout -enddate 2>/dev/null || echo 'n/a')"
