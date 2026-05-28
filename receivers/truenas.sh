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
source "${SCRIPT_DIR}/../lib/tailscale.sh"

load_secrets

CERT_DIR="${HOMELAB_DIR}/certs"
CERT_NAME="homelab_wildcard"
API_KEY="${TRUENAS_API_KEY:?Missing TRUENAS_API_KEY in .env}"

# Target by Tailscale IP (the UDM can't resolve names); orchestrator sets TS_TARGET_IP.
TARGET_IP="${TS_TARGET_IP:-}"
if [[ -z "${TARGET_IP}" ]]; then
    TARGET_IP=$(ts_device_ip truenas)
fi
[[ -n "${TARGET_IP}" ]] || die "Could not determine TrueNAS Tailscale IP (device unknown/offline)"
API_BASE="http://${TARGET_IP}/api/v2.0"

api() {
    local method="$1" endpoint="$2"; shift 2
    curl -fsSL --connect-timeout 10 --max-time 120 -X "${method}" \
        -H "Authorization: Bearer ${API_KEY}" \
        -H "Content-Type: application/json" \
        "${API_BASE}${endpoint}" "$@"
}

# First certificate id matching a name, or empty.
cert_id_by_name() {
    api GET /certificate | jq -r --arg n "$1" 'first(.[] | select(.name == $n) | .id) // empty'
}

# Poll a middleware job until it leaves the running state. Returns non-zero on
# FAILED or timeout. Usage: wait_for_job <id> [tries]
wait_for_job() {
    local id="$1" tries="${2:-30}" state i
    for ((i = 0; i < tries; i++)); do
        state=$(api GET "/core/get_jobs?id=${id}" | jq -r 'first(.[].state) // "UNKNOWN"')
        case "${state}" in
            SUCCESS) return 0 ;;
            FAILED)  return 1 ;;
        esac
        sleep 1
    done
    return 1
}

log_info "Deploying cert to TrueNAS via API (${API_BASE})..."

EXISTING_ID=$(cert_id_by_name "${CERT_NAME}")
if [[ -n "${EXISTING_ID}" ]]; then
    log_info "Found existing certificate (id=${EXISTING_ID}), replacing..."

    # If it's the active UI cert, switch away before deleting
    UI_CERT_ID=$(api GET /system/general | jq -r '.ui_certificate.id')
    if [[ "${UI_CERT_ID}" == "${EXISTING_ID}" ]]; then
        DEFAULT_ID=$(cert_id_by_name truenas_default)
        if [[ -n "${DEFAULT_ID}" ]]; then
            api PUT /system/general -d "{\"ui_certificate\": ${DEFAULT_ID}}" > /dev/null
        fi
    fi

    DEL_JOB=$(api DELETE "/certificate/id/${EXISTING_ID}" -d 'true')
    wait_for_job "${DEL_JOB}" 15 || log_warn "Delete job did not succeed, continuing anyway"
    log_info "Deleted old certificate"
fi

# --rawfile reads each PEM into a JSON string with newlines encoded correctly
PAYLOAD=$(jq -n \
    --arg name "${CERT_NAME}" \
    --rawfile cert "${CERT_DIR}/fullchain.pem" \
    --rawfile key  "${CERT_DIR}/key.pem" \
    '{name: $name, create_type: "CERTIFICATE_CREATE_IMPORTED", certificate: $cert, privatekey: $key}')

log_info "Importing new certificate..."
JOB_ID=$(api POST /certificate -d "${PAYLOAD}")
log_info "Import job id=${JOB_ID}, waiting..."
wait_for_job "${JOB_ID}" 30 || die "Certificate import job failed"

NEW_CERT_ID=$(cert_id_by_name "${CERT_NAME}")
[[ -n "${NEW_CERT_ID}" ]] || die "Certificate not found after import"
log_info "Imported certificate id=${NEW_CERT_ID}"

# Set as active UI certificate
log_info "Setting as UI certificate..."
api PUT /system/general -d "{\"ui_certificate\": ${NEW_CERT_ID}}" > /dev/null

# Restart the web UI
log_info "Restarting web UI..."
api GET /system/general/ui_restart > /dev/null 2>&1 || true

log_info "TrueNAS cert deployed, web UI restarting"
