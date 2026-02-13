#!/usr/bin/env bash
# Home Assistant receiver: install cert and restart
#
# Called by deploy-remote.sh with: ./receiver.sh /tmp/homelab-cert
# TODO: implement when Home Assistant is set up

set -euo pipefail

CERT_SRC="${1:?Usage: $0 <cert-dir>}"

echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] Home Assistant cert deployment not yet implemented"

# Future implementation:
# cp "${CERT_SRC}/fullchain.pem" /config/ssl/fullchain.pem
# cp "${CERT_SRC}/key.pem"       /config/ssl/privkey.pem
# ha core restart
