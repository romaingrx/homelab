#!/usr/bin/env bash
# Sync Tailscale device hostnames -> dnsmasq address records
# Each device gets: <hostname>.internal.romaingrx.com -> <tailscale-ipv4>
#
# Writes a dnsmasq config snippet with address= directives.
# If the file changes, dnsmasq is restarted to pick up the new config.

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "${SCRIPT_DIR}/config.sh"
# shellcheck source=../lib/tailscale.sh
source "${SCRIPT_DIR}/../lib/tailscale.sh"

load_secrets

RECORDS_FILE="${HOMELAB_DIR}/dns-sync/records.conf"

log_info "=== DNS sync starting ==="

# 1. Fetch Tailscale devices
devices_json=$(ts_list_devices)
device_count=$(echo "${devices_json}" | jq 'length')
log_info "Found ${device_count} Tailscale devices"

if [[ "${device_count}" -eq 0 ]]; then
    log_warn "No Tailscale devices found. Aborting to avoid clearing all records."
    exit 1
fi

# 2. Generate dnsmasq address= config
new_records=$(echo "${devices_json}" | jq -r '.[] | "address=/\(.hostname).'"${DNS_SUFFIX}"'/\(.ipv4)"' | sort)

# 3. Compare with existing file and update if changed
if [[ -f "${RECORDS_FILE}" ]] && [[ "$(cat "${RECORDS_FILE}")" == "${new_records}" ]]; then
    log_info "=== DNS sync complete: no changes ==="
    exit 0
fi

echo "${new_records}" > "${RECORDS_FILE}"
log_info "Updated ${RECORDS_FILE} with ${device_count} entries"

# 4. Restart dnsmasq to pick up new config (conf-file requires restart, not SIGHUP)
if systemctl is-active --quiet homelab-dnsmasq 2>/dev/null; then
    systemctl restart homelab-dnsmasq
    log_info "Restarted homelab-dnsmasq"
fi

log_info "=== DNS sync complete: ${device_count} records written ==="
