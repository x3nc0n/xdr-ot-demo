#!/usr/bin/env bash
set -euo pipefail
timestamp="$(date --utc +%FT%TZ)"
correlation="$(cat /proc/sys/kernel/random/uuid)"
message="$(printf '{"timestamp":"%s","correlationId":"%s","scenario":"synthetic-only","state":"healthy"}' "$timestamp" "$correlation")"
printf '%s\n' "$message" > /var/lib/ot-lab/sample-state.json
logger --priority local0.info --tag OT-Lab -- "$message"
