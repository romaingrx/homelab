#!/usr/bin/env bash
# Common utilities: logging, error handling, secrets loading

set -eo pipefail

HOMELAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="${HOMELAB_DIR}/logs"
mkdir -p "${LOG_DIR}"

# --- Logging ---

_log() {
    local level="$1"; shift
    printf '%s [%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "${level}" "$*" >&2
}

log_info()  { _log INFO  "$@"; }
log_warn()  { _log WARN  "$@"; }
log_error() { _log ERROR "$@"; }

die() {
    log_error "$@"
    exit 1
}

# --- Secrets ---

load_secrets() {
    local env_file="${HOMELAB_DIR}/.env"
    [[ -f "${env_file}" ]] || die ".env file not found at ${env_file}"

    local perms
    perms=$(stat -c '%a' "${env_file}" 2>/dev/null || stat -f '%Lp' "${env_file}")
    if [[ "${perms}" != "600" ]]; then
        log_warn ".env has permissions ${perms}, expected 600. Fixing..."
        chmod 600 "${env_file}"
    fi

    set -a
    # shellcheck source=/dev/null
    source "${env_file}"
    set +a

    local required=(TS_OAUTH_CLIENT_ID TS_OAUTH_CLIENT_SECRET CF_API_TOKEN CF_ZONE_ID)
    for var in "${required[@]}"; do
        [[ -n "${!var:-}" ]] || die "Missing required secret: ${var}"
    done
}

# --- HTTP helpers ---

# Portable curl wrapper with retries
http_get() {
    curl -fsSL --retry 3 --retry-delay 2 "$@"
}

http_post() {
    curl -fsSL --retry 3 --retry-delay 2 -X POST "$@"
}

http_put() {
    curl -fsSL --retry 3 --retry-delay 2 -X PUT "$@"
}

http_patch() {
    curl -fsSL --retry 3 --retry-delay 2 -X PATCH "$@"
}

http_delete() {
    curl -fsSL --retry 3 --retry-delay 2 -X DELETE "$@"
}

# --- Misc ---

require_cmd() {
    command -v "$1" &>/dev/null || die "Required command not found: $1"
}
