#!/usr/bin/env bash
# TrueNAS Scale receiver: install wildcard cert for web UI
#
# Called by deploy-remote.sh with: ./receiver.sh /tmp/homelab-cert
#
# Uses midclt API to:
#   1. Import (or re-import) the certificate
#   2. Set it as the active UI certificate
#   3. Restart the web UI to pick up changes

set -euo pipefail

CERT_SRC="${1:?Usage: $0 <cert-dir>}"
CERT_NAME="homelab_wildcard"
MIDCLT="midclt"
export PATH="/usr/sbin:/sbin:${PATH}"

echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] Installing cert to TrueNAS..."

# Read cert and key
FULLCHAIN=$(cat "${CERT_SRC}/fullchain.pem")
PRIVKEY=$(cat "${CERT_SRC}/key.pem")

# Check if our named cert already exists
EXISTING_ID=$($MIDCLT call certificate.query | \
    python3 -c "import sys,json; certs=json.load(sys.stdin); print(next((c['id'] for c in certs if c['name']=='${CERT_NAME}'), ''))")

if [[ -n "${EXISTING_ID}" ]]; then
    echo "  Updating existing certificate (id=${EXISTING_ID})..."
    # Delete and recreate (TrueNAS doesn't support updating cert contents)
    # First check if it's the active UI cert
    UI_CERT_ID=$($MIDCLT call system.general.config | python3 -c "import sys,json; print(json.load(sys.stdin)['ui_certificate']['id'])")

    if [[ "${UI_CERT_ID}" == "${EXISTING_ID}" ]]; then
        # Switch UI back to default before deleting
        DEFAULT_ID=$($MIDCLT call certificate.query | \
            python3 -c "import sys,json; certs=json.load(sys.stdin); print(next((c['id'] for c in certs if c['name']=='truenas_default'), ''))")
        if [[ -n "${DEFAULT_ID}" ]]; then
            $MIDCLT call system.general.update "{\"ui_certificate\": ${DEFAULT_ID}}" > /dev/null
        fi
    fi

    $MIDCLT call certificate.delete "${EXISTING_ID}" > /dev/null 2>&1 || true
    echo "  Deleted old certificate"
fi

# Build JSON payload with python to handle PEM escaping
PAYLOAD=$(python3 -c "
import json, sys
cert = open('${CERT_SRC}/fullchain.pem').read()
key = open('${CERT_SRC}/key.pem').read()
print(json.dumps({
    'name': '${CERT_NAME}',
    'create_type': 'CERTIFICATE_CREATE_IMPORTED',
    'certificate': cert,
    'privatekey': key
}))
")

# Import certificate
echo "  Importing new certificate..."
JOB_ID=$($MIDCLT call certificate.create "${PAYLOAD}")
echo "  Import job: ${JOB_ID}"

# Wait for the job to complete
$MIDCLT call core.job_wait "${JOB_ID}" > /dev/null 2>&1 || true

# Get the new certificate ID
NEW_CERT_ID=$($MIDCLT call certificate.query | \
    python3 -c "import sys,json; certs=json.load(sys.stdin); print(next((c['id'] for c in certs if c['name']=='${CERT_NAME}'), ''))")

if [[ -z "${NEW_CERT_ID}" ]]; then
    echo "ERROR: Certificate import failed — cert not found after import"
    exit 1
fi

echo "  New certificate id: ${NEW_CERT_ID}"

# Set as active UI certificate
echo "  Setting as UI certificate..."
$MIDCLT call system.general.update "{\"ui_certificate\": ${NEW_CERT_ID}}" > /dev/null

# Restart the web UI
echo "  Restarting web UI..."
$MIDCLT call system.general.ui_restart > /dev/null 2>&1 || true

echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] TrueNAS cert deployed, web UI restarting"
