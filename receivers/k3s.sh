#!/usr/bin/env bash
# k3s receiver: update TLS secret for ingress controller
#
# Called by deploy-remote.sh with: ./receiver.sh /tmp/homelab-cert
# TODO: implement when k3s is set up

set -euo pipefail

CERT_SRC="${1:?Usage: $0 <cert-dir>}"

echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] k3s cert deployment not yet implemented"

# Future implementation:
# kubectl -n kube-system delete secret homelab-tls --ignore-not-found
# kubectl -n kube-system create secret tls homelab-tls \
#     --cert="${CERT_SRC}/fullchain.pem" \
#     --key="${CERT_SRC}/key.pem"
# kubectl -n kube-system rollout restart deployment/traefik
