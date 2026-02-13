#!/usr/bin/env bash
# DNS sync configuration

# Domain suffix appended to each Tailscale hostname
DNS_SUFFIX="internal.romaingrx.com"

# TTL for A records (seconds)
DNS_TTL=300

# Dry-run mode: set to "true" to preview changes without applying
DRY_RUN="${DRY_RUN:-false}"
