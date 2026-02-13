#!/usr/bin/env bash
# Sync Tailscale device hostnames -> Cloudflare A records
# Each device gets: <hostname>.internal.romaingrx.com -> <tailscale-ipv4>
#
# Convergence logic:
#   - Device exists, no record       -> CREATE
#   - Device exists, record stale IP  -> UPDATE
#   - Record exists, no device        -> DELETE
#   - Record matches device           -> SKIP (no-op)

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "${SCRIPT_DIR}/config.sh"
# shellcheck source=../lib/tailscale.sh
source "${SCRIPT_DIR}/../lib/tailscale.sh"
# shellcheck source=../lib/cloudflare.sh
source "${SCRIPT_DIR}/../lib/cloudflare.sh"

load_secrets

log_info "=== DNS sync starting ==="

# 1. Fetch Tailscale devices -> associative array: hostname -> ipv4
declare -A desired_records
devices_json=$(ts_list_devices)
while IFS= read -r entry; do
    hostname=$(echo "${entry}" | jq -r '.hostname')
    ipv4=$(echo "${entry}" | jq -r '.ipv4')
    fqdn="${hostname}.${DNS_SUFFIX}"
    desired_records["${fqdn}"]="${ipv4}"
done < <(echo "${devices_json}" | jq -c '.[]')

log_info "Found ${#desired_records[@]} Tailscale devices"

if [[ ${#desired_records[@]} -eq 0 ]]; then
    log_warn "No Tailscale devices found — this would delete ALL DNS records. Aborting."
    exit 1
fi

# 2. Fetch existing Cloudflare A records -> associative arrays
declare -A existing_ips     # fqdn -> ip
declare -A existing_ids     # fqdn -> record_id
records_json=$(cf_list_a_records "${DNS_SUFFIX}")
while IFS= read -r entry; do
    name=$(echo "${entry}" | jq -r '.name')
    content=$(echo "${entry}" | jq -r '.content')
    id=$(echo "${entry}" | jq -r '.id')
    existing_ips["${name}"]="${content}"
    existing_ids["${name}"]="${id}"
done < <(echo "${records_json}" | jq -c '.[]')

log_info "Found ${#existing_ips[@]} existing A records under *.${DNS_SUFFIX}"

# 3. Converge: create/update desired records
created=0
updated=0
unchanged=0

for fqdn in "${!desired_records[@]}"; do
    desired_ip="${desired_records[${fqdn}]}"

    if [[ -z "${existing_ips[${fqdn}]:-}" ]]; then
        # No record exists -> create
        if [[ "${DRY_RUN}" == "true" ]]; then
            log_info "[dry-run] Would CREATE ${fqdn} -> ${desired_ip}"
        else
            cf_create_a_record "${fqdn}" "${desired_ip}" "${DNS_TTL}"
        fi
        (( created++ ))
    elif [[ "${existing_ips[${fqdn}]}" != "${desired_ip}" ]]; then
        # Record exists with wrong IP -> update
        if [[ "${DRY_RUN}" == "true" ]]; then
            log_info "[dry-run] Would UPDATE ${fqdn}: ${existing_ips[${fqdn}]} -> ${desired_ip}"
        else
            cf_update_a_record "${existing_ids[${fqdn}]}" "${fqdn}" "${desired_ip}" "${DNS_TTL}"
        fi
        (( updated++ ))
    else
        (( unchanged++ ))
    fi
done

# 4. Converge: delete orphaned records (exist in CF but not in Tailscale)
deleted=0
for fqdn in "${!existing_ips[@]}"; do
    # Skip the bare domain record (internal.romaingrx.com) — managed by cert issuance
    [[ "${fqdn}" != "${DNS_SUFFIX}" ]] || continue

    if [[ -z "${desired_records[${fqdn}]:-}" ]]; then
        if [[ "${DRY_RUN}" == "true" ]]; then
            log_info "[dry-run] Would DELETE orphan ${fqdn} (${existing_ips[${fqdn}]})"
        else
            cf_delete_a_record "${existing_ids[${fqdn}]}" "${fqdn}"
        fi
        (( deleted++ ))
    fi
done

log_info "=== DNS sync complete: ${created} created, ${updated} updated, ${deleted} deleted, ${unchanged} unchanged ==="
