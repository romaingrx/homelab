#!/usr/bin/env bash
# local-receiver
# TrueNAS Scale receiver: deploy wildcard cert via REST API
#
# This is a LOCAL receiver — it runs on the UDM and calls the TrueNAS API
# remotely, since TrueNAS has a read-only rootfs and SSH runs inside a
# container without access to the host middleware.
#
# Called by renew-and-distribute.sh (local receiver path).
# Requires: TRUENAS_API_KEY in .env
#
# API flow:
#   1. Import (or re-import) the certificate
#   2. Set it as the active UI certificate
#   3. Restart the web UI

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

load_secrets

CERT_DIR="${HOMELAB_DIR}/certs"
CERT_NAME="homelab_wildcard"
API_BASE="http://truenas/api/v2.0"
API_KEY="${TRUENAS_API_KEY:?Missing TRUENAS_API_KEY in .env}"

api() {
    local method="$1" endpoint="$2"; shift 2
    curl -fsSL -X "${method}" \
        -H "Authorization: Bearer ${API_KEY}" \
        -H "Content-Type: application/json" \
        "${API_BASE}${endpoint}" "$@"
}

log_info "Deploying cert to TrueNAS via API..."

# Read cert and key files
FULLCHAIN=$(cat "${CERT_DIR}/fullchain.pem")
PRIVKEY=$(cat "${CERT_DIR}/key.pem")

# Check if our named cert already exists
EXISTING_ID=$(api GET /certificate | \
    python3 -c "import sys,json; certs=json.load(sys.stdin); print(next((str(c['id']) for c in certs if c['name']=='${CERT_NAME}'), ''))")

if [[ -n "${EXISTING_ID}" ]]; then
    log_info "Found existing certificate (id=${EXISTING_ID}), replacing..."

    # Check if it's the active UI cert
    UI_CERT_ID=$(api GET /system/general | python3 -c "import sys,json; print(json.load(sys.stdin)['ui_certificate']['id'])")

    if [[ "${UI_CERT_ID}" == "${EXISTING_ID}" ]]; then
        # Switch to default cert before deleting
        DEFAULT_ID=$(api GET /certificate | \
            python3 -c "import sys,json; certs=json.load(sys.stdin); print(next((str(c['id']) for c in certs if c['name']=='truenas_default'), ''))")
        if [[ -n "${DEFAULT_ID}" ]]; then
            api PUT /system/general -d "{\"ui_certificate\": ${DEFAULT_ID}}" > /dev/null
        fi
    fi

    api DELETE "/certificate/id/${EXISTING_ID}" -d '{"force": true}' > /dev/null 2>&1 || true
    log_info "Deleted old certificate"
fi

# Build JSON payload with python to handle PEM newlines
PAYLOAD=$(python3 -c "
import json
cert = open('${CERT_DIR}/fullchain.pem').read()
key = open('${CERT_DIR}/key.pem').read()
print(json.dumps({
    'name': '${CERT_NAME}',
    'create_type': 'CERTIFICATE_CREATE_IMPORTED',
    'certificate': cert,
    'privatekey': key
}))
")

# Import certificate (API returns a job ID, wait then fetch cert by name)
log_info "Importing new certificate..."
JOB_ID=$(api POST /certificate -d "${PAYLOAD}")
log_info "Import job id=${JOB_ID}, waiting..."

# Poll job until complete
for i in $(seq 1 30); do
    JOB_STATE=$(api GET "/core/get_jobs?id=${JOB_ID}" | python3 -c "import sys,json; j=json.load(sys.stdin); print(j[0]['state'] if j else 'UNKNOWN')")
    if [[ "${JOB_STATE}" == "SUCCESS" ]]; then break; fi
    if [[ "${JOB_STATE}" == "FAILED" ]]; then die "Certificate import job failed"; fi
    sleep 1
done

NEW_CERT_ID=$(api GET /certificate | \
    python3 -c "import sys,json; certs=json.load(sys.stdin); print(next((str(c['id']) for c in certs if c['name']=='${CERT_NAME}'), ''))")
[[ -n "${NEW_CERT_ID}" ]] || die "Certificate not found after import"
log_info "Imported certificate id=${NEW_CERT_ID}"

# Set as active UI certificate
log_info "Setting as UI certificate..."
api PUT /system/general -d "{\"ui_certificate\": ${NEW_CERT_ID}}" > /dev/null

# Restart the web UI
log_info "Restarting web UI..."
api GET /system/general/ui_restart > /dev/null 2>&1 || true

log_info "TrueNAS cert deployed, web UI restarting"
