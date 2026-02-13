#!/usr/bin/env bash
# Tailscale API helpers — OAuth client flow (short-lived tokens)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

TS_API="https://api.tailscale.com"
TS_TOKEN_CACHE="${HOMELAB_DIR}/.ts_token"

# Obtain a short-lived access token via OAuth2 client credentials.
# Tokens last ~1 hour; we cache and reuse until expired.
ts_get_token() {
    # Check cached token
    if [[ -f "${TS_TOKEN_CACHE}" ]]; then
        local cached expires_at now
        cached=$(cat "${TS_TOKEN_CACHE}")
        expires_at=$(echo "${cached}" | jq -r '.expires_at // 0')
        now=$(date +%s)
        if (( expires_at > now + 60 )); then
            echo "${cached}" | jq -r '.access_token'
            return
        fi
    fi

    log_info "Requesting new Tailscale OAuth token..."
    local resp
    resp=$(http_post \
        -u "${TS_OAUTH_CLIENT_ID}:${TS_OAUTH_CLIENT_SECRET}" \
        -d "grant_type=client_credentials" \
        "${TS_API}/api/v2/oauth/token") || die "Failed to obtain Tailscale OAuth token"

    local access_token expires_in
    access_token=$(echo "${resp}" | jq -r '.access_token // empty')
    expires_in=$(echo "${resp}" | jq -r '.expires_in // 3600')
    [[ -n "${access_token}" ]] || die "Empty access_token in OAuth response"

    local expires_at
    expires_at=$(( $(date +%s) + expires_in ))

    # Cache with expiry
    printf '{"access_token":"%s","expires_at":%d}\n' "${access_token}" "${expires_at}" > "${TS_TOKEN_CACHE}"
    chmod 600 "${TS_TOKEN_CACHE}"

    echo "${access_token}"
}

# List all Tailscale devices. Returns JSON array of {hostname, addresses[]}.
ts_list_devices() {
    local token
    token=$(ts_get_token)

    local resp
    resp=$(http_get \
        -H "Authorization: Bearer ${token}" \
        "${TS_API}/api/v2/tailnet/-/devices?fields=default") || die "Failed to list Tailscale devices"

    echo "${resp}" | jq -c '[.devices[] | {
        hostname: (.hostname // .name | split(".")[0] | ascii_downcase),
        ipv4: ([.addresses[] | select(startswith("100."))] | first // empty),
        tags: (.tags // [])
    }] | map(select(.ipv4 != null))'
}
