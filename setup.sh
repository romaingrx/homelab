#!/usr/bin/env bash
# One-time UDM bootstrap for homelab infrastructure
# Idempotent — safe to re-run.
#
# What it does:
#   1. Validates prerequisites (jq, curl, .env)
#   2. Installs acme.sh (if not present)
#   3. Registers acme.sh account with Let's Encrypt
#   4. Installs systemd timer units
#   5. Issues initial wildcard cert (if not present)
#   6. Runs initial DNS sync
#
# Usage: sudo ./setup.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

ACME_HOME="${HOMELAB_DIR}/.acme.sh"
SYSTEMD_DIR="/etc/systemd/system"

# --- Check root ---
[[ "$(id -u)" -eq 0 ]] || die "This script must be run as root"

# --- Check prerequisites ---
log_info "Checking prerequisites..."
require_cmd curl
require_cmd jq
require_cmd openssl
require_cmd ssh
require_cmd scp

# --- Validate .env ---
log_info "Validating .env..."
if [[ ! -f "${HOMELAB_DIR}/.env" ]]; then
    die ".env not found. Copy .env.example to .env and fill in your secrets:\n  cp ${HOMELAB_DIR}/.env.example ${HOMELAB_DIR}/.env"
fi
load_secrets
log_info ".env OK"

# --- Install acme.sh ---
if [[ ! -x "${ACME_HOME}/acme.sh" ]]; then
    log_info "Installing acme.sh..."
    local tmp_dir
    tmp_dir=$(mktemp -d)
    if ! curl -fsSL -o "${tmp_dir}/install.tar.gz" \
        "https://github.com/acmesh-official/acme.sh/archive/master.tar.gz"; then
        rm -rf "${tmp_dir}"
        die "Failed to download acme.sh"
    fi
    tar xzf "${tmp_dir}/install.tar.gz" -C "${tmp_dir}"
    cd "${tmp_dir}/acme.sh-master"
    if ! ./acme.sh --install \
        --home "${ACME_HOME}" \
        --nocron \
        --accountemail "${ACME_EMAIL:-}"; then
        cd /
        rm -rf "${tmp_dir}"
        die "acme.sh installation failed"
    fi
    cd /
    rm -rf "${tmp_dir}"
    log_info "acme.sh installed to ${ACME_HOME}"
else
    log_info "acme.sh already installed at ${ACME_HOME}"
    # Upgrade to latest
    "${ACME_HOME}/acme.sh" --upgrade --home "${ACME_HOME}" || true
fi

# --- Install systemd units ---
log_info "Installing systemd units..."
for unit in homelab-dns-sync.service homelab-dns-sync.timer homelab-cert-renew.service homelab-cert-renew.timer; do
    src="${HOMELAB_DIR}/systemd/${unit}"
    dest="${SYSTEMD_DIR}/${unit}"
    if [[ ! -f "${src}" ]]; then
        log_warn "Missing unit file: ${src}, skipping"
        continue
    fi
    cp "${src}" "${dest}"
    log_info "Installed ${unit}"
done

systemctl daemon-reload

# Enable and start timers
systemctl enable --now homelab-dns-sync.timer
systemctl enable --now homelab-cert-renew.timer
log_info "Systemd timers enabled and started"

# --- Make scripts executable ---
log_info "Setting script permissions..."
find "${HOMELAB_DIR}" -name '*.sh' -exec chmod +x {} \;

# --- Issue initial cert if needed ---
if [[ ! -f "${HOMELAB_DIR}/certs/fullchain.pem" ]]; then
    log_info "No existing cert found, issuing initial wildcard certificate..."
    "${HOMELAB_DIR}/certs/issue.sh"
else
    log_info "Certificate already exists, skipping initial issuance"
    log_info "  Subject: $(openssl x509 -in "${HOMELAB_DIR}/certs/fullchain.pem" -noout -subject 2>/dev/null || echo 'n/a')"
    log_info "  Expiry:  $(openssl x509 -in "${HOMELAB_DIR}/certs/fullchain.pem" -noout -enddate 2>/dev/null || echo 'n/a')"
fi

# --- Run initial DNS sync ---
log_info "Running initial DNS sync..."
"${HOMELAB_DIR}/dns-sync/sync.sh"

log_info "========================================="
log_info "  Setup complete!"
log_info "========================================="
log_info ""
log_info "Timers active:"
log_info "  systemctl list-timers 'homelab-*'"
log_info ""
log_info "Manual triggers:"
log_info "  systemctl start homelab-dns-sync    # sync DNS now"
log_info "  systemctl start homelab-cert-renew  # renew + distribute now"
log_info ""
log_info "Logs:"
log_info "  journalctl -u homelab-dns-sync -e"
log_info "  journalctl -u homelab-cert-renew -e"
