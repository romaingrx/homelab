#!/usr/bin/env bash
# Sync Tailscale device hostnames -> dnsmasq hosts file
# Each device gets: <hostname>.internal.romaingrx.com -> <tailscale-ipv4>
#
# Writes to a hosts file that dnsmasq reads. If the file changes,
# dnsmasq is sent SIGHUP to reload.

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "${SCRIPT_DIR}/config.sh"
# shellcheck source=../lib/tailscale.sh
source "${SCRIPT_DIR}/../lib/tailscale.sh"

load_secrets

HOSTS_FILE="${SCRIPT_DIR}/hosts"

log_info "=== DNS sync starting ==="

# 1. Fetch Tailscale devices
devices_json=$(ts_list_devices)
device_count=$(echo "${devices_json}" | jq 'length')
log_info "Found ${device_count} Tailscale devices"

if [[ "${device_count}" -eq 0 ]]; then
    log_warn "No Tailscale devices found. Aborting to avoid clearing all records."
    exit 1
fi

# 2. Generate new hosts file content
new_hosts=$(echo "${devices_json}" | jq -r '.[] | "\(.ipv4)\t\(.hostname).'"${DNS_SUFFIX}"'"' | sort)

# 3. Compare with existing file and update if changed
if [[ -f "${HOSTS_FILE}" ]] && [[ "$(cat "${HOSTS_FILE}")" == "${new_hosts}" ]]; then
    log_info "=== DNS sync complete: no changes ==="
    exit 0
fi

echo "${new_hosts}" > "${HOSTS_FILE}"
log_info "Updated ${HOSTS_FILE} with ${device_count} entries"

# 4. Reload dnsmasq if running
if pidof dnsmasq-homelab &>/dev/null || systemctl is-active --quiet homelab-dnsmasq 2>/dev/null; then
    # SIGHUP causes dnsmasq to re-read hosts files
    systemctl kill --signal=SIGHUP homelab-dnsmasq 2>/dev/null || true
    log_info "Sent SIGHUP to homelab-dnsmasq"
fi

log_info "=== DNS sync complete: ${device_count} records written ==="
