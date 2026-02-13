#!/usr/bin/env bash
# Cloudflare DNS API helpers — scoped API token

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

CF_API="https://api.cloudflare.com/client/v4"

# List all A records under a given name suffix.
# Usage: cf_list_a_records "internal.romaingrx.com"
# Returns: JSON array of {id, name, content(ip), ttl}
cf_list_a_records() {
    local suffix="$1"
    local page=1 per_page=100
    local all_records="[]"

    while true; do
        local resp
        resp=$(http_get \
            -H "Authorization: Bearer ${CF_API_TOKEN}" \
            -H "Content-Type: application/json" \
            "${CF_API}/zones/${CF_ZONE_ID}/dns_records?type=A&per_page=${per_page}&page=${page}&name=contains:${suffix}") \
            || die "Failed to list Cloudflare DNS records (page ${page})"

        local records
        records=$(echo "${resp}" | jq -c '[.result[] | select(.name | endswith("'"${suffix}"'")) | {id, name, content, ttl, proxied}]')

        all_records=$(echo "${all_records}" "${records}" | jq -sc '.[0] + .[1]')

        local total_pages
        total_pages=$(echo "${resp}" | jq '.result_info.total_pages // 1')
        (( page < total_pages )) || break
        (( page++ ))
    done

    echo "${all_records}"
}

# Create an A record.
# Usage: cf_create_a_record "proxmox.internal.romaingrx.com" "100.99.206.70" 300
cf_create_a_record() {
    local name="$1" ip="$2" ttl="${3:-300}"

    local resp
    resp=$(http_post \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$(jq -nc --arg n "${name}" --arg c "${ip}" --argjson t "${ttl}" \
            '{type:"A", name:$n, content:$c, ttl:$t, proxied:false}')" \
        "${CF_API}/zones/${CF_ZONE_ID}/dns_records") || die "Failed to create A record for ${name}"

    local success
    success=$(echo "${resp}" | jq -r '.success')
    [[ "${success}" == "true" ]] || die "Cloudflare API error creating ${name}: $(echo "${resp}" | jq -c '.errors')"

    log_info "Created A record: ${name} -> ${ip}"
}

# Update an existing A record.
# Usage: cf_update_a_record "record_id" "proxmox.internal.romaingrx.com" "100.99.206.70" 300
cf_update_a_record() {
    local record_id="$1" name="$2" ip="$3" ttl="${4:-300}"

    local resp
    resp=$(http_patch \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$(jq -nc --arg c "${ip}" --argjson t "${ttl}" \
            '{content:$c, ttl:$t, proxied:false}')" \
        "${CF_API}/zones/${CF_ZONE_ID}/dns_records/${record_id}") || die "Failed to update A record ${name}"

    local success
    success=$(echo "${resp}" | jq -r '.success')
    [[ "${success}" == "true" ]] || die "Cloudflare API error updating ${name}: $(echo "${resp}" | jq -c '.errors')"

    log_info "Updated A record: ${name} -> ${ip}"
}

# Delete an A record.
# Usage: cf_delete_a_record "record_id" "name (for logging)"
cf_delete_a_record() {
    local record_id="$1" name="${2:-unknown}"

    local resp
    resp=$(http_delete \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" \
        "${CF_API}/zones/${CF_ZONE_ID}/dns_records/${record_id}") || die "Failed to delete A record ${name}"

    local success
    success=$(echo "${resp}" | jq -r '.success')
    [[ "${success}" == "true" ]] || die "Cloudflare API error deleting ${name}: $(echo "${resp}" | jq -c '.errors')"

    log_info "Deleted A record: ${name}"
}
