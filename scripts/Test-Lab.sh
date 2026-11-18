#!/usr/bin/env bash
set -euo pipefail
if [[ $# -ne 1 || ! "$1" =~ ^http://[a-zA-Z0-9.-]+:3128$ ]]; then
  echo "Usage: sudo bash Test-Lab.sh http://PROXY-IP:3128" >&2
  exit 2
fi
proxy="$1"
failures=0
check() {
  local label="$1"; shift
  if "$@"; then printf 'PASS %s\n' "$label"; else printf 'FAIL %s\n' "$label"; failures=$((failures+1)); fi
}
not_running() { ! systemctl is-active --quiet "$1"; }
disabled() { [[ "$(systemctl is-enabled "$1" 2>/dev/null || true)" == "disabled" ]]; }
for unit in walinuxagent waagent; do
  if systemctl cat "$unit.service" >/dev/null 2>&1; then
    check "$unit stopped" not_running "$unit"
    check "$unit disabled" disabled "$unit"
  fi
done
check 'Arc service' systemctl is-active --quiet himds
check 'Arc connection' /opt/azcmagent/bin/azcmagent check
if command -v mdatp >/dev/null 2>&1; then
  check 'MDE real-time protection' bash -c '[[ "$(mdatp health --field real_time_protection_enabled)" == "true" ]]'
  mdatp health
  mdatp exclusion list
else
  echo 'FAIL MDE is not installed'; failures=$((failures+1))
fi
check 'approved proxy transport' curl --silent --show-error --output /dev/null --connect-timeout 5 --max-time 15 --proxy "$proxy" --noproxy '' https://login.microsoftonline.com/
if curl --silent --output /dev/null --connect-timeout 3 --max-time 8 --proxy "$proxy" --noproxy '' https://example.com/; then
  echo 'FAIL proxy allowed non-allowlisted destination'; failures=$((failures+1))
else echo 'PASS negative proxy probe (correlate Squid log)'; fi
if curl --silent --output /dev/null --connect-timeout 3 --max-time 8 --noproxy '*' https://example.com/; then
  echo 'FAIL direct Internet succeeded'; failures=$((failures+1))
else echo 'PASS negative direct probe (correlate NSG/firewall evidence)'; fi
echo 'Inspect persistent IMDS blocks, reboot, repeat, then verify tenant settings and Sentinel ingestion per runbook.'
[[ "$failures" -eq 0 ]]
